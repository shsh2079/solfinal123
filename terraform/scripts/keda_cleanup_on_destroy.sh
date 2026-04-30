#!/usr/bin/env bash
# KEDA cleanup hook for terraform destroy.
# 목적: destroy 직전/중간에 KEDA가 남겨두는 webhook/secret/finalizer 잔재 때문에
# 다음 apply에서 "cannot re-use a name that is still in use"가 나는 것을 방지한다.
set -euo pipefail

NS="${KEDA_NAMESPACE:-keda}"
REL="${KEDA_RELEASE_NAME:-keda}"
WAIT_SEC="${KEDA_CLEANUP_WAIT_SEC:-300}"
FORCE_FINALIZERS="${KEDA_FORCE_REMOVE_FINALIZERS:-0}"
FORCE_AFTER_SEC="${KEDA_FORCE_FINALIZERS_AFTER_SEC:-20}"

if [ -z "${CLUSTER_NAME:-}" ] || [ -z "${AWS_REGION:-}" ]; then
  echo "ERROR: CLUSTER_NAME/AWS_REGION env required" >&2
  exit 1
fi

unset KUBECONFIG 2>/dev/null || true
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1 || true

if ! command -v helm >/dev/null 2>&1; then
  echo "WARN: helm not found; skipping helm uninstall (will try kubectl cleanup only)" >&2
fi
if ! command -v kubectl >/dev/null 2>&1; then
  echo "WARN: kubectl not found; cannot cleanup keda" >&2
  exit 0
fi

echo "KEDA destroy-cleanup: ns=$NS release=$REL wait=${WAIT_SEC}s" >&2

# 1) Best-effort helm uninstall (if helm present)
if command -v helm >/dev/null 2>&1; then
  if helm -n "$NS" status "$REL" >/dev/null 2>&1; then
    echo "Uninstalling helm release $NS/$REL ..." >&2
    # IMPORTANT: terraform destroy가 10분 기본 타임아웃에 걸리지 않게,
    # helm uninstall은 WAIT_SEC 안에 끝나도록 강제 제한한다.
    if command -v timeout >/dev/null 2>&1; then
      timeout "${WAIT_SEC}s" helm -n "$NS" uninstall "$REL" --timeout "${WAIT_SEC}s" >/dev/null 2>&1 || true
    else
      helm -n "$NS" uninstall "$REL" --timeout "${WAIT_SEC}s" >/dev/null 2>&1 || true
    fi
  fi
fi

# 2) Delete leftover release secrets (these block re-install)
if kubectl get ns "$NS" >/dev/null 2>&1; then
  kubectl -n "$NS" get secret 2>/dev/null \
    | awk '{print $1}' \
    | grep "^sh\\.helm\\.release\\.v1\\.${REL}\\." \
    | xargs -r kubectl -n "$NS" delete secret --ignore-not-found --wait=false >/dev/null 2>&1 || true
fi

# 3) Try to delete namespace (optional, but helps remove webhooks in some broken states)
# Default kubectl delete ns blocks until the object is gone; Terminating can take unbounded time
# and skips the timed loop below. Prefer async delete; fall back to capped synchronous delete.
if ! kubectl delete ns "$NS" --ignore-not-found --wait=false >/dev/null 2>&1; then
  if command -v timeout >/dev/null 2>&1; then
    timeout "${WAIT_SEC}s" kubectl delete ns "$NS" --ignore-not-found >/dev/null 2>&1 || true
  else
    kubectl delete ns "$NS" --ignore-not-found >/dev/null 2>&1 || true
  fi
fi

deadline=$(( $(date +%s) + WAIT_SEC ))
start_ts="$(date +%s)"
while [ "$(date +%s)" -lt "$deadline" ]; do
  if ! kubectl get ns "$NS" >/dev/null 2>&1; then
    echo "KEDA namespace removed." >&2
    exit 0
  fi
  phase="$(kubectl get ns "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  now="$(date +%s)"
  elapsed=$(( now - start_ts ))
  echo "Waiting for keda namespace to terminate... phase=${phase:-unknown} elapsed=${elapsed}s" >&2

  # If it is stuck in Terminating, force-remove finalizers early (last resort).
  if [ "${phase:-}" = "Terminating" ] && [ "$FORCE_FINALIZERS" != "0" ] && [ "$elapsed" -ge "$FORCE_AFTER_SEC" ]; then
    echo "Force removing namespace finalizers for $NS (elapsed=${elapsed}s) ..." >&2
    kubectl patch ns "$NS" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
  fi
  sleep 5
done

echo "WARN: timed out waiting for keda namespace cleanup; proceeding" >&2
exit 0

