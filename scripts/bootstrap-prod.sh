#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$ROOT_DIR/infra/terraform"
K8S_DIR="$ROOT_DIR/infra/k8s"
NS="service-track"

# Perfil AWS opcional (local usa aws-student; na pipeline vem vazio).
: "${AWS_PROFILE=aws-student}"
aws_profile_arg=()
if [ -z "$AWS_PROFILE" ]; then unset AWS_PROFILE; else export AWS_PROFILE; aws_profile_arg=(--profile "$AWS_PROFILE"); fi

tf() { terraform -chdir="$TF_DIR" "$@"; }
tf init -input=false -reconfigure >/dev/null

echo ">> Lendo outputs do Terraform..."
CLUSTER_NAME="$(tf output -raw cluster_name)"
REGION="$(tf output -raw region)"
RDS_JDBC_URL="$(tf output -raw rds_jdbc_url)"
RDS_USERNAME="$(tf output -raw db_username)"
RDS_PASSWORD="$(tf output -raw db_password)"

: "${APP_DB_PASSWORD:?defina APP_DB_PASSWORD (senha do role app_user)}"
: "${FLYWAY_DB_PASSWORD:?defina FLYWAY_DB_PASSWORD (senha do role flyway_user)}"
: "${RESEND_API_KEY:?defina RESEND_API_KEY (chave de API do Resend)}"
: "${JWT_PRIVATE_KEY_B64:?defina JWT_PRIVATE_KEY_B64 (privateKey.pem em base64)}"
: "${JWT_PUBLIC_KEY_B64:?defina JWT_PUBLIC_KEY_B64 (publicKey.pem em base64)}"
APP_DB_USER="${APP_DB_USER:-app_user}"
FLYWAY_DB_USER="${FLYWAY_DB_USER:-flyway_user}"
UNSPLASH_CHAVE_ACESSO="${UNSPLASH_CHAVE_ACESSO:-local-placeholder}"

RDS_HOST="$(echo "$RDS_JDBC_URL" | sed -E 's#^jdbc:postgresql://([^:/]+).*#\1#')"
RDS_PORT="$(echo "$RDS_JDBC_URL" | sed -E 's#^jdbc:postgresql://[^:/]+:([0-9]+).*#\1#')"
RDS_DB="$(echo "$RDS_JDBC_URL" | sed -E 's#.*/([^/?]+)(\?.*)?$#\1#')"

echo ">> Configurando kubeconfig ($CLUSTER_NAME / $REGION)..."
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" "${aws_profile_arg[@]}"

kubectl apply -f "$K8S_DIR/base/namespace.yaml"

echo ">> Secret das chaves JWT (service-track-jwt)..."
JWT_TMP="$(mktemp -d)"; trap 'rm -rf "$JWT_TMP"' EXIT
echo "$JWT_PRIVATE_KEY_B64" | base64 -d > "$JWT_TMP/privateKey.pem"
echo "$JWT_PUBLIC_KEY_B64"  | base64 -d > "$JWT_TMP/publicKey.pem"
kubectl -n "$NS" create secret generic service-track-jwt \
  --from-file=privateKey.pem="$JWT_TMP/privateKey.pem" \
  --from-file=publicKey.pem="$JWT_TMP/publicKey.pem" \
  --dry-run=client -o yaml | kubectl apply -f -

echo ">> Secret da aplicacao (service-track-secret)..."
kubectl -n "$NS" create secret generic service-track-secret \
  --from-literal=APP_DB_USER="$APP_DB_USER" \
  --from-literal=APP_DB_PASSWORD="$APP_DB_PASSWORD" \
  --from-literal=FLYWAY_DB_USER="$FLYWAY_DB_USER" \
  --from-literal=FLYWAY_DB_PASSWORD="$FLYWAY_DB_PASSWORD" \
  --from-literal=UNSPLASH_CHAVE_ACESSO="$UNSPLASH_CHAVE_ACESSO" \
  --from-literal=RESEND_API_KEY="$RESEND_API_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

