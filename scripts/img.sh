#!/usr/bin/env bash
set -euo pipefail

# 이미지 빌드·푸시는 terraform apply 전에 실행하는 것이 자연스러움.
# region / ECR 레포 / 태그는 Terraform(state·console)에 의존하지 않고,
# 환경변수 → AWS CLI 설정 → terraform/*.tfvars 순으로만 읽는다.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT_DIR}/terraform"
ACCOUNT_ID="${ACCOUNT_ID:-}"

_tfvars_paths() {
  [ -f "${TF_DIR}/terraform.tfvars" ] && printf '%s\n' "${TF_DIR}/terraform.tfvars"
  shopt -s nullglob
  local files=( "${TF_DIR}"/*.auto.tfvars )
  shopt -u nullglob
  if [ "${#files[@]}" -gt 0 ]; then
    printf '%s\n' "${files[@]}" | sort
  fi
}

# HCL 단순 대입 한 줄만 파싱 (terraform.tfvars / *.auto.tfvars). 나중 파일이 이전 값을 덮어씀.
_tfvars_get() {
  local key="$1"
  local val="" f line
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line//$'\r'/}"
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      [[ "${line//[[:space:]]/}" == "" ]] && continue
      if [[ "$line" =~ ^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"([^\"]*)\" ]]; then
        val="${BASH_REMATCH[1]}"
      elif [[ "$line" =~ ^[[:space:]]*${key}[[:space:]]*=[[:space:]]*([^[:space:]#\"]+) ]]; then
        val="${BASH_REMATCH[1]}"
      fi
    done < "$f"
  done < <(_tfvars_paths)
  [ -n "$val" ] && printf '%s\n' "$val" && return 0
  return 1
}

if [ -z "${ACCOUNT_ID}" ]; then
  ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
fi

AWS_REGION="${AWS_REGION:-}"
if [ -z "${AWS_REGION}" ]; then
  AWS_REGION="${AWS_DEFAULT_REGION:-}"
fi
if [ -z "${AWS_REGION}" ]; then
  AWS_REGION="$(aws configure get region 2>/dev/null || true)"
  AWS_REGION="${AWS_REGION//$'\r'/}"
fi
if [ -z "${AWS_REGION}" ]; then
  AWS_REGION="$(_tfvars_get aws_region 2>/dev/null || true)"
fi
if [ -z "${AWS_REGION}" ]; then
  echo "ERROR: AWS region을 정할 수 없습니다. 다음 중 하나를 설정하세요:" >&2
  echo "  - 환경변수 AWS_REGION 또는 AWS_DEFAULT_REGION" >&2
  echo "  - aws configure set region <region> (또는 ~/.aws/config 의 region)" >&2
  echo "  - ${TF_DIR}/terraform.tfvars 안의 aws_region = \"...\"" >&2
  exit 1
fi

# 태그: 환경변수 TAG 우선, 없으면 tfvars 의 image_tag, 마지막 latest
if [ -z "${TAG:-}" ]; then
  TAG="$(_tfvars_get image_tag 2>/dev/null || true)"
  TAG="${TAG:-latest}"
fi

# 레포 경로: 환경변수 우선, 없으면 tfvars, 마지막 variables.tf 기본과 동일
REPO_WAS="${ECR_REPO_TICKETING_WAS:-}"
if [ -z "${REPO_WAS}" ]; then
  REPO_WAS="$(_tfvars_get ecr_repo_ticketing_was 2>/dev/null || true)"
  REPO_WAS="${REPO_WAS:-ticketing/ticketing-was}"
fi

REPO_WORKER="${ECR_REPO_WORKER_SVC:-}"
if [ -z "${REPO_WORKER}" ]; then
  REPO_WORKER="$(_tfvars_get ecr_repo_worker_svc 2>/dev/null || true)"
  REPO_WORKER="${REPO_WORKER:-ticketing/worker-svc}"
fi

ECR_BASE="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
WAS_DIR="${ROOT_DIR}/services/ticketing-was"
WORKER_DIR="${ROOT_DIR}/services/worker-svc"
WAS_IMAGE="${ECR_BASE}/${REPO_WAS}:${TAG}"
WORKER_IMAGE="${ECR_BASE}/${REPO_WORKER}:${TAG}"

aws ecr get-login-password --region "${AWS_REGION}" | docker login --username AWS --password-stdin "${ECR_BASE}"
docker build -t "${WAS_IMAGE}" "${WAS_DIR}"
docker push "${WAS_IMAGE}"
docker build -t "${WORKER_IMAGE}" "${WORKER_DIR}"
docker push "${WORKER_IMAGE}"
