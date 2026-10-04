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
RESPOSTA_FILE=""
KUBECONFIG_FILE="$(mktemp)"
trap 'rm -f "$KUBECONFIG_FILE" "$REPOS_FILE" "$RESPOSTA_FILE"' EXIT
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

definir_senha_do_admin() {
  if [ -z "${ARGOCD_ADMIN_PASSWORD:-}" ]; then
    echo ">> ARGOCD_ADMIN_PASSWORD ausente: o Argo segue com a senha gerada no bootstrap."
    echo ">> leia com: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
    return 0
  fi

  local hash=""
  if command -v htpasswd >/dev/null 2>&1; then
    hash="$(htpasswd -bnBC 10 "" "$ARGOCD_ADMIN_PASSWORD" | tr -d ':\n')"
  elif command -v docker >/dev/null 2>&1; then
    hash="$(docker run --rm httpd:2-alpine htpasswd -bnBC 10 "" "$ARGOCD_ADMIN_PASSWORD" | tr -d ':\n')"
  fi

  if [ -z "$hash" ]; then
    echo ">> AVISO: sem htpasswd e sem docker para gerar o hash bcrypt; senha do Argo nao alterada." >&2
    return 0
  fi

  echo ">> definindo a senha do admin do ArgoCD a partir do segredo da esteira..."
  kubectl -n argocd patch secret argocd-secret --type merge \
    -p "{\"stringData\":{\"admin.password\":\"$hash\",\"admin.passwordMtime\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}}" >/dev/null

  kubectl -n argocd delete secret argocd-initial-admin-secret --ignore-not-found >/dev/null
  kubectl -n argocd rollout restart deploy/argocd-server >/dev/null
  kubectl -n argocd rollout status deploy/argocd-server --timeout=180s >/dev/null || \
    echo ">> AVISO: argocd-server nao reportou pronto em 3 minutos." >&2
  echo ">> senha do admin definida; o segredo inicial foi removido."
}

echo ">> aplicando AppProject..."
kubectl apply -f "$ARGOCD_DIR/projects/service-track.appproject.yaml"

echo ">> descobrindo microsservicos com k8s/argocd/${ENVIRONMENT}.yaml..."

REPOS_FILE="$(mktemp)"
RESPOSTA_FILE="$(mktemp)"

TOKEN="${OPS_TOKEN:-${GITHUB_TOKEN:-${GH_TOKEN:-}}}"
CABECALHOS=(-H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")
if [ -n "$TOKEN" ]; then
  CABECALHOS+=(-H "Authorization: Bearer $TOKEN")
else
  echo ">> AVISO: sem token do GitHub. A API limita a 60 chamadas por hora por IP," >&2
  echo ">>        e o IP de um runner do Actions e compartilhado: o limite estoura facil." >&2
fi

curl -sS "${CABECALHOS[@]}" \
  "https://api.github.com/users/${OWNER}/repos?per_page=100" > "$RESPOSTA_FILE"

python3 - "$RESPOSTA_FILE" > "$REPOS_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as arquivo:
    try:
        dados = json.load(arquivo)
    except json.JSONDecodeError as erro:
        sys.exit(f"A API do GitHub nao respondeu JSON: {erro}")

if isinstance(dados, dict):
    sys.exit(
        "A API do GitHub respondeu com erro em vez da lista de repositorios: "
        + dados.get("message", str(dados))
    )

for repositorio in dados:
    print(repositorio["name"])
PY

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

definir_senha_do_admin
