#!/usr/bin/env bash
set -euo pipefail

# init and web are SEPARATE containers on ECS (separate filesystems), so the web container must
# render its own portal_config.yml (DB host/user/port/name/password + secret key + S3 storages)
# before starting. portal-config.sh is idempotent and does NOT touch the DB or run migrations.
/usr/local/bin/portal-config.sh

export DJANGO_SETTINGS_MODULE="${DJANGO_SETTINGS_MODULE:-tethys_portal.settings}"

exec uvicorn \
  tethys_portal.asgi:application \
  --host 0.0.0.0 \
  --port "${PORT:-${TETHYS_PORT:-8000}}" \
  --workers "${ASGI_PROCESSES:-1}" \
  --proxy-headers \
  --forwarded-allow-ips="${FORWARDED_ALLOW_IPS:-*}"