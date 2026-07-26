#!/usr/bin/env bash
set -euo pipefail

# render config + inject secrets
/usr/local/bin/portal-config.sh

export DJANGO_SETTINGS_MODULE="${DJANGO_SETTINGS_MODULE:-tethys_portal.settings}"
APP="tethys_portal.asgi:application"
HOST="0.0.0.0"
PORT="${PORT:-${TETHYS_PORT:-8000}}"
WORKERS="${ASGI_PROCESSES:-1}"
FWD="${FORWARDED_ALLOW_IPS:-*}"

# DEBUG -> dev server (runserver)
DEBUG="$(python -c 'import yaml,os
p=os.path.join(os.environ.get("TETHYS_HOME","/home/tethys/portal"),"portal_config.yml")
print(str((yaml.safe_load(open(p)) or {}).get("settings",{}).get("DEBUG",False)).lower())' 2>/dev/null || echo false)"

if [ "$DEBUG" = "true" ]; then
  echo "DEBUG on: serving with runserver"
  exec tethys manage -p "${HOST}:${PORT}" start
fi

case "${SERVER:-uvicorn}" in
  gunicorn)
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
    exec uvicorn "$APP" \
      --host "$HOST" \
      --port "$PORT" \
      --workers "$WORKERS" \
      --proxy-headers \
      --forwarded-allow-ips="$FWD"
    ;;
esac
