#!/usr/bin/env bash
#
# Gera o par de chaves RS256 usado pelo overlay local (kind) para assinar/verificar
# o JWT. As chaves sao de DESENVOLVIMENTO, descartaveis e NAO versionadas (o
# .gitignore ignora *.pem). Rode uma vez ao preparar o ambiente local.
#
# Prod nao usa estas chaves: la o secret service-track-jwt e entregue fora do git.
# Ver ADR-013.
#
# Uso: scripts/gen-local-jwt-keys.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEYS_DIR="$REPO_ROOT/kubernetes/k8s/overlays/local/keys"
PRIV="$KEYS_DIR/privateKey.pem"
PUB="$KEYS_DIR/publicKey.pem"

command -v openssl >/dev/null || { echo "openssl nao encontrado" >&2; exit 1; }

mkdir -p "$KEYS_DIR"

if [ -f "$PRIV" ] && [ "${FORCE:-}" != "true" ]; then
  echo "chaves ja existem em $KEYS_DIR (use FORCE=true para regenerar)"
  exit 0
fi

# PKCS#8 (BEGIN PRIVATE KEY) e SPKI (BEGIN PUBLIC KEY) -- os formatos que o
# SmallRye JWT do Quarkus le por padrao.
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$PRIV" 2>/dev/null
openssl rsa -in "$PRIV" -pubout -out "$PUB" 2>/dev/null
chmod 600 "$PRIV"

echo "chaves de dev geradas (nao versionadas):"
echo "  $PRIV"
echo "  $PUB"
