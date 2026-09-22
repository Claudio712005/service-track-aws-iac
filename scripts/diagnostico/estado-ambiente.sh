#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/comum.sh"
exigir_credenciais

echo "Estado de $AMBIENTE — conta $(aws sts get-caller-identity --query Account --output text)"

secao "Borda"
URL="$(url_da_api)"
[ -n "$URL" ] && ok "API: $URL" || erro "URL da API ausente no SSM"
for c in web mobile ci; do
  k="$(chave_de_api "$c")" && ok "chave $c: ${k:0:6}... (${#k} chars)" || alerta "chave $c ausente"
done

secao "Computacao"
conectar_cluster
NAMESPACES="$(kubectl get ns --no-headers -o custom-columns=:metadata.name 2>/dev/null | grep '^service-track-' || true)"
[ -z "$NAMESPACES" ] && alerta "nenhum namespace service-track-* no cluster"
for ns in $NAMESPACES; do
  kubectl -n "$ns" get pods --no-headers 2>/dev/null | while read -r nome pronto estado reinicios _; do
    case "$estado" in
      Running) [ "${pronto%/*}" = "${pronto#*/}" ] && ok "$ns/$nome $pronto $estado ($reinicios reinicios)" || alerta "$ns/$nome $pronto $estado" ;;
      Completed) ok "$ns/$nome $estado" ;;
      *) erro "$ns/$nome $pronto $estado ($reinicios reinicios)" ;;
    esac
  done
done
kubectl -n argocd get applications.argoproj.io --no-headers \
  -o custom-columns=:metadata.name,:status.sync.status,:status.health.status 2>/dev/null \
  | while read -r app sync saude; do
      [ "$sync/$saude" = "Synced/Healthy" ] && ok "Application $app $sync/$saude" || alerta "Application $app $sync/$saude"
    done
FUNC="$PROJETO-$AMBIENTE-auth"
EST="$(aws lambda get-function-configuration --function-name "$FUNC" --region "$REGIAO" --query 'State' --output text 2>/dev/null)"
[ "$EST" = "Active" ] && ok "Lambda $FUNC: $EST" || erro "Lambda $FUNC: ${EST:-ausente}"

secao "Dados"
RDS="$(aws ssm get-parameter --name "/$PROJETO/$AMBIENTE/db/endpoint" --region "$REGIAO" --query Parameter.Value --output text 2>/dev/null)"
[ -n "$RDS" ] && ok "RDS: $RDS" || erro "endpoint do RDS ausente no SSM"
echo
