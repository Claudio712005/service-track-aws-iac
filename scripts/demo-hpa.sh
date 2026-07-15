#!/usr/bin/env bash

set -euo pipefail

API_URL="${API_URL:?defina API_URL (ex.: http://xxx.elb.amazonaws.com)}"
EMAIL="${EMAIL:?defina EMAIL do usuario de teste}"
SENHA="${SENHA:?defina SENHA do usuario de teste}"
DURACAO="${1:-180}"
CONC="${2:-60}"
ALVO="$API_URL/catalogo/servicos"

echo ">> Login (1 chamada — rate limit do login e 20/min)..."
TOKEN="$(curl -sf -X POST "$API_URL/autenticacao" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"senha\":\"$SENHA\"}" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["token"])')"
[ -n "$TOKEN" ] || { echo "!! Falha no login"; exit 1; }
echo "   token obtido."

echo ""
echo ">> Em OUTRO terminal, deixe rodando para acompanhar o scale:"
echo "   watch -n2 'kubectl -n service-track get hpa,pods'"
echo ""
echo ">> Gerando carga: $CONC conexoes por ${DURACAO}s em $ALVO"

if command -v hey >/dev/null 2>&1; then
  hey -z "${DURACAO}s" -c "$CONC" -H "Authorization: Bearer $TOKEN" "$ALVO"
else
  echo "   (hey nao encontrado — fallback com curl em loop; instale com: brew install hey)"
  END=$(( $(date +%s) + DURACAO ))
  while [ "$(date +%s)" -lt "$END" ]; do
    for _ in $(seq 1 "$CONC"); do
      curl -s -o /dev/null -H "Authorization: Bearer $TOKEN" "$ALVO" &
    done
    wait
  done
fi

echo ""
echo ">> Carga encerrada. O HPA reduz de volta ao minimo (~5 min de estabilizacao)."
echo "   Acompanhe: kubectl -n service-track get hpa -w"
