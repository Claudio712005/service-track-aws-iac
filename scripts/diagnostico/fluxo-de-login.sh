#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/comum.sh"
exigir_credenciais

CPF_CLIENTE="${CPF_CLIENTE:-13646633093}"
CPF_MECANICO="${CPF_MECANICO:-98124421030}"
SENHA="${SENHA:-Senha@123}"

URL="$(url_da_api)"
KEY="$(chave_de_api web)"
[ -z "$URL" ] && { erro "URL da API ausente"; exit 1; }
[ -z "$KEY" ] && { erro "chave de API ausente"; exit 1; }

echo "Fluxo de login em $AMBIENTE -> $URL"

autenticar() {
  local cpf="$1" corpo
  for _ in $(seq 1 10); do
    corpo="$(curl -s --max-time 25 -X POST "$URL/autenticacao" \
      -H "x-api-key: $KEY" -H 'Content-Type: application/json' \
      -d "{\"cpf\":\"$cpf\",\"senha\":\"$SENHA\"}")"
    printf '%s' "$corpo" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("token",""))' 2>/dev/null && return
    sleep 2
  done
}

secao "Autenticacao"
TC="$(autenticar "$CPF_CLIENTE")"
TM="$(autenticar "$CPF_MECANICO")"
[ -n "$TC" ] && ok "cliente ($CPF_CLIENTE): token de ${#TC} chars" || erro "cliente nao autenticou"
[ -n "$TM" ] && ok "mecanico ($CPF_MECANICO): token de ${#TM} chars" || erro "mecanico nao autenticou"

if [ -n "$TC" ]; then
  ISS="$(printf '%s' "$TC" | cut -d. -f2 | tr '_-' '/+' | python3 -c '
import sys, base64, json
d = sys.stdin.read().strip(); d += "=" * (-len(d) % 4)
print(json.loads(base64.b64decode(d))["iss"])' 2>/dev/null)"
  echo "  issuer emitido: $ISS"
  [ "$ISS" = "service-track-api" ] || erro "issuer diverge do que a aplicacao verifica; toda rota respondera 401"
fi

chamar() {
  local rota="$1" token="$2" c
  for _ in $(seq 1 6); do
    c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 25 \
      -H "x-api-key: $KEY" -H "Authorization: Bearer $token" "$URL$rota")"
    [ "$c" != "403" ] && break; sleep 2
  done
  printf '%s' "$c"
}

secao "Rotas de cliente"
for r in /veiculos /catalogo/servicos /catalogo/insumos /ordem-servico/lista /notificacoes; do
  c="$(chamar "$r" "$TC")"
  [ "$c" = "200" ] && ok "$r" || erro "$r -> $c"
done

secao "Rotas de mecanico"
for r in /servicos /insumos /mecanicos; do
  c="$(chamar "$r" "$TM")"
  [ "$c" = "200" ] && ok "$r" || erro "$r -> $c"
done
echo
