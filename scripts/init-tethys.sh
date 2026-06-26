#!/usr/bin/env bash
set -euo pipefail

# Portal init — runs in the init container/job BEFORE the web (uvicorn) tier. Salt-free
# (replaces salt/top.sls: tethys_services + tethysdash). Every step is idempotent, so it
# runs cleanly on every deploy and picks up edits to the mounted portal_config.yml.
#
# Roles + the databases themselves are provisioned PRE-ECS by the DB-provisioning repo
# (provision.sh, as the database `postgres` admin). This script does everything the app role can do
# against those already-created databases.
#
# DB-agnostic: connects to whatever Postgres TETHYS_DB_* points at (a transaction-mode pooler like
# Supabase Supavisor / PgBouncer, or a plain Postgres / RDS). TETHYS_DB_POOL_MODE ("transaction" or
# "direct", default direct) only controls DISABLE_SERVER_SIDE_CURSORS (set in portal-config.sh).
#
# Order:
#   0. wait-for-role        guard: app DB role usable (a plain `select 1`; instant on direct Postgres)
#   1. portal-config        render portal_config.yml + inject secrets + DB host/port + cursor mode
#   2. db-migrations        tethys db migrate  -> tethys_platform core schema
#   3. configure-services   PostGIS Tethys service                       (was salt/tethys_services)
#   4. configure-tethysdash link store + syncstores + plugin static      (was salt/tethysdash)
#   5. portal-bootstrap     portal superuser + site/branding

# Every-deploy steps (idempotent): guard nothing — db-migrations MUST run so image upgrades apply
# new migrations; portal-config re-applies config/secrets; bootstrap is idempotent.
/usr/local/bin/wait-for-role.sh         # app DB role usable before we connect as it
/usr/local/bin/portal-config.sh         # render config + DATABASES (HOST/PORT/USER + cursor mode)
/usr/local/bin/db-migrations.sh         # core migrations

# Once-per-image-version steps (structural/heavy) — guarded by a DB marker (run-once.sh). Bump
# INIT_VERSION (set it to the image tag) to force these to re-run after an app/services change.
/usr/local/bin/run-once.sh services   -- /usr/local/bin/configure-services.sh     # PostGIS
/usr/local/bin/run-once.sh tethysdash -- /usr/local/bin/configure-tethysdash.sh   # link + syncstores
/usr/local/bin/run-once.sh static     -- /usr/local/bin/publish-static.sh         # collect_plugin_static + collectstatic -> S3

/usr/local/bin/portal-bootstrap.sh      # superuser + `tethys site -f`

echo "Tethys init complete"
