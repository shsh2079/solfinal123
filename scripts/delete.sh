#!/usr/bin/env bash
set -Eeuo pipefail

# DB reset helper (fresh-boot state)
# - Keeps schema (tables/constraints/indexes)
# - Truncates ALL tables (deletes ALL data)
# - Re-seeds baseline data from db-schema/Insert.sql
#
# Usage:
#   bash ../scripts/delete.sh
#
# Optional:
# - MYSQL_CLIENT_MODE=local requires DB_HOST/DB_USER/DB_PASSWORD/DB_NAME/DB_PORT
# - default is MYSQL_CLIENT_MODE=k8s-pod which reads settings from Kubernetes secrets/configmaps

KUBECTL_REQUEST_TIMEOUT="${KUBECTL_REQUEST_TIMEOUT:-20s}"
POD_READY_TIMEOUT="${POD_READY_TIMEOUT:-180s}"

_on_err() {
  local exit_code=$?
  echo "ERROR: delete.sh failed (exit=$exit_code) at line=$LINENO" >&2
  echo "ERROR: last_command=$BASH_COMMAND" >&2
  exit "$exit_code"
}
trap _on_err ERR

NS="${NS:-ticketing}"

MYSQL_POD="${MYSQL_POD:-db-reset-$(date +%s)}"
MYSQL_IMAGE="${MYSQL_IMAGE:-mysql:8}"
MYSQL_CLIENT_MODE="${MYSQL_CLIENT_MODE:-k8s-pod}"

_need() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing command: $1" >&2; exit 127; }
}

_need kubectl

_k() {
  kubectl --request-timeout="$KUBECTL_REQUEST_TIMEOUT" "$@"
}

echo "=== db reset (truncate + seed) ==="
echo "namespace=$NS"
echo "mysql_client_mode=$MYSQL_CLIENT_MODE"

if [[ "$MYSQL_CLIENT_MODE" == "local" ]]; then
  _need mysql
  : "${DB_HOST:?DB_HOST required when MYSQL_CLIENT_MODE=local}"
  : "${DB_USER:?DB_USER required when MYSQL_CLIENT_MODE=local}"
  : "${DB_PASSWORD:?DB_PASSWORD required when MYSQL_CLIENT_MODE=local}"
  : "${DB_NAME:?DB_NAME required when MYSQL_CLIENT_MODE=local}"
  : "${DB_PORT:?DB_PORT required when MYSQL_CLIENT_MODE=local}"
else
  DB_HOST="$(_k -n "$NS" get secret ticketing-secrets -o jsonpath='{.data.DB_WRITER_HOST}' | base64 -d | tr -d '\r\n')"
  DB_USER="$(_k -n "$NS" get secret ticketing-secrets -o jsonpath='{.data.DB_USER}' | base64 -d | tr -d '\r\n')"
  DB_PASSWORD="$(_k -n "$NS" get secret ticketing-secrets -o jsonpath='{.data.DB_PASSWORD}' | base64 -d | tr -d '\r\n')"
  DB_NAME="$(_k -n "$NS" get configmap ticketing-config -o jsonpath='{.data.DB_NAME}' | tr -d '\r\n')"
  DB_PORT="$(_k -n "$NS" get configmap ticketing-config -o jsonpath='{.data.DB_PORT}' | tr -d '\r\n')"
fi

if [[ -z "${DB_HOST}" || -z "${DB_USER}" || -z "${DB_NAME}" || -z "${DB_PORT}" ]]; then
  echo "ERROR: failed to load DB settings from $NS/{ticketing-secrets,ticketing-config}" >&2
  exit 1
fi

