#!/usr/bin/env bash
set -uo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$RAIZ/scripts/diagnostico/comum.sh"

command -v kubectl >/dev/null || { erro "kubectl nao encontrado"; exit 1; }
exigir_credenciais
conectar_cluster || { erro "nao foi possivel conectar ao cluster $CLUSTER"; exit 1; }

ALVOS=("ordens:${PORTA_ORDENS:-18083}" "checkout:${PORTA_CHECKOUT:-18084}")
PIDS=()

encerrar() {
  for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null; done
}
trap encerrar EXIT INT TERM

secao "Port-forward para $CLUSTER"
for alvo in "${ALVOS[@]}"; do
  servico="${alvo%%:*}"
  porta="${alvo##*:}"
  kubectl -n "service-track-$servico" port-forward "svc/service-track-$servico" "$porta:80" >/dev/null 2>&1 &
  PIDS+=("$!")
done
sleep 4

for alvo in "${ALVOS[@]}"; do
  servico="${alvo%%:*}"
  porta="${alvo##*:}"
  if curl -fs "http://localhost:$porta/actuator/health/readiness" >/dev/null; then
    ok "$servico em http://localhost:$porta"
  else
    erro "$servico nao respondeu em http://localhost:$porta"
  fi
done

echo
echo "  Deixe este terminal aberto enquanto usa a collection. Ctrl+C encerra."
wait
