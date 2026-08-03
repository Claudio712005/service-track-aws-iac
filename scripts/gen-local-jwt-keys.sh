#!/usr/bin/env bash
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

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$PRIV" 2>/dev/null
openssl rsa -in "$PRIV" -pubout -out "$PUB" 2>/dev/null
chmod 600 "$PRIV"

echo "chaves de dev geradas (nao versionadas):"
echo "  $PRIV"
echo "  $PUB"
