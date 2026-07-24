#!/usr/bin/env bash
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DNS_DIR="$REPO_ROOT/iac/bootstrap/dns"

ZONE_EXISTS=false
ZONE_NAME=""
NAME_SERVERS=""
DELEGATED=false

if terraform -chdir="$DNS_DIR" init -input=false -no-color >/dev/null 2>&1; then
  ZONE_NAME="$(terraform -chdir="$DNS_DIR" output -raw zone_name 2>/dev/null | sed 's/\.$//')"
  if [ -n "$ZONE_NAME" ]; then
    ZONE_EXISTS=true
    NAME_SERVERS="$(terraform -chdir="$DNS_DIR" output -json name_servers 2>/dev/null |
      jq -r '.[]' 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
  fi
fi

if [ "$ZONE_EXISTS" = "true" ]; then
  if QUIET=true bash "$REPO_ROOT/scripts/dns-delegation-check.sh" "$ZONE_NAME" $NAME_SERVERS; then
    DELEGATED=true
  fi
fi

echo "ZONE_EXISTS=$ZONE_EXISTS"
echo "ZONE_NAME=$ZONE_NAME"
echo "NAME_SERVERS=\"$NAME_SERVERS\""
echo "DELEGATED=$DELEGATED"
