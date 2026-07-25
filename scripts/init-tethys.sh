#!/usr/bin/env bash
set -euo pipefail

# Portal init: runs before the web tier.

/usr/local/bin/wait-for-role.sh
/usr/local/bin/portal-config.sh
/usr/local/bin/db-migrations.sh

# PostGIS service (only if configured)
if [ -n "${TETHYS_PS_CONNECTION:-}" ]; then
  /usr/local/bin/run-once.sh services -- /usr/local/bin/configure-services.sh
fi

/usr/local/bin/portal-bootstrap.sh

# portal-specific hooks
if [ -d /opt/portal/init.d ]; then
  for hook in /opt/portal/init.d/*.sh; do
    [ -e "$hook" ] || continue
    echo "Running portal init hook: $(basename "$hook")"
    bash "$hook"
  done
fi

echo "Tethys init complete"
