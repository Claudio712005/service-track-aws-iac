#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/comum.sh"
exigir_credenciais

CONSUMIDOR="${CONSUMIDOR:-${2:-web}}"
URL="$(url_da_api)"
CHAVE="$(chave_de_api "$CONSUMIDOR")"

if [ -z "$CHAVE" ]; then
  erro "chave '$CONSUMIDOR' nao encontrada em $AMBIENTE"
  echo "        consumidores: web, mobile, ci" >&2
  exit 1
fi

if [ "${FORMATO:-tabela}" = "exportar" ]; then
  echo "export SERVICETRACK_URL='$URL'"
  echo "export SERVICETRACK_KEY='$CHAVE'"
  exit 0
fi

echo "$AMBIENTE / $CONSUMIDOR"
echo "  url:   $URL"
echo "  chave: $CHAVE"
echo
echo "Login:"
echo "  curl -s -X POST \"$URL/autenticacao\" \\"
echo "    -H 'x-api-key: $CHAVE' -H 'Content-Type: application/json' \\"
echo "    -d '{\"cpf\":\"13646633093\",\"senha\":\"Senha@123\"}'"
echo
echo "Para exportar no shell:  FORMATO=exportar $0 $AMBIENTE $CONSUMIDOR"
