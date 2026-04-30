#!/usr/bin/env bash
set -euo pipefail

: "${K8S_NAMESPACE:?K8S_NAMESPACE required}"
: "${DB_HOST:?DB_HOST required}"
: "${DB_USER:?DB_USER required}"
: "${DB_PASSWORD:?DB_PASSWORD required}"
: "${DB_NAME:?DB_NAME required}"
: "${CREATE_SQL:?CREATE_SQL required}"
: "${INSERT_SQL:?INSERT_SQL required}"
: "${EKS_CLUSTER_NAME:?EKS_CLUSTER_NAME required (set by Terraform null_resource.db_schema_init)}"
: "${AWS_REGION:?AWS_REGION required}"

FORCE_DB_SCHEMA_INIT="${FORCE_DB_SCHEMA_INIT:-0}"
FORCE_DB_DDL="${FORCE_DB_DDL:-0}"
FORCE_DB_SEED="${FORCE_DB_SEED:-0}"
SKIP_DB_SCHEMA_IF_EXISTS="${SKIP_DB_SCHEMA_IF_EXISTS:-1}"

if ! command -v aws >/dev/null 2>&1; then
  echo "ERROR: aws CLI not found. Install AWS CLI and retry." >&2
  exit 127
fi
if ! command -v kubectl >/dev/null 2>&1; then
  echo "ERROR: kubectl not found. Install kubectl (https://kubernetes.io/docs/tasks/tools/) and retry." >&2
  echo "      Terraform apply must run on a host that can reach the EKS API." >&2
  exit 127
fi

# Avoid corrupting ~/.kube/config when other null_resource local-exec runs in parallel.
unset KUBECONFIG 2>/dev/null || true
_TMP_KUBECONFIG="$(mktemp)"
export KUBECONFIG="$_TMP_KUBECONFIG"
trap 'rm -f "$_TMP_KUBECONFIG"' EXIT

echo "=== kubeconfig: ${EKS_CLUSTER_NAME} (${AWS_REGION}) ==="
aws eks update-kubeconfig --name "${EKS_CLUSTER_NAME}" --region "${AWS_REGION}" --kubeconfig "$_TMP_KUBECONFIG"

if [ ! -f "$CREATE_SQL" ]; then
  echo "create.sql not found at: $CREATE_SQL"
  exit 1
fi
if [ ! -f "$INSERT_SQL" ]; then
  echo "Insert.sql not found at: $INSERT_SQL"
  exit 1
fi

POD_NAME="db-schema-init-$(date +%s)"

echo "=== DB schema init via Kubernetes ==="
echo "Namespace: $K8S_NAMESPACE"
echo "Pod: $POD_NAME"
echo "RDS writer: $DB_HOST"

kubectl get ns "$K8S_NAMESPACE" >/dev/null 2>&1 || kubectl create ns "$K8S_NAMESPACE" >/dev/null

CLEANUP_POD_ON_EXIT="${CLEANUP_POD_ON_EXIT:-1}"
_SCRIPT_OK=0

cleanup() {
  if [ "${CLEANUP_POD_ON_EXIT}" = "1" ] && [ "${_SCRIPT_OK}" = "1" ]; then
    kubectl -n "$K8S_NAMESPACE" delete pod "$POD_NAME" --ignore-not-found >/dev/null 2>&1 || true
  else
    echo "NOTE: leaving pod for debugging: ${K8S_NAMESPACE}/${POD_NAME}" >&2
    echo "  kubectl -n ${K8S_NAMESPACE} describe pod ${POD_NAME}" >&2
    echo "  kubectl -n ${K8S_NAMESPACE} logs ${POD_NAME}" >&2
  fi
  rm -f "$_TMP_KUBECONFIG"
}
trap cleanup EXIT

_debug_dump() {
  echo "--- debug: pod status ---" >&2
  kubectl -n "$K8S_NAMESPACE" get pod "$POD_NAME" -o wide >&2 || true
  echo "--- debug: pod describe ---" >&2
  kubectl -n "$K8S_NAMESPACE" describe pod "$POD_NAME" >&2 || true
  echo "--- debug: pod logs ---" >&2
  kubectl -n "$K8S_NAMESPACE" logs "$POD_NAME" >&2 || true
  echo "--- debug: events (tail) ---" >&2
  kubectl -n "$K8S_NAMESPACE" get events --sort-by=.lastTimestamp | tail -n 50 >&2 || true
}

# mysql client container (no server) + long sleep
kubectl -n "$K8S_NAMESPACE" run "$POD_NAME" \
  --image=mysql:8 \
  --restart=Never \
  --command -- sh -lc "sleep 3600" >/dev/null

if ! kubectl -n "$K8S_NAMESPACE" wait --for=condition=Ready pod/"$POD_NAME" --timeout=180s; then
  echo "ERROR: pod did not become Ready within timeout." >&2
  _debug_dump
  exit 1
fi

echo "Checking DB init state (schema vs seed)..."

