#!/usr/bin/env bash
set -euo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$RAIZ/scripts/diagnostico/comum.sh"

CONSUMIDOR="${2:-${CONSUMIDOR:-web}}"
MODELO="$RAIZ/docs/postman/servicetrack.postman_collection.json"
SAIDA="${SAIDA:-$RAIZ/docs/postman/servicetrack-$AMBIENTE.gerado.postman_collection.json}"

command -v python3 >/dev/null || { erro "python3 nao encontrado"; exit 1; }
[ -f "$MODELO" ] || { erro "collection modelo ausente: $MODELO"; exit 1; }
exigir_credenciais

URL="$(url_da_api || true)"
if [ -z "$URL" ] || [ "$URL" = "None" ]; then
  erro "a URL da API de $AMBIENTE nao esta no SSM (/$PROJETO/$AMBIENTE/api/base-url). O ambiente esta de pe?"
  exit 1
fi

if ! CHAVE="$(chave_de_api "$CONSUMIDOR")" || [ -z "$CHAVE" ]; then
  erro "chave do consumidor '$CONSUMIDOR' nao encontrada em $AMBIENTE (use web, mobile ou ci)"
  exit 1
fi

MODELO="$MODELO" SAIDA="$SAIDA" URL="$URL" CHAVE="$CHAVE" AMBIENTE="$AMBIENTE" python3 -I - <<'PY'
import json
import os

colecao = json.load(open(os.environ["MODELO"], encoding="utf-8"))
preenchidas = {"baseUrl": os.environ["URL"], "apiKey": os.environ["CHAVE"]}
for variavel in colecao["variable"]:
    if variavel["key"] in preenchidas:
        variavel["value"] = preenchidas[variavel["key"]]
colecao["info"]["name"] += f" ({os.environ['AMBIENTE']})"
colecao["info"]["_postman_id"] += "-" + os.environ["AMBIENTE"]
with open(os.environ["SAIDA"], "w", encoding="utf-8") as arquivo:
    json.dump(colecao, arquivo, ensure_ascii=False, indent=2)
    arquivo.write("\n")
PY
unset CHAVE

secao "Collection de $AMBIENTE atualizada"
ok "arquivo: $SAIDA"
ok "baseUrl: $URL"
ok "apiKey:  preenchida (consumidor $CONSUMIDOR)"
echo
echo "  Importe o arquivo no Postman e use com 'No Environment'."
echo "  O arquivo carrega a chave de API e nao e versionado; gere de novo a cada ambiente recriado."
echo "  Rotas [interno] exigem: bash scripts/abrir-port-forwards.sh $AMBIENTE"
