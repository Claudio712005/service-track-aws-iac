#!/usr/bin/env bash
set -euo pipefail

CLUSTER="${1:?cluster_name}"
REGION="${2:?region}"
ENVIRONMENT="${3:?environment}"
OWNER="${GITHUB_OWNER:-Claudio712005}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARGOCD_DIR="$REPO_ROOT/kubernetes/argocd"
TEMPLATE="$ARGOCD_DIR/templates/application.yaml"

for bin in aws kubectl curl python3; do
  command -v "$bin" >/dev/null || { echo "$bin nao encontrado no PATH" >&2; exit 1; }
done

[ -f "$TEMPLATE" ] || { echo "Template de Application nao encontrado: $TEMPLATE" >&2; exit 1; }

REPOS_FILE=""
KUBECONFIG_FILE="$(mktemp)"
trap 'rm -f "$KUBECONFIG_FILE" "$REPOS_FILE"' EXIT
export KUBECONFIG="$KUBECONFIG_FILE"

aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" >/dev/null

echo ">> aguardando CRDs do ArgoCD..."
for _ in $(seq 1 30); do
  kubectl get crd appprojects.argoproj.io >/dev/null 2>&1 && break
  sleep 5
done
kubectl get crd appprojects.argoproj.io >/dev/null 2>&1 || {
  echo "CRD appprojects.argoproj.io nao registrou a tempo" >&2
  exit 1
}

echo ">> aplicando AppProject..."
kubectl apply -f "$ARGOCD_DIR/projects/service-track.appproject.yaml"

echo ">> descobrindo microsservicos com k8s/argocd/${ENVIRONMENT}.yaml..."

REPOS_FILE="$(mktemp)"
curl -s "https://api.github.com/users/${OWNER}/repos?per_page=100" \
  | python3 -c "
import json, sys
for r in json.load(sys.stdin):
    print(r['name'])
" > "$REPOS_FILE"

ENCONTRADOS=0
while IFS= read -r REPO; do
  [ -z "$REPO" ] && continue
  CODE="$(curl -s -o /dev/null -w '%{http_code}' \
    "https://raw.githubusercontent.com/${OWNER}/${REPO}/main/k8s/argocd/${ENVIRONMENT}.yaml")"
  [ "$CODE" != "200" ] && continue

  ENCONTRADOS=$((ENCONTRADOS + 1))
  echo "   + ${REPO}"

  sed -e "s/__REPO__/${REPO}/g" \
      -e "s/__ENV__/${ENVIRONMENT}/g" \
      -e "s/__OWNER__/${OWNER}/g" \
      "$TEMPLATE" | kubectl apply -f -
done < "$REPOS_FILE"

if [ "$ENCONTRADOS" -eq 0 ]; then
  echo "   nenhum microsservico com k8s/argocd/${ENVIRONMENT}.yaml encontrado."
fi

echo ">> ok: ${ENCONTRADOS} microsservico(s) sincronizado(s) para ${ENVIRONMENT}."
echo ">> repositorio novo com k8s/argocd/${ENVIRONMENT}.yaml entra na proxima"
echo ">> execucao desta esteira, sem editar este repositorio."