_mysql_scalar() {
  # Usage: _mysql_scalar "<db_or_empty>" "<sql>"
  local db="${1:-}"
  local sql="${2:-}"
  if [ -z "$sql" ]; then
    echo ""
    return 0
  fi
  local db_flag=""
  if [ -n "$db" ]; then
    db_flag="-D \"$db\""
  fi
  # NOTE: avoid nested quote pitfalls by embedding SQL directly inside one double-quoted sh -lc string.
  kubectl -n "$K8S_NAMESPACE" exec "$POD_NAME" -- sh -lc \
    "MYSQL_PWD=\"$DB_PASSWORD\" mysql -N -s -h \"$DB_HOST\" -u \"$DB_USER\" --protocol=tcp --default-character-set=utf8mb4 ${db_flag} -e \"$sql\"" \
    | tr -d '\r' | tail -n 1
}

# Schema check: a couple of core tables from create.sql
HAS_MOVIES_TABLE="$(_mysql_scalar '' "SELECT 1 FROM information_schema.tables WHERE table_schema='${DB_NAME}' AND table_name='movies' LIMIT 1;")"
HAS_CONCERTS_TABLE="$(_mysql_scalar '' "SELECT 1 FROM information_schema.tables WHERE table_schema='${DB_NAME}' AND table_name='concerts' LIMIT 1;")"

# Seed check: only after core tables exist. On a fresh RDS, DB_NAME may not exist yet — querying
# movies/concerts with -D would make mysql exit 1 ("Unknown database") before we ever apply DDL.
HAS_MOVIE_1=""
HAS_BIG_CONCERT=""
if [ "$HAS_MOVIES_TABLE" = "1" ] && [ "$HAS_CONCERTS_TABLE" = "1" ]; then
  HAS_MOVIE_1="$(_mysql_scalar "$DB_NAME" "SELECT 1 FROM movies WHERE movie_id = 1 LIMIT 1;")"
  HAS_BIG_CONCERT="$(_mysql_scalar "$DB_NAME" "SELECT 1 FROM concerts WHERE title='2026 봄 페스티벌 LIVE - 5만석' LIMIT 1;")"
fi

SCHEMA_OK=0
SEED_OK=0
if [ "$HAS_MOVIES_TABLE" = "1" ] && [ "$HAS_CONCERTS_TABLE" = "1" ]; then
  SCHEMA_OK=1
fi
if [ "$HAS_MOVIE_1" = "1" ] || [ "$HAS_BIG_CONCERT" = "1" ]; then
  SEED_OK=1
fi

echo "Schema present: $SCHEMA_OK (movies=$HAS_MOVIES_TABLE concerts=$HAS_CONCERTS_TABLE)"
echo "Seed present:   $SEED_OK (movie#1=$HAS_MOVIE_1 big_concert=$HAS_BIG_CONCERT)"

# Force overrides
if [ "$FORCE_DB_SCHEMA_INIT" = "1" ]; then
  FORCE_DB_DDL=1
  FORCE_DB_SEED=1
fi

NEED_DDL=0
NEED_SEED=0

if [ "$FORCE_DB_DDL" = "1" ]; then
  NEED_DDL=1
elif [ "$SCHEMA_OK" != "1" ]; then
  NEED_DDL=1
fi

if [ "$FORCE_DB_SEED" = "1" ]; then
  NEED_SEED=1
elif [ "$SEED_OK" != "1" ]; then
  NEED_SEED=1
fi

if [ "$SKIP_DB_SCHEMA_IF_EXISTS" = "1" ] && [ "$NEED_DDL" = "0" ] && [ "$NEED_SEED" = "0" ]; then
  echo "DB already has schema + seed. Skipping initialization."
  echo "Tip: set FORCE_DB_SCHEMA_INIT=1 (or FORCE_DB_DDL=1 / FORCE_DB_SEED=1) to re-apply."
  exit 0
fi

echo "Copying SQL files into pod..."
kubectl -n "$K8S_NAMESPACE" cp "$CREATE_SQL" "$POD_NAME":/tmp/create.sql >/dev/null
kubectl -n "$K8S_NAMESPACE" cp "$INSERT_SQL" "$POD_NAME":/tmp/Insert.sql >/dev/null

if [ "$NEED_DDL" = "1" ]; then
  echo "Applying DDL (create.sql)..."
  kubectl -n "$K8S_NAMESPACE" exec "$POD_NAME" -- sh -lc \
    "MYSQL_PWD=\"$DB_PASSWORD\" mysql -h \"$DB_HOST\" -u \"$DB_USER\" --protocol=tcp --default-character-set=utf8mb4 < /tmp/create.sql"
else
  echo "Skipping DDL (schema already present)."
fi

if [ "$NEED_SEED" = "1" ]; then
  echo "Applying seed (Insert.sql)..."
  kubectl -n "$K8S_NAMESPACE" exec "$POD_NAME" -- sh -lc \
    "MYSQL_PWD=\"$DB_PASSWORD\" mysql -h \"$DB_HOST\" -u \"$DB_USER\" --protocol=tcp --default-character-set=utf8mb4 < /tmp/Insert.sql"
else
  echo "Skipping seed (baseline data already present)."
fi

echo "Verifying basic objects..."
kubectl -n "$K8S_NAMESPACE" exec "$POD_NAME" -- sh -lc \
  "MYSQL_PWD=\"$DB_PASSWORD\" mysql -h \"$DB_HOST\" -u \"$DB_USER\" --protocol=tcp --default-character-set=utf8mb4 -D \"$DB_NAME\" -e \"SHOW TABLES; SELECT COUNT(*) AS movies_count FROM movies;\" >/dev/null"

echo "=== DB schema init complete ==="
_SCRIPT_OK=1

