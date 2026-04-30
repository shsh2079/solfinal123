#!/usr/bin/env bash
set -eu
set -o pipefail 2>/dev/null || true

# 인자 없이 실행하면 테스트 최소 스펙으로 강제 세팅:
# - 노드 그룹: min=desired=1 (maxSize는 유지해서 다른 스크립트/CA가 다시 scale-up 가능)
# - write/read burst: HPA는 삭제하지 않고 min=max=1로 잠금 (토글 가능하게 유지)
# - worker burst: KEDA paused 유지 + worker-svc-burst=0 (spec min/max는 건드리지 않음 → worker-autoscale-on으로 복구 가능)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# HGFS/Windows 환경에서 CRLF가 섞이면 bash가 '\r'을 문자로 읽어 실패한다.
# 실행 전 한 번 정규화(멱등)해서 재발을 막는다.
bash "$SCRIPT_DIR/normalize-line-endings.sh" >/dev/null 2>&1 || true

NS="${KUBECTL_NAMESPACE:-ticketing}"

_die() { echo "ERROR: $*" >&2; exit 1; }
_need() { command -v "$1" >/dev/null 2>&1 || _die "missing command: $1"; }

_tf_dir() { cd "$SCRIPT_DIR/../terraform" && pwd; }
_tf_out() { terraform -chdir="$(_tf_dir)" output -raw "$1" 2>/dev/null || true; }

_set_nodegroup_min_desired_1_keep_max() {
  local region cluster ng j pmax
  region="$(_tf_out aws_region)"
  cluster="$(_tf_out eks_cluster_name)"
  ng="$(_tf_out eks_app_node_group_name)"
  [[ -n "$region" && -n "$cluster" && -n "$ng" ]] || _die "terraform outputs missing (aws_region/eks_cluster_name/eks_app_node_group_name)"

  j="$(aws eks describe-nodegroup --region "$region" --cluster-name "$cluster" --nodegroup-name "$ng" 2>/dev/null || true)"
  [[ -n "$j" ]] || _die "aws eks describe-nodegroup failed (check AWS creds / cluster / nodegroup name)"

  pmax="$(printf "%s" "$j" | python -c 'import json,sys; j=json.load(sys.stdin); sc=j.get("nodegroup",{}).get("scalingConfig",{}) or {}; print(sc.get("maxSize",""))' 2>/dev/null || true)"
  if [[ -z "${pmax:-}" || ! "$pmax" =~ ^[0-9]+$ ]]; then
    _die "cannot read nodegroup.maxSize from aws eks describe-nodegroup output"
  fi
  if (( pmax < 1 )); then
    pmax=1
  fi

  aws eks update-nodegroup-config \
    --region "$region" \
    --cluster-name "$cluster" \
    --nodegroup-name "$ng" \
    --scaling-config "minSize=1,desiredSize=1,maxSize=${pmax}" \
    >/dev/null
}

_set_write_read_burst_min1_keep_hpa() {
  # 토글 규칙:
  # - 여기서 "꺼도", 다른 쪽(set-test-capacity.sh 등)에서 실행하면 다시 "켜질" 수 있어야 한다.
  # - 이 클러스터는 HPA(Resource metric)로 scale-to-zero(min=0)를 허용하지 않아 HPA 삭제를 하면
  #   다시 켜려면 별도의 apply가 필요해 토글이 깨질 수 있다.
  # 따라서 HPA는 삭제하지 않고, burst를 "최소치(1)로 잠그는" 방식으로 OFF에 가깝게 만든다.

  # HPA가 없으면 먼저 복구(멱등)
  kubectl -n "$NS" get hpa/write-api-hpa >/dev/null 2>&1 || kubectl apply -f "$SCRIPT_DIR/../k8s/write-api/hpa.yaml" >/dev/null
  kubectl -n "$NS" get hpa/read-api-hpa  >/dev/null 2>&1 || kubectl apply -f "$SCRIPT_DIR/../k8s/read-api/hpa.yaml"  >/dev/null

  # min=max=1로 고정 → Pending 유발(대량 burst) 방지 + 다른 스크립트가 patch로 다시 올리기 쉬움
  kubectl -n "$NS" patch hpa/write-api-hpa --type merge -p "{\"spec\":{\"minReplicas\":1,\"maxReplicas\":1}}" >/dev/null
  kubectl -n "$NS" patch hpa/read-api-hpa  --type merge -p "{\"spec\":{\"minReplicas\":1,\"maxReplicas\":1}}" >/dev/null

  # HPA가 원하는 값에 맞춰 직접 scale (stabilization window로 즉시 반영이 안 되는 것 방지)
  kubectl -n "$NS" scale deploy/write-api-burst --replicas=1 >/dev/null 2>&1 || true
  kubectl -n "$NS" scale deploy/read-api-burst  --replicas=1 >/dev/null 2>&1 || true
}

_need kubectl
_need aws
_need terraform
_need python

_set_write_read_burst_min1_keep_hpa

# KEDA spec(min/max)까지 0으로 패치하면 worker-autoscale-on(unpause)만으로는 복구가 안 된다.
# 여기서는 OFF 스크립트와 동일하게 "paused + burst=0"만 적용한다.
bash "$SCRIPT_DIR/worker-autoscale-off.sh" >/dev/null

_set_nodegroup_min_desired_1_keep_max

echo "set-test-capacity-min1 OK"