cleanup() {
  _k -n "$NS" delete pod "$MYSQL_POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

if [[ "$MYSQL_CLIENT_MODE" == "k8s-pod" ]]; then
  _k -n "$NS" run "$MYSQL_POD" \
    --image="$MYSQL_IMAGE" \
    --restart=Never \
    --command -- sh -lc "sleep 3600" >/dev/null

  if ! _k -n "$NS" wait --for=condition=Ready pod/"$MYSQL_POD" --timeout="$POD_READY_TIMEOUT" >/dev/null; then
    echo "ERROR: mysql client pod not Ready: $MYSQL_POD (timeout=$POD_READY_TIMEOUT)" >&2
    _k -n "$NS" get pod "$MYSQL_POD" -o wide >&2 || true
    _k -n "$NS" describe pod "$MYSQL_POD" >&2 || true
    exit 1
  fi
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SEED_FILE="$ROOT_DIR/db-schema/Insert.sql"
if [[ ! -f "$SEED_FILE" ]]; then
  echo "ERROR: seed file not found: $SEED_FILE" >&2
  exit 1
fi

TRUNCATE_SQL="$(cat <<'EOF'
USE ticketing;
DROP PROCEDURE IF EXISTS __truncate_all_tables;
DELIMITER $$
CREATE PROCEDURE __truncate_all_tables()
BEGIN
  DECLARE done INT DEFAULT 0;
  DECLARE t VARCHAR(128);
  DECLARE cur CURSOR FOR
    SELECT table_name
    FROM information_schema.tables
    WHERE table_schema = DATABASE()
      AND table_type = 'BASE TABLE';
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;

  SET FOREIGN_KEY_CHECKS = 0;
  OPEN cur;
  read_loop: LOOP
    FETCH cur INTO t;
    IF done = 1 THEN
      LEAVE read_loop;
    END IF;
    SET @sql := CONCAT('TRUNCATE TABLE `', t, '`');
    PREPARE stmt FROM @sql;
    EXECUTE stmt;
    DEALLOCATE PREPARE stmt;
  END LOOP;
  CLOSE cur;
  SET FOREIGN_KEY_CHECKS = 1;
END$$
DELIMITER ;
CALL __truncate_all_tables();
DROP PROCEDURE IF EXISTS __truncate_all_tables;
EOF
)"

echo "Truncating all tables."
if [[ "$MYSQL_CLIENT_MODE" == "local" ]]; then
  MYSQL_PWD="$DB_PASSWORD" mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" --protocol=tcp --default-character-set=utf8mb4 -D "$DB_NAME" -e "$TRUNCATE_SQL"
else
  _k -n "$NS" exec "$MYSQL_POD" -- sh -lc \
    "MYSQL_PWD=\"$DB_PASSWORD\" mysql -h \"$DB_HOST\" -P \"$DB_PORT\" -u \"$DB_USER\" --protocol=tcp --default-character-set=utf8mb4 -D \"$DB_NAME\" -e \"$TRUNCATE_SQL\""
fi

echo "Applying seed: db-schema/Insert.sql"
if [[ "$MYSQL_CLIENT_MODE" == "local" ]]; then
  MYSQL_PWD="$DB_PASSWORD" mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" --protocol=tcp --default-character-set=utf8mb4 -D "$DB_NAME" < "$SEED_FILE"
else
  _k -n "$NS" cp "$SEED_FILE" "$MYSQL_POD":/tmp/Insert.sql
  _k -n "$NS" exec "$MYSQL_POD" -- sh -lc \
    "MYSQL_PWD=\"$DB_PASSWORD\" mysql -h \"$DB_HOST\" -P \"$DB_PORT\" -u \"$DB_USER\" --protocol=tcp --default-character-set=utf8mb4 -D \"$DB_NAME\" < /tmp/Insert.sql"
fi

echo "=== done ==="
#!/usr/bin/env bash
set -Eeuo pipefail

# When kubectl cannot reach API server (auth/network), it may appear to "hang".
# Force request-level timeouts so the script fails fast with a useful error.
KUBECTL_REQUEST_TIMEOUT="${KUBECTL_REQUEST_TIMEOUT:-20s}"
POD_READY_TIMEOUT="${POD_READY_TIMEOUT:-180s}"

_on_err() {
  local exit_code=$?
  echo "ERROR: delete.sh failed (exit=$exit_code) at line=$LINENO" >&2
  echo "ERROR: last_command=$BASH_COMMAND" >&2
  exit "$exit_code"
}
trap _on_err ERR

