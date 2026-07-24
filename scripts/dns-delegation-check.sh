#!/usr/bin/env bash
set -uo pipefail

ZONE="${1:-}"
shift || true
EXPECTED=("$@")
QUIET="${QUIET:-false}"

log() { [ "$QUIET" = "true" ] || printf '%s\n' "$*"; }

[ -n "$ZONE" ] || { echo "uso: dns-delegation-check.sh <zone_name> [ns...]" >&2; exit 2; }
ZONE="${ZONE%.}"

if ! command -v dig >/dev/null 2>&1; then
  echo "dig nao encontrado (instale bind9-dnsutils / dnsutils)" >&2
  exit 2
fi

actual="$(dig +short NS "$ZONE" @1.1.1.1 2>/dev/null | sed 's/\.$//' | sort -u)"

if [ -z "$actual" ]; then
  log "delegacao AUSENTE: $ZONE nao responde NS em resolver publico"
  exit 1
fi

log "delegacao encontrada para $ZONE:"
printf '  %s\n' $actual | { [ "$QUIET" = "true" ] && cat >/dev/null || cat; }

if [ ${#EXPECTED[@]} -eq 0 ]; then
  exit 0
fi

expected_sorted="$(printf '%s\n' "${EXPECTED[@]}" | sed 's/\.$//' | sort -u)"

if comm -12 <(printf '%s\n' $actual) <(printf '%s\n' $expected_sorted) | grep -q .; then
  log "delegacao CONFERE com a hosted zone"
  exit 0
fi

log "delegacao DIVERGENTE: a zona responde, mas por outros servidores"
log "  esperado: $(printf '%s ' $expected_sorted)"
log "  atual:    $(printf '%s ' $actual)"
exit 1
