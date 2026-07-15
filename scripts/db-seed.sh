#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$ROOT_DIR/infra/terraform"
SEED_FILE="$ROOT_DIR/software/service-track-api/_infrastructure/src/main/resources/import.sql"
NS="service-track"
export AWS_PROFILE="${AWS_PROFILE:-aws-student}"

tf() { terraform -chdir="$TF_DIR" "$@"; }

RDS_HOST="$(tf output -raw rds_endpoint)"
RDS_USER="$(tf output -raw db_username)"
RDS_PASS="$(tf output -raw db_password)"
DB_NAME="servicetrack"

echo ">> Publicando import.sql como ConfigMap..."
kubectl -n "$NS" create configmap service-track-seed \
  --from-file=import.sql="$SEED_FILE" \
  --dry-run=client -o yaml | kubectl apply -f -

echo ">> Criando Secret temporária com a senha do RDS..."
kubectl -n "$NS" create secret generic service-track-seed-db \
  --from-literal=PGPASSWORD="$RDS_PASS" \
  --dry-run=client -o yaml | kubectl apply -f -

echo ">> Executando Job de seed..."
kubectl -n "$NS" delete job service-track-seed --ignore-not-found
cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: service-track-seed
  namespace: $NS
spec:
  backoffLimit: 1
  ttlSecondsAfterFinished: 300
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: seed
          image: postgres:16-alpine
          env:
            - name: PGPASSWORD
              valueFrom:
                secretKeyRef:
                  name: service-track-seed-db
                  key: PGPASSWORD
          command: ["/bin/sh", "-c"]
          args:
            - |
              set -e
              COUNT=\$(psql -h $RDS_HOST -U $RDS_USER -d $DB_NAME -tAc "SELECT count(*) FROM usuarios" || echo 0)
              if [ "\$COUNT" -gt 0 ]; then
                echo "usuarios já possui \$COUNT linhas. Seed ignorado."
                exit 0
              fi
              echo "Aplicando import.sql..."
              psql -h $RDS_HOST -U $RDS_USER -d $DB_NAME -v ON_ERROR_STOP=1 -f /seed/import.sql
              echo "Seed concluído."
          volumeMounts:
            - name: seed
              mountPath: /seed
      volumes:
        - name: seed
          configMap:
            name: service-track-seed
EOF

echo ">> Aguardando conclusão..."
kubectl -n "$NS" wait --for=condition=complete job/service-track-seed --timeout=120s
kubectl -n "$NS" logs job/service-track-seed

echo ">> Limpando Secret temporária..."
kubectl -n "$NS" delete secret service-track-seed-db --ignore-not-found
echo ">> OK."
