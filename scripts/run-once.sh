#!/usr/bin/env bash
set -euo pipefail
# run-once.sh <marker> -- <command...>
. /usr/local/bin/db-env.sh

marker="${1:?usage: run-once.sh <marker> -- <command...>}"; shift
[ "${1:-}" = "--" ] && shift
[ "$#" -ge 1 ] || { echo "run-once: no command given" >&2; exit 2; }
key="${marker}${INIT_VERSION:+@${INIT_VERSION}}"

# sqlite: file marker
if [ "$DB_IS_SERVER" != 1 ]; then
  mdir="$(dirname "$SQLITE_PATH")/.init_markers"; mkdir -p "$mdir"
  mfile="$mdir/${key//\//_}"
  if [ "${INIT_FORCE:-false}" = "true" ]; then
    echo "run-once: INIT_FORCE=true -- running '${key}' regardless of marker"
  elif [ -e "$mfile" ]; then
    echo "run-once: '${key}' already done -- skipping"; exit 0
  fi
  echo "run-once: '${key}' -- running"; "$@"; : > "$mfile"
  echo "run-once: '${key}' -- recorded"; exit 0
fi

# server DB: marker table
: "${TETHYS_DB_HOST:?}" "${TETHYS_DB_PORT:?}" "${TETHYS_DB_USERNAME:?}" "${TETHYS_DB_PASSWORD:?}" "${TETHYS_DB_NAME:?}"

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
