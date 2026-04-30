#!/usr/bin/env bash
set -euo pipefail

# Run the same steps as terraform output zzzzz, but reliably on Linux even
# when scripts were edited on Windows (CRLF). No extra flags needed.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS="${TICKETING_NAMESPACE:-ticketing}"

bash "$ROOT_DIR/scripts/normalize-line-endings.sh" >/dev/null

cd "$ROOT_DIR/terraform"

kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS" >/dev/null

NAMESPACE="$NS" bash "$ROOT_DIR/k8s/scripts/apply-secrets-from-terraform.sh"
kubectl delete pdb metrics-server -n kube-system --ignore-not-found >/dev/null 2>&1 || true
kubectl apply -k "$ROOT_DIR/k8s"

if kubectl -n kube-system get deploy metrics-server >/dev/null 2>&1; then
  kubectl -n kube-system patch deployment metrics-server --type=strategic -p \
    '{"spec":{"template":{"spec":{"priorityClassName":"system-cluster-critical"}}}}' 2>/dev/null || true
  kubectl -n kube-system rollout status deployment/metrics-server --timeout=120s 2>/dev/null || true
fi

# manual mode also needs ECR image injection (otherwise it tries DockerHub: ticketing/*:latest -> ImagePullBackOff)
ACCOUNT_ID="$(terraform output -raw aws_account_id 2>/dev/null || true)"
REGION="$(terraform output -raw aws_region 2>/dev/null || true)"
IMAGE_TAG="${IMAGE_TAG:-latest}"
ECR_REPO_TICKETING_WAS="${ECR_REPO_TICKETING_WAS:-ticketing/ticketing-was}"
ECR_REPO_WORKER_SVC="${ECR_REPO_WORKER_SVC:-ticketing/worker-svc}"
if [[ -n "$ACCOUNT_ID" && -n "$REGION" ]]; then
  ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
  WAS_IMAGE="${ECR_REGISTRY}/${ECR_REPO_TICKETING_WAS}:${IMAGE_TAG}"
  WORKER_IMAGE="${ECR_REGISTRY}/${ECR_REPO_WORKER_SVC}:${IMAGE_TAG}"
  kubectl -n "$NS" set image deploy/read-api "read-api=${WAS_IMAGE}" >/dev/null || true
  kubectl -n "$NS" set image deploy/read-api-burst "read-api=${WAS_IMAGE}" >/dev/null || true
  kubectl -n "$NS" set image deploy/write-api "write-api=${WAS_IMAGE}" >/dev/null || true
  kubectl -n "$NS" set image deploy/write-api-burst "write-api=${WAS_IMAGE}" >/dev/null || true
  kubectl -n "$NS" set image deploy/worker-svc "worker-svc=${WORKER_IMAGE}" >/dev/null || true
  kubectl -n "$NS" set image deploy/worker-svc-burst "worker-svc=${WORKER_IMAGE}" >/dev/null || true
fi

SQS_ROLE_ARN="$(terraform output -raw sqs_access_role_arn 2>/dev/null || true)"
if [[ -n "$SQS_ROLE_ARN" ]]; then
  # worker-svc(write-api)에서 SQS Receive/Delete 하려면 IRSA 권한 주입 필요
  kubectl -n "$NS" annotate sa sqs-access-sa "eks.amazonaws.com/role-arn=${SQS_ROLE_ARN}" --overwrite >/dev/null 2>&1 || true
fi

TICKETING_NAMESPACE="$NS" bash "$ROOT_DIR/k8s/scripts/sync-s3-endpoints-from-ingress.sh"
kubectl -n "$NS" patch cm ticketing-config --type merge -p '{"data":{"DB_NAME":"ticketing"}}'
kubectl -n "$NS" rollout restart deploy/worker-svc deploy/worker-svc-burst || true
kubectl -n "$NS" rollout restart deploy/read-api deploy/read-api-burst || true
kubectl -n "$NS" rollout restart deploy/write-api deploy/write-api-burst || true

