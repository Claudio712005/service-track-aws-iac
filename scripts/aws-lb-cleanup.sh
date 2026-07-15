#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-servicetrack-dev}"
AWS_REGION="${AWS_REGION:-us-east-1}"
TAG_KEY="kubernetes.io/cluster/${CLUSTER_NAME}"

log() { echo ">> $*"; }

if aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1 \
   && kubectl version >/dev/null 2>&1; then
  log "Cluster acessivel — apagando Services type=LoadBalancer via kubectl..."
  kubectl get svc -A -o json \
    | jq -r '.items[] | select(.spec.type=="LoadBalancer") | "\(.metadata.namespace) \(.metadata.name)"' \
    | while read -r ns name; do
        [ -n "$name" ] || continue
        log "  delete svc $ns/$name"
        kubectl -n "$ns" delete svc "$name" --ignore-not-found --wait=false
      done
else
  log "Cluster inacessivel (ja destruido?) — indo direto para varredura de ELBs orfaos."
fi

VPC_ID="$(aws ec2 describe-vpcs --region "$AWS_REGION" \
  --filters "Name=tag:${TAG_KEY},Values=shared,owned" \
  --query 'Vpcs[0].VpcId' --output text 2>/dev/null || true)"
if [ -z "$VPC_ID" ] || [ "$VPC_ID" = "None" ]; then
  VPC_ID="$(aws ec2 describe-subnets --region "$AWS_REGION" \
    --filters "Name=tag:${TAG_KEY},Values=shared,owned" \
    --query 'Subnets[0].VpcId' --output text 2>/dev/null || true)"
fi
log "VPC alvo: ${VPC_ID:-<nao encontrada>}"

if [ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
  aws elbv2 describe-load-balancers --region "$AWS_REGION" \
    --query "LoadBalancers[?VpcId=='${VPC_ID}'].LoadBalancerArn" --output text 2>/dev/null \
    | tr '\t' '\n' | while read -r arn; do
        [ -n "$arn" ] || continue
        log "  delete elbv2 $arn"
        aws elbv2 delete-load-balancer --region "$AWS_REGION" --load-balancer-arn "$arn" || true
      done

  aws elb describe-load-balancers --region "$AWS_REGION" \
    --query "LoadBalancerDescriptions[?VPCId=='${VPC_ID}'].LoadBalancerName" --output text 2>/dev/null \
    | tr '\t' '\n' | while read -r name; do
        [ -n "$name" ] || continue
        log "  delete elb (classic) $name"
        aws elb delete-load-balancer --region "$AWS_REGION" --load-balancer-name "$name" || true
      done
fi

log "Aguardando ELBs desprovisionarem..."
for i in $(seq 1 18); do
  REST_V2="$(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
    --query "length(LoadBalancers[?VpcId=='${VPC_ID}'])" --output text 2>/dev/null || echo 0)"
  REST_V1="$(aws elb describe-load-balancers --region "$AWS_REGION" \
    --query "length(LoadBalancerDescriptions[?VPCId=='${VPC_ID}'])" --output text 2>/dev/null || echo 0)"
  [ "$REST_V2" = "0" ] && [ "$REST_V1" = "0" ] && { log "ELBs limpos."; break; }
  log "  ainda restam v2=$REST_V2 v1=$REST_V1 ($i/18)"; sleep 10
done

if [ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
  aws ec2 describe-network-interfaces --region "$AWS_REGION" \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=status,Values=available" \
    --query 'NetworkInterfaces[].NetworkInterfaceId' --output text 2>/dev/null \
    | tr '\t' '\n' | while read -r eni; do
        [ -n "$eni" ] || continue
        log "  delete eni orfa $eni"
        aws ec2 delete-network-interface --region "$AWS_REGION" --network-interface-id "$eni" || true
      done
fi

log "Limpeza de LB/ENI concluida."
