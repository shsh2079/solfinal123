#!/usr/bin/env bash
set -eu
set -o pipefail 2>/dev/null || true

# 목적:
# 1) tools-once Pod 안에서 sqs_load_real_concert5.py 또는 sqs_load_real_concert6.py 실행
# 2) 종료 후 호스트(로컬)에서 k8s 스냅샷 출력
#
# 사용 예:
#   bash ../scripts/run_concert5_then_snapshot.sh --http-concurrency 2000 --duration-sec 10 --show-id 100 -n 1
#   bash ../scripts/run_concert5_then_snapshot.sh ... -n 30 -v5    # 명시적 v5 (기본과 동일)
#   bash ../scripts/run_concert5_then_snapshot.sh ... -n 30 -v6    # v6 부하 스크립트
#   bash ../scripts/run_concert5_then_snapshot.sh ... -n 30 v6     # - 없이 v5 / v6 도 허용
#
# NOTE:
# - 버전 토큰은 인자 목록의 "맨 끝" 한 개만 인식하고, python에는 넘기지 않는다.
# - 스냅샷은 호스트 kubectl 권한으로 kubectl exec 세션 밖에서 실행한다.

NS="${TICKETING_NAMESPACE:-ticketing}"
POD="${TOOLS_ONCE_POD:-tools-once}"
WRITE_API_BASE_URL="${WRITE_API_BASE_URL:-http://write-api.${NS}.svc.cluster.local:5001}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SNAPSHOT_SH="${SNAPSHOT_SH:-$SCRIPT_DIR/k8s-snapshot-host.sh}"

LOAD_SCRIPT="sqs_load_real_concert5.py"
py_args=("$@")
if [[ ${#py_args[@]} -gt 0 ]]; then
  last_i=$((${#py_args[@]} - 1))
  case "${py_args[$last_i]}" in
    -v5|v5)
      LOAD_SCRIPT="sqs_load_real_concert5.py"
      py_args=("${py_args[@]:0:$last_i}")
      ;;
    -v6|v6)
      LOAD_SCRIPT="sqs_load_real_concert6.py"
      py_args=("${py_args[@]:0:$last_i}")
      ;;
  esac
fi

remote_py_args=""
for a in "${py_args[@]}"; do
  q="$(printf '%q' "$a")"
  if [[ -z "$remote_py_args" ]]; then
    remote_py_args="$q"
  else
    remote_py_args+=" $q"
  fi
done

echo "[run_concert_then_snapshot] load_script=${LOAD_SCRIPT} extra_args=${remote_py_args:-<none>}" >&2

kubectl -n "$NS" exec -it "$POD" -- sh -lc \
  "cd /work/ticketing-db/terraform && WRITE_API_BASE_URL='${WRITE_API_BASE_URL}' python3 ../scripts/${LOAD_SCRIPT} ${remote_py_args}"

# python이 실패해도(비정상 종료/timeout) 스냅샷은 찍고 싶으면 아래를 '|| true'로 바꿔도 됨
bash "$SNAPSHOT_SH"
