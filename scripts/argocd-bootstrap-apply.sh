#!/usr/bin/env bash
set -euo pipefail

CLUSTER="${1:?cluster_name}"
REGION="${2:?region}"
ENVIRONMENT="${3:?environment}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARGOCD_DIR="$REPO_ROOT/kubernetes/argocd"
APP_FILE="$ARGOCD_DIR/applications/service-track-${ENVIRONMENT}.application.yaml"

for bin in aws kubectl; do
  command -v "$bin" >/dev/null || { echo "$bin nao encontrado no PATH" >&2; exit 1; }
done

[ -f "$APP_FILE" ] || { echo "Application nao encontrada: $APP_FILE" >&2; exit 1; }

KUBECONFIG_FILE="$(mktemp)"
trap 'rm -f "$KUBECONFIG_FILE"' EXIT
export KUBECONFIG="$KUBECONFIG_FILE"

aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" >/dev/null

echo ">> aguardando CRDs do ArgoCD..."
for _ in $(seq 1 30); do
  kubectl get crd appprojects.argoproj.io >/dev/null 2>&1 && break
  sleep 5
done
kubectl get crd appprojects.argoproj.io >/dev/null 2>&1 || {
  echo "CRDs do ArgoCD nao registraram a tempo" >&2
  exit 1
}

echo ">> aplicando AppProject e Application de ${ENVIRONMENT}..."
kubectl apply -f "$ARGOCD_DIR/projects/service-track.appproject.yaml"
kubectl apply -f "$APP_FILE"

echo ">> ok: o Argo assume o deploy da aplicacao (${ENVIRONMENT}) a partir daqui."
