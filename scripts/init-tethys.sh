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

# Portal-specific extensions: run any executable in /opt/portal/init.d, in lexical order, after the
# portal is fully configured (migrations done, services/branding applied). Portals drop their own
# scripts in via their Dockerfile (COPY init.d/ /opt/portal/init.d/) without touching this base
# image. Each hook should be idempotent; a hook that must run once per image version can wrap itself
# in run-once.sh.
if [ -d /opt/portal/init.d ]; then
  for hook in /opt/portal/init.d/*.sh; do
    [ -e "$hook" ] || continue        # no-match glob guard when the dir is empty
    echo "Running portal init hook: $(basename "$hook")"
    bash "$hook"
  done
fi

echo "Tethys init complete"
