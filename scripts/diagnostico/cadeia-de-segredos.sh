#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/comum.sh"
exigir_credenciais
conectar_cluster

echo "Cadeia de segredos de $AMBIENTE"
echo "secret do GitHub -> TF_VAR -> SSM -> secret do k8s -> variavel no pod"

secao "SSM"
for p in unsplash-access-key resend-api-key jwt-private jwt-public; do
  v="$(aws ssm get-parameter --name "/$PROJETO/$AMBIENTE/$p" --with-decryption \
    --region "$REGIAO" --query Parameter.Value --output text 2>&1)"
  case "$v" in
    *ParameterNotFound*) erro "$p ausente — o TF_VAR chegou vazio no apply" ;;
    *) [ ${#v} -gt 0 ] && ok "$p (${#v} chars)" || erro "$p vazio" ;;
  esac
done

secao "Secret do Kubernetes"
kubectl -n service-track get secret service-track-secret -o json 2>/dev/null \
  | python3 -c '
import sys, json, base64
try:
    d = json.load(sys.stdin)["data"]
except Exception:
    print("  secret service-track-secret ausente"); raise SystemExit
for k in sorted(d):
    v = base64.b64decode(d[k]).decode()
    marca = "VAZIO — a aplicacao nao inicia" if len(v) == 0 else f"{len(v)} chars"
    print(f"  {k:<24} {marca}")'

secao "Variaveis no pod"
POD="$(kubectl -n service-track get pods -l app=service-track-app \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
if [ -n "$POD" ]; then
  kubectl -n service-track exec "$POD" -- sh -c \
    'env | grep -E "UNSPLASH|RESEND|GATEWAY_SEGREDO" | sed -E "s/=(.{0,4}).*/=\1.../"' 2>/dev/null \
    | sed 's/^/  /' || alerta "nao consegui ler o ambiente do pod"
else
  erro "nenhum pod da aplicacao em execucao"
fi

secao "Lambda"
aws lambda get-function-configuration --function-name "$PROJETO-$AMBIENTE-auth" \
  --region "$REGIAO" --query 'Environment.Variables' --output json 2>/dev/null \
  | python3 -c '
import sys, json
d = json.load(sys.stdin) or {}
for k in sorted(d):
    print(f"  {k:<38} {len(str(d[k]))} chars")' 2>/dev/null || erro "funcao ausente"
echo
