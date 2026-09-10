#!/usr/bin/env bash
set -uo pipefail

AMBIENTE="${AMBIENTE:-${1:-hml}}"
REGIAO="${AWS_REGION:-us-east-1}"
PROJETO=servicetrack
CLUSTER="$PROJETO-$AMBIENTE"

case "$AMBIENTE" in
  hml|prd) ;;
  *) echo "ambiente invalido: $AMBIENTE (use hml ou prd)" >&2; exit 2 ;;
esac

ok()    { printf '  \033[32mok\033[0m      %s\n' "$1"; }
alerta(){ printf '  \033[33maviso\033[0m   %s\n' "$1"; }
erro()  { printf '  \033[31mfalha\033[0m   %s\n' "$1"; }
secao() { printf '\n\033[1m%s\033[0m\n' "$1"; }

exigir_credenciais() {
  if ! aws sts get-caller-identity >/dev/null 2>&1; then
    erro "credenciais AWS invalidas ou expiradas"
    echo "        renove o laboratorio e atualize o perfil, ou exporte AWS_PROFILE" >&2
    exit 1
  fi
}

url_da_api() {
  aws ssm get-parameter --name "/$PROJETO/$AMBIENTE/api/base-url" \
    --region "$REGIAO" --query Parameter.Value --output text 2>/dev/null
}

chave_de_api() {
  local consumidor="${1:-web}" id
  id="$(aws apigateway get-api-keys --region "$REGIAO" \
    --query "items[?name=='$PROJETO-$AMBIENTE-$consumidor'].id" --output text 2>/dev/null)"
  [ -z "$id" ] && return 1
  aws apigateway get-api-key --api-key "$id" --include-value \
    --region "$REGIAO" --query value --output text 2>/dev/null
}

conectar_cluster() {
  aws eks update-kubeconfig --name "$CLUSTER" --region "$REGIAO" >/dev/null 2>&1
}
