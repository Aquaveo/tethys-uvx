#!/usr/bin/env bash
set -euo pipefail

# Web container entrypoint. init and web are SEPARATE containers on ECS (separate filesystems), so the
# web container renders its own portal_config.yml (DB host/user/port + secrets + S3 storages) before
# serving. portal-config.sh is idempotent and does NOT touch the DB or run migrations.
/usr/local/bin/portal-config.sh

export DJANGO_SETTINGS_MODULE="${DJANGO_SETTINGS_MODULE:-tethys_portal.settings}"

APP="tethys_portal.asgi:application"
HOST="0.0.0.0"
PORT="${PORT:-${TETHYS_PORT:-8000}}"
WORKERS="${ASGI_PROCESSES:-1}"
FWD="${FORWARDED_ALLOW_IPS:-*}"

# SERVER=uvicorn (default) | gunicorn. Both serve the SAME ASGI app. gunicorn just MANAGES the uvicorn
# workers (pre-fork model: worker recycling via --max-requests, hung-worker timeouts, graceful
# restarts). gunicorn MUST use the uvicorn worker class -- Tethys is ASGI (Django + Channels/async),
# so a sync/WSGI worker would break async + websockets.
case "${SERVER:-uvicorn}" in
  gunicorn)
    echo "Serving with gunicorn (uvicorn workers): workers=${WORKERS} port=${PORT}"
    exec gunicorn "$APP" \
      -k uvicorn.workers.UvicornWorker \
      -w "$WORKERS" \
      -b "${HOST}:${PORT}" \
      --forwarded-allow-ips="$FWD" \
      --max-requests "${GUNICORN_MAX_REQUESTS:-1000}" \
      --max-requests-jitter "${GUNICORN_MAX_REQUESTS_JITTER:-100}" \
      --timeout "${GUNICORN_TIMEOUT:-60}" \
      --graceful-timeout "${GUNICORN_GRACEFUL_TIMEOUT:-30}" \
      --access-logfile - --error-logfile -
    ;;
  uvicorn | *)
    echo "Serving with uvicorn: workers=${WORKERS} port=${PORT}"
    exec uvicorn "$APP" \
      --host "$HOST" \
      --port "$PORT" \
      --workers "$WORKERS" \
      --proxy-headers \
      --forwarded-allow-ips="$FWD"
    ;;
esac