# Deletes ONLY rows created by:
#   python3 ../scripts/sqs_load_real_concert.py -n 30000 --spread-users 30000 --via-was ...
#
# Safety constraints (must all match):
# - concert title = DEFAULT_CONCERT_TITLE in sqs_load_real_concert.py
# - users user_id in [1..30000]
# - users.name starts with "sqs-load-concert-" (created/ensured by the load script)
#
# Notes:
# - Deleting from concert_booking cascades to concert_booking_seats + concert_payment (FK ON DELETE CASCADE).

NS="${NS:-ticketing}"
UID_MIN="${UID_MIN:-1}"
UID_MAX="${UID_MAX:-30000}"
USER_NAME_PREFIX="${USER_NAME_PREFIX:-sqs-load-concert-}"
CONCERT_TITLE="${CONCERT_TITLE:-2026 봄 페스티벌 LIVE - 5만석}"
# Optional: if set, skip auto-detect query and delete only this show_id.
SHOW_ID="${SHOW_ID:-}"
# Default behavior: reset DB to "fresh boot" state (keep schema, truncate all data, re-seed).
# To run the old selective cleanup instead, invoke:
#   bash delete.sh selective
MODE="${MODE:-reset}"
# If true, wipe all concert booking tables (fast reset for test env).
WIPE_CONCERT_TABLES="${WIPE_CONCERT_TABLES:-false}"
# If true, wipe ALL booking-related tables (theater+concert) and related Redis keys (test env reset).
# IMPORTANT: This does NOT touch catalog/master data (concerts, shows, halls, seats, etc).
# Default: selective delete only (loadtest bookings for the detected show/users).
# To do a full wipe, run with: WIPE_ALL_BOOKINGS=true
WIPE_ALL_BOOKINGS="${WIPE_ALL_BOOKINGS:-false}"
# Optional: also delete loadtest users (name prefix) after wiping.
WIPE_LOADTEST_USERS="${WIPE_LOADTEST_USERS:-false}"

# mysql client pod (ephemeral)
MYSQL_POD="${MYSQL_POD:-db-loadtest-clean-$(date +%s)}"
MYSQL_IMAGE="${MYSQL_IMAGE:-mysql:8}"
# How to run mysql client:
# - k8s-pod (default): create a temporary mysql client pod and exec into it
# - local: run local `mysql` binary directly (no temp pod; avoids pod Ready timeouts)
MYSQL_CLIENT_MODE="${MYSQL_CLIENT_MODE:-k8s-pod}"

_need() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing command: $1" >&2; exit 127; }
}

_need kubectl

_k() {
  kubectl --request-timeout="$KUBECTL_REQUEST_TIMEOUT" "$@"
}

echo "=== loadtest cleanup (concert via-was) ==="
echo "namespace=$NS"
echo "uid_range=$UID_MIN..$UID_MAX"
echo "user_name_prefix=${USER_NAME_PREFIX}*"
echo "concert_title=$CONCERT_TITLE"
if [[ -n "$SHOW_ID" ]]; then
  echo "show_id=$SHOW_ID (explicit)"
else
  echo "show_id=(auto-detect by max matching bookings)"
fi
echo "wipe_concert_tables=$WIPE_CONCERT_TABLES"
echo "wipe_all_bookings=$WIPE_ALL_BOOKINGS"
echo "wipe_loadtest_users=$WIPE_LOADTEST_USERS"
echo "mysql_client_mode=$MYSQL_CLIENT_MODE"

if [[ "$MYSQL_CLIENT_MODE" == "local" ]]; then
  _need mysql
  : "${DB_HOST:?DB_HOST required when MYSQL_CLIENT_MODE=local}"
  : "${DB_USER:?DB_USER required when MYSQL_CLIENT_MODE=local}"
  : "${DB_PASSWORD:?DB_PASSWORD required when MYSQL_CLIENT_MODE=local}"
  : "${DB_NAME:?DB_NAME required when MYSQL_CLIENT_MODE=local}"
  : "${DB_PORT:?DB_PORT required when MYSQL_CLIENT_MODE=local}"
  # Redis invalidation still uses cluster lookup unless explicitly provided.
  REDIS_HOST="${REDIS_HOST:-}"
