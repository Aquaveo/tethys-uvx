#!/usr/bin/env bash
set -euo pipefail
#
# publish-static.sh -- gather + publish the portal static files. Run guarded by run-once (per
# INIT_VERSION) in the init job, so it publishes ONCE per image version.
#
# With django-storages configured (STORAGES.staticfiles = S3Storage, injected by portal-config.sh
# when STATIC_S3_BUCKET is set), `collectstatic` uploads files DIRECTLY to S3 -- no separate sync.
#
# Requires:
#   - the DB reachable (collectstatic triggers django.setup())  -> run after db-migrations
#   - S3 WRITE creds on the task role (PutObject on the bucket)
#   - the tethysdash React bundle (baked at image build) -- already present
#
# 1) tethysdash plugin static -- MUST run before collectstatic so the plugin assets are gathered.
# Only when tethysdash is installed: a store-less / non-tethysdash portal (e.g. a sqlite local
# portal) has no plugin static to gather and skips straight to collectstatic.
if SCRIPT_DIR="$(python -c 'import tethysapp.tethysdash as m, os; print(os.path.dirname(m.__file__))' 2>/dev/null)"; then
  ( cd "$SCRIPT_DIR" && python collect_plugin_static.py )
else
  echo "tethysdash not installed -- skipping plugin static collection."
fi

# 2) collect everything (platform + tethysdash bundle + ggst) -> uploaded to S3 by django-storages.
tethys manage collectstatic --noinput

echo "static published."
