#!/usr/bin/env bash
set -euo pipefail
# Wait for DB role to authenticate
. /usr/local/bin/db-env.sh
[ "$DB_IS_SERVER" = 1 ] || { echo "sqlite: no DB server to wait for"; exit 0; }

: "${TETHYS_DB_HOST:?}" "${TETHYS_DB_PORT:?}" "${TETHYS_DB_USERNAME:?}" "${TETHYS_DB_PASSWORD:?}"
db="${TETHYS_DB_NAME:-postgres}"
max="${MAX_TRIES:-30}"; delay="${DELAY:-4}"

for i in $(seq 1 "$max"); do
  if PGPASSWORD="$TETHYS_DB_PASSWORD" psql \
       -h "$TETHYS_DB_HOST" -p "$TETHYS_DB_PORT" -U "$TETHYS_DB_USERNAME" -d "$db" \
       -tAc 'select 1' >/dev/null 2>&1; then
    echo "DB role authenticates (after $i attempt(s))"
    exit 0
  fi
  echo "waiting for DB role to sync into the pooler... ($i/$max)"
  sleep "$delay"
done

echo "FATAL: DB role never became usable after $((max*delay))s" >&2
exit 1
