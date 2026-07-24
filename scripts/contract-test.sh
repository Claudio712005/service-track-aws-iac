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
UUID="550e8400-e29b-41d4-a716-446655440000"
PASS=0
FAIL=0

pass() { printf '  ok      %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FALHOU  %s -- %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }

status() { curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$@"; }

expect_status() {
  local name="$1" want="$2"; shift 2
  local got; got="$(status "$@")"
  if [ "$got" = "$want" ]; then pass "$name"; else fail "$name" "esperava $want, veio $got"; fi
}

expect_not_status() {
  local name="$1" unwanted="$2"; shift 2
  local got; got="$(status "$@")"
  if [ "$got" != "$unwanted" ]; then pass "$name"; else fail "$name" "nao deveria ser $unwanted"; fi
}

echo "contract test -> $BASE_URL"

preflight="$(curl -s -i -X OPTIONS --max-time 20 \
  -H 'Origin: https://exemplo.test' \
  -H 'Access-Control-Request-Method: GET' \
  "$BASE_URL/clientes" 2>/dev/null || true)"

if printf '%s' "$preflight" | head -1 | grep -q ' 200'; then
  pass "preflight OPTIONS /clientes responde 200"
else
  fail "preflight OPTIONS /clientes responde 200" "$(printf '%s' "$preflight" | head -1)"
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

expect_status "rota protegida sem x-api-key devolve 403" 403 \
  "$BASE_URL/clientes/$UUID"

expect_status "x-api-key invalida devolve 403" 403 \
  -H "x-api-key: chave-invalida-para-teste" "$BASE_URL/clientes/$UUID"

if curl -s -i --max-time 20 -H 'Origin: https://exemplo.test' "$BASE_URL/clientes/$UUID" \
   | grep -qi '^access-control-allow-origin:'; then
  pass "403 do gateway carrega headers de CORS"
else
  fail "403 do gateway carrega headers de CORS" "header ausente na resposta de erro"
fi

expect_status "body invalido em POST /clientes devolve 400" 400 \
  -X POST -H "x-api-key: $API_KEY" -H 'Content-Type: application/json' \
  -d '{"nome":"x"}' "$BASE_URL/clientes"

expect_status "body vazio em POST /autenticacao devolve 400" 400 \
  -X POST -H "x-api-key: $API_KEY" -H 'Content-Type: application/json' \
  -d '{}' "$BASE_URL/autenticacao"

expect_status "query param obrigatorio ausente devolve 400" 400 \
  -H "x-api-key: $API_KEY" "$BASE_URL/veiculos/imagens/sugestoes"

expect_status "rota inexistente devolve 403" 403 \
  -H "x-api-key: $API_KEY" "$BASE_URL/rota-que-nao-existe"

expect_not_status "magic link de orcamento nao exige API key" 403 \
  "$BASE_URL/ordem-servico/orcamento/aprovacao?token=teste"

if [ "${EXPECT_AUTHORIZER:-false}" = "true" ]; then
  expect_status "authorizer rejeita ausencia de Bearer com 401" 401 \
    -H "x-api-key: $API_KEY" "$BASE_URL/clientes/$UUID"

  expect_status "authorizer rejeita token invalido com 401" 401 \
    -H "x-api-key: $API_KEY" -H 'Authorization: Bearer token.invalido.aqui' \
    "$BASE_URL/clientes/$UUID"
fi

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
