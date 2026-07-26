#!/usr/bin/env bash
set -euo pipefail

# Provision verb: run once per release (see README).

. /usr/local/bin/db-env.sh

# wait for the DB role
if [ "$DB_IS_SERVER" = 1 ]; then
  : "${TETHYS_DB_HOST:?}" "${TETHYS_DB_PORT:?}" "${TETHYS_DB_USERNAME:?}" "${TETHYS_DB_PASSWORD:?}"
  db="${TETHYS_DB_NAME:-postgres}"; max="${MAX_TRIES:-30}"; delay="${DELAY:-4}"; ok=0
  for i in $(seq 1 "$max"); do
    if PGPASSWORD="$TETHYS_DB_PASSWORD" psql -h "$TETHYS_DB_HOST" -p "$TETHYS_DB_PORT" \
         -U "$TETHYS_DB_USERNAME" -d "$db" -tAc 'select 1' >/dev/null 2>&1; then
      echo "DB role authenticates (after $i attempt(s))"; ok=1; break
    fi
    echo "waiting for DB role... ($i/$max)"; sleep "$delay"
  done
  [ "$ok" = 1 ] || { echo "FATAL: DB role never became usable after $((max*delay))s" >&2; exit 1; }
fi

/usr/local/bin/portal-config.sh

echo "Running database migrations"
tethys db migrate

# PostGIS persistent-store service (if configured)
if [ -n "${TETHYS_PS_CONNECTION:-}" ]; then
  : "${POSTGIS_SERVICE_NAME:?}"
  tethys services create persistent -n "$POSTGIS_SERVICE_NAME" -c "$TETHYS_PS_CONNECTION" \
    || echo "  (service '$POSTGIS_SERVICE_NAME' may already exist)"
fi

# publish static (prod only; DEBUG skips)
DEBUG="$(python -c 'import yaml,os
p=os.path.join(os.environ.get("TETHYS_HOME","/home/tethys/portal"),"portal_config.yml")
print(str((yaml.safe_load(open(p)) or {}).get("settings",{}).get("DEBUG",False)).lower())' 2>/dev/null || echo false)"
if [ "$DEBUG" != "true" ]; then
  /usr/local/bin/publish-static.sh
fi

# superuser + site settings
if [ "${CREATE_SUPERUSER:-true}" = "true" ]; then
  tethys db createsuperuser --pn "${PORTAL_SUPERUSER_NAME:-admin}" \
    --pp "${PORTAL_SUPERUSER_PASSWORD:-pass}" --pe "${PORTAL_SUPERUSER_EMAIL:-}"
fi
tethys site -f

# portal hooks
if [ -d /opt/portal/init.d ]; then
  for hook in /opt/portal/init.d/*.sh; do
    [ -e "$hook" ] || continue
    echo "Running portal provision hook: $(basename "$hook")"
    bash "$hook"
  done
fi

echo "Tethys provision complete"