else
  DB_HOST="$(_k -n "$NS" get secret ticketing-secrets -o jsonpath='{.data.DB_WRITER_HOST}' | base64 -d | tr -d '\r\n')"
  DB_USER="$(_k -n "$NS" get secret ticketing-secrets -o jsonpath='{.data.DB_USER}' | base64 -d | tr -d '\r\n')"
  DB_PASSWORD="$(_k -n "$NS" get secret ticketing-secrets -o jsonpath='{.data.DB_PASSWORD}' | base64 -d | tr -d '\r\n')"
  DB_NAME="$(_k -n "$NS" get configmap ticketing-config -o jsonpath='{.data.DB_NAME}' | tr -d '\r\n')"
  DB_PORT="$(_k -n "$NS" get configmap ticketing-config -o jsonpath='{.data.DB_PORT}' | tr -d '\r\n')"
  REDIS_HOST="$(_k -n "$NS" get secret ticketing-secrets -o jsonpath='{.data.REDIS_HOST}' 2>/dev/null | base64 -d | tr -d '\r\n' || true)"
fi
if [[ -z "$REDIS_HOST" ]]; then
  if [[ "$MYSQL_CLIENT_MODE" != "local" ]]; then
    REDIS_HOST="$(_k -n "$NS" get secret ticketing-secrets -o jsonpath='{.data.ELASTICACHE_PRIMARY_ENDPOINT}' 2>/dev/null | base64 -d | tr -d '\r\n' || true)"
  fi
fi
if [[ "$MYSQL_CLIENT_MODE" == "local" ]]; then
  REDIS_PORT="${REDIS_PORT:-}"
  REDIS_DB_CACHE="${REDIS_DB_CACHE:-}"
else
  REDIS_PORT="$(_k -n "$NS" get configmap ticketing-config -o jsonpath='{.data.REDIS_PORT}' | tr -d '\r\n')"
  REDIS_DB_CACHE="$(_k -n "$NS" get configmap ticketing-config -o jsonpath='{.data.ELASTICACHE_LOGICAL_DB_CACHE}' | tr -d '\r\n')"
fi

if [[ -z "${DB_HOST}" || -z "${DB_USER}" || -z "${DB_NAME}" || -z "${DB_PORT}" ]]; then
  echo "ERROR: failed to load DB settings from $NS/{ticketing-secrets,ticketing-config}" >&2
  exit 1
fi

