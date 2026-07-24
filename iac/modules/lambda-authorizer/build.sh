#!/usr/bin/env bash
set -euo pipefail

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$MODULE_DIR/build/bootstrap"

mkdir -p "$MODULE_DIR/build"
cd "$MODULE_DIR/src"

GOOS=linux GOARCH=arm64 CGO_ENABLED=0 \
  go build -tags lambda.norpc -trimpath -ldflags='-s -w' -o "$OUT" .

echo "authorizer compilado: $OUT"
