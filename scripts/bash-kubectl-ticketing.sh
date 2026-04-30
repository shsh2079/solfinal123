# Ticketing kubectl shortcuts for bash.
# terraform/ 에서: source ../scripts/bash-kubectl-ticketing.sh
# 저장소 루트에서: source scripts/bash-kubectl-ticketing.sh
#
# 로그인 셸에 항상 넣으려면 클론 루트를 한 번 지정:
#   export TICKETING_REPO_ROOT="$HOME/.../ticketing-db"
#   source "$TICKETING_REPO_ROOT/scripts/bash-kubectl-ticketing.sh"
#
# Usage (no leading $ — that is for variables, not commands):
#   파드
#   인그레스
# Fallback names if 한글 함수명이 안 먹는 환경:
#   ㅔㅐㅇ
#   ㅑㅐㄱ

export TICKETING_K8S_NS="${TICKETING_K8S_NS:-ticketing}"

파드() {
  kubectl get pods -n "$TICKETING_K8S_NS" "$@"
}

인그레스() {
  kubectl get ingress -n "$TICKETING_K8S_NS" "$@"
}

# Jamo-only fallbacks (some terminals/locales에서 한글 식별자가 깨질 때)
ㅔㅐㅇ() {
  kubectl get pods -n "$TICKETING_K8S_NS" "$@"
}

ㅑㅐㄱ() {
  kubectl get ingress -n "$TICKETING_K8S_NS" "$@"
}
