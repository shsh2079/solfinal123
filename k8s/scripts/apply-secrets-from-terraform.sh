#!/usr/bin/env bash
set -euo pipefail

# Creates/updates the Kubernetes Secret `ticketing-secrets` from Terraform outputs.
# This file contains NO secrets; it fetches endpoints from Terraform and reads DB password from your input/env.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TF_DIR="$ROOT_DIR/terraform"
_KS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! kubectl config view >/dev/null 2>&1; then
  echo "WARN: kubectl 이 기본 kubeconfig 를 읽지 못함 — refresh_kubeconfig.sh 로 재생성합니다." >&2
  bash "${_KS_DIR}/refresh_kubeconfig.sh"
fi

NAMESPACE="${NAMESPACE:-ticketing}"
SECRET_NAME="${SECRET_NAME:-ticketing-secrets}"

DB_PASSWORD="${DB_PASSWORD:-}"
if [ -z "${DB_PASSWORD}" ]; then
  echo "ERROR: DB_PASSWORD is required (export DB_PASSWORD=...)" >&2
  exit 1
fi

# post_apply local-exec 는 POST_APPLY_* 로 엔드포인트를 넘김(동일 apply 내 terraform output 회피).
if [ -n "${POST_APPLY_RDS_WRITER_ENDPOINT:-}" ]; then
  DB_WRITER="$POST_APPLY_RDS_WRITER_ENDPOINT"
else
  DB_WRITER="$(terraform -chdir="$TF_DIR" output -raw rds_writer_endpoint)"
fi

if [ -n "${POST_APPLY_REDIS_PRIMARY_ENDPOINT:-}" ]; then
  REDIS_EP="$POST_APPLY_REDIS_PRIMARY_ENDPOINT"
elif REDIS_EP="$(terraform -chdir="$TF_DIR" output -raw redis_endpoint 2>/dev/null)"; then
  :
elif REDIS_EP="$(terraform -chdir="$TF_DIR" output -raw elasticache_primary_endpoint 2>/dev/null)"; then
  :
else
  REGION_USE="${AWS_REGION:-${AWS_DEFAULT_REGION:-ap-northeast-2}}"
  if REDIS_EP="$(aws elasticache describe-replication-groups \
    --region "$REGION_USE" \
    --replication-group-id ticketing-redis \
    --query 'ReplicationGroups[0].NodeGroups[0].PrimaryEndpoint.Address' \
    --output text 2>/dev/null)" && [ -n "$REDIS_EP" ] && [ "$REDIS_EP" != "None" ]; then
    :
  else
    echo "ERROR: Redis 엔드포인트를 알 수 없음 (POST_APPLY_REDIS_PRIMARY_ENDPOINT / terraform output / AWS CLI). ElastiCache apply 후 재시도하세요." >&2
    exit 1
  fi
fi

SQS_QUEUE_NAME="${SQS_QUEUE_NAME:-ticketing-reservation.fifo}"

if [ -n "${POST_APPLY_SQS_QUEUE_URL:-}" ]; then
  SQS_QUEUE_URL="$POST_APPLY_SQS_QUEUE_URL"
else
  SQS_QUEUE_URL="$(terraform -chdir="$TF_DIR" output -raw sqs_queue_url)"
fi

# DB_READER_HOST: 단일 RDS 시 writer 와 동일. Replica 생기면 rds_reader_endpoint 로 분리.
# Read replica 를 실제로 쓰려면 ConfigMap 등에서 DB_READ_REPLICA_ENABLED=true 로 켠 뒤에만 리더 접속.
kubectl create secret generic "$SECRET_NAME" -n "$NAMESPACE" \
  --from-literal=DB_WRITER_HOST="$DB_WRITER" \
  --from-literal=DB_READER_HOST="$DB_WRITER" \
  --from-literal=DB_USER="root" \
  --from-literal=DB_PASSWORD="$DB_PASSWORD" \
  --from-literal=ELASTICACHE_PRIMARY_ENDPOINT="$REDIS_EP" \
  --from-literal=REDIS_HOST="$REDIS_EP" \
  --from-literal=SQS_QUEUE_NAME="$SQS_QUEUE_NAME" \
  --from-literal=SQS_QUEUE_URL="$SQS_QUEUE_URL" \
  --dry-run=client -o yaml \
  | kubectl apply -f -

echo "Applied secret: $NAMESPACE/$SECRET_NAME"

