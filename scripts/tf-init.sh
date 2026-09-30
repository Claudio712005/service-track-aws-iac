#!/usr/bin/env bash
set -euo pipefail

CAMADA="${1:-}"
AMBIENTE="${2:-}"

uso() {
  echo "uso: scripts/tf-init.sh <rede|stack> <hml|prd> [argumentos extra do init]" >&2
  exit 1
}

case "$CAMADA" in
  rede)  DIRETORIO="iac/network/$AMBIENTE" ;;
  stack) DIRETORIO="iac/environments/$AMBIENTE" ;;
  *)     uso ;;
esac

case "$AMBIENTE" in
  hml|prd) ;;
  *) uso ;;
esac

shift 2

CONTA="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="servicetrack-tfstate-${CONTA}"

echo ">> conta $CONTA, backend s3://$BUCKET"

terraform -chdir="$DIRETORIO" init -input=false -backend-config="bucket=$BUCKET" "$@"
