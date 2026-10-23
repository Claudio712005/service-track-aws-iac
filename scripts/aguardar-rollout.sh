#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${1:-}"
DEPLOYMENT="${2:-}"
TIMEOUT_SEGUNDOS="${TIMEOUT_SEGUNDOS:-900}"
INTERVALO_SEGUNDOS="${INTERVALO_SEGUNDOS:-15}"

if [ -z "$NAMESPACE" ] || [ -z "$DEPLOYMENT" ]; then
  echo "uso: $0 <namespace> <deployment>" >&2
  exit 2
fi

inicio="$(date +%s)"

while :; do
  decorrido=$(( $(date +%s) - inicio ))

  if ! kubectl -n "$NAMESPACE" get deploy "$DEPLOYMENT" >/dev/null 2>&1; then
    if [ "$decorrido" -ge "$TIMEOUT_SEGUNDOS" ]; then
      echo "::error::$NAMESPACE/$DEPLOYMENT nao existe depois de ${decorrido}s." >&2
      echo "::error::O ArgoCD cria o Deployment ao sincronizar: confira a Application do ambiente." >&2
      exit 1
    fi
    echo "$DEPLOYMENT: ainda nao existe, o ArgoCD pode nao ter sincronizado (${decorrido}s)"
    sleep "$INTERVALO_SEGUNDOS"
    continue
  fi

  PRONTAS="$(kubectl -n "$NAMESPACE" get deploy "$DEPLOYMENT" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  PRONTAS="${PRONTAS:-0}"

  if [ "$PRONTAS" -ge 1 ]; then
    echo "$DEPLOYMENT: $PRONTAS replica(s) pronta(s) em ${decorrido}s"
    break
  fi

  if [ "$decorrido" -ge "$TIMEOUT_SEGUNDOS" ]; then
    echo "::error::$NAMESPACE/$DEPLOYMENT nao ficou pronto em ${decorrido}s." >&2
    kubectl -n "$NAMESPACE" get pods -o wide >&2 || true
    echo "--- eventos ---" >&2
    kubectl -n "$NAMESPACE" get events --sort-by=.lastTimestamp 2>/dev/null | tail -20 >&2 || true
    echo "--- ultimas linhas do log ---" >&2
    kubectl -n "$NAMESPACE" logs "deploy/$DEPLOYMENT" --tail=40 2>/dev/null >&2 || true
    exit 1
  fi

  ESTADO="$(kubectl -n "$NAMESPACE" get pods \
    -o jsonpath='{range .items[*]}{.status.phase}{" "}{end}' 2>/dev/null || echo '')"
  echo "$DEPLOYMENT: sem replica pronta, pods: ${ESTADO:-nenhum} (${decorrido}s)"
  sleep "$INTERVALO_SEGUNDOS"
done

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  echo "| $NAMESPACE/$DEPLOYMENT | $PRONTAS replica(s) pronta(s) |" >> "$GITHUB_STEP_SUMMARY"
fi
