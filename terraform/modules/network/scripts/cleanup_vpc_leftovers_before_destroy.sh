#!/usr/bin/env bash
# VPC destroy 직전 정리. 환경변수: NET_VPC_ID, NET_REGION
set -euo pipefail

VPC_ID="${NET_VPC_ID:-}"
REGION="${NET_REGION:-}"

if [ -z "$VPC_ID" ]; then
  echo "VPC_ID empty; skipping cleanup."
  exit 0
fi

echo "=== VPC cleanup before destroy: $VPC_ID ($REGION) ==="

for VPCE_ID in $(aws ec2 describe-vpc-endpoints --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=vpc-endpoint-type,Values=Interface" \
  --query "VpcEndpoints[].VpcEndpointId" --output text 2>/dev/null); do
  [ -n "$VPCE_ID" ] || continue
  echo "Deleting VPC endpoint: $VPCE_ID"
  aws ec2 delete-vpc-endpoints --region "$REGION" --vpc-endpoint-ids "$VPCE_ID" 2>/dev/null || true
done

for ENI in $(aws ec2 describe-network-interfaces --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query "NetworkInterfaces[?starts_with(Description, 'aws-K8S-') || contains(Description, 'ELB')].NetworkInterfaceId" \
  --output text 2>/dev/null); do
  [ -n "$ENI" ] || continue
  ATTACH_ID=$(aws ec2 describe-network-interfaces --region "$REGION" \
    --network-interface-ids "$ENI" --query 'NetworkInterfaces[0].Attachment.AttachmentId' --output text 2>/dev/null || true)
  if [ "$ATTACH_ID" != "None" ] && [ -n "$ATTACH_ID" ]; then
    echo "Detaching ENI: $ENI"
    aws ec2 detach-network-interface --region "$REGION" --attachment-id "$ATTACH_ID" --force 2>/dev/null || true
  fi
done

sleep 10

for ENI in $(aws ec2 describe-network-interfaces --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=status,Values=available" \
  --query "NetworkInterfaces[?starts_with(Description, 'aws-K8S-') || contains(Description, 'ELB')].NetworkInterfaceId" \
  --output text 2>/dev/null); do
  [ -n "$ENI" ] || continue
  echo "Deleting ENI: $ENI"
  aws ec2 delete-network-interface --region "$REGION" --network-interface-id "$ENI" 2>/dev/null || true
done

TF_SG_NAMES="prod-monitoring-sg prod-eks-sg prod-rds-sg Cache_SG default"
for SG_ID in $(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query "SecurityGroups[].GroupId" --output text 2>/dev/null); do
  [ -n "$SG_ID" ] || continue
  SG_NAME=$(aws ec2 describe-security-groups --region "$REGION" --group-ids "$SG_ID" \
    --query "SecurityGroups[0].GroupName" --output text 2>/dev/null || true)
  case " $TF_SG_NAMES " in
    *" $SG_NAME "*) continue ;;
  esac

  if [[ "$SG_NAME" =~ ^k8s- ]] || [[ "$SG_NAME" =~ ^eks-cluster-sg- ]]; then
    echo "Attempting to delete k8s SG: $SG_ID ($SG_NAME)"
    aws ec2 revoke-security-group-ingress --region "$REGION" --group-id "$SG_ID" \
      --ip-permissions "$(aws ec2 describe-security-groups --region "$REGION" --group-ids "$SG_ID" --query 'SecurityGroups[0].IpPermissions' --output json 2>/dev/null)" 2>/dev/null || true
    aws ec2 revoke-security-group-egress --region "$REGION" --group-id "$SG_ID" \
      --ip-permissions "$(aws ec2 describe-security-groups --region "$REGION" --group-ids "$SG_ID" --query 'SecurityGroups[0].IpPermissionsEgress' --output json 2>/dev/null)" 2>/dev/null || true
    aws ec2 delete-security-group --region "$REGION" --group-id "$SG_ID" 2>/dev/null || true
  fi
done

echo "=== VPC cleanup complete ==="
