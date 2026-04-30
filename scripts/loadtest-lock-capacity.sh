#!/usr/bin/env bash
set -euo pipefail

# Lock cluster capacity for a load test:
# - EKS managed node group min/desired/max are pinned to the same node count.
# - Cluster Autoscaler is scaled to 0 so it cannot remove idle nodes while you prepare traffic.
# - read/write HPAs are pinned to fixed burst pod counts.
# - worker KEDA is paused and worker-svc-burst is scaled manually.
#
# Example:
#   bash scripts/loadtest-lock-capacity.sh -n 16 -wr 8 -r 4 -wk 20
#
# Restore afterwards:
#   bash scripts/loadtest-unlock-capacity.sh

NS="${KUBECTL_NAMESPACE:-ticketing}"
LOCK_CM="${LOADTEST_LOCK_CONFIGMAP:-ticketing-loadtest-capacity-lock}"

_die() { echo "ERROR: $*" >&2; exit 1; }
_need() { command -v "$1" >/dev/null 2>&1 || _die "missing command: $1"; }

_script_dir() { cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd; }
_tf_dir() { cd "$(_script_dir)/../terraform" && pwd; }
_tf_out() { terraform -chdir="$(_tf_dir)" output -raw "$1" 2>/dev/null || true; }

_json_get() {
  python -c 'import json,sys
data=json.load(sys.stdin)
cur=data
for part in sys.argv[1].split("."):
    cur = cur.get(part, "") if isinstance(cur, dict) else ""
print(cur if cur is not None else "")' "$1"
}

_get_hpa_field() {
  local hpa="$1" field="$2"
  kubectl -n "$NS" get "hpa/$hpa" -o "jsonpath={.spec.${field}}" 2>/dev/null || true
}

_get_keda_field() {
  local field="$1"
  kubectl -n "$NS" get scaledobject/worker-svc-sqs -o "jsonpath={.spec.${field}}" 2>/dev/null || true
}

_get_keda_paused() {
  kubectl -n "$NS" get scaledobject/worker-svc-sqs -o 'jsonpath={.metadata.annotations.autoscaling\.keda\.sh/paused}' 2>/dev/null || true
}

_save_lock_state() {
  local region="$1" cluster="$2" ng="$3" node_json="$4"
  local node_min node_desired node_max ca_replicas
  node_min="$(printf "%s" "$node_json" | _json_get "nodegroup.scalingConfig.minSize")"
  node_desired="$(printf "%s" "$node_json" | _json_get "nodegroup.scalingConfig.desiredSize")"
  node_max="$(printf "%s" "$node_json" | _json_get "nodegroup.scalingConfig.maxSize")"
  ca_replicas="$(kubectl -n kube-system get deploy/cluster-autoscaler -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
  ca_replicas="${ca_replicas:-1}"

  kubectl -n "$NS" create configmap "$LOCK_CM" \
    --from-literal=aws_region="$region" \
    --from-literal=cluster_name="$cluster" \
    --from-literal=nodegroup_name="$ng" \
    --from-literal=node_min="$node_min" \
    --from-literal=node_desired="$node_desired" \
    --from-literal=node_max="$node_max" \
    --from-literal=ca_replicas="$ca_replicas" \
    --from-literal=write_hpa_min="$(_get_hpa_field write-api-hpa minReplicas)" \
    --from-literal=write_hpa_max="$(_get_hpa_field write-api-hpa maxReplicas)" \
    --from-literal=read_hpa_min="$(_get_hpa_field read-api-hpa minReplicas)" \
    --from-literal=read_hpa_max="$(_get_hpa_field read-api-hpa maxReplicas)" \
    --from-literal=keda_min="$(_get_keda_field minReplicaCount)" \
    --from-literal=keda_max="$(_get_keda_field maxReplicaCount)" \
    --from-literal=keda_paused="$(_get_keda_paused)" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

_patch_hpa_fixed() {
  local hpa="$1" replicas="$2"
  local deploy="$3"
  if (( replicas <= 0 )); then
    kubectl -n "$NS" scale "deploy/$deploy" --replicas=0 >/dev/null 2>&1 || true
    kubectl -n "$NS" patch "hpa/$hpa" --type merge -p '{"spec":{"minReplicas":1,"maxReplicas":1}}' >/dev/null 2>&1 || true
    return 0
  fi
  kubectl -n "$NS" patch "hpa/$hpa" --type merge -p "{\"spec\":{\"minReplicas\":${replicas},\"maxReplicas\":${replicas}}}" >/dev/null
  kubectl -n "$NS" scale "deploy/$deploy" --replicas="$replicas" >/dev/null 2>&1 || true
}

_wait_for_nodes() {
  local expected="$1"
  local timeout="${LOADTEST_LOCK_WAIT_SEC:-1200}"
  local end=$((SECONDS + timeout))
  echo "waiting for Ready nodes >= ${expected} (timeout ${timeout}s)"
  while (( SECONDS < end )); do
    local ready
    ready="$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 ~ /Ready/ {n++} END {print n+0}')"
    if (( ready >= expected )); then
      echo "Ready nodes: ${ready}"
      return 0
    fi
    echo "Ready nodes: ${ready}/${expected}"
    sleep 15
  done
  _die "timed out waiting for ${expected} Ready nodes"
}

nodes="" wr="" rd="" wk=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--nodes) nodes="$2"; shift 2 ;;
    -wr|--write) wr="$2"; shift 2 ;;
    -r|--read) rd="$2"; shift 2 ;;
    -wk|--worker) wk="$2"; shift 2 ;;
    *) _die "unknown arg: $1 (use: -n <nodes> -wr <write-burst> -r <read-burst> -wk <worker-burst>)" ;;
  esac
