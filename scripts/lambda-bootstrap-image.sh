#!/usr/bin/env bash
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
REPO_URL="${1:?uso: lambda-bootstrap-image.sh <ecr_repository_url> [tag]}"
TAG="${2:-bootstrap}"
BASE_IMAGE="public.ecr.aws/lambda/java:21"

REGISTRY="${REPO_URL%%/*}"
REPO_NAME="${REPO_URL#*/}"

log() { echo ">> $*"; }

if aws ecr describe-images --region "$REGION" \
     --repository-name "$REPO_NAME" --image-ids "imageTag=$TAG" >/dev/null 2>&1; then
  log "Imagem $REPO_URL:$TAG ja existe. Seed ignorado."
  exit 0
fi

log "Login no ECR privado ($REGISTRY)..."
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY"

log "Login no ECR publico (para puxar a base)..."
aws ecr-public get-login-password --region us-east-1 \
  | docker login --username AWS --password-stdin public.ecr.aws || true

log "Puxando base $BASE_IMAGE..."
docker pull "$BASE_IMAGE"

log "Publicando placeholder em $REPO_URL:$TAG..."
docker tag "$BASE_IMAGE" "$REPO_URL:$TAG"
docker push "$REPO_URL:$TAG"

log "Seed concluido."
