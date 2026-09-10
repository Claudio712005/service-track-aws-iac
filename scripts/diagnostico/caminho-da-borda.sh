#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/comum.sh"
exigir_credenciais
conectar_cluster

echo "Caminho da borda ate a aplicacao em $AMBIENTE"
echo "gateway -> VPC Link -> NLB -> NodePort -> pod"

URL="$(url_da_api)"
API_ID="$(printf '%s' "$URL" | sed -E 's#https://([^.]+)\..*#\1#')"

secao "1. Integracao publicada"
RID="$(aws apigateway get-resources --rest-api-id "$API_ID" --limit 500 --region "$REGIAO" \
  --query "items[?path=='/veiculos'].id" --output text 2>/dev/null)"
INT="$(aws apigateway get-integration --rest-api-id "$API_ID" --resource-id "$RID" \
  --http-method GET --region "$REGIAO" --query '[uri,connectionId]' --output text 2>/dev/null)"
URI="$(echo "$INT" | cut -f1)"; LINK="$(echo "$INT" | cut -f2)"
echo "  uri: $URI"
DNS_REAL="$(aws elbv2 describe-load-balancers --region "$REGIAO" \
  --query "LoadBalancers[?contains(LoadBalancerName,'$PROJETO-$AMBIENTE')].DNSName" --output text 2>/dev/null)"
case "$URI" in
  *"$DNS_REAL"*) ok "aponta para o NLB atual" ;;
  *) erro "aponta para outro host; NLB atual e $DNS_REAL" ;;
esac

secao "2. VPC Link"
EST="$(aws apigateway get-vpc-link --vpc-link-id "$LINK" --region "$REGIAO" --query status --output text 2>/dev/null)"
[ "$EST" = "AVAILABLE" ] && ok "status $EST" || erro "status ${EST:-ausente}"
ALVO="$(aws apigateway get-vpc-link --vpc-link-id "$LINK" --region "$REGIAO" --query 'targetArns[0]' --output text 2>/dev/null)"
ARN_REAL="$(aws elbv2 describe-load-balancers --region "$REGIAO" \
  --query "LoadBalancers[?contains(LoadBalancerName,'$PROJETO-$AMBIENTE')].LoadBalancerArn" --output text 2>/dev/null)"
[ "$ALVO" = "$ARN_REAL" ] && ok "alvo confere com o NLB" || erro "alvo diverge do NLB atual"

secao "3. Security group do NLB"
SG="$(aws elbv2 describe-load-balancers --load-balancer-arns "$ARN_REAL" --region "$REGIAO" \
  --query 'LoadBalancers[0].SecurityGroups[0]' --output text 2>/dev/null)"
if [ "$SG" = "None" ] || [ -z "$SG" ]; then
  ok "NLB sem security group: aceita qualquer origem"
else
  ORIGENS="$(aws ec2 describe-security-group-rules --region "$REGIAO" \
    --filters Name=group-id,Values="$SG" \
    --query 'SecurityGroupRules[?!IsEgress && FromPort==`80`].CidrIpv4' --output text 2>/dev/null)"
  echo "  origens liberadas na porta 80: ${ORIGENS:-nenhuma}"
  case "$ORIGENS" in
    *0.0.0.0/0*) ok "cobre as ENIs do VPC Link" ;;
    *) erro "restrito a $ORIGENS — as ENIs do VPC Link vivem em VPC da AWS, fora deste CIDR" ;;
  esac
fi

secao "4. NLB -> pod, de dentro da VPC"
POD="$(kubectl -n service-track get pods -l app=service-track-app -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
if [ -n "$POD" ]; then
  C="$(kubectl -n service-track exec "$POD" -- sh -c \
    "wget -qO- --timeout=10 'http://$DNS_REAL/q/health/ready' >/dev/null 2>&1 && echo ok || echo falha" 2>/dev/null)"
  [ "$C" = "ok" ] && ok "o NLB entrega no pod" || erro "o NLB nao entrega no pod"
else
  erro "nenhum pod para testar de dentro"
fi

secao "5. Gateway -> aplicacao"
KEY="$(chave_de_api web)"
if [ -n "$KEY" ]; then
  for i in $(seq 1 6); do
    C="$(curl -s -o /dev/null -w '%{http_code}' --max-time 25 -H "x-api-key: $KEY" "$URL/veiculos")"
    [ "$C" != "403" ] && break; sleep 2
  done
  case "$C" in
    401) ok "o gateway alcanca a aplicacao (401 = falta token, esperado sem login)" ;;
    200) ok "resposta 200" ;;
    500) erro "500 — o gateway nao alcanca a aplicacao; veja os passos 2 e 3" ;;
    *)   alerta "resposta $C" ;;
  esac
else
  erro "sem chave de API para testar"
fi
echo
