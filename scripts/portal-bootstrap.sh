#!/usr/bin/env bash
set -euo pipefail

# Create superuser (idempotent)
if [ "${CREATE_SUPERUSER:-true}" = "true" ]; then
  echo "Creating portal superuser . . ."
  tethys db createsuperuser --pn "${PORTAL_SUPERUSER_NAME:-admin}" --pp "${PORTAL_SUPERUSER_PASSWORD:-pass}" --pe "${PORTAL_SUPERUSER_EMAIL:-}"
fi

# Apply site settings
echo "Applying site settings from portal_config.yml"
tethys site -f

echo "Portal bootstrap complete!"