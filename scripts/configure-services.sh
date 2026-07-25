#!/usr/bin/env bash
set -euo pipefail
# Create Tethys service objects
: "${POSTGIS_SERVICE_NAME:?}" "${TETHYS_PS_CONNECTION:?}"

echo "==> PostGIS persistent-store service '$POSTGIS_SERVICE_NAME'"
tethys services create persistent -n "$POSTGIS_SERVICE_NAME" -c "$TETHYS_PS_CONNECTION" \
  || echo "    (service '$POSTGIS_SERVICE_NAME' may already exist -- continuing)"

echo "Services configured."
