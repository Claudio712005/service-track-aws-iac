#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export AWS_PROFILE="${AWS_PROFILE:-aws-student}"

if [ "${1:-}" = "destroy" ]; then
  "$ROOT_DIR/scripts/aws-lb-cleanup.sh"
fi

terraform -chdir="$ROOT_DIR/infra/terraform" "$@"