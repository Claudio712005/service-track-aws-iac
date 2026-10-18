#!/usr/bin/env bash
set -uo pipefail

AMBIENTE="${1:-}"
REGIAO="${AWS_REGION:-us-east-1}"

if [[ "$AMBIENTE" != "hml" && "$AMBIENTE" != "prd" ]]; then
  echo "uso: $0 <hml|prd>" >&2
  exit 2
fi

aws eks update-kubeconfig --name "servicetrack-$AMBIENTE" --region "$REGIAO" >/dev/null 2>&1 || {
  echo "::error::cluster servicetrack-$AMBIENTE inalcancavel." >&2
  exit 1
}

declare -a NAMESPACES=(
  service-track-usuarios-veiculos
  service-track-catalogo
  service-track-ordens
  service-track-checkout
  service-track-bff
)

problemas=0
linhas=""

for ns in "${NAMESPACES[@]}"; do
  if ! kubectl get ns "$ns" >/dev/null 2>&1; then
    linhas+="| $ns | namespace ausente | — | o ArgoCD nao sincronizou |"$'\n'
    problemas=$((problemas + 1))
    continue
  fi

  DESEJADAS="$(kubectl -n "$ns" get deploy "$ns" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo '')"
  PRONTAS="$(kubectl -n "$ns" get deploy "$ns" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  PRONTAS="${PRONTAS:-0}"
  DESEJADAS="${DESEJADAS:-0}"

  IMAGEM="$(kubectl -n "$ns" get deploy "$ns" \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo '?')"
  TAG="${IMAGEM##*:}"

  MOTIVO="$(kubectl -n "$ns" get pods \
    -o jsonpath='{range .items[*]}{.status.containerStatuses[*].state.waiting.reason}{" "}{end}' 2>/dev/null \
    | tr ' ' '\n' | grep -v '^$' | sort -u | paste -sd, - || echo '')"

  if [ "$PRONTAS" -ge 1 ]; then
    linhas+="| $ns | $PRONTAS/$DESEJADAS pronta(s) | \`$TAG\` | — |"$'\n'
  else
    diagnostico="sem replica pronta"
    case "$MOTIVO" in
      *ImagePullBackOff*|*ErrImagePull*)
        diagnostico="imagem \`$TAG\` nao existe no ECR: o CD nao rodou ou o PR de tag nao foi mesclado" ;;
      *CrashLoopBackOff*)
        diagnostico="sobe e morre: banco sem baseline, ou segredo ausente" ;;
      *CreateContainerConfigError*)
        diagnostico="Secret ou ConfigMap referenciado nao existe" ;;
    esac
    linhas+="| $ns | **$MOTIVO** | \`$TAG\` | $diagnostico |"$'\n'
    problemas=$((problemas + 1))
  fi
done

LAMBDA="$(aws lambda get-function-configuration \
  --function-name "servicetrack-$AMBIENTE-auth" \
  --query 'LastUpdateStatus' --output text --region "$REGIAO" 2>/dev/null || echo 'ausente')"

URL_USUARIOS="$(aws lambda get-function-configuration \
  --function-name "servicetrack-$AMBIENTE-auth" \
  --query 'Environment.Variables.ST_USU_BASE_URL' --output text --region "$REGIAO" 2>/dev/null || echo '')"

{
  echo ""
  echo "### Conferencia do ambiente"
  echo ""
  echo "| Servico | Replicas | Tag | Diagnostico |"
  echo "|---|---|---|---|"
  printf '%s' "$linhas"
  echo ""
  echo "| Componente | Estado |"
  echo "|---|---|"
  echo "| Lambda de autenticacao | $LAMBDA |"
  if [ -n "$URL_USUARIOS" ] && [ "$URL_USUARIOS" != "None" ]; then
    echo "| Caminho da Lambda ate o servico de usuarios | definido |"
  else
    echo "| Caminho da Lambda ate o servico de usuarios | **ST_USU_BASE_URL ausente**: todo login falha |"
  fi
} >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"

if [ "$problemas" -gt 0 ]; then
  echo "::warning::$problemas servico(s) sem replica pronta. Veja a tabela do resumo."
fi

exit 0
