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

secao "Rede"
LB="$(aws elbv2 describe-load-balancers --region "$REGIAO" \
  --query "LoadBalancers[?contains(LoadBalancerName,'$PROJETO-$AMBIENTE')].LoadBalancerArn" --output text 2>/dev/null)"
if [ -n "$LB" ]; then
  ok "NLB: $(aws elbv2 describe-load-balancers --load-balancer-arns "$LB" --region "$REGIAO" --query 'LoadBalancers[0].DNSName' --output text)"
  TG="$(aws elbv2 describe-target-groups --load-balancer-arn "$LB" --region "$REGIAO" --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null)"
  aws elbv2 describe-target-health --target-group-arn "$TG" --region "$REGIAO" \
    --query 'TargetHealthDescriptions[].[Target.Id,Target.Port,TargetHealth.State]' --output text 2>/dev/null \
    | while read -r alvo porta estado; do
        [ "$estado" = "healthy" ] && ok "alvo $alvo:$porta $estado" || erro "alvo $alvo:$porta $estado"
      done
else
  erro "NLB nao encontrado"
fi
aws apigateway get-vpc-links --region "$REGIAO" \
  --query "items[?contains(name,'$PROJETO-$AMBIENTE')].[name,status]" --output text 2>/dev/null \
  | while read -r n s; do [ "$s" = "AVAILABLE" ] && ok "VPC Link $n: $s" || erro "VPC Link $n: $s"; done

secao "Computacao"
conectar_cluster
kubectl -n service-track get pods --no-headers 2>/dev/null | while read -r nome pronto estado reinicios _; do
  case "$estado" in
    Running) [ "$pronto" = "1/1" ] && ok "$nome $pronto $estado ($reinicios reinicios)" || alerta "$nome $pronto $estado" ;;
    Completed) ok "$nome $estado" ;;
    *) erro "$nome $pronto $estado ($reinicios reinicios)" ;;
  esac
done
FUNC="$PROJETO-$AMBIENTE-auth"
EST="$(aws lambda get-function-configuration --function-name "$FUNC" --region "$REGIAO" --query 'State' --output text 2>/dev/null)"
[ "$EST" = "Active" ] && ok "Lambda $FUNC: $EST" || erro "Lambda $FUNC: ${EST:-ausente}"

secao "Dados"
RDS="$(aws ssm get-parameter --name "/$PROJETO/$AMBIENTE/db/endpoint" --region "$REGIAO" --query Parameter.Value --output text 2>/dev/null)"
[ -n "$RDS" ] && ok "RDS: $RDS" || erro "endpoint do RDS ausente no SSM"
echo
