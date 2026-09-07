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

apply_configmap() {
  kubectl create configmap "$1" -n "$NAMESPACE" "${@:2}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  echo ">> configmap $1 aplicado"
}

DB_MASTER_USER="$(fetch db/username || true)"
DB_MASTER_PASS="$(fetch db/password || true)"
DB_NOME="$(fetch db/name || true)"
APP_USER="$(fetch db/roles/app/usuario || true)"
APP_PASS="$(fetch db/roles/app/senha || true)"
FLYWAY_USER="$(fetch db/roles/flyway/usuario || true)"
FLYWAY_PASS="$(fetch db/roles/flyway/senha || true)"
READONLY_USER="$(fetch db/roles/readonly/usuario || true)"
READONLY_PASS="$(fetch db/roles/readonly/senha || true)"

if [ -z "$APP_PASS" ] || [ -z "$FLYWAY_PASS" ]; then
  echo "!! credenciais de role ausentes em $PREFIX/db/roles/" >&2
  echo "!! aplique antes o repositorio service-track-db-infra para este ambiente" >&2
  exit 1
fi

UNSPLASH="$(fetch unsplash-access-key || true)"
RESEND="$(fetch resend-api-key || true)"

cat > "$WORKDIR/app.env" <<EOF
APP_DB_USER=$APP_USER
APP_DB_PASSWORD=$APP_PASS
FLYWAY_DB_USER=$FLYWAY_USER
FLYWAY_DB_PASSWORD=$FLYWAY_PASS
UNSPLASH_CHAVE_ACESSO=$UNSPLASH
RESEND_API_KEY=$RESEND
EOF
apply_secret service-track-secret --from-env-file="$WORKDIR/app.env"

DB_HOST="$(fetch db/endpoint || true)"
DB_PORTA="$(fetch db/port || true)"

cat > "$WORKDIR/db-init.env" <<EOF
POSTGRES_HOST=$DB_HOST
POSTGRES_PORT=${DB_PORTA:-5432}
POSTGRES_USER=$DB_MASTER_USER
POSTGRES_PASSWORD=$DB_MASTER_PASS
POSTGRES_DB=$DB_NOME
APP_DB_USER=$APP_USER
APP_DB_PASSWORD=$APP_PASS
FLYWAY_DB_USER=$FLYWAY_USER
FLYWAY_DB_PASSWORD=$FLYWAY_PASS
READONLY_DB_USER=$READONLY_USER
READONLY_DB_PASSWORD=$READONLY_PASS
EOF
apply_secret db-init-creds --from-env-file="$WORKDIR/db-init.env"

priv="$(fetch jwt-private || true)"
pub="$(fetch jwt-public || true)"
if [ -n "$priv" ] && [ -n "$pub" ]; then
  printf '%s' "$priv" > "$WORKDIR/privateKey.pem"
  printf '%s' "$pub" > "$WORKDIR/publicKey.pem"
  apply_secret service-track-jwt \
    --from-file=privateKey.pem="$WORKDIR/privateKey.pem" \
    --from-file=publicKey.pem="$WORKDIR/publicKey.pem"
else
  echo "!! par RS256 ausente em $PREFIX/jwt-: a aplicacao nao validara token" >&2
fi

JDBC="$(fetch db/jdbc-url || true)"
POOL_API="$(fetch db/pool/api-max-size || true)"
POOL_MIG="$(fetch db/pool/api-migration-max-size || true)"

if [ -n "$JDBC" ]; then
  apply_configmap service-track-db \
    --from-literal=DB_JDBC_URL="$JDBC" \
    --from-literal=DB_POOL_MAX_SIZE="${POOL_API:-8}" \
    --from-literal=DB_POOL_MIGRATION_MAX_SIZE="${POOL_MIG:-2}"
fi

BASE_URL="$(fetch api/base-url || true)"
if [ -n "$BASE_URL" ]; then
  apply_configmap service-track-runtime --from-literal=SERVICETRACK_API_BASE_URL="$BASE_URL"
else
  echo "!! $PREFIX/api/base-url ausente: os links de aprovacao por e-mail ficarao invalidos" >&2
fi

SEGREDO="$(fetch gateway/shared-secret || true)"
if [ -n "$SEGREDO" ]; then
  apply_secret service-track-gateway --from-literal=SERVICETRACK_GATEWAY_SEGREDO="$SEGREDO"
else
  echo "!! $PREFIX/gateway/shared-secret ausente: a aplicacao aceitara requisicao fora do gateway" >&2
fi

echo ">> configuracao sincronizada do SSM ($PREFIX)"
