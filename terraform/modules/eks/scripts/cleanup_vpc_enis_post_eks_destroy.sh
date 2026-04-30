#!/usr/bin/env bash
# 노드그룹/클러스터 삭제 후 ENI 잔재 정리. 환경변수: EKS_POST_REGION, EKS_POST_VPC_ID
set -euo pipefail

REGION="${EKS_POST_REGION:-}"
VPC_ID="${EKS_POST_VPC_ID:-}"

echo "=== Post-EKS cleanup: deleting leftover aws-k8s ENIs in VPC $VPC_ID ==="

if [ -z "$VPC_ID" ]; then
  echo "VPC_ID empty; skipping."
  exit 0
fi

for i in 1 2 3 4 5; do
  ENIS=$(aws ec2 describe-network-interfaces --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=status,Values=available" \
    --query "NetworkInterfaces[?starts_with(Description, 'aws-K8S-')].NetworkInterfaceId" \
    --output text 2>/dev/null || true)

  if [ -z "$ENIS" ]; then
    echo "No aws-k8s ENIs found (attempt $i/5)."
    sleep 10
    continue
  fi

  for ENI_ID in $ENIS; do
    echo "Deleting ENI: $ENI_ID"
    aws ec2 delete-network-interface --network-interface-id "$ENI_ID" --region "$REGION" 2>/dev/null || true
  done

  sleep 10
done

echo "=== Post-EKS cleanup complete ==="
