#!/usr/bin/env bash
set -euo pipefail

# Render portal_config: copy + inject secrets/DB/hosts/storage.

export TETHYS_HOME="${TETHYS_HOME:-/home/tethys/portal}"
export TETHYS_PERSIST="${TETHYS_PERSIST:-/home/tethys/persist}"
export STATIC_ROOT="${STATIC_ROOT:-/home/tethys/persist/static}"
export MEDIA_ROOT="${MEDIA_ROOT:-/home/tethys/persist/media}"
export TETHYS_WORKSPACES_ROOT="${TETHYS_WORKSPACES_ROOT:-/home/tethys/persist/workspaces}"

. /usr/local/bin/db-env.sh

PORTAL_CONFIG_SRC="${PORTAL_CONFIG_SRC:-/config/portal_config.yml}"

mkdir -p "$TETHYS_HOME"

echo "Applying portal config from $PORTAL_CONFIG_SRC"
cp "$PORTAL_CONFIG_SRC" "$TETHYS_HOME/portal_config.yml"

# ECS-only: this task's private IP
TASK_IP=""
if [ -n "${ECS_CONTAINER_METADATA_URI_V4:-}" ]; then
  TASK_IP="$(curl -s --max-time 3 "${ECS_CONTAINER_METADATA_URI_V4}/task" \
    | python -c 'import sys,json
try:
    d=json.load(sys.stdin)
    ips=[a for c in d.get("Containers",[]) for n in c.get("Networks",[]) for a in n.get("IPv4Addresses",[])]
    print(ips[0] if ips else "")
except Exception:
    print("")' 2>/dev/null || true)"
fi
PORTAL_ALLOWED_HOSTS="${PORTAL_ALLOWED_HOSTS:-}" TASK_IP="$TASK_IP" \
  python - "$TETHYS_HOME/portal_config.yml" <<'PY'
import os, re, sys, yaml
path = sys.argv[1]
with open(path) as f:
    cfg = yaml.safe_load(f) or {}
s = cfg.setdefault("settings", {})
extra = [h.strip() for h in os.environ.get("PORTAL_ALLOWED_HOSTS", "").split(",") if h.strip()]

# ALLOWED_HOSTS: baseline + env + task IP
hosts = list(s.get("ALLOWED_HOSTS") or [])
for h in extra:
    if h not in hosts:
        hosts.append(h)
ip = os.environ.get("TASK_IP", "").strip()
if ip and ip not in hosts:
    hosts.append(ip)
s["ALLOWED_HOSTS"] = hosts

# CSRF_TRUSTED_ORIGINS: https origin per real domain
def is_ip(h):
    return bool(re.match(r"^\d{1,3}(\.\d{1,3}){3}$", h))
csrf = list(s.get("CSRF_TRUSTED_ORIGINS") or [])
for h in extra:
    if h in ("localhost", "127.0.0.1") or is_ip(h):
        continue
    origin = "https://" + h
    if origin not in csrf:
        csrf.append(origin)
if csrf:
    s["CSRF_TRUSTED_ORIGINS"] = csrf

with open(path, "w") as f:
    yaml.safe_dump(cfg, f, default_flow_style=False, sort_keys=False)
print("ALLOWED_HOSTS =", hosts)
print("CSRF_TRUSTED_ORIGINS =", csrf)
PY


# secrets + DB connection (from env)
set_args=(
  --set SECRET_KEY "${TETHYS_SECRET_KEY:?TETHYS_SECRET_KEY is required (from tethys-secret)}"
  --set DATABASES.default.ENGINE "$TETHYS_DB_ENGINE"
)
if [ "$DB_IS_SERVER" = 1 ]; then
  set_args+=(--set DATABASES.default.PASSWORD "${TETHYS_DB_PASSWORD:?TETHYS_DB_PASSWORD is required (from tethys-db-app)}")
  [ -n "${TETHYS_DB_HOST:-}" ]     && set_args+=(--set DATABASES.default.HOST "$TETHYS_DB_HOST")
  [ -n "${TETHYS_DB_USERNAME:-}" ] && set_args+=(--set DATABASES.default.USER "$TETHYS_DB_USERNAME")
  [ -n "${TETHYS_DB_PORT:-}" ]     && set_args+=(--set DATABASES.default.PORT "$TETHYS_DB_PORT")
  [ -n "${TETHYS_DB_NAME:-}" ]     && set_args+=(--set DATABASES.default.NAME "$TETHYS_DB_NAME")
else
  # sqlite: one file under persist
  mkdir -p "$(dirname "$SQLITE_PATH")"
  set_args+=(--set DATABASES.default.NAME "$SQLITE_PATH")
fi

tethys settings "${set_args[@]}"

# S3 static/media (only when configured)
if [ -n "${STATIC_S3_BUCKET:-}" ]; then
  loc="static"
  s3_args=(
    --set STORAGES.staticfiles.BACKEND "portal_storage.PortalStaticS3Storage"
    --set STORAGES.staticfiles.OPTIONS.bucket_name "$STATIC_S3_BUCKET"
    --set STORAGES.staticfiles.OPTIONS.region_name "${AWS_REGION:-us-east-1}"
    --set STORAGES.staticfiles.OPTIONS.location "$loc"
    --set STORAGES.staticfiles.OPTIONS.querystring_auth false
    --set STORAGES.default.BACKEND "storages.backends.s3.S3Storage"
    --set STORAGES.default.OPTIONS.bucket_name "$STATIC_S3_BUCKET"
    --set STORAGES.default.OPTIONS.region_name "${AWS_REGION:-us-east-1}"
    --set STORAGES.default.OPTIONS.location "media"
    --set STORAGES.default.OPTIONS.querystring_auth false
  )
  if [ -n "${STATIC_CLOUDFRONT_DOMAIN:-}" ]; then
    s3_args+=( --set STORAGES.staticfiles.OPTIONS.custom_domain "$STATIC_CLOUDFRONT_DOMAIN" )
    s3_args+=( --set STATIC_URL "https://${STATIC_CLOUDFRONT_DOMAIN}/${loc}/" )
    s3_args+=( --set STORAGES.default.OPTIONS.custom_domain "$STATIC_CLOUDFRONT_DOMAIN" )
    s3_args+=( --set MEDIA_URL "https://${STATIC_CLOUDFRONT_DOMAIN}/media/" )
  fi
  tethys settings "${s3_args[@]}"
  echo "S3 static+media configured: bucket=$STATIC_S3_BUCKET static=static/ media=media/ domain=${STATIC_CLOUDFRONT_DOMAIN:-<none>}"
fi

echo "Tethys portal config applied."
