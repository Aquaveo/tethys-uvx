#!/usr/bin/env bash
set -euo pipefail
#
# run-once.sh <marker> -- <command...>
#
# Runs <command> only the FIRST time for a given marker, then records that it ran so later runs
# skip it. The record (the "marker") lives in the DATABASE, not in a file -- see WHY below.
#
# Marker storage: a tiny table `tethys_init_markers(name, completed_at)` in tethys_platform. One row
# per completed step. run-once creates the table on first use (the app role has CREATE from the
# bootstrap grants).
#
# WHY the DB and not a file: on ECS the init/web containers are ephemeral and replaced often. A
# file marker on the container filesystem would vanish with the container, so the step would re-run
# on every task -- defeating "once" (and it's the same instance-replacement trap that wiped data
# earlier). The Supabase DB is the one thing that survives task/instance replacement, so a marker
# there means "once" actually holds across restarts, new tasks, and new instances.
#
# Key = "<marker>" or, if INIT_VERSION is set (set it to the image tag), "<marker>@<INIT_VERSION>".
#   - Same version  -> key already recorded -> SKIP (fast restarts/redeploys of the same image).
#   - New version   -> new key -> RUNS ONCE, then records (so a new image applies new services/store
#                      migrations exactly once).
#   - INIT_VERSION unset -> run-once-ever.
#
# Escape hatch: INIT_FORCE=true ignores the marker and runs anyway (re-records). Use it to re-apply
# a guarded step (e.g. changed ggst settings) without cutting a new image.
#
# Reads the image DB env: TETHYS_DB_HOST/PORT/USERNAME/PASSWORD/NAME (NAME must be tethys_platform).
#
# Example:  run-once.sh tethysdash -- /usr/local/bin/configure-tethysdash.sh
: "${TETHYS_DB_HOST:?}" "${TETHYS_DB_PORT:?}" "${TETHYS_DB_USERNAME:?}" "${TETHYS_DB_PASSWORD:?}" "${TETHYS_DB_NAME:?}"

marker="${1:?usage: run-once.sh <marker> -- <command...>}"; shift
[ "${1:-}" = "--" ] && shift
[ "$#" -ge 1 ] || { echo "run-once: no command given" >&2; exit 2; }
key="${marker}${INIT_VERSION:+@${INIT_VERSION}}"

psqlc() {
  PGPASSWORD="$TETHYS_DB_PASSWORD" psql -h "$TETHYS_DB_HOST" -p "$TETHYS_DB_PORT" \
    -U "$TETHYS_DB_USERNAME" -d "$TETHYS_DB_NAME" -X -tA -v ON_ERROR_STOP=1 "$@"
}

psqlc -c "CREATE TABLE IF NOT EXISTS tethys_init_markers (
            name text PRIMARY KEY,
            completed_at timestamptz NOT NULL DEFAULT now());" >/dev/null

if [ "${INIT_FORCE:-false}" = "true" ]; then
  echo "run-once: INIT_FORCE=true -- running '${key}' regardless of marker"
elif [ "$(psqlc -c "SELECT 1 FROM tethys_init_markers WHERE name = '${key}'")" = "1" ]; then
  echo "run-once: '${key}' already done -- skipping"
  exit 0
fi

echo "run-once: '${key}' -- running"
"$@"
psqlc -c "INSERT INTO tethys_init_markers(name, completed_at) VALUES ('${key}', now())
          ON CONFLICT (name) DO UPDATE SET completed_at = now();" >/dev/null
echo "run-once: '${key}' -- recorded"
