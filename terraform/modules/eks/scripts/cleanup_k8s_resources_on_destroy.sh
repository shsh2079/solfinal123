#!/usr/bin/env bash
# EKS destroy 시 null_resource 에서 호출. 환경변수: EKS_CLUSTER_NAME, EKS_REGION, EKS_VPC_ID
set -uo pipefail

CLUSTER_NAME="${EKS_CLUSTER_NAME:-}"
REGION="${EKS_REGION:-}"
VPC_ID="${EKS_VPC_ID:-}"

echo "=== Cleaning up Kubernetes-managed AWS resources before EKS destroy ==="

if [ -n "$CLUSTER_NAME" ] && [ -n "$REGION" ]; then
  if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1; then
    unset KUBECONFIG 2>/dev/null || true
    _TMP_KUBECONFIG="$(mktemp)"
    export KUBECONFIG="$_TMP_KUBECONFIG"
    trap 'rm -f "$_TMP_KUBECONFIG"' EXIT
    aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" --kubeconfig "$_TMP_KUBECONFIG" 2>/dev/null || true

    kubectl delete ingress --all --all-namespaces --timeout=120s 2>/dev/null || true

    kubectl delete svc --field-selector spec.type=LoadBalancer --all-namespaces --timeout=120s 2>/dev/null || true

    echo "Waiting 60s for AWS resources to be cleaned up by controllers..."
    sleep 60
  fi
fi

if [ -n "$VPC_ID" ] && [ -n "$REGION" ]; then
  echo "Cleaning up leftover ELBs in VPC $VPC_ID..."

  for LB_ARN in $(aws elbv2 describe-load-balancers --region "$REGION" \
    --query "LoadBalancers[?VpcId=='$VPC_ID'].LoadBalancerArn" --output text 2>/dev/null); do
    echo "Deleting load balancer: $LB_ARN"
    aws elbv2 delete-load-balancer --load-balancer-arn "$LB_ARN" --region "$REGION" 2>/dev/null || true
  done

  for CLB_NAME in $(aws elb describe-load-balancers --region "$REGION" \
    --query "LoadBalancerDescriptions[?VPCId=='$VPC_ID'].LoadBalancerName" --output text 2>/dev/null); do
    echo "Deleting classic LB: $CLB_NAME"
    aws elb delete-load-balancer --load-balancer-name "$CLB_NAME" --region "$REGION" 2>/dev/null || true
  done

  for TG_ARN in $(aws elbv2 describe-target-groups --region "$REGION" \
    --query "TargetGroups[?VpcId=='$VPC_ID'].TargetGroupArn" --output text 2>/dev/null); do
    echo "Deleting target group: $TG_ARN"
    aws elbv2 delete-target-group --target-group-arn "$TG_ARN" --region "$REGION" 2>/dev/null || true
  done

  echo "Waiting 30s for ENIs to detach..."
  sleep 30

  echo "Releasing Elastic IPs in VPC $VPC_ID..."
  for ALLOC_ID in $(aws ec2 describe-addresses --region "$REGION" \
    --filters "Name=domain,Values=vpc" \
    --query "Addresses[?NetworkInterfaceId!=null].{A:AllocationId,N:NetworkInterfaceId}" \
    --output text 2>/dev/null | while read -r AID NID; do
      ENI_VPC=$(aws ec2 describe-network-interfaces --region "$REGION" \
        --network-interface-ids "$NID" \
        --query 'NetworkInterfaces[0].VpcId' --output text 2>/dev/null)
      if [ "$ENI_VPC" = "$VPC_ID" ]; then echo "$AID"; fi
    done); do
    echo "Disassociating and releasing EIP: $ALLOC_ID"
    ASSOC_ID=$(aws ec2 describe-addresses --region "$REGION" \
      --allocation-ids "$ALLOC_ID" \
      --query 'Addresses[0].AssociationId' --output text 2>/dev/null)
    if [ "$ASSOC_ID" != "None" ] && [ -n "$ASSOC_ID" ]; then
      aws ec2 disassociate-address --association-id "$ASSOC_ID" --region "$REGION" 2>/dev/null || true
    fi
    aws ec2 release-address --allocation-id "$ALLOC_ID" --region "$REGION" 2>/dev/null || true
  done

  for ALLOC_ID in $(aws ec2 describe-addresses --region "$REGION" \
    --filters "Name=domain,Values=vpc" \
    --query "Addresses[?AssociationId==null].AllocationId" --output text 2>/dev/null); do
    echo "Releasing unused EIP: $ALLOC_ID"
    aws ec2 release-address --allocation-id "$ALLOC_ID" --region "$REGION" 2>/dev/null || true
  done

  echo "Cleaning up leftover ENIs (aws-K8S / ELB) in VPC $VPC_ID..."
  for ENI_ID in $(aws ec2 describe-network-interfaces --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query "NetworkInterfaces[?starts_with(Description, 'aws-K8S-') || contains(Description, 'ELB')].NetworkInterfaceId" \
    --output text 2>/dev/null); do
    [ -n "$ENI_ID" ] || continue
    ATTACH_ID=$(aws ec2 describe-network-interfaces --region "$REGION" \
      --network-interface-ids "$ENI_ID" \
      --query 'NetworkInterfaces[0].Attachment.AttachmentId' --output text 2>/dev/null || true)
    if [ "$ATTACH_ID" != "None" ] && [ -n "$ATTACH_ID" ]; then
      echo "Detaching ENI: $ENI_ID"
      aws ec2 detach-network-interface --attachment-id "$ATTACH_ID" --force --region "$REGION" 2>/dev/null || true
    fi
  done
  sleep 15
  for ENI_ID in $(aws ec2 describe-network-interfaces --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=status,Values=available" \
    --query "NetworkInterfaces[?starts_with(Description, 'aws-K8S-') || contains(Description, 'ELB')].NetworkInterfaceId" \
    --output text 2>/dev/null); do
    [ -n "$ENI_ID" ] || continue
    echo "Deleting ENI: $ENI_ID"
    aws ec2 delete-network-interface --network-interface-id "$ENI_ID" --region "$REGION" 2>/dev/null || true
  done

  echo "Cleaning up k8s-generated security groups in VPC $VPC_ID (skip Terraform SGs)..."
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
    if [[ "$SG_NAME" =~ ^k8s- ]]; then
      echo "Revoking rules for k8s SG: $SG_ID ($SG_NAME)"
      aws ec2 revoke-security-group-ingress --group-id "$SG_ID" --region "$REGION" \
        --ip-permissions "$(aws ec2 describe-security-groups --group-ids "$SG_ID" --region "$REGION" \
        --query 'SecurityGroups[0].IpPermissions' --output json 2>/dev/null)" 2>/dev/null || true
      aws ec2 revoke-security-group-egress --group-id "$SG_ID" --region "$REGION" \
        --ip-permissions "$(aws ec2 describe-security-groups --group-ids "$SG_ID" --region "$REGION" \
        --query 'SecurityGroups[0].IpPermissionsEgress' --output json 2>/dev/null)" 2>/dev/null || true
      echo "Deleting k8s SG: $SG_ID ($SG_NAME)"
      aws ec2 delete-security-group --group-id "$SG_ID" --region "$REGION" 2>/dev/null || true
    fi
  done
fi

echo "=== Cleanup complete ==="
