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

# Configuracao de banco e orcamento de pool vem do repositorio service-track-db-infra,
# publicados no SSM. Materializados aqui como ConfigMap para que a aplicacao os
# consuma sem que o numero seja repetido em dois repositorios.
JDBC="$(fetch db/jdbc-url || true)"
POOL_API="$(fetch db/pool/api-max-size || true)"
POOL_MIG="$(fetch db/pool/api-migration-max-size || true)"

if [ -n "$JDBC" ]; then
  kubectl create configmap service-track-db -n "$NAMESPACE" \
    --from-literal=DB_JDBC_URL="$JDBC" \
    --from-literal=DB_POOL_MAX_SIZE="${POOL_API:-8}" \
    --from-literal=DB_POOL_MIGRATION_MAX_SIZE="${POOL_MIG:-2}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  echo ">> configmap service-track-db aplicado (pool: ${POOL_API:-8} + ${POOL_MIG:-2} por pod)"
else
  echo "!! $PREFIX/db/jdbc-url ausente: aplique primeiro o repositorio service-track-db-infra" >&2
fi

BASE_URL="$(fetch api/base-url || true)"
SEGREDO="$(fetch gateway/shared-secret || true)"

if [ -n "$BASE_URL" ]; then
  kubectl create configmap service-track-runtime -n "$NAMESPACE" \
    --from-literal=SERVICETRACK_API_BASE_URL="$BASE_URL" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  echo ">> configmap service-track-runtime aplicado (base-url: $BASE_URL)"
else
  echo "!! $PREFIX/api/base-url ausente: os links de aprovacao por e-mail ficarao invalidos" >&2
fi

if [ -n "$SEGREDO" ]; then
  kubectl create secret generic service-track-gateway -n "$NAMESPACE" \
    --from-literal=SERVICETRACK_GATEWAY_SEGREDO="$SEGREDO" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  echo ">> secret service-track-gateway aplicado"
else
  echo "!! $PREFIX/gateway/shared-secret ausente: a aplicacao aceitara requisicao fora do gateway" >&2
fi

echo ">> secrets sincronizados do SSM ($PREFIX)"
