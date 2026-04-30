#!/usr/bin/env bash
# RDS writer 로 socat 터널 Pod + (선택) port-forward. terraform output 으로 엔드포인트 조회.
# ticketing-priority-devtools(preemption Never) + 작은 requests. 워커를 선점하지 않음.
set -euo pipefail

NS="${KUBECTL_NAMESPACE:-ticketing}"
POD="${RDS_BASTION_POD:-rds-bastion}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TF_DIR="${REPO_ROOT}/terraform"

if [ -z "${RDS_HOST:-}" ]; then
  RDS_HOST="$(terraform -chdir="$TF_DIR" output -raw rds_writer_endpoint)"
fi
AWS_REGION="${AWS_REGION:-$(terraform -chdir="$TF_DIR" output -raw aws_region)}"
EKS_NAME="${EKS_NAME:-$(terraform -chdir="$TF_DIR" output -raw eks_cluster_name)}"

aws eks update-kubeconfig --region "$AWS_REGION" --name "$EKS_NAME" >/dev/null
kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS"

kubectl -n "$NS" delete pod "$POD" --ignore-not-found 2>/dev/null || true

kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${POD}
  namespace: ${NS}
spec:
  priorityClassName: ticketing-priority-devtools
  restartPolicy: Never
  containers:
    - name: socat
      image: alpine:3.20
      resources:
        requests:
          cpu: "25m"
          memory: "32Mi"
        limits:
          cpu: "500m"
          memory: "128Mi"
      command: ["/bin/sh", "-c"]
      args:
        - apk add --no-cache socat >/dev/null && exec socat TCP-LISTEN:3306,fork,reuseaddr TCP:${RDS_HOST}:3306
EOF

kubectl -n "$NS" wait --for=condition=Ready "pod/$POD" --timeout=120s

if [ "${1:-}" = "--port-forward" ]; then
  HOST_BIND="${PORT_FORWARD_BIND:-0.0.0.0}"
  LOCAL_PORT="${LOCAL_PORT:-13306}"
  VM_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  echo "Pod ready. VM_IP=${VM_IP:-unknown}"
  echo "Windows: Test-NetConnection -ComputerName <VM_IP> -Port ${LOCAL_PORT}"
  exec kubectl -n "$NS" port-forward --address "$HOST_BIND" "pod/$POD" "${LOCAL_PORT}:3306"
fi

echo "Pod $NS/$POD is Ready. Example:"
echo "  kubectl -n $NS port-forward --address 0.0.0.0 pod/$POD 13306:3306"
