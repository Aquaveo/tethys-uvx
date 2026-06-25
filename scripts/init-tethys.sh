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
# Connection split (Supabase): DDL/migrations here use the SESSION pooler (:5432); the web tier is
# flipped to the TRANSACTION pooler (:6543) at the end. The direct endpoint is IPv6-only/unused.
#
# Order:
#   0. wait-for-role        guard: app DB role usable via the pooler (Supavisor new-role sync lag)
#   1. portal-config        render portal_config.yml + inject secrets + DB host (session pooler)
#   2. db-migrations        tethys db migrate  -> tethys_platform core schema
#   3. configure-services   PostGIS Tethys service                       (was salt/tethys_services)
#   4. configure-tethysdash link store + syncstores + plugin static      (was salt/tethysdash)
#   5. portal-bootstrap     portal superuser + site/branding
#   6. flip web tier -> transaction pooler

# Every-deploy steps (idempotent): guard nothing — db-migrations MUST run so image upgrades apply
# new migrations; portal-config re-applies config/secrets; bootstrap is idempotent.
/usr/local/bin/wait-for-role.sh         # app role synced before we connect as it
/usr/local/bin/portal-config.sh         # DATABASES.default.HOST/PORT = session pooler (:5432)
/usr/local/bin/db-migrations.sh         # core migrations on the session pooler

# Once-per-image-version steps (structural/heavy) — guarded by a DB marker (run-once.sh). Bump
# INIT_VERSION (set it to the image tag) to force these to re-run after an app/services change.
/usr/local/bin/run-once.sh services   -- /usr/local/bin/configure-services.sh     # PostGIS
/usr/local/bin/run-once.sh tethysdash -- /usr/local/bin/configure-tethysdash.sh   # link + syncstores
/usr/local/bin/run-once.sh static     -- /usr/local/bin/publish-static.sh         # collect_plugin_static + collectstatic -> S3

/usr/local/bin/portal-bootstrap.sh      # superuser + `tethys site -f`

# Point the web tier at the transaction-mode pooler. DDL above ran on the session pooler; web reads
# this same portal_config.yml. On Supabase the pooler host is the same and only the PORT changes
# (5432 session -> 6543 transaction), so support flipping HOST and/or PORT. Skip if unset.
if [ -n "${TETHYS_POOLER_HOST:-}" ]; then
  echo "Repointing portal_config DB host -> ${TETHYS_POOLER_HOST} (web tier)"
  tethys settings --set DATABASES.default.HOST "${TETHYS_POOLER_HOST}"
fi
if [ -n "${TETHYS_POOLER_PORT:-}" ]; then
  echo "Repointing portal_config DB port -> ${TETHYS_POOLER_PORT} (web tier)"
  tethys settings --set DATABASES.default.PORT "${TETHYS_POOLER_PORT}"
fi

echo "Tethys init complete"
