#!/usr/bin/env bash
set -euo pipefail

# Provision verb: run once per release (see README).

/usr/local/bin/wait-for-role.sh
/usr/local/bin/portal-config.sh
/usr/local/bin/db-migrations.sh

# PostGIS persistent-store service (only if configured)
if [ -n "${TETHYS_PS_CONNECTION:-}" ]; then
  /usr/local/bin/run-once.sh services -- /usr/local/bin/configure-services.sh
fi

# publish static (prod only; DEBUG skips)
DEBUG="$(python -c 'import yaml,os
p=os.path.join(os.environ.get("TETHYS_HOME","/home/tethys/portal"),"portal_config.yml")
print(str((yaml.safe_load(open(p)) or {}).get("settings",{}).get("DEBUG",False)).lower())' 2>/dev/null || echo false)"
if [ "$DEBUG" != "true" ]; then
  /usr/local/bin/publish-static.sh
fi

/usr/local/bin/portal-bootstrap.sh

# portal hooks
if [ -d /opt/portal/init.d ]; then
  for hook in /opt/portal/init.d/*.sh; do
    [ -e "$hook" ] || continue
    echo "Running portal provision hook: $(basename "$hook")"
    bash "$hook"
  done
fi

echo "Tethys provision complete"