cleanup() {
  # IMPORTANT: do not block shell prompt on pod termination.
  # If the API server is slow or the pod gets stuck terminating, waiting here looks like a "hang".
  _k -n "$NS" delete pod "$MYSQL_POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

if [[ "$MYSQL_CLIENT_MODE" == "k8s-pod" ]]; then
  _k -n "$NS" run "$MYSQL_POD" \
    --image="$MYSQL_IMAGE" \
    --restart=Never \
    --command -- sh -lc "sleep 3600" >/dev/null

  if ! _k -n "$NS" wait --for=condition=Ready pod/"$MYSQL_POD" --timeout="$POD_READY_TIMEOUT" >/dev/null; then
    echo "ERROR: mysql client pod not Ready: $MYSQL_POD (timeout=$POD_READY_TIMEOUT)" >&2
    echo "--- pod status ---" >&2
    _k -n "$NS" get pod "$MYSQL_POD" -o wide >&2 || true
    echo "--- pod describe (tail) ---" >&2
    _k -n "$NS" describe pod "$MYSQL_POD" 2>&1 | tail -n 80 >&2 || true
    echo "--- namespace events (tail) ---" >&2
    _k -n "$NS" get events --sort-by=.lastTimestamp 2>&1 | tail -n 80 >&2 || true
    exit 1
  fi
fi

if [[ "${1-}" == "selective" ]]; then
  MODE="selective"
fi

if [[ "$MODE" != "selective" ]]; then
  echo "MODE=reset: truncating all tables and re-seeding from db-schema/Insert.sql"

  TRUNCATE_SQL="$(cat <<'EOF'
USE ticketing;
DROP PROCEDURE IF EXISTS __truncate_all_tables;
DELIMITER $$
CREATE PROCEDURE __truncate_all_tables()
BEGIN
  DECLARE done INT DEFAULT 0;
  DECLARE t VARCHAR(128);
  DECLARE cur CURSOR FOR
    SELECT table_name
    FROM information_schema.tables
    WHERE table_schema = DATABASE()
      AND table_type = 'BASE TABLE';
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;

  SET FOREIGN_KEY_CHECKS = 0;
  OPEN cur;
  read_loop: LOOP
    FETCH cur INTO t;
    IF done = 1 THEN
      LEAVE read_loop;
    END IF;
    SET @sql := CONCAT('TRUNCATE TABLE `', t, '`');
    PREPARE stmt FROM @sql;
    EXECUTE stmt;
    DEALLOCATE PREPARE stmt;
  END LOOP;
  CLOSE cur;
  SET FOREIGN_KEY_CHECKS = 1;
END$$
DELIMITER ;
CALL __truncate_all_tables();
DROP PROCEDURE IF EXISTS __truncate_all_tables;
EOF
)"

  if [[ "$MYSQL_CLIENT_MODE" == "local" ]]; then
    echo "Running truncate via local mysql client"
    MYSQL_PWD="$DB_PASSWORD" mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" --protocol=tcp --default-character-set=utf8mb4 -D "$DB_NAME" -e "$TRUNCATE_SQL"
    echo "Running seed: db-schema/Insert.sql"
    MYSQL_PWD="$DB_PASSWORD" mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" --protocol=tcp --default-character-set=utf8mb4 -D "$DB_NAME" < "$(cd "$(dirname "$0")/.." && pwd)/db-schema/Insert.sql"
  else
    echo "Running truncate via mysql client pod: $MYSQL_POD"
    _k -n "$NS" exec "$MYSQL_POD" -- sh -lc \
      "MYSQL_PWD=\"$DB_PASSWORD\" mysql -h \"$DB_HOST\" -P \"$DB_PORT\" -u \"$DB_USER\" --protocol=tcp --default-character-set=utf8mb4 -D \"$DB_NAME\" -e \"$TRUNCATE_SQL\""
    echo "Copying seed file into pod and applying"
    _k -n "$NS" cp "$(cd "$(dirname "$0")/.." && pwd)/db-schema/Insert.sql" "$MYSQL_POD":/tmp/Insert.sql
    _k -n "$NS" exec "$MYSQL_POD" -- sh -lc \
      "MYSQL_PWD=\"$DB_PASSWORD\" mysql -h \"$DB_HOST\" -P \"$DB_PORT\" -u \"$DB_USER\" --protocol=tcp --default-character-set=utf8mb4 -D \"$DB_NAME\" < /tmp/Insert.sql"
  fi

  echo "=== done (reset) ==="
  exit 0
fi

_sql_escape_squote() {
  # escape for SQL single-quoted strings:  '  ->  ''
  local s="${1-}"
  s="${s//\'/\'\'}"
  printf '%s' "$s"
}

USER_NAME_PREFIX_ESC="$(_sql_escape_squote "$USER_NAME_PREFIX")"
CONCERT_TITLE_ESC="$(_sql_escape_squote "$CONCERT_TITLE")"

SQL="$(cat <<EOF
SET @uid_min := $UID_MIN;
SET @uid_max := $UID_MAX;
SET @user_prefix := '$USER_NAME_PREFIX_ESC';
SET @concert_title := '$CONCERT_TITLE_ESC';
SET @explicit_show_id := ${SHOW_ID:-NULL};
SET @wipe_tables := ${WIPE_CONCERT_TABLES};
SET @wipe_all_bookings := ${WIPE_ALL_BOOKINGS};
SET @wipe_users := ${WIPE_LOADTEST_USERS};

-- Fast path: wipe whole tables (test env reset)
-- NOTE: this removes ALL rows in these tables, not just loadtest rows.
-- Use only when you truly want a clean slate.
SET @do_wipe := (LOWER(COALESCE(@wipe_tables, 'false')) IN ('1','true','yes','y','on'));
SET @do_wipe_all := (LOWER(COALESCE(@wipe_all_bookings, 'false')) IN ('1','true','yes','y','on'));
SET @do_wipe_users := (LOWER(COALESCE(@wipe_users, 'false')) IN ('1','true','yes','y','on'));

