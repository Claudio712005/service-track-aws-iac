#!/usr/bin/env bash
set -euo pipefail

PROFILE="aws-student"
REGION="us-east-1"

AWS_ACCESS_KEY_ID=""
AWS_SECRET_ACCESS_KEY=""
AWS_SESSION_TOKEN=""

aws configure set aws_access_key_id "$AWS_ACCESS_KEY_ID" --profile "$PROFILE"
aws configure set aws_secret_access_key "$AWS_SECRET_ACCESS_KEY" --profile "$PROFILE"
aws configure set aws_session_token "$AWS_SESSION_TOKEN" --profile "$PROFILE"
aws configure set region "$REGION" --profile "$PROFILE"
aws configure set output json --profile "$PROFILE"

echo "Validando credenciais..."

aws sts get-caller-identity --profile "$PROFILE"

echo
echo "Profile '$PROFILE' configurado com sucesso."