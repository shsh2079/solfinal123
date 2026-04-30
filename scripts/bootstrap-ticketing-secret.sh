#!/usr/bin/env bash
# GitOps bootstrap — ArgoCD가 k8s/ 매니페스트를 sync 하기 전에 필요한 최소한의
# 리소스만 생성한다:
#   1) ticketing namespace
#   2) ticketing-secrets (terraform output 기반, git에 못 넣는 동적 값)
#
# 나머지(ConfigMap, ServiceAccount, Deployment, Service, HPA, Ingress,
# ScaledObject)는 모두 ArgoCD가 k8s/kustomization.yaml 따라 동기화한다.
#
# 과거에는 이 스크립트가 kubectl apply -k 로 전체 스택을 직접 생성했지만,
# GitOps 일원화 이후 역할을 bootstrap-only 로 축소했다.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$ROOT/terraform"
cd "$TF_DIR"

if [[ -z "${DB_PASSWORD:-}" ]]; then
  echo "ERROR: DB_PASSWORD 환경변수를 설정하세요." >&2
  echo "  export DB_PASSWORD='your-password'" >&2
  exit 1
fi

DB_W="$(terraform output -raw rds_writer_endpoint)"
# 단일 RDS 구성에서는 module.rds.reader_endpoint 가 null → terraform output 이 "not found".
# Read replica 가 생기기 전에는 writer 와 동일하게 두고, 생기면 별도 output 노출 후 교체.
DB_R="$(terraform output -raw rds_reader_endpoint 2>/dev/null || echo "$DB_W")"
REDIS_H="$(terraform output -raw redis_endpoint)"
SQS_URL="$(terraform output -raw sqs_queue_url)"
COGNITO_POOL="$(terraform output -raw cognito_user_pool_id)"
COGNITO_CID="$(terraform output -raw cognito_client_id)"

# ── 1) namespace: 이후 단계(Secret 생성 / DB init pod / ArgoCD sync)가
# 전부 ticketing ns 위에서 돌기 때문에 선제 생성. ArgoCD가 나중에 git의
# namespace.yaml을 적용해도 이미 존재 → no-op.
kubectl apply -f "$ROOT/k8s/namespace.yaml"

# ── 2) ticketing-secrets: DB endpoint / password / Redis / SQS / Cognito 등
# terraform output + DB_PASSWORD 환경변수를 합성. 민감값이라 git 미보관.
kubectl create secret generic ticketing-secrets \
  --from-literal=DB_WRITER_HOST="$DB_W" \
  --from-literal=DB_READER_HOST="$DB_R" \
  --from-literal=DB_USER=root \
  --from-literal=DB_PASSWORD="$DB_PASSWORD" \
  --from-literal=DB_NAME=ticketing \
  --from-literal=REDIS_HOST="$REDIS_H" \
  --from-literal=SQS_QUEUE_URL="$SQS_URL" \
  --from-literal=COGNITO_USER_POOL_ID="$COGNITO_POOL" \
  --from-literal=COGNITO_CLIENT_ID="$COGNITO_CID" \
  -n ticketing \
  --dry-run=client -o yaml | kubectl apply -f -

echo "bootstrap 완료: namespace + ticketing-secrets"
