#!/usr/bin/env bash
set -eu
set -o pipefail 2>/dev/null || true

# 인자만 반영한다. 중간 저장·restore·annotation 기억 없음 — 같은 명령을 다시 실행해도 항상 그 입력 그대로 패치.
#
#   bash scripts/set-test-capacity.sh -n 25 -wr 35 -r 3 -wk 60
#
# 적용 값:
#   - 노드 그룹: minSize = desiredSize = -n,  maxSize = max(-n + 5, AWS에 현재 설정된 maxSize)  (5는 NODE_MAX_DELTA)
#   - write/read HPA(burst): minReplicas = -wr / -r,  maxReplicas = 그 min + 20  (20은 POD_MAX_DELTA)
#   - worker KEDA: minReplicaCount = -wk,  maxReplicaCount = -wk + 20,  paused 해제
#
# 버퍼 오버라이드: SET_TEST_CAP_POD_MAX_DELTA (기본 20), SET_TEST_CAP_NODE_MAX_DELTA (기본 5)

NS="${KUBECTL_NAMESPACE:-ticketing}"

POD_MAX_DELTA="${SET_TEST_CAP_POD_MAX_DELTA:-20}"
NODE_MAX_DELTA="${SET_TEST_CAP_NODE_MAX_DELTA:-5}"
# min 모드에서 노드 maxSize까지 강제로 desired로 고정하고 싶을 때 사용.
# (기본 동작은 기존 AWS maxSize(pmax)가 더 크면 줄이지 않음)
FORCE_NODE_MAX="${SET_TEST_CAP_FORCE_NODE_MAX:-0}"

# 예전 스크립트가 남긴 annotation 제거(혼동 방지). 더 이상 읽지 않음.
ANN_PREFIX="ticketing.soldesk/test-capacity"

_die() { echo "ERROR: $*" >&2; exit 1; }

_need() {
  command -v "$1" >/dev/null 2>&1 || _die "missing command: $1"
}

_tf_dir() {
  cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../terraform" && pwd
}

_tf_out() {
  terraform -chdir="$(_tf_dir)" output -raw "$1" 2>/dev/null || true
}

_strip_legacy_annotations() {
  local keys=(
    "${ANN_PREFIX}.prev-min"
    "${ANN_PREFIX}.prev-max"
    "${ANN_PREFIX}.prev-paused"
    "${ANN_PREFIX}.prev-node-min"
    "${ANN_PREFIX}.prev-node-desired"
    "${ANN_PREFIX}.prev-node-max"
    "${ANN_PREFIX}.ts"
  )
  local k
  for k in "${keys[@]}"; do
    kubectl -n "$NS" annotate hpa/write-api-hpa "${k}-" --overwrite >/dev/null 2>&1 || true
    kubectl -n "$NS" annotate hpa/read-api-hpa "${k}-" --overwrite >/dev/null 2>&1 || true
    kubectl -n "$NS" annotate scaledobject/worker-svc-sqs "${k}-" --overwrite >/dev/null 2>&1 || true
  done
}

_set_hpa() {
  local name="$1" rep="$2" obj="hpa/$1"
  # 이 클러스터는 Resource metric(HPA)로 scale-to-zero(min=0)를 허용하지 않는다.
  # 최소 유지 모드(rep<=0)에서는 HPA 자체가 1로 되살리는 것을 막기 위해 HPA를 삭제하고,
  # burst Deployment를 0으로 내려 Pending → 노드 증가 트리거를 제거한다.
  if (( rep <= 0 )); then
    case "$name" in
      write-api-hpa) kubectl -n "$NS" scale deploy/write-api-burst --replicas=0 >/dev/null 2>&1 || true ;;
      read-api-hpa)  kubectl -n "$NS" scale deploy/read-api-burst  --replicas=0 >/dev/null 2>&1 || true ;;
    esac
    kubectl -n "$NS" delete "$obj" --ignore-not-found >/dev/null 2>&1 || true
    return 0
  fi

  local new_max=$((rep + POD_MAX_DELTA))
  if (( new_max < rep )); then new_max="$rep"; fi
  kubectl -n "$NS" patch "$obj" --type merge -p "{\"spec\":{\"minReplicas\":${rep},\"maxReplicas\":${new_max}}}" >/dev/null
}

