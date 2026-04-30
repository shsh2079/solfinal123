#!/usr/bin/env bash
# apply 마지막 null_resource 또는 수동 실행: ~/.kube/config 가 깨져 있으면 삭제 후 EKS 컨텍스트만 다시 등록.
# (parallel local-exec 가 temp 만 쓰더라도, 예전에 깨진 기본 파일이 남으면 수동 kubectl 이 실패함)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ -z "${CLUSTER_NAME:-}" ]; then
  CLUSTER_NAME="$(terraform -chdir="$TF_DIR" output -raw eks_cluster_name)"
fi
if [ -z "${AWS_REGION:-}" ]; then
  AWS_REGION="$(terraform -chdir="$TF_DIR" output -raw aws_region)"
fi

mkdir -p "${HOME}/.kube"
_cfg="${HOME}/.kube/config"

if [ -f "$_cfg" ]; then
  _remove=0
  if command -v kubectl >/dev/null 2>&1; then
    kubectl config view >/dev/null 2>&1 || _remove=1
  fi
  if [ "$_remove" = "1" ]; then
    rm -f "$_cfg"
    echo "Removed invalid ~/.kube/config (kubectl could not parse it)" >&2
  fi
fi

unset KUBECONFIG 2>/dev/null || true

if ! aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION"; then
  echo "WARN: update-kubeconfig failed; removing $_cfg and retrying once" >&2
  rm -f "$_cfg"
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION"
fi

echo "Host kubeconfig OK: cluster=$CLUSTER_NAME region=$AWS_REGION"