SELECT
  @do_wipe AS will_wipe_concert_tables,
  @do_wipe_all AS will_wipe_all_booking_tables,
  @do_wipe_users AS will_wipe_loadtest_users;

-- Wipe mode: MySQL IF/THEN is not allowed outside stored programs.
-- Use WHERE @do_wipe/@do_wipe_all to conditionally delete all rows.
SET FOREIGN_KEY_CHECKS=0;

-- 1) ALL bookings wipe (theater + concert)
DELETE FROM payment WHERE @do_wipe_all;
DELETE FROM booking_seats WHERE @do_wipe_all;
DELETE FROM booking WHERE @do_wipe_all;

DELETE FROM concert_payment WHERE (@do_wipe OR @do_wipe_all);
DELETE FROM concert_booking_seats WHERE (@do_wipe OR @do_wipe_all);
DELETE FROM concert_booking WHERE (@do_wipe OR @do_wipe_all);

-- Recompute remain_count columns (catalog rows remain intact)
UPDATE schedules s
SET remain_count = GREATEST(0, s.total_count - IFNULL((
  SELECT COUNT(*) FROM booking_seats bs WHERE bs.schedule_id = s.schedule_id
), 0))
WHERE @do_wipe_all;

UPDATE concert_shows cs
SET remain_count = GREATEST(0, cs.total_count - IFNULL((
  SELECT COUNT(*) FROM concert_booking_seats cbs
  WHERE cbs.show_id = cs.show_id AND UPPER(COALESCE(cbs.status, '')) = 'ACTIVE'
), 0))
WHERE (@do_wipe OR @do_wipe_all);

SET FOREIGN_KEY_CHECKS=1;

DELETE FROM users
WHERE @do_wipe_users
  AND user_id BETWEEN @uid_min AND @uid_max
  AND name LIKE CONCAT(@user_prefix, '%');

-- If wipe ran, show post counts and exit early.
SELECT COUNT(*) AS booking_rows_total FROM booking;
SELECT COUNT(*) AS booking_seats_rows_total FROM booking_seats;
SELECT COUNT(*) AS payment_rows_total FROM payment;
SELECT COUNT(*) AS concert_booking_rows_total FROM concert_booking;
SELECT COUNT(*) AS concert_booking_seats_rows_total FROM concert_booking_seats;
SELECT COUNT(*) AS concert_payment_rows_total FROM concert_payment;

-- Find target show_id (or use explicit one).
SET @target_show_id := IF((@do_wipe OR @do_wipe_all), NULL, IFNULL(@explicit_show_id, (
  SELECT t.show_id FROM (
    SELECT cb.show_id AS show_id, COUNT(*) AS bookings
    FROM concert_booking cb
    JOIN users u ON u.user_id = cb.user_id
    JOIN concert_shows cs ON cs.show_id = cb.show_id
    JOIN concerts c ON c.concert_id = cs.concert_id
    WHERE cb.user_id BETWEEN @uid_min AND @uid_max
      AND u.name LIKE CONCAT(@user_prefix, '%')
      AND c.title = @concert_title
    GROUP BY cb.show_id
    ORDER BY bookings DESC
    LIMIT 1
  ) t
)));

SELECT @target_show_id AS target_show_id;
SELECT concert_id INTO @target_concert_id
FROM concert_shows
WHERE show_id = @target_show_id;
SELECT @target_concert_id AS target_concert_id;

-- Materialize only the booking_ids we intend to delete (avoid repeating joins).
DROP TEMPORARY TABLE IF EXISTS _loadtest_booking_ids;
CREATE TEMPORARY TABLE _loadtest_booking_ids (
  booking_id BIGINT PRIMARY KEY
) ENGINE=MEMORY;

INSERT INTO _loadtest_booking_ids (booking_id)
SELECT cb.booking_id
FROM concert_booking cb
JOIN users u ON u.user_id = cb.user_id
JOIN concert_shows cs ON cs.show_id = cb.show_id
JOIN concerts c ON c.concert_id = cs.concert_id
WHERE cb.show_id = @target_show_id
  AND cb.user_id BETWEEN @uid_min AND @uid_max
  AND u.name LIKE CONCAT(@user_prefix, '%')
  AND c.title = @concert_title;

