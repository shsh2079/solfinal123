#!/usr/bin/env bash
# EKS에 AWS Load Balancer Controller 설치 (Helm).
# 사전: helm, kubectl, aws CLI / update-kubeconfig, terraform apply
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$ROOT/terraform"
cd "$TF_DIR"

CLUSTER_NAME="$(terraform output -raw eks_cluster_name)"
VPC_ID="$(terraform output -raw vpc_id)"
ROLE_ARN="$(terraform output -raw alb_controller_role_arn)"
REGION="$(terraform output -raw aws_region)"

echo "cluster=$CLUSTER_NAME vpc=$VPC_ID region=$REGION"

if ! command -v helm >/dev/null 2>&1; then
  echo "helm 이 필요합니다. setup-all.sh 거쳐 실행하거나 helm을 설치하세요."
  exit 1
fi

# ── 사전 정리: stale webhook config 선제 삭제 ─────────────────────
# ALB Controller는 pod 내부에서 self-signed cert를 생성하고 webhook의
# caBundle로 주입한다. 재설치/재실행 시 이전 caBundle이 남아있으면 새 pod가
# serve하는 cert와 불일치 → "x509: certificate signed by unknown authority"
# 에러로 Service/Ingress 생성이 webhook 단계에서 거부됨.
# helm chart가 webhook 리소스를 처음부터 새 caBundle로 생성하도록 미리 제거.
echo "기존 webhook config 정리 중 (stale caBundle 방지)..."
kubectl delete validatingwebhookconfiguration aws-load-balancer-webhook --ignore-not-found 2>/dev/null || true
kubectl delete mutatingwebhookconfiguration aws-load-balancer-webhook --ignore-not-found 2>/dev/null || true

helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
helm repo update

VALUES="$(mktemp)"
trap 'rm -f "$VALUES"' EXIT
cat >"$VALUES" <<EOF
clusterName: ${CLUSTER_NAME}
region: ${REGION}
vpcId: ${VPC_ID}
replicaCount: 1
serviceAccount:
  create: true
  name: aws-load-balancer-controller
  annotations:
    eks.amazonaws.com/role-arn: ${ROLE_ARN}
EOF

if helm list -n kube-system | grep -q aws-load-balancer-controller; then
  echo "이미 설치됨 → upgrade"
  helm upgrade aws-load-balancer-controller eks/aws-load-balancer-controller \
    -n kube-system -f "$VALUES" --wait
else
  helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
    -n kube-system -f "$VALUES" --wait
fi

# ── 사후 검증: rollout 대기 + webhook cert sanity check ───────────
# helm --wait이 있지만 controller pod가 self-signed cert를 재생성하는 타이밍이
# webhook 주입 직후인 경우가 있어, 실제 dry-run으로 TLS handshake를 확인.
echo "controller rollout 대기..."
kubectl rollout status deployment/aws-load-balancer-controller -n kube-system --timeout=180s

echo "webhook cert 검증 (dry-run으로 실제 webhook 호출)..."
WEBHOOK_PROBE=$(cat <<'YAML'
apiVersion: v1
kind: Service
metadata:
  name: alb-webhook-probe
  namespace: default
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: external
spec:
  type: LoadBalancer
  ports:
    - port: 80
  selector:
    app: nonexistent
YAML
)
for i in 1 2 3 4 5 6; do
  if echo "$WEBHOOK_PROBE" | kubectl create --dry-run=server -f - >/dev/null 2>&1; then
    echo "webhook cert 검증 통과"
    break
  fi
  if [ "$i" -eq 6 ]; then
    echo "ERROR: webhook cert 검증 실패. controller 로그 확인 필요:" >&2
    echo "  kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=50" >&2
    exit 1
  fi
  echo "  webhook 준비 대기 중... ($i/6)"
  sleep 10
done

echo "완료: kubectl get deployment -n kube-system aws-load-balancer-controller"
