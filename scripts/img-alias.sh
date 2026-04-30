#!/usr/bin/env bash
# `img` 별칭: scripts/img.sh 와 완전히 동일하게 동작합니다.
# - Terraform(init/console/state) 없이 실행 가능 (이미지 푸시 → apply 순서 지원).
# - 리전·레포·태그는 img.sh 와 같이: 환경변수 → aws configure region → terraform.tfvars / *.auto.tfvars 직접 파싱.
# 사용: 저장소 루트에서 `source scripts/img-alias.sh` 후 같은 셸에서 `img`

TICKETING_REPO_ROOT="${TICKETING_REPO_ROOT:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"}"
alias img='bash "$TICKETING_REPO_ROOT/scripts/img.sh"'
