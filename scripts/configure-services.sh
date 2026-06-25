#!/usr/bin/env bash
set -euo pipefail
#
# configure-services.sh  -- replaces salt/tethys_services.sls (salt-free).
#
# Creates the Tethys *service* objects (stored in tethys_platform): the PostGIS persistent-store
# service. Idempotent: `tethys services create` errors if a service already exists, so we don't abort
# for that (replaces the old marker-file guard).
#
# PostGIS (Supabase / Option B): uses the app role over the SESSION pooler (:5432) via
# TETHYS_PS_CONNECTION ("user:pass@host:port"). Supabase has no superuser.
#
# Required env:
#   POSTGIS_SERVICE_NAME, TETHYS_PS_CONNECTION

: "${POSTGIS_SERVICE_NAME:?}" "${TETHYS_PS_CONNECTION:?}"

echo "==> PostGIS persistent-store service '$POSTGIS_SERVICE_NAME'"
tethys services create persistent -n "$POSTGIS_SERVICE_NAME" -c "$TETHYS_PS_CONNECTION" \
  || echo "    (service '$POSTGIS_SERVICE_NAME' may already exist -- continuing)"

echo "Services configured."
