#!/usr/bin/env bash
set -euo pipefail

# Restore the state saved by scripts/loadtest-lock-capacity.sh.

NS="${KUBECTL_NAMESPACE:-ticketing}"
LOCK_CM="${LOADTEST_LOCK_CONFIGMAP:-ticketing-loadtest-capacity-lock}"

_die() { echo "ERROR: $*" >&2; exit 1; }
_need() { command -v "$1" >/dev/null 2>&1 || _die "missing command: $1"; }

_cm() {
  local key="$1"
  kubectl -n "$NS" get "cm/$LOCK_CM" -o "jsonpath={.data.${key}}" 2>/dev/null || true
}

_patch_hpa_restore() {
  local hpa="$1" min="$2" max="$3"
  if [[ -n "$min" && -n "$max" ]]; then
    kubectl -n "$NS" patch "hpa/$hpa" --type merge -p "{\"spec\":{\"minReplicas\":${min},\"maxReplicas\":${max}}}" >/dev/null 2>&1 || true
  fi
}

_need kubectl
_need aws

kubectl -n "$NS" get "cm/$LOCK_CM" >/dev/null 2>&1 || _die "lock state not found: $NS/$LOCK_CM"

region="$(_cm aws_region)"
cluster="$(_cm cluster_name)"
ng="$(_cm nodegroup_name)"
node_min="$(_cm node_min)"
node_desired="$(_cm node_desired)"
node_max="$(_cm node_max)"
ca_replicas="$(_cm ca_replicas)"

[[ -n "$region" && -n "$cluster" && -n "$ng" && -n "$node_min" && -n "$node_desired" && -n "$node_max" ]] || _die "lock state is incomplete"
ca_replicas="${ca_replicas:-1}"

echo "restoring node group ${ng}: min=${node_min}, desired=${node_desired}, max=${node_max}"
aws eks update-nodegroup-config \
  --region "$region" \
  --cluster-name "$cluster" \
  --nodegroup-name "$ng" \
  --scaling-config "minSize=${node_min},desiredSize=${node_desired},maxSize=${node_max}" \
  >/dev/null

echo "restoring app autoscalers"
_patch_hpa_restore write-api-hpa "$(_cm write_hpa_min)" "$(_cm write_hpa_max)"
_patch_hpa_restore read-api-hpa "$(_cm read_hpa_min)" "$(_cm read_hpa_max)"

keda_min="$(_cm keda_min)"
keda_max="$(_cm keda_max)"
if [[ -n "$keda_min" && -n "$keda_max" ]]; then
  kubectl -n "$NS" patch scaledobject/worker-svc-sqs --type merge -p "{\"spec\":{\"minReplicaCount\":${keda_min},\"maxReplicaCount\":${keda_max}}}" >/dev/null 2>&1 || true
fi

keda_paused="$(_cm keda_paused)"
if [[ "$keda_paused" == "true" ]]; then
  kubectl -n "$NS" annotate scaledobject/worker-svc-sqs autoscaling.keda.sh/paused=true --overwrite >/dev/null 2>&1 || true
else
  kubectl -n "$NS" annotate scaledobject/worker-svc-sqs autoscaling.keda.sh/paused- >/dev/null 2>&1 || true
fi

echo "restoring Cluster Autoscaler replicas=${ca_replicas}"
kubectl -n kube-system scale deploy/cluster-autoscaler --replicas="$ca_replicas" >/dev/null 2>&1 || true

kubectl -n "$NS" delete "cm/$LOCK_CM" >/dev/null 2>&1 || true
echo "UNLOCKED: previous node group and autoscaler settings were restored."
