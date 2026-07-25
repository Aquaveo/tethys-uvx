#!/usr/bin/env bash
set -euo pipefail
# Provision persistent store, least-privilege role
APP="${1:?usage: provision-persistent-store.sh <app_package> <ps_database_setting_name>}"
SETTING="${2:?usage: provision-persistent-store.sh <app_package> <ps_database_setting_name>}"

SERVICE_NAME="${TETHYS_APP_PS_SERVICE:-tethys_app_ps}"
DB_USER="${TETHYS_APP_DB_USERNAME:-tethys_app}"
DB_PASS="${TETHYS_APP_DB_PASSWORD:-pass}"
DB_HOST="${TETHYS_APP_DB_HOST:-${TETHYS_DB_HOST:-postgres}}"   # direct, not pooler
DB_PORT="${TETHYS_DB_PORT:-5432}"

echo "==> 1/3 Persistent-store service '${SERVICE_NAME}' -> ${DB_USER}@${DB_HOST}:${DB_PORT} (direct)"
tethys services create persistent \
  -n "${SERVICE_NAME}" \
  -c "${DB_USER}:${DB_PASS}@${DB_HOST}:${DB_PORT}" \
  || echo "    (service '${SERVICE_NAME}' may already exist -- continuing)"

echo "==> 2/3 Linking service to ${APP}:ps_database:${SETTING}"
tethys link "persistent:${SERVICE_NAME}" "${APP}:ps_database:${SETTING}" \
  || echo "    (link may already exist -- continuing)"

echo "==> 3/3 syncstores ${APP}  (creates <app>_${SETTING}, owned by ${DB_USER})"
tethys syncstores "${APP}"

# Verify store DB exists
STORE_DB="$(echo "${APP}_${SETTING}" | tr '[:upper:]' '[:lower:]' | tr ' ' '_')"
if PGPASSWORD="${DB_PASS}" psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" \
     -d "${DB_USER}" -tAc \
     "SELECT 1 FROM pg_database WHERE datname='${STORE_DB}'" 2>/dev/null | grep -q 1; then
  echo "Done. '${APP}' persistent store '${STORE_DB}' provisioned with least-privilege role '${DB_USER}' (no superuser)."
else
  echo "ERROR: syncstores reported done but store database '${STORE_DB}' does not exist." >&2
  echo "       (tethys syncstores swallows failures -- check the traceback above; common cause:" >&2
  echo "        the '${DB_USER}' maintenance database is missing, or the role lacks CREATEDB.)" >&2
  exit 1
fi