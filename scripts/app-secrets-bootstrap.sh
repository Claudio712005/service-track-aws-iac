#!/usr/bin/env bash
set -euo pipefail

CLUSTER="${1:?cluster_name}"
REGION="${2:?region}"
PREFIX="${3:?ssm_name_prefix}"
NAMESPACE="service-track"

for bin in aws kubectl; do
  command -v "$bin" >/dev/null || { echo "$bin nao encontrado no PATH" >&2; exit 1; }
done

KUBECONFIG_FILE="$(mktemp)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$KUBECONFIG_FILE" "$WORKDIR"' EXIT
export KUBECONFIG="$KUBECONFIG_FILE"

aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" >/dev/null
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

fetch() {
  aws ssm get-parameter --name "$PREFIX/$1" --with-decryption \
    --query Parameter.Value --output text 2>/dev/null
}

apply_secret() {
  kubectl create secret generic "$1" -n "$NAMESPACE" "${@:2}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  echo ">> secret $1 aplicado"
}

if v="$(fetch service-track-secret)"; then
  printf '%s' "$v" > "$WORKDIR/app.env"
  apply_secret service-track-secret --from-env-file="$WORKDIR/app.env"
fi

if v="$(fetch db-init-creds)"; then
  printf '%s' "$v" > "$WORKDIR/db.env"
  apply_secret db-init-creds --from-env-file="$WORKDIR/db.env"
fi

priv="$(fetch jwt-private || true)"
pub="$(fetch jwt-public || true)"
if [ -n "$priv" ] && [ -n "$pub" ]; then
  printf '%s' "$priv" > "$WORKDIR/privateKey.pem"
  printf '%s' "$pub" > "$WORKDIR/publicKey.pem"
  apply_secret service-track-jwt \
    --from-file=privateKey.pem="$WORKDIR/privateKey.pem" \
    --from-file=publicKey.pem="$WORKDIR/publicKey.pem"
fi

echo ">> secrets sincronizados do SSM ($PREFIX)"
