#!/usr/bin/env bash
set -eu
set -o pipefail 2>/dev/null || true

# CRLF -> LF for all repo shell scripts and Terraform files (HGFS/Windows/IDE safe).
# Idempotent. Git clone 후·terraform apply 전에 한 번 실행해도 됨.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

_sedi() {
  if sed --version >/dev/null 2>&1; then
    sed -i "$@"
  else
    sed -i '' "$@"
  fi
}

normalize_file() {
  local f="$1"
  [ -f "$f" ] || return 0
  _sedi 's/\r$//' "$f" || true
}

normalize_glob() {
  local pattern="$1"
  local f
  shopt -s nullglob
  for f in $pattern; do
    normalize_file "$f"
  done
  shopt -u nullglob
}

normalize_glob "$ROOT_DIR/k8s/scripts/"'*.sh'
normalize_glob "$ROOT_DIR/terraform/scripts/"'*.sh'
normalize_glob "$ROOT_DIR/scripts/"'*.sh'

# scripts/**/**/*.sh (locust 등 하위 폴더 포함)
if [ -d "$ROOT_DIR/scripts" ]; then
  while IFS= read -r -d '' f; do
    normalize_file "$f"
  done < <(find "$ROOT_DIR/scripts" -type f -name '*.sh' -print0 2>/dev/null || true)
fi

# terraform/modules/*/scripts/*.sh (eks, network 등)
if [ -d "$ROOT_DIR/terraform/modules" ]; then
  while IFS= read -r -d '' f; do
    normalize_file "$f"
  done < <(find "$ROOT_DIR/terraform/modules" -type f -name '*.sh' -print0 2>/dev/null || true)
fi

# Terraform 본문 heredoc·local-exec 문자열도 CRLF면 깨질 수 있음
if [ -d "$ROOT_DIR/terraform" ]; then
  while IFS= read -r -d '' f; do
    normalize_file "$f"
  done < <(find "$ROOT_DIR/terraform" -type f \( -name '*.tf' -o -name '*.tfvars' \) -print0 2>/dev/null || true)
fi

echo "Normalized CRLF->LF: *.sh, terraform/**/*.tf, terraform/**/*.tfvars"
