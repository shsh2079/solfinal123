#!/usr/bin/env bash
set -euo pipefail

# Create/patch kube-system/aws-auth so EKS managed nodes can join the cluster.
# Uses Terraform output eks_node_role_arn.
#
# Usage (from terraform/ directory):
#   bash ../k8s/scripts/apply-aws-auth-from-terraform.sh

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TF_DIR="$ROOT_DIR/terraform"
KS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! kubectl config view >/dev/null 2>&1; then
  echo "WARN: kubectl 이 kubeconfig 를 읽지 못함 — refresh_kubeconfig.sh 로 재생성합니다." >&2
  bash "${KS_DIR}/refresh_kubeconfig.sh"
fi

ROLE_ARN="$(terraform -chdir="$TF_DIR" output -raw eks_node_role_arn 2>/dev/null || true)"
if [ -z "${ROLE_ARN:-}" ] || [ "${ROLE_ARN:-}" = "None" ]; then
  # output이 state에 아직 없을 수 있음(새 output 추가 직후). 그 경우 NodeGroup에서 nodeRole을 직접 조회한다.
  REGION="$(terraform -chdir="$TF_DIR" output -raw aws_region 2>/dev/null || true)"
  CLUSTER="$(terraform -chdir="$TF_DIR" output -raw eks_cluster_name 2>/dev/null || true)"
  NG="$(terraform -chdir="$TF_DIR" output -raw eks_app_node_group_name 2>/dev/null || true)"
  if [ -z "${REGION:-}" ] || [ -z "${CLUSTER:-}" ] || [ -z "${NG:-}" ]; then
    echo "ERROR: terraform outputs missing (aws_region/eks_cluster_name/eks_app_node_group_name)" >&2
    exit 1
  fi
  ROLE_ARN="$(aws eks describe-nodegroup --region "$REGION" --cluster-name "$CLUSTER" --nodegroup-name "$NG" \
    --query "nodegroup.nodeRole" --output text 2>/dev/null || true)"
fi

if [ -z "${ROLE_ARN:-}" ] || [ "${ROLE_ARN:-}" = "None" ]; then
  echo "ERROR: could not resolve node role ARN (terraform output eks_node_role_arn or aws eks describe-nodegroup)" >&2
  exit 1
fi

kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: aws-auth
  namespace: kube-system
data:
  mapRoles: |
    - rolearn: ${ROLE_ARN}
      username: system:node:{{EC2PrivateDNSName}}
      groups:
        - system:bootstrappers
        - system:nodes
EOF

echo "Applied kube-system/aws-auth mapRoles for: ${ROLE_ARN}"

