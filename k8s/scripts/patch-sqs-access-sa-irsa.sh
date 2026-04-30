#!/usr/bin/env bash
# sqs-access-sa 에 terraform output sqs_access_role_arn IRSA 주석 추가 (KEDA SQS 스케일러·워커 공용).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
_KS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="${KUBECTL_NAMESPACE:-ticketing}"
SA="${SQS_ACCESS_SA:-sqs-access-sa}"
TF_DIR="${ROOT}/terraform"

if ! kubectl config view >/dev/null 2>&1; then
  echo "WARN: kubeconfig 손상/없음 — refresh_kubeconfig.sh 실행" >&2
  bash "${_KS_DIR}/refresh_kubeconfig.sh"
fi

if [ -n "${SQS_ACCESS_ROLE_ARN:-}" ]; then
  ROLE_ARN="$SQS_ACCESS_ROLE_ARN"
elif [ -d "$TF_DIR" ] && command -v terraform >/dev/null 2>&1; then
  ROLE_ARN="$(terraform -chdir="$TF_DIR" output -raw sqs_access_role_arn)"
else
  echo "ERROR: SQS_ACCESS_ROLE_ARN 이 없고 terraform output 도 사용할 수 없습니다." >&2
  exit 1
fi

kubectl annotate serviceaccount "$SA" -n "$NS" \
  "eks.amazonaws.com/role-arn=${ROLE_ARN}" \
  --overwrite
echo "Annotated $NS/$SA with eks.amazonaws.com/role-arn=${ROLE_ARN}"
