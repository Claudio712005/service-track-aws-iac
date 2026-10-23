#!/usr/bin/env bash
set -euo pipefail

# Tres armadilhas justificam este script existir, porque `gh workflow run` nao
# devolve o id da execucao que acabou de criar:
#
# 1. A execucao nao aparece na API no mesmo instante do dispatch. Consultar uma
#    vez e desistir da falso negativo, por isso a busca insiste por BUSCA_SEGUNDOS.
# 2. Pegar "a mais recente" pode pegar execucao de outra pessoa. O corte e por
#    horario: guardamos o instante antes do dispatch e so aceitamos execucao
#    criada a partir dele; entre as candidatas, a mais antiga e a nossa, porque
#    as posteriores nasceram depois.
# 3. A execucao nasce queued, passa por in_progress e so entao completed. Parar
#    em in_progress terminaria antes do resultado existir.

REPO="${1:-}"
ESTEIRA="${2:-}"
shift 2 2>/dev/null || true

REF="${REF:-main}"
TIMEOUT_SEGUNDOS="${TIMEOUT_SEGUNDOS:-2700}"
INTERVALO_SEGUNDOS="${INTERVALO_SEGUNDOS:-15}"
BUSCA_SEGUNDOS="${BUSCA_SEGUNDOS:-90}"

uso() {
  echo "uso: $0 <owner/repo> <arquivo-da-esteira> [chave=valor ...]" >&2
}

if [ -z "$REPO" ] || [ -z "$ESTEIRA" ]; then
  uso
  exit 2
fi

if ! [[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "::error::repositorio invalido: '$REPO'. Esperado owner/repo." >&2
  uso
  exit 2
fi

if [ -z "${GH_TOKEN:-}" ]; then
  echo "::error::GH_TOKEN ausente. Disparar esteira de outro repositorio exige o OPS_TOKEN" >&2
  echo "::error::com permissao de Actions: read and write em $REPO." >&2
  exit 1
fi

ENTRADAS=()
for par in "$@"; do
  if ! [[ "$par" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
    echo "::error::entrada invalida: '$par'. Esperado chave=valor." >&2
    exit 2
  fi
  ENTRADAS+=(-f "$par")
done

CORTE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "disparando $ESTEIRA em $REPO (ref=$REF, corte=$CORTE)"
[ "${#ENTRADAS[@]}" -eq 0 ] || echo "entradas: $*"

if ! gh workflow run "$ESTEIRA" --repo "$REPO" --ref "$REF" "${ENTRADAS[@]+"${ENTRADAS[@]}"}"; then
  echo "::error::$REPO: o dispatch de $ESTEIRA foi recusado." >&2
  echo "::error::Confira se a esteira tem workflow_dispatch, se o arquivo existe em $REF," >&2
  echo "::error::e se o token alcanca Actions neste repositorio." >&2
  exit 1
fi

achar_execucao() {
  gh run list --repo "$REPO" --workflow "$ESTEIRA" --event workflow_dispatch \
    --limit 30 --json databaseId,createdAt,url,status \
    --jq "[.[] | select(.createdAt >= \"$CORTE\")] | sort_by(.createdAt) | first"
}

inicio_busca="$(date +%s)"
EXECUCAO=""

while :; do
  EXECUCAO="$(achar_execucao || echo '')"
  if [ -n "$EXECUCAO" ] && [ "$EXECUCAO" != "null" ]; then
    break
  fi

  decorrido=$(( $(date +%s) - inicio_busca ))
  if [ "$decorrido" -ge "$BUSCA_SEGUNDOS" ]; then
    echo "::error::$REPO: o dispatch de $ESTEIRA foi aceito, mas nenhuma execucao criada" >&2
    echo "::error::a partir de $CORTE apareceu em ${decorrido}s. Veja as execucoes em" >&2
    echo "::error::https://github.com/$REPO/actions/workflows/$ESTEIRA" >&2
    exit 1
  fi
  sleep 5
done

RUN_ID="$(echo "$EXECUCAO" | jq -r .databaseId)"
RUN_URL="$(echo "$EXECUCAO" | jq -r .url)"
echo "execucao $RUN_ID: $RUN_URL"

inicio="$(date +%s)"
ESTADO_ANTERIOR=""

while :; do
  ESTADO="$(gh run view "$RUN_ID" --repo "$REPO" --json status,conclusion \
    --jq '[.status, (.conclusion // "")] | join(" ")' 2>/dev/null || echo 'desconhecido ')"
  read -r status conclusao <<<"$ESTADO"
  decorrido=$(( $(date +%s) - inicio ))

  if [ "$status" = "completed" ]; then
    break
  fi

  if [ "$status" != "$ESTADO_ANTERIOR" ]; then
    echo "$REPO/$ESTEIRA: $status (${decorrido}s)"
    ESTADO_ANTERIOR="$status"
  elif [ $(( decorrido % 60 )) -lt "$INTERVALO_SEGUNDOS" ]; then
    echo "$REPO/$ESTEIRA: $status (${decorrido}s)"
  fi

  if [ "$decorrido" -ge "$TIMEOUT_SEGUNDOS" ]; then
    echo "::error::$REPO/$ESTEIRA: ainda em '$status' depois de ${decorrido}s." >&2
    echo "::error::Abra a execucao e decida: $RUN_URL" >&2
    exit 1
  fi

  sleep "$INTERVALO_SEGUNDOS"
done

DURACAO=$(( $(date +%s) - inicio ))
echo "$REPO/$ESTEIRA: $conclusao em ${DURACAO}s — $RUN_URL"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "run_url=$RUN_URL"
    echo "run_id=$RUN_ID"
    echo "conclusion=$conclusao"
    echo "duracao=$DURACAO"
  } >> "$GITHUB_OUTPUT"
fi

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  echo "| $REPO | $ESTEIRA | $conclusao | [execucao]($RUN_URL) |" >> "$GITHUB_STEP_SUMMARY"
fi

if [ "$conclusao" != "success" ]; then
  echo "::error::$REPO/$ESTEIRA terminou em '$conclusao'. Log: $RUN_URL" >&2
  exit 1
fi
