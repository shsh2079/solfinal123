#!/usr/bin/env bash
# 수동 복구: terraform/scripts/sync_host_kubeconfig.sh 와 동일 로직(깨진 ~/.kube/config 는 삭제 후 재생성).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TF_SCRIPT="${ROOT_DIR}/terraform/scripts/sync_host_kubeconfig.sh"

if [ ! -f "$TF_SCRIPT" ]; then
  echo "ERROR: missing $TF_SCRIPT" >&2
  exit 1
fi

tr -d '\r' < "$TF_SCRIPT" | bash
