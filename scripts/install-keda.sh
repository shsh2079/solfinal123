#!/usr/bin/env bash
# EKS에 KEDA 설치 (Helm).
# KEDA = Kubernetes Event-Driven Autoscaling
# worker-svc를 SQS 큐 길이 기반으로 스케일링하기 위해 사용한다.
# 사전: helm, kubectl, aws CLI / update-kubeconfig, terraform apply
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$ROOT/terraform"
cd "$TF_DIR"

ROLE_ARN="$(terraform output -raw keda_operator_role_arn)"
REGION="$(terraform output -raw aws_region)"

echo "KEDA operator role: $ROLE_ARN"
echo "region: $REGION"

if ! command -v helm >/dev/null 2>&1; then
  echo "helm 이 필요합니다. 예: curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
  exit 1
fi

helm repo add kedacore https://kedacore.github.io/charts 2>/dev/null || true
helm repo update

VALUES="$(mktemp)"
trap 'rm -f "$VALUES"' EXIT
cat >"$VALUES" <<EOF
serviceAccount:
  create: true
  name: keda-operator
  annotations:
    eks.amazonaws.com/role-arn: ${ROLE_ARN}

podIdentity:
  aws:
    irsa:
      enabled: true
      roleArn: ${ROLE_ARN}

# AWS region 환경변수 (KEDA SQS scaler가 SDK 호출 시 사용)
operator:
  env:
    - name: AWS_REGION
      value: ${REGION}
    - name: AWS_DEFAULT_REGION
      value: ${REGION}
EOF

if helm list -n keda 2>/dev/null | grep -q '^keda\b'; then
  echo "이미 설치됨 → upgrade"
  helm upgrade keda kedacore/keda \
    --namespace keda \
    -f "$VALUES" \
    --wait
else
  helm install keda kedacore/keda \
    --namespace keda \
    --create-namespace \
    -f "$VALUES" \
    --wait
fi

echo "완료: kubectl get pods -n keda"
kubectl get pods -n keda