done

[[ -n "$nodes" && -n "$wr" && -n "$rd" && -n "$wk" ]] || _die "required: -n/-wr/-r/-wk"
[[ "$nodes" =~ ^[0-9]+$ && "$wr" =~ ^[0-9]+$ && "$rd" =~ ^[0-9]+$ && "$wk" =~ ^[0-9]+$ ]] || _die "all capacity values must be non-negative integers"
(( nodes >= 1 )) || _die "nodes must be >= 1"

_need kubectl
_need aws
_need terraform
_need python

region="$(_tf_out aws_region)"
cluster="$(_tf_out eks_cluster_name)"
ng="$(_tf_out eks_app_node_group_name)"
[[ -n "$region" && -n "$cluster" && -n "$ng" ]] || _die "terraform outputs missing (aws_region/eks_cluster_name/eks_app_node_group_name)"

node_json="$(aws eks describe-nodegroup --region "$region" --cluster-name "$cluster" --nodegroup-name "$ng")"
_save_lock_state "$region" "$cluster" "$ng" "$node_json"

echo "pinning node group ${ng}: min=desired=max=${nodes}"
aws eks update-nodegroup-config \
  --region "$region" \
  --cluster-name "$cluster" \
  --nodegroup-name "$ng" \
  --scaling-config "minSize=${nodes},desiredSize=${nodes},maxSize=${nodes}" \
  >/dev/null

echo "pausing Cluster Autoscaler"
kubectl -n kube-system scale deploy/cluster-autoscaler --replicas=0 >/dev/null 2>&1 || true

echo "pinning burst pods: write=${wr}, read=${rd}, worker=${wk}"
_patch_hpa_fixed write-api-hpa "$wr" write-api-burst
_patch_hpa_fixed read-api-hpa "$rd" read-api-burst
kubectl -n "$NS" annotate scaledobject/worker-svc-sqs autoscaling.keda.sh/paused=true --overwrite >/dev/null 2>&1 || true
kubectl -n "$NS" scale deploy/worker-svc-burst --replicas="$wk" >/dev/null 2>&1 || true

_wait_for_nodes "$nodes"

kubectl -n "$NS" get deploy read-api read-api-burst write-api write-api-burst worker-svc worker-svc-burst -o wide 2>/dev/null || true
echo "LOCKED: capacity will stay pinned until scripts/loadtest-unlock-capacity.sh is run."