SELECT COUNT(*) AS target_booking_ids FROM _loadtest_booking_ids;

-- Counts before delete
SELECT COUNT(*) AS concert_booking_rows
FROM concert_booking cb
JOIN _loadtest_booking_ids t ON t.booking_id = cb.booking_id;

SELECT COUNT(*) AS concert_booking_seats_rows
FROM concert_booking_seats s
JOIN _loadtest_booking_ids t ON t.booking_id = s.booking_id;

SELECT COUNT(*) AS concert_payment_rows
FROM concert_payment p
JOIN _loadtest_booking_ids t ON t.booking_id = p.booking_id;

-- Delete (cascades to seats/payment)
DELETE cb
FROM concert_booking cb
JOIN _loadtest_booking_ids t ON t.booking_id = cb.booking_id;

-- Sync remain_count after cleanup (cache reads this column)
UPDATE concert_shows cs
SET remain_count = GREATEST(0, cs.total_count - IFNULL((
  SELECT COUNT(*) FROM concert_booking_seats cbs
  WHERE cbs.show_id = cs.show_id AND UPPER(COALESCE(cbs.status, '')) = 'ACTIVE'
), 0))
WHERE (@do_wipe OR @do_wipe_all) OR cs.show_id = @target_show_id;

SELECT show_id, total_count, remain_count
FROM concert_shows
WHERE show_id = @target_show_id;

-- Counts after delete
SELECT COUNT(*) AS concert_booking_rows_after
FROM concert_booking cb
JOIN _loadtest_booking_ids t ON t.booking_id = cb.booking_id;

-- For bash parsing (tsv): __IDS__  <show_id>  <concert_id>
SELECT '__IDS__' AS tag, @target_show_id AS show_id, @target_concert_id AS concert_id;
EOF
)"

echo "Running cleanup SQL via mysql client pod: $MYSQL_POD"
if [[ "$MYSQL_CLIENT_MODE" == "local" ]]; then
  echo "Running cleanup SQL via local mysql client"
  OUT="$(MYSQL_PWD="$DB_PASSWORD" mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" --protocol=tcp --default-character-set=utf8mb4 -D "$DB_NAME" -N -B -e "$SQL")"
else
  echo "Running cleanup SQL via mysql client pod: $MYSQL_POD"
  OUT="$(_k -n "$NS" exec "$MYSQL_POD" -- sh -lc \
    "MYSQL_PWD=\"$DB_PASSWORD\" mysql -h \"$DB_HOST\" -P \"$DB_PORT\" -u \"$DB_USER\" --protocol=tcp --default-character-set=utf8mb4 -D \"$DB_NAME\" -N -B -e \"$SQL\"")"
fi
printf '%s\n' "$OUT"

IDS_LINE="$(printf '%s\n' "$OUT" | grep -F '__IDS__' | tail -n 1 || true)"
TARGET_SHOW_ID=""
TARGET_CONCERT_ID=""
if [[ -n "$IDS_LINE" ]]; then
  IFS=$'\t' read -r _tag TARGET_SHOW_ID TARGET_CONCERT_ID <<< "$IDS_LINE" || true
fi

if [[ -n "$REDIS_HOST" && -n "$TARGET_SHOW_ID" && -n "$TARGET_CONCERT_ID" ]]; then
  echo "Invalidating Redis read-cache keys (show_id=$TARGET_SHOW_ID concert_id=$TARGET_CONCERT_ID db=$REDIS_DB_CACHE)"
  REDIS_POD="redis-loadtest-clean-$(date +%s)"
  _k -n "$NS" delete pod "$REDIS_POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  _k -n "$NS" run "$REDIS_POD" --image="redis:7-alpine" --restart=Never --command -- sh -lc "sleep 3600" >/dev/null
  _k -n "$NS" wait --for=condition=Ready pod/"$REDIS_POD" --timeout="$POD_READY_TIMEOUT" >/dev/null
  _k -n "$NS" exec "$REDIS_POD" -- sh -lc \
    "redis-cli -h \"$REDIS_HOST\" -p \"$REDIS_PORT\" -n \"${REDIS_DB_CACHE:-0}\" DEL \
      \"concert:show:${TARGET_SHOW_ID}:read:v2\" \
      \"concert:shows_meta:${TARGET_CONCERT_ID}:read:v1\" \
      \"concert:bootstrap:${TARGET_CONCERT_ID}:read:v1\" >/dev/null || true"
  _k -n "$NS" delete pod "$REDIS_POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
