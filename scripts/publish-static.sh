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
SCRIPT_DIR="$(dirname "$(python -c 'import tethysapp.tethysdash as m; print(m.__file__)')")"
( cd "$SCRIPT_DIR" && python collect_plugin_static.py )

# 2) collect everything (platform + tethysdash bundle + ggst) -> uploaded to S3 by django-storages.
tethys manage collectstatic --noinput

echo "static published."
