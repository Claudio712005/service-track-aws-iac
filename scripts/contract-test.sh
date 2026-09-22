#!/usr/bin/env bash
set -uo pipefail

BASE_URL="${1:-${API_BASE_URL:-}}"
API_KEY="${2:-${API_KEY:-}}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPEC="$REPO_ROOT/apis/service-track-api-ext/openApi.yaml"

if [ -z "$BASE_URL" ] || [ -z "$API_KEY" ]; then
  echo "uso: scripts/contract-test.sh <base_url> <api_key>" >&2
  exit 2
fi

BASE_URL="${BASE_URL%/}"
PASS=0
FAIL=0

pass() { printf '  ok      %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FALHOU  %s -- %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }

status() { curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$@"; }

expect_status() {
  local name="$1" want="$2"; shift 2
  local got tentativas="${ASSERCAO_TENTATIVAS:-8}" i
  for i in $(seq 1 "$tentativas"); do
    got="$(status "$@")"
    [ "$got" = "$want" ] && { pass "$name"; return; }
    [ "$got" != "403" ] && break
    [ "$want" = "403" ] && break
    sleep 2
  done
  if [ "$got" = "$want" ]; then pass "$name"; else fail "$name" "esperava $want, veio $got"; fi
}

expect_not_status() {
  local name="$1" unwanted="$2"; shift 2
  local got; got="$(status "$@")"
  if [ "$got" != "$unwanted" ]; then pass "$name"; else fail "$name" "nao deveria ser $unwanted"; fi
}

echo "contract test -> $BASE_URL"

esperar_chave_valer() {
  local tentativas="${API_KEY_ESPERA_TENTATIVAS:-20}" i got
  for i in $(seq 1 "$tentativas"); do
    got="$(status -X POST "$BASE_URL/autenticacao" \
      -H "x-api-key: $API_KEY" -H 'Content-Type: application/json' \
      --data '{}')"
    if [ "$got" != "403" ]; then
      [ "$i" -gt 1 ] && echo "  chave valendo apos ${i} tentativa(s)"
      return 0
    fi
    sleep 6
  done
  echo "  AVISO: a chave de API ainda responde 403 apos $((tentativas * 6))s." >&2
  echo "         As asserções que dependem dela vao falhar." >&2
  return 1
}

esperar_chave_valer || true

preflight="$(curl -s -i -X OPTIONS --max-time 20 \
  -H 'Origin: https://exemplo.test' \
  -H 'Access-Control-Request-Method: POST' \
  "$BASE_URL/autenticacao" 2>/dev/null || true)"

if printf '%s' "$preflight" | head -1 | grep -q ' 200'; then
  pass "preflight OPTIONS /autenticacao responde 200"
else
  fail "preflight OPTIONS /autenticacao responde 200" "$(printf '%s' "$preflight" | head -1)"
fi

if printf '%s' "$preflight" | grep -qi '^access-control-allow-origin:'; then
  pass "preflight devolve Access-Control-Allow-Origin"
else
  fail "preflight devolve Access-Control-Allow-Origin" "header ausente"
fi

if printf '%s' "$preflight" | grep -qi '^access-control-allow-methods:'; then
  pass "preflight devolve Access-Control-Allow-Methods"
else
  fail "preflight devolve Access-Control-Allow-Methods" "header ausente"
fi

expect_status "POST /autenticacao sem x-api-key devolve 403" 403 \
  -X POST -H 'Content-Type: application/json' -d '{}' "$BASE_URL/autenticacao"

expect_status "x-api-key invalida devolve 403" 403 \
  -X POST -H "x-api-key: chave-invalida-para-teste" -H 'Content-Type: application/json' \
  -d '{}' "$BASE_URL/autenticacao"

if curl -s -i --max-time 20 -X POST -H 'Origin: https://exemplo.test' \
     -H 'Content-Type: application/json' -d '{}' "$BASE_URL/autenticacao" \
   | grep -qi '^access-control-allow-origin:'; then
  pass "403 do gateway carrega headers de CORS"
else
  fail "403 do gateway carrega headers de CORS" "header ausente na resposta de erro"
fi

expect_status "body vazio em POST /autenticacao devolve 400" 400 \
  -X POST -H "x-api-key: $API_KEY" -H 'Content-Type: application/json' \
  -d '{}' "$BASE_URL/autenticacao"

expect_status "CPF fora do padrao devolve 400" 400 \
  -X POST -H "x-api-key: $API_KEY" -H 'Content-Type: application/json' \
  -d '{"cpf":"abc","senha":"12345678"}' "$BASE_URL/autenticacao"

expect_status "rota inexistente devolve 403" 403 \
  -H "x-api-key: $API_KEY" "$BASE_URL/rota-que-nao-existe"

if [ -n "${REST_API_ID:-}" ] && [ -n "${STAGE_NAME:-}" ] && command -v aws >/dev/null 2>&1; then
  exported="$(mktemp)"
  if aws apigateway get-export --rest-api-id "$REST_API_ID" --stage-name "$STAGE_NAME" \
       --export-type oas30 --accepts application/json "$exported" >/dev/null 2>&1; then
    deployed="$(jq -r '.paths | keys[]' "$exported" | sort)"
    declared="$(grep -Eo '^  (/[^:]*):' "$SPEC" | sed 's/^  //; s/:$//' | sort)"
    if [ "$deployed" = "$declared" ]; then
      pass "rotas publicadas conferem com o contrato ($(printf '%s\n' "$declared" | wc -l | tr -d ' ') paths)"
    else
      fail "rotas publicadas conferem com o contrato" \
        "diff:\n$(diff <(printf '%s\n' "$declared") <(printf '%s\n' "$deployed") || true)"
    fi
  else
    echo "  aviso   get-export indisponivel; drift nao verificado"
  fi
  rm -f "$exported"
else
  echo "  aviso   REST_API_ID/STAGE_NAME nao informados; drift nao verificado"
fi

echo
echo "$PASS passaram, $FAIL falharam"
[ "$FAIL" -eq 0 ]
