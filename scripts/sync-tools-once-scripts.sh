#!/usr/bin/env bash
# tools-once-setup.sh 로 통합됨 — 이 파일은 호환용 별칭.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
exec "$SCRIPT_DIR/tools-once-setup.sh" "$@"
