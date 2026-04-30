#!/usr/bin/env bash
# Terraform data.external: 성공 시 stdout 에 JSON 한 줄만 출력. 설치 로그는 전부 stderr.
set -uo pipefail

log() { printf '%s\n' "$*" >&2; }

as_root() {
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

k8s_dl_arch() {
  case "$(uname -m)" in
    x86_64 | amd64) echo amd64 ;;
    aarch64 | arm64) echo arm64 ;;
    *) echo "" ;;
  esac
}

have() { command -v "$1" >/dev/null 2>&1; }

ensure_unzip() {
  have unzip && return 0
  if have dnf; then as_root dnf install -y unzip
  elif have yum; then as_root yum install -y unzip
  elif have apt-get; then as_root apt-get update -qq && as_root apt-get install -y unzip
  else
    log "ERROR: unzip 이 없고 알려진 패키지 매니저도 없습니다. unzip 을 설치한 뒤 다시 terraform 을 실행하세요."
    return 1
  fi
}

install_kubectl_linux() {
  local arch ver url tmp
  arch="$(k8s_dl_arch)"
  if [ -z "$arch" ]; then
    log "ERROR: 지원하지 않는 uname -m: $(uname -m)"
    return 1
  fi
  ver="$(curl -fsSL https://dl.k8s.io/release/stable.txt)" || return 1
  url="https://dl.k8s.io/release/${ver}/bin/linux/${arch}/kubectl"
  tmp="$(mktemp)"
  log "kubectl 설치 중 (${ver}, linux/${arch})..."
  curl -fSL "$url" -o "$tmp" || return 1
  chmod +x "$tmp"
  as_root install -m 0755 "$tmp" /usr/local/bin/kubectl || return 1
  rm -f "$tmp"
}

install_kubectl_darwin() {
  local arch ver url tmp
  arch="$(k8s_dl_arch)"
  if [ -z "$arch" ]; then
    log "ERROR: 지원하지 않는 uname -m: $(uname -m)"
    return 1
  fi
  ver="$(curl -fsSL https://dl.k8s.io/release/stable.txt)" || return 1
  url="https://dl.k8s.io/release/${ver}/bin/darwin/${arch}/kubectl"
  tmp="$(mktemp)"
  log "kubectl 설치 중 (${ver}, darwin/${arch})..."
  curl -fSL "$url" -o "$tmp" || return 1
  chmod +x "$tmp"
  as_root install -m 0755 "$tmp" /usr/local/bin/kubectl || return 1
  rm -f "$tmp"
}

install_helm_unix() {
  log "Helm 3 설치 중 (공식 get-helm-3 스크립트)..."
  export HELM_INSTALL_DIR="${HELM_INSTALL_DIR:-/usr/local/bin}"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash || return 1
}

install_awscli_linux() {
  local zip dir arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64) zip="awscli-exe-linux-x86_64.zip" ;;
    aarch64) zip="awscli-exe-linux-aarch64.zip" ;;
    *)
      log "ERROR: AWS CLI 자동 설치: 지원하지 않는 아키텍처 ($arch)"
      return 1
      ;;
  esac
  ensure_unzip || return 1
  dir="$(mktemp -d)"
  log "AWS CLI v2 설치 중 (${zip})..."
  curl -fsSL "https://awscli.amazonaws.com/${zip}" -o "${dir}/awscliv2.zip" || return 1
  (cd "$dir" && unzip -oq awscliv2.zip) || return 1
  as_root "${dir}/aws/install" --update || return 1
  rm -rf "$dir"
}

install_awscli_darwin() {
  if have brew; then
    log "Homebrew 로 awscli 설치 시도..."
    brew install awscli || return 1
    return 0
  fi
  log "ERROR: macOS 에서는 Homebrew 로 AWS CLI 를 설치하세요: brew install awscli"
  return 1
}

install_missing_tools() {
  local os
  os="$(uname -s)"

  if ! have curl; then
    log "ERROR: curl 이 필요합니다. dnf/yum/apt 등으로 curl 을 설치한 뒤 다시 실행하세요."
    return 1
  fi

  case "$os" in
    Linux)
      have aws || install_awscli_linux || return 1
      have kubectl || install_kubectl_linux || return 1
      have helm || install_helm_unix || return 1
      ;;
    Darwin)
      if have brew; then
        have aws || { brew install awscli || return 1; }
        have kubectl || { brew install kubectl || return 1; }
        have helm || { brew install helm || return 1; }
      else
        have aws || install_awscli_darwin || return 1
        have kubectl || install_kubectl_darwin || return 1
        have helm || install_helm_unix || return 1
      fi
      ;;
    *)
      log "ERROR: 자동 설치는 Linux / macOS 만 지원합니다 (현재: $os)."
      return 1
      ;;
  esac
  return 0
}

# --- main ---
# data.external 은 stdout 전체를 JSON 으로만 받는다. dnf/yum/aws install 등이 stdout 에
# "Downloading..." 같은 텍스트를 쓰면 파싱이 깨지므로, 메인 구간은 기본 stdout 을 stderr 로 돌리고
# 성공 시 JSON 만 원래 stdout(파일 디스크립터 4)으로 보낸다.
exec 4>&1
exec 1>&2

missing=()
have aws || missing+=("aws")
have kubectl || missing+=("kubectl")
have helm || missing+=("helm")

if [ "${#missing[@]}" -gt 0 ]; then
  log "다음 도구가 PATH 에 없습니다: ${missing[*]} — 자동 설치를 시도합니다."
  if ! install_missing_tools; then
    log "자동 설치에 실패했습니다. 수동 설치 후 다시 terraform 을 실행하세요."
    exit 1
  fi
fi

missing=()
have aws || missing+=("aws")
have kubectl || missing+=("kubectl")
have helm || missing+=("helm")

if [ "${#missing[@]}" -gt 0 ]; then
  log "설치 시도 후에도 PATH 에서 찾을 수 없습니다: ${missing[*]}"
  log "/usr/local/bin 이 PATH 에 포함돼 있는지 확인하세요."
  exit 1
fi

printf '%s\n' '{"aws":"ok","kubectl":"ok","helm":"ok"}' >&4
