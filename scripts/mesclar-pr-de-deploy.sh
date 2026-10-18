#!/usr/bin/env bash
set -euo pipefail

REPO="${1:-}"
AMBIENTE="${2:-}"
TIMEOUT_SEGUNDOS="${TIMEOUT_SEGUNDOS:-600}"
INTERVALO_SEGUNDOS="${INTERVALO_SEGUNDOS:-15}"

if [ -z "$REPO" ] || [ -z "$AMBIENTE" ]; then
  echo "uso: $0 <owner/repo> <hml|prd>" >&2
  exit 2
fi

if [ -z "${GH_TOKEN:-}" ]; then
  echo "::error::GH_TOKEN ausente. Mesclar PR exige OPS_TOKEN com Contents e Pull requests: read and write em $REPO." >&2
  exit 1
fi

achar_pr() {
  gh pr list --repo "$REPO" --state open --json number,headRefName,title \
    --jq "[.[] | select(.headRefName | startswith(\"deploy/$AMBIENTE-\"))] | sort_by(.number) | last"
}

inicio="$(date +%s)"
PR=""

while :; do
  PR="$(achar_pr)"
  if [ -n "$PR" ] && [ "$PR" != "null" ]; then
    break
  fi

  decorrido=$(( $(date +%s) - inicio ))
  if [ "$decorrido" -ge "$TIMEOUT_SEGUNDOS" ]; then
    echo "::error::$REPO: nenhum PR aberto com branch deploy/$AMBIENTE-* apareceu em ${decorrido}s." >&2
    echo "::error::O CD publica a imagem e abre o PR no mesmo run: se ele concluiu, o PR existe." >&2
    exit 1
  fi
  echo "$REPO: esperando o PR de deploy aparecer (${decorrido}s)"
  sleep "$INTERVALO_SEGUNDOS"
done

NUMERO="$(echo "$PR" | jq -r .number)"
BRANCH="$(echo "$PR" | jq -r .headRefName)"
echo "$REPO: PR #$NUMERO na branch $BRANCH"

inicio_merge="$(date +%s)"
while :; do
  ESTADO="$(gh pr view "$NUMERO" --repo "$REPO" --json state,mergeable,mergeStateStatus \
    --jq '[.state, .mergeable, .mergeStateStatus] | join(" ")')"
  read -r estado mesclavel situacao <<<"$ESTADO"

  if [ "$estado" = "MERGED" ]; then
    echo "$REPO: PR #$NUMERO ja estava mesclado"
    break
  fi

  if [ "$estado" = "CLOSED" ]; then
    echo "::error::$REPO: PR #$NUMERO foi fechado sem merge." >&2
    exit 1
  fi

  if [ "$mesclavel" = "CONFLICTING" ]; then
    echo "::error::$REPO: PR #$NUMERO tem conflito e precisa de resolucao manual." >&2
    echo "::error::Em geral e um PR de tag antigo que ficou aberto no mesmo arquivo de overlay." >&2
    exit 1
  fi

  if [ "$mesclavel" = "MERGEABLE" ] && [ "$situacao" != "BLOCKED" ] && [ "$situacao" != "UNKNOWN" ]; then
    if gh pr merge "$NUMERO" --repo "$REPO" --squash --delete-branch; then
      echo "$REPO: PR #$NUMERO mesclado"
      break
    fi
    echo "$REPO: merge recusado agora, vou tentar de novo"
  fi

  decorrido=$(( $(date +%s) - inicio_merge ))
  if [ "$decorrido" -ge "$TIMEOUT_SEGUNDOS" ]; then
    echo "::error::$REPO: PR #$NUMERO nao ficou mesclavel em ${decorrido}s (estado=$estado mesclavel=$mesclavel situacao=$situacao)." >&2
    echo "::error::Com main protegida, o merge exige check verde ou auto-merge habilitado no repositorio." >&2
    exit 1
  fi
  echo "$REPO: PR #$NUMERO estado=$estado mesclavel=$mesclavel situacao=$situacao (${decorrido}s)"
  sleep "$INTERVALO_SEGUNDOS"
done

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  echo "| $REPO | [#$NUMERO](https://github.com/$REPO/pull/$NUMERO) | mesclado |" >> "$GITHUB_STEP_SUMMARY"
fi
