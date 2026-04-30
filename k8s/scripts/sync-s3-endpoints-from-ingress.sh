#!/usr/bin/env bash
# kubectl apply 로 Ingress(ALB)가 생긴 뒤, 실제 ALB DNS로 S3의 api-origin.js 를 덮어씀.
# (endpoints.json 은 사용하지 않음 — JS 정적 파일만 ALB 주소를 참조.)
# terraform apply 끝의 post_apply_k8s_bootstrap 에서 호출 — 두 번째 apply 없이 브라우저용 API 오리진 확정.
set -euo pipefail

_self="${BASH_SOURCE[0]:-$0}"
if [[ -n "${REPO_ROOT:-}" ]]; then
  ROOT_DIR="$(cd "${REPO_ROOT}" && pwd)"
else
  ROOT_DIR="$(cd "$(dirname "${_self}")/../.." && pwd)"
fi
TF_DIR="$ROOT_DIR/terraform"

_tf_region="$(terraform -chdir="$TF_DIR" output -raw aws_region 2>/dev/null || true)"
export AWS_REGION="${AWS_REGION:-${_tf_region:-}}"
if [[ -z "${AWS_REGION}" ]]; then
  echo "ERROR: AWS_REGION is required (set env or ensure terraform output aws_region is available)" >&2
  exit 1
fi
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-$AWS_REGION}"

_KS_DIR="$(cd "$(dirname "${_self}")" && pwd)"
if ! kubectl config view >/dev/null 2>&1; then
  echo "WARN: kubeconfig 손상/없음 — refresh_kubeconfig.sh 실행" >&2
  bash "${_KS_DIR}/refresh_kubeconfig.sh"
fi

# terraform 출력으로 «이 스택에 CloudFront가 있는지»부터 고정한다 (tfvars / state 기준).
_routing="$(terraform -chdir="$TF_DIR" output -raw frontend_routing_mode 2>/dev/null || echo "unknown")"
_eks_tf="$(terraform -chdir="$TF_DIR" output -raw eks_cluster_name 2>/dev/null || true)"
_kctx="$(kubectl config current-context 2>/dev/null || echo "")"
echo "=== api-origin 동기화: terraform frontend_routing_mode=${_routing}"
echo "    (s3_website_alb_origin_js = S3 웹사이트 + Ingress ALB를 api-origin.js에 기록)"
echo "    (cloudfront_alb = CloudFront 동일 오리진 + api-origin.js에 CF URL)"
echo "    (none = S3 v2 호스팅 미사용 — 아래에서 bucket 없으면 종료)"
if [[ -n "${_eks_tf}" && -n "${_kctx}" ]] && ! grep -Fq "${_eks_tf}" <<<"${_kctx}"; then
  echo "WARN: kubectl current-context 에 terraform eks_cluster_name(${_eks_tf})이 안 보입니다. 다른 클러스터 Ingress로 api-origin.js를 쓸 수 있습니다." >&2
fi

NAMESPACE="${TICKETING_NAMESPACE:-${TICKETING_NS:-ticketing}}"
INGRESS_NAME="${INGRESS_NAME:-ticketing-ingress}"
MAX_WAIT_SEC="${MAX_WAIT_SEC:-600}"
SLEEP_SEC="${SLEEP_SEC:-5}"

bucket="$(terraform -chdir="$TF_DIR" output -raw frontend_bucket_name 2>/dev/null || true)"
if [[ -z "${bucket}" || "${bucket}" == "null" ]]; then
  echo "frontend_bucket_name 없음 — S3 hosting(v2) 미적용 상태로 보고 api-origin.js 동기화를 건너뜁니다."
  exit 0
fi

tmp="$(mktemp)"
cleanup_tmp() { rm -f "${tmp}"; }
trap cleanup_tmp EXIT

cf_url="$(terraform -chdir="$TF_DIR" output -raw frontend_cloudfront_url 2>/dev/null || true)"
if [[ "${_routing}" == "s3_website_alb_origin_js" ]] && [[ -n "${cf_url}" && "${cf_url}" != "null" ]]; then
  echo "WARN: terraform frontend_routing_mode 는 S3 웹사이트인데 frontend_cloudfront_url 값이 있습니다. state/tfvars 확인. ALB(Ingress) 경로로 동기화합니다." >&2
fi

# 분기는 반드시 terraform frontend_routing_mode 기준(URL 존재 여부만으로 CloudFront로 단정하지 않음).
if [[ "${_routing}" == "cloudfront_alb" ]]; then
  if [[ -z "${cf_url}" || "${cf_url}" == "null" ]]; then
    echo "ERROR: terraform 이 cloudfront_alb 인데 frontend_cloudfront_url 이 없습니다. terraform apply 완료 여부를 확인하세요." >&2
    exit 1
  fi
  origin="${cf_url%/}"
  printf 'window.__TICKETING_API_ORIGIN__="%s";\n' "${origin}" >"${tmp}"
  echo "=== CloudFront: s3://${bucket}/api-origin.js ← ${origin} (viewer가 /api/* 를 이 도메인으로 호출) ==="
  aws s3 cp "${tmp}" "s3://${bucket}/api-origin.js" \
    --content-type "application/javascript; charset=utf-8" \
    --cache-control "no-store, max-age=0"
  echo "완료. CloudFront URL로 접속한 뒤 api-origin.js 는 캐시 비활성 정책이어도 브라우저 강력 새로고침 권장."
  exit 0
fi

if [[ "${_routing}" != "s3_website_alb_origin_js" ]]; then
  echo "WARN: frontend_routing_mode=${_routing} — S3 웹사이트+ALB 동기화 경로가 아닙니다(none 이면 버킷만 있고 프론트 모듈 미사용일 수 있음). Ingress ALB 로 진행합니다." >&2
fi

echo "=== Ingress ${NAMESPACE}/${INGRESS_NAME} 에서 ALB 호스트 대기 (최대 ${MAX_WAIT_SEC}s) ==="
host=""
elapsed=0
while [[ "${elapsed}" -lt "${MAX_WAIT_SEC}" ]]; do
  host="$(kubectl get ingress -n "${NAMESPACE}" "${INGRESS_NAME}" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  if [[ -n "${host}" ]]; then
    break
  fi
  sleep "${SLEEP_SEC}"
  elapsed=$((elapsed + SLEEP_SEC))
done

if [[ -z "${host}" ]]; then
  echo "ERROR: ALB hostname 을 받지 못했습니다. kubectl describe ingress -n ${NAMESPACE} ${INGRESS_NAME} 확인" >&2
  exit 1
fi

origin="http://${host}"
printf 'window.__TICKETING_API_ORIGIN__="%s";\n' "${origin}" >"${tmp}"

echo "=== S3 웹사이트 모드: s3://${bucket}/api-origin.js ← ${origin} ==="
aws s3 cp "${tmp}" "s3://${bucket}/api-origin.js" \
  --content-type "application/javascript; charset=utf-8" \
  --cache-control "no-store, max-age=0"

echo "완료. 브라우저에서 S3 사이트 새로고침(api-origin.js 반영, 필요 시 캐시 비우기)."
