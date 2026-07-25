#!/usr/bin/env bash
#
# Aplica o AppProject e o app-of-apps do ServiceTrack no cluster, apos o ArgoCD
# estar instalado. E o unico "empurrao" imperativo: dai em diante o proprio Argo
# sincroniza as Applications a partir do git (GitOps).
#
# Chamado pelo Terraform (modules/stack, null_resource) no apply. Idempotente.
#
# Uso: scripts/argocd-bootstrap-apply.sh <cluster_name> <region>
set -euo pipefail

CLUSTER="${1:?cluster_name}"
REGION="${2:?region}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARGOCD_DIR="$REPO_ROOT/kubernetes/argocd"

for bin in aws kubectl; do
  command -v "$bin" >/dev/null || { echo "$bin nao encontrado no PATH" >&2; exit 1; }
done

# Kubeconfig isolado, para nao mexer no ~/.kube/config de quem roda.
KUBECONFIG_FILE="$(mktemp)"
trap 'rm -f "$KUBECONFIG_FILE"' EXIT
export KUBECONFIG="$KUBECONFIG_FILE"

aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" >/dev/null

# O ArgoCD instala os CRDs junto com o release, mas a API pode levar alguns
# segundos para registra-los. Espera o CRD do AppProject aparecer.
echo ">> aguardando CRDs do ArgoCD..."
for _ in $(seq 1 30); do
  if kubectl get crd appprojects.argoproj.io >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
kubectl get crd appprojects.argoproj.io >/dev/null 2>&1 || {
  echo "CRDs do ArgoCD nao registraram a tempo" >&2
  exit 1
}

echo ">> aplicando AppProject e app-of-apps..."
kubectl apply -f "$ARGOCD_DIR/projects/service-track.appproject.yaml"
kubectl apply -f "$ARGOCD_DIR/root-app.yaml"

echo ">> ok: o Argo assume o deploy da aplicacao a partir daqui."
