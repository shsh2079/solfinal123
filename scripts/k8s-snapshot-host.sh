#!/usr/bin/env bash
set -eu
set -o pipefail 2>/dev/null || true

# Terminal locale may not be UTF-8; keep output ASCII and
# best-effort force UTF-8 locale to avoid garbled text.
export LC_ALL="${LC_ALL:-C.UTF-8}" 2>/dev/null || true
export LANG="${LANG:-C.UTF-8}" 2>/dev/null || true

# Print k8s snapshot using *host* kubectl credentials.
# This is meant to be independent from the tools-once Pod serviceAccount RBAC.
#
# Usage:
#   bash scripts/k8s-snapshot-host.sh
#   TICKETING_NAMESPACE=ticketing bash scripts/k8s-snapshot-host.sh

NS="${TICKETING_NAMESPACE:-ticketing}"

_jsonpath_ns() {
  local res="$1"
  local jp="$2"
  kubectl -n "$NS" get "$res" -o "jsonpath=${jp}" 2>/dev/null || true
}

_deploy_ready_desired() {
  local name="$1"
  local ready desired
  ready="$(_jsonpath_ns "deploy/${name}" '{.status.readyReplicas}')"
  desired="$(_jsonpath_ns "deploy/${name}" '{.status.replicas}')"
  ready="${ready:-0}"
  desired="${desired:-0}"
  printf "%s / desired=%s" "$ready" "$desired"
}

_deploy_ready_desired_sum() {
  # stable+burst 같이 세는 용도 (예: write-api + write-api-burst)
  local a="$1" b="$2"
  local a_ready a_desired b_ready b_desired
  a_ready="$(_jsonpath_ns "deploy/${a}" '{.status.readyReplicas}')"; a_ready="${a_ready:-0}"
  a_desired="$(_jsonpath_ns "deploy/${a}" '{.status.replicas}')";     a_desired="${a_desired:-0}"
  b_ready="$(_jsonpath_ns "deploy/${b}" '{.status.readyReplicas}')"; b_ready="${b_ready:-0}"
  b_desired="$(_jsonpath_ns "deploy/${b}" '{.status.replicas}')";     b_desired="${b_desired:-0}"
  printf "%s / desired=%s" "$((a_ready + b_ready))" "$((a_desired + b_desired))"
}

_scaledobject_keda_summary() {
  # worker-svc-sqs 의 min/max/paused 상태를 함께 보여준다(토글/부하 테스트 디버깅용).
  # 권한/리소스 없으면 N/A.
  local obj="scaledobject/worker-svc-sqs"
  local min max paused
  min="$(_jsonpath_ns "$obj" '{.spec.minReplicaCount}')"; min="${min:-N/A}"
  max="$(_jsonpath_ns "$obj" '{.spec.maxReplicaCount}')"; max="${max:-N/A}"
  paused="$(_jsonpath_ns "$obj" '{.metadata.annotations.autoscaling\.keda\.sh/paused}')"
  paused="${paused:-false}"
  printf "keda(min=%s max=%s paused=%s)" "$min" "$max" "$paused"
}

_nodes_ready_best_effort() {
  # nodes is cluster-scoped and may be RBAC-blocked; best-effort.
  # 1) Count Ready nodes directly
  # 2) If blocked, fallback to kube-system/aws-node DaemonSet numberReady
  local out cnt
  out="$(kubectl get nodes -o jsonpath='{range .items[*]}{range .status.conditions[?(@.type=="Ready")]}{.status}{"\n"}{end}{end}' 2>/dev/null || true)"
  if [[ -n "$out" ]]; then
    # "True" line count = Ready nodes
    cnt="$(printf "%s" "$out" | tr -d '\r' | awk '$1=="True"{c++} END{print c+0}')"
    printf "%s" "${cnt:-0}"
    return 0
  fi

  # fallback: aws-node DaemonSet numberReady (proxy for healthy nodes)
  out="$(kubectl -n kube-system get ds aws-node -o jsonpath='{.status.numberReady}' 2>/dev/null || true)"
  if [[ -n "$out" ]]; then
    printf "%s" "$out"
    return 0
  fi

  printf "N/A"
}

echo "-----------------------------------------------------------"
echo "  eks nodes (ready)   : $(_nodes_ready_best_effort)"
echo "  write pods          : $(_deploy_ready_desired_sum write-api write-api-burst)"
echo "  read  pods          : $(_deploy_ready_desired_sum read-api read-api-burst)"
echo "  work  pods          : $(_deploy_ready_desired_sum worker-svc worker-svc-burst)  $(_scaledobject_keda_summary)"
echo "    - work stable     : $(_deploy_ready_desired worker-svc)"
echo "    - work burst      : $(_deploy_ready_desired worker-svc-burst)"
echo "-----------------------------------------------------------"

