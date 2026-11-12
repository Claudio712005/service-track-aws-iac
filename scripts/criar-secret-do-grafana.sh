#!/usr/bin/env bash
set -euo pipefail

AMBIENTE="${1:-}"
PROJETO="${PROJETO:-servicetrack}"
REGIAO="${AWS_REGION:-us-east-1}"
PREFIXO_DE_NAMESPACE="${PREFIXO_DE_NAMESPACE:-service-track-}"
SEGREDO="service-track-observabilidade"
REINICIAR="${REINICIAR:-sim}"

if [[ "$AMBIENTE" != "hml" && "$AMBIENTE" != "prd" ]]; then
  echo "uso: $0 <hml|prd>" >&2
  exit 1
fi

ler() {
  local chave="$1"
  aws ssm get-parameter --name "/$PROJETO/$AMBIENTE/grafana/$chave" --with-decryption --region "$REGIAO" \
    --query Parameter.Value --output text 2>/dev/null || true
}

ENDPOINT="$(ler otlp-endpoint)"
INSTANCIA="$(ler instance-id)"
TOKEN="$(ler token)"

faltando=()
[[ -z "$ENDPOINT" ]] && faltando+=("otlp-endpoint")
[[ -z "$INSTANCIA" ]] && faltando+=("instance-id")
[[ -z "$TOKEN" ]] && faltando+=("token")

if (( ${#faltando[@]} > 0 )); then
  for chave in "${faltando[@]}"; do
    echo "::warning::/$PROJETO/$AMBIENTE/grafana/$chave nao existe no SSM."
  done
  echo "::warning::Sem credencial do Grafana Cloud os servicos sobem com o agente do OTel desligado."
  echo "::warning::Os tres parametros sao cadastrados a mao, uma vez por conta. Ver GLOBAL-RFC-013."
  exit 0
fi

if [[ "$ENDPOINT" != https://* ]]; then
  echo "::error::otlp-endpoint precisa comecar com https:// (recebido: $ENDPOINT)" >&2
  exit 1
fi

if [[ ! "$INSTANCIA" =~ ^[0-9]+$ ]]; then
  echo "::error::instance-id precisa ser o id numerico da stack do Grafana Cloud" >&2
  exit 1
fi

ENDPOINT="${ENDPOINT%/}"
CREDENCIAL="$(printf '%s:%s' "$INSTANCIA" "$TOKEN" | base64 | tr -d '\n')"
if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
  echo "::add-mask::$CREDENCIAL"
fi

NAMESPACES=()
while IFS= read -r namespace; do
  [[ -n "$namespace" ]] && NAMESPACES+=("$namespace")
done < <(kubectl get namespaces -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
  | grep "^${PREFIXO_DE_NAMESPACE}" || true)

if (( ${#NAMESPACES[@]} == 0 )); then
  echo "::warning::nenhum namespace ${PREFIXO_DE_NAMESPACE}* no cluster; nada a configurar."
  exit 0
fi

for namespace in "${NAMESPACES[@]}"; do
  kubectl create secret generic "$SEGREDO" \
    --namespace "$namespace" \
    --from-literal=OTEL_JAVAAGENT_ENABLED=true \
    --from-literal=OTEL_EXPORTER_OTLP_ENDPOINT="$ENDPOINT" \
    --from-literal=OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf \
    --from-literal=OTEL_EXPORTER_OTLP_HEADERS="Authorization=Basic%20$CREDENCIAL" \
    --from-literal=OTEL_TRACES_EXPORTER=otlp \
    --from-literal=OTEL_METRICS_EXPORTER=otlp \
    --from-literal=OTEL_LOGS_EXPORTER=otlp \
    --from-literal=OTEL_INSTRUMENTATION_MICROMETER_ENABLED=true \
    --from-literal=OTEL_RESOURCE_ATTRIBUTES="deployment.environment=$AMBIENTE,service.namespace=$PROJETO" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  echo "secret $SEGREDO aplicado em $namespace"

  if [[ "$REINICIAR" == "sim" ]]; then
    kubectl -n "$namespace" get deployments -o json \
      | jq -r --arg segredo "$SEGREDO" \
          '.items[] | select([.spec.template.spec.containers[].envFrom[]?.secretRef.name] | index($segredo)) | .metadata.name' \
      | xargs -r -I{} kubectl -n "$namespace" rollout restart deployment/{} >/dev/null
  fi
done

echo "telemetria de $AMBIENTE apontada para $ENDPOINT em ${#NAMESPACES[@]} namespace(s)"