else
  echo "Skip Redis invalidation (missing REDIS_HOST or target ids)."
fi

# Full bookings wipe: remove booking-related redis keys too (both cache db + booking db).
if [[ -n "$REDIS_HOST" ]]; then
  DO_WIPE_ALL="$(printf '%s' "${WIPE_ALL_BOOKINGS}" | tr '[:upper:]' '[:lower:]' | tr -d ' \r\n')"
  if [[ "$DO_WIPE_ALL" == "1" || "$DO_WIPE_ALL" == "true" || "$DO_WIPE_ALL" == "yes" || "$DO_WIPE_ALL" == "y" || "$DO_WIPE_ALL" == "on" ]]; then
    echo "WIPE_ALL_BOOKINGS=true: wiping booking-related Redis keys (cache_db=$REDIS_DB_CACHE booking_db=$REDIS_DB_BOOKING)"
    REDIS_DB_BOOKING="${REDIS_DB_BOOKING:-$(_k -n "$NS" get configmap ticketing-config -o jsonpath='{.data.ELASTICACHE_LOGICAL_DB_BOOKING}' | tr -d '\r\n')}"
    REDIS_POD2="redis-booking-wipe-$(date +%s)"
    _k -n "$NS" delete pod "$REDIS_POD2" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    _k -n "$NS" run "$REDIS_POD2" --image="redis:7-alpine" --restart=Never --command -- sh -lc "sleep 3600" >/dev/null
    _k -n "$NS" wait --for=condition=Ready pod/"$REDIS_POD2" --timeout="$POD_READY_TIMEOUT" >/dev/null
    _k -n "$NS" exec "$REDIS_POD2" -- sh -lc "
set -e
wipe_db() {
  db=\"\$1\"
  pat=\"\$2\"
  echo \"db=\$db pattern=\$pat\" >&2
  redis-cli -h \"$REDIS_HOST\" -p \"$REDIS_PORT\" -n \"\$db\" --scan --pattern \"\$pat\" | xargs -r redis-cli -h \"$REDIS_HOST\" -p \"$REDIS_PORT\" -n \"\$db\" DEL >/dev/null
}

# cache db: concert seat status/holds + show snapshots
wipe_db \"${REDIS_DB_CACHE:-0}\" 'concert:show:*:read:v2'
wipe_db \"${REDIS_DB_CACHE:-0}\" 'concert:bootstrap:*:read:v1'
wipe_db \"${REDIS_DB_CACHE:-0}\" 'concert:shows_meta:*:read:v1'
wipe_db \"${REDIS_DB_CACHE:-0}\" 'concert:hold:*:v1'
wipe_db \"${REDIS_DB_CACHE:-0}\" 'concert:confirmed:*:v1'
wipe_db \"${REDIS_DB_CACHE:-0}\" 'concert:show:*:hold_rev:v1'
wipe_db \"${REDIS_DB_CACHE:-0}\" 'concert:seat:*:hold:v1'
wipe_db \"${REDIS_DB_CACHE:-0}\" 'concert:holdmeta:*:v1'

# booking db: async status + queue counters + waiting-room counters
wipe_db \"${REDIS_DB_BOOKING:-1}\" 'booking:result:*'
wipe_db \"${REDIS_DB_BOOKING:-1}\" 'booking:queued:*'
wipe_db \"${REDIS_DB_BOOKING:-1}\" 'booking:queue:*'
wipe_db \"${REDIS_DB_BOOKING:-1}\" 'wr:*'
"
    _k -n "$NS" delete pod "$REDIS_POD2" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
fi

echo "=== done ==="

