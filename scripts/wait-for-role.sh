#!/usr/bin/env bash
set -euo pipefail
#
# wait-for-role.sh — gentle guard: block until the app DB role can authenticate before the init
# runs migrations. Run FIRST in the init flow (before db-migrations.sh).
#
# WHY: the app role (tethys_default) is created PRE-ECS by the DB-provisioning repo (provision.sh).
# Supabase's pooler (Supavisor) syncs new roles lazily, so the very first login as that role can
# fail with "password authentication failed" for tens of seconds after creation. It only ever waits
# on the first bring-up (the role is cached forever after), so this is ~0s on normal deploys.
# Probe GENTLY (a plain `select 1`): hammering can cache a bad role state in Supavisor.
#
# Reads the image's DB env: TETHYS_DB_HOST / TETHYS_DB_PORT / TETHYS_DB_USERNAME / TETHYS_DB_PASSWORD
# (TETHYS_DB_NAME optional; falls back to 'postgres' just for the probe).
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