_set_keda() {
  local rep="$1"
  local obj="scaledobject/worker-svc-sqs"
  local new_max=$((rep + POD_MAX_DELTA))
  if (( new_max < rep )); then new_max="$rep"; fi
  kubectl -n "$NS" patch "$obj" --type merge -p "{\"spec\":{\"minReplicaCount\":${rep},\"maxReplicaCount\":${new_max}}}" >/dev/null
  # rep=0은 "클러스터 최소 유지" 모드에서 사용됨:
  # - 큐에 메시지가 남아있으면 KEDA가 즉시 scale-out 하며 Pending → 노드 증가로 이어질 수 있다.
  # - 따라서 rep=0일 때는 paused를 유지/설정해서 burst가 자동으로 다시 올라오지 않게 한다.
  if (( rep <= 0 )); then
    kubectl -n "$NS" annotate "$obj" autoscaling.keda.sh/paused="true" --overwrite >/dev/null 2>&1 || true
  else
    kubectl -n "$NS" annotate "$obj" autoscaling.keda.sh/paused- >/dev/null 2>&1 || true
  fi
}

_set_nodegroup() {
  local desired="$1"
  local region cluster ng j pmax new_max cand
  region="$(_tf_out aws_region)"
  cluster="$(_tf_out eks_cluster_name)"
  ng="$(_tf_out eks_app_node_group_name)"
  [[ -n "$region" && -n "$cluster" && -n "$ng" ]] || _die "terraform outputs missing (aws_region/eks_cluster_name/eks_app_node_group_name)"

  j="$(aws eks describe-nodegroup --region "$region" --cluster-name "$cluster" --nodegroup-name "$ng" 2>/dev/null || true)"
  [[ -n "$j" ]] || _die "aws eks describe-nodegroup failed (check AWS creds / cluster / nodegroup name)"

  pmax="$(printf "%s" "$j" | python -c 'import json,sys; j=json.load(sys.stdin); sc=j.get("nodegroup",{}).get("scalingConfig",{}) or {}; print(sc.get("maxSize",""))' 2>/dev/null || true)"

  if [[ "${FORCE_NODE_MAX:-0}" = "1" ]]; then
    new_max="$desired"
  else
  cand=$((desired + NODE_MAX_DELTA))
  new_max="$cand"
  if [[ -n "${pmax:-}" && "$pmax" =~ ^[0-9]+$ ]] && (( pmax > new_max )); then
    new_max="$pmax"
  fi
  if (( new_max < desired )); then new_max="$desired"; fi
  fi

  aws eks update-nodegroup-config \
    --region "$region" \
    --cluster-name "$cluster" \
    --nodegroup-name "$ng" \
    --scaling-config "minSize=${desired},desiredSize=${desired},maxSize=${new_max}" \
    >/dev/null
}

_force_scale_targets_now() {
  # HPA/KEDA는 downscale이 안정화 윈도우/쿨다운 때문에 즉시 내려가지 않을 수 있음.
  # 테스트에서는 "명령어 입력값대로 desired가 바로 맞는 것"이 목적이므로 scale을 함께 수행한다.
  # - write/read: HPA 대상 burst Deployment
  # - worker: KEDA 대상 burst Deployment
  local wr="$1" rd="$2" wk="$3"
  kubectl -n "$NS" scale deploy/write-api-burst --replicas="$wr" >/dev/null 2>&1 || true
  kubectl -n "$NS" scale deploy/read-api-burst --replicas="$rd" >/dev/null 2>&1 || true
  kubectl -n "$NS" scale deploy/worker-svc-burst --replicas="$wk" >/dev/null 2>&1 || true
}

_need kubectl
_need aws
_need terraform
_need python

nodes="" wr="" rd="" wk=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n)  nodes="$2"; shift 2;;
    -wr) wr="$2"; shift 2;;
    -r)  rd="$2"; shift 2;;
    -wk) wk="$2"; shift 2;;
    *) _die "unknown arg: $1 (use: -n <nodes> -wr <write> -r <read> -wk <worker>)";;
  esac
done

[[ -n "$nodes" && -n "$wr" && -n "$rd" && -n "$wk" ]] || _die "required: -n/-wr/-r/-wk"

_strip_legacy_annotations

_set_hpa "write-api-hpa" "$wr"
_set_hpa "read-api-hpa" "$rd"
_set_keda "$wk"
_set_nodegroup "$nodes"

_force_scale_targets_now "$wr" "$rd" "$wk"

echo "set OK"