echo ">> Provisionando roles no RDS (flyway_user / app_user)..."
kubectl -n "$NS" create configmap db-init-script \
  --from-file=01-init-roles.sh="$ROOT_DIR/software/service-track-api/scripts/postgres-init/01-init-roles.sh" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$NS" create secret generic db-init-creds \
  --from-literal=PGHOST="$RDS_HOST" \
  --from-literal=PGPORT="${RDS_PORT:-5432}" \
  --from-literal=PGUSER="$RDS_USERNAME" \
  --from-literal=PGPASSWORD="$RDS_PASSWORD" \
  --from-literal=PGDATABASE="${RDS_DB:-servicetrack}" \
  --from-literal=FLYWAY_DB_USER="$FLYWAY_DB_USER" \
  --from-literal=FLYWAY_DB_PASSWORD="$FLYWAY_DB_PASSWORD" \
  --from-literal=APP_DB_USER="$APP_DB_USER" \
  --from-literal=APP_DB_PASSWORD="$APP_DB_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$NS" delete job service-track-db-init --ignore-not-found
kubectl apply -f "$K8S_DIR/db-init-job.yaml"
kubectl -n "$NS" wait --for=condition=complete job/service-track-db-init --timeout=180s

echo ">> LoadBalancer do app (capturando hostname publico)..."
kubectl -n "$NS" apply -f "$K8S_DIR/overlays/prod/service-lb.yaml"
API_HOST=""
for i in $(seq 1 30); do
  API_HOST="$(kubectl -n "$NS" get svc service-track-app-lb \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  [ -n "$API_HOST" ] && break
  echo "   aguardando hostname do LoadBalancer... ($i/30)"; sleep 10
done
[ -z "$API_HOST" ] && echo "!! Hostname do LoadBalancer indisponivel; magic links de e-mail podem ficar invalidos." >&2

echo ">> ConfigMap de runtime (service-track-runtime)..."
kubectl -n "$NS" create configmap service-track-runtime \
  --from-literal=DB_JDBC_URL="$RDS_JDBC_URL" \
  --from-literal=SERVICETRACK_API_BASE_URL="http://${API_HOST}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo ">> Registrando AppProject e Application no ArgoCD..."
kubectl apply -f "$ROOT_DIR/infra/argocd/projects/service-track.appproject.yaml"
kubectl apply -f "$ROOT_DIR/infra/argocd/applications/service-track-prod.application.yaml"

echo ">> Capturando URL do ArgoCD..."
ARGO_HOST=""
for i in $(seq 1 30); do
  ARGO_HOST="$(kubectl -n argocd get svc argocd-server \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  [ -n "$ARGO_HOST" ] && break
  echo "   aguardando hostname do LoadBalancer do ArgoCD... ($i/30)"; sleep 10
done
if [ -n "$ARGO_HOST" ]; then
  ARGO_URL="http://${ARGO_HOST}"
else
  ARGO_URL="(LB nao pronto — use: kubectl -n argocd port-forward svc/argocd-server 8081:443)"
fi
ARGO_PASS="$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"

echo ""
echo ">> OK."
echo ">> API publica:   http://${API_HOST}"
echo ">> ArgoCD URL:     ${ARGO_URL}"
echo ">> ArgoCD login:   admin / ${ARGO_PASS:-<rode: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d>}"
echo ">> O ArgoCD sincroniza o app automaticamente a partir de infra/k8s/overlays/prod (branch main)."
echo ">> Acompanhe: kubectl -n argocd get applications  |  kubectl -n $NS get pods,svc,hpa"

# Resumo bonito no GitHub Actions (quando rodando na pipeline).
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "## ServiceTrack — Bootstrap prod"
    echo ""
    echo "| Item | Valor |"
    echo "|---|---|"
    echo "| API publica | http://${API_HOST} |"
    echo "| ArgoCD URL | ${ARGO_URL} |"
    echo "| ArgoCD login | admin / ${ARGO_PASS:-ver secret argocd-initial-admin-secret} |"
    echo "| Swagger | http://${API_HOST}/q/swagger-ui |"
  } >> "$GITHUB_STEP_SUMMARY"
fi
