#!/usr/bin/env bash
# RDS writer 엔드포인트를 terraform output 에서 읽어 DB_* 환경변수를 맞춘다.
#
# (기본) 저장소의 terraform/ 디렉터리에서 작업할 때 — 파일명만 고정, 경로는 .. 로:
#   source ../scripts/db-env-from-terraform.sh
#   eval "$(bash ../scripts/db-env-from-terraform.sh --print)"
#
# 현재 디렉터리가 terraform/ 이고 main.tf 가 있으면 그 폴더를 TF_DIR 로 쓴다.
# 그 외에는 이 스크립트 위치(scripts/) 기준으로 저장소 루트를 찾는다.
#
# 저장소 루트에 있을 때: source scripts/db-env-from-terraform.sh
# TICKETING_REPO_ROOT 로 루트 강제 가능.
#
# DB_PASSWORD 는 비밀 — 별도 export.
#
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [[ -n "${TICKETING_REPO_ROOT:-}" ]]; then
  ROOT="$(cd "$TICKETING_REPO_ROOT" && pwd)"
  TF_DIR="$ROOT/terraform"
elif [[ "$(basename "${PWD}")" == "terraform" ]] && [[ -f "${PWD}/main.tf" ]]; then
  TF_DIR="$(cd "$PWD" && pwd)"
  ROOT="$(cd "$TF_DIR/.." && pwd)"
else
  ROOT="$(cd "$_SCRIPT_DIR/.." && pwd)"
  TF_DIR="$ROOT/terraform"
fi

_run_output() {
  (cd "$TF_DIR" && terraform output -raw "$1")
}

if [[ ! -d "$TF_DIR" ]]; then
  echo "terraform 디렉터리 없음: $TF_DIR" >&2
  exit 1
fi

EP="$(_run_output rds_writer_endpoint)" || {
  echo "terraform output rds_writer_endpoint 실패 (terraform 디렉터리에서 init/apply 확인)" >&2
  exit 1
}

# --print 는 bash 로만 실행 (eval "$(bash ... --print)" 용). source 와 함께 쓰면 안 됨.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]] && [[ "${1-}" == "--print" ]]; then
  printf 'export DB_WRITER_HOST=%q\n' "$EP"
  printf 'export DB_NAME=%q\n' "ticketing"
  exit 0
fi

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "현재 셸에 남기려면 terraform/ 에서:" >&2
  echo "  source ../scripts/db-env-from-terraform.sh" >&2
  echo "  eval \"\$(bash ../scripts/db-env-from-terraform.sh --print)\"" >&2
  echo "저장소 루트에서: source scripts/db-env-from-terraform.sh" >&2
  exit 1
fi

export DB_WRITER_HOST="$EP"
export DB_NAME=ticketing
[[ -z "${DB_USER-}" ]] && export DB_USER=root

echo "export 완료: DB_WRITER_HOST DB_NAME=ticketing DB_USER=${DB_USER} (DB_PASSWORD 는 별도 설정)" >&2
