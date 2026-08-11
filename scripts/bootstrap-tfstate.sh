#!/usr/bin/env bash
set -euo pipefail

REGIAO="${AWS_REGION:-us-east-1}"
ESPERADO="821146464895"

log() { echo ">> $*"; }
erro() { echo "!! $*" >&2; }

command -v aws >/dev/null || { erro "aws cli nao encontrado no PATH"; exit 1; }

CONTA="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="servicetrack-tfstate-${CONTA}"

log "conta AWS atual: $CONTA"

if [ "$CONTA" != "$ESPERADO" ]; then
  erro "a conta mudou: o codigo referencia $ESPERADO e voce esta em $CONTA."
  erro "o nome do bucket esta fixado nos dois repositorios. Atualize antes de aplicar:"
  erro ""
  erro "  cd .. && grep -rl 'servicetrack-tfstate-${ESPERADO}' \\"
  erro "    service-track-aws-iac service-track-db-infra --include='*.tf' --include='*.yml' \\"
  erro "    | xargs sed -i '' 's/servicetrack-tfstate-${ESPERADO}/servicetrack-tfstate-${CONTA}/g'"
  erro ""
  erro "Depois atualize ESPERADO neste script e commite as duas mudancas."
  exit 1
fi

if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  log "bucket $BUCKET ja existe."
else
  log "criando $BUCKET em $REGIAO..."
  if [ "$REGIAO" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGIAO" >/dev/null
  else
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGIAO" \
      --create-bucket-configuration "LocationConstraint=$REGIAO" >/dev/null
  fi
fi

log "habilitando versionamento..."
aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled

log "habilitando criptografia em repouso..."
aws s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'

log "bloqueando acesso publico..."
aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

log "pronto. Backend disponivel em s3://$BUCKET"
log "este bucket sobrevive ao destroy dos ambientes. Nao remover."
