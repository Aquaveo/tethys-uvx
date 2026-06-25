#!/usr/bin/env bash
set -euo pipefail
#
# configure-tethysdash.sh  - replaces salt/tethysdash.sls (salt-free).
#
# Links the PostGIS service to the tethysdash persistent store, ensures the store schema, and
# collects the tethysdash plugin static metadata. Idempotent (replaces the tethysdash_setup_complete
# marker guard).
#
# ⚠ OVERLAP WITH THE DB REPO: in the new design the store DB (tethysdash_primary_db) is created and
# its schema applied PRE-ECS by the DB-provisioning repo (provision.sh + migrate.sh, which runs the
# link + syncstores). If you keep that, this script's link/syncstores are idempotent no-ops here and
# you really only need step 3 (collect_plugin_static). Toggle with RUN_STORE_SETUP.
#   - syncstores is SAFE even though we banned its CREATE DATABASE: the DB already exists, so
#     create_persistent_store_database() skips CREATE DATABASE and runs only the alembic initializer.
#
# Required env:
#   POSTGIS_SERVICE_NAME     e.g. primary_postgis
# Optional:
#   RUN_STORE_SETUP=true|false   (default true) - do the link + syncstores here too

: "${POSTGIS_SERVICE_NAME:?}"
RUN_STORE_SETUP="${RUN_STORE_SETUP:-true}"

if [ "$RUN_STORE_SETUP" = "true" ]; then
  echo "==> link PostGIS service to tethysdash store"
  tethys link "persistent:${POSTGIS_SERVICE_NAME}" "tethysdash:ps_database:primary_db" \
    || echo "    (link may already exist - continuing)"

  # Apply the tethysdash store schema DIRECTLY via its initializer (alembic upgrade head against the
  # already-existing store DB). We do NOT use `tethys syncstores`: on Supabase its maintenance step
  # opens a connection WITHOUT a dbname, so psycopg2 defaults the dbname to the username
  # (tethys_default.<ref>) and fails with "database does not exist". Calling the initializer with the
  # store engine skips that maintenance/CREATE-DATABASE path entirely. Idempotent (upgrades to head;
  # stamps revisions whose objects already exist).
  echo "==> apply tethysdash store schema (init_primary_db -> alembic upgrade head)"
  DJANGO_SETTINGS_MODULE="${DJANGO_SETTINGS_MODULE:-tethys_portal.settings}" python - <<'PY'
import django
django.setup()
from tethysapp.tethysdash.app import App
from tethysapp.tethysdash.model import init_primary_db
engine = App.get_persistent_store_database("primary_db")
# clean=False: skip cleanup_old_jsons(), which is non-essential tidying and currently throws
# AttributeError on a fresh store (would abort init even though the schema upgrade succeeded).
init_primary_db(engine, first_time=True, clean=False)
print("tethysdash store schema applied (alembic upgrade head).")
PY
fi

# NOTE: tethysdash plugin static collection moved to publish-static.sh (it must run right before
# collectstatic, which is its own run-once step). This script now only does the store link + sync.

echo "tethysdash configured."
