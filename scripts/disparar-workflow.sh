#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "uso: disparar-workflow.sh <owner/repo> <workflow.yml> [-f chave=valor ...]" >&2
  exit 2
fi

repo="$1"; workflow="$2"; shift 2

: "${GH_TOKEN:?GH_TOKEN nao definido. Use o secret OPS_TOKEN.}"

marca="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "::group::$repo :: $workflow $*"

gh workflow run "$workflow" --repo "$repo" --ref main "$@"

id=""
for tentativa in $(seq 1 60); do
  sleep 5
  id="$(gh run list --repo "$repo" --workflow "$workflow" --limit 10 \
    --json databaseId,createdAt \
    --jq "[.[] | select(.createdAt >= \"$marca\")] | sort_by(.createdAt) | last | .databaseId // empty" \
    2>/dev/null || true)"
  [ -n "$id" ] && break
  echo "  procurando a execucao... ($tentativa/60)"
done

if [ -z "$id" ]; then
  echo "::error::Nao localizei a execucao de $workflow em $repo apos 5 minutos."
  echo "::error::Confira se OPS_TOKEN tem Actions: read and write em $repo."
  exit 1
fi

echo "execucao: https://github.com/$repo/actions/runs/$id"
gh run watch "$id" --repo "$repo" --exit-status --interval 15
echo "::endgroup::"
