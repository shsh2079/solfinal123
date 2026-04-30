#!/usr/bin/env bash
# terraform/ 에서 (권장): bash ../scripts/tf-out.sh <output_name>
# 예: bash ../scripts/tf-out.sh sqs_queue_url
# 저장소 루트에서: bash scripts/tf-out.sh sqs_queue_url
set -euo pipefail
NAME="${1:?사용법: $0 <terraform_output_name> 예: frontend_website_url}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec terraform -chdir="$ROOT/terraform" output -raw "$NAME"
