#!/usr/bin/env bash
set -euo pipefail

# Render the portal config for this pod.
#
# The portal config is now declarative: it comes from the mounted tethys-portal-config
# This script only:
#   1. copies that file into TETHYS_HOME, and
#   2. injects the values that must NOT live in a ConfigMap - secrets, plus the
#      environment-specific DB host (the init Job sets TETHYS_DB_HOST=tethys-postgres-rw
#      to bypass the transaction-mode pooler for migrations).
#
# => Changing any Django/portal setting is just an edit to portal_config.yml + re-apply.
#    No image rebuild, because this script never enumerates settings.

export TETHYS_HOME="${TETHYS_HOME:-/home/tethys/portal}"
export TETHYS_PERSIST="${TETHYS_PERSIST:-/home/tethys/persist}"
export STATIC_ROOT="${STATIC_ROOT:-/home/tethys/persist/static}"
export MEDIA_ROOT="${MEDIA_ROOT:-/home/tethys/persist/media}"
export TETHYS_WORKSPACES_ROOT="${TETHYS_WORKSPACES_ROOT:-/home/tethys/persist/workspaces}"

# Where the ConfigMap is mounted (see the configure initContainer volumeMount).
PORTAL_CONFIG_SRC="${PORTAL_CONFIG_SRC:-/config/portal_config.yml}"

mkdir -p "$TETHYS_HOME" 

echo "Applying portal config from $PORTAL_CONFIG_SRC"
cp "$PORTAL_CONFIG_SRC" "$TETHYS_HOME/portal_config.yml"

# Merge ALLOWED_HOSTS: baseline (from the file) + PORTAL_ALLOWED_HOSTS env (ALB DNS, public domain)
# + THIS task's own private IP, fetched from the ECS metadata endpoint. The ALB health check sends
# the request with Host=<task-ip>, so the running task must allow its own IP (avoids ALLOWED_HOSTS=*).
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

# ALLOWED_HOSTS: baseline + PORTAL_ALLOWED_HOSTS (ALB DNS, CloudFront domain, public domain) + task IP
hosts = list(s.get("ALLOWED_HOSTS") or [])
for h in extra:
    if h not in hosts:
        hosts.append(h)
ip = os.environ.get("TASK_IP", "").strip()
if ip and ip not in hosts:
    hosts.append(ip)
s["ALLOWED_HOSTS"] = hosts

# CSRF_TRUSTED_ORIGINS: https://<host> for each real domain (skip localhost + bare IPs). Required
# for POST/login behind CloudFront (the Origin header is the public https domain, not the ALB).
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

# Behind CloudFront -> ALB (HTTP): trust X-Forwarded-Proto so Django knows the request is HTTPS.
s["SECURE_PROXY_SSL_HEADER"] = ["HTTP_X_FORWARDED_PROTO", "https"]

with open(path, "w") as f:
    yaml.safe_dump(cfg, f, default_flow_style=False, sort_keys=False)
print("ALLOWED_HOSTS =", hosts)
print("CSRF_TRUSTED_ORIGINS =", csrf)
PY


set_args=(
  --set SECRET_KEY "${TETHYS_SECRET_KEY:?TETHYS_SECRET_KEY is required (from tethys-secret)}"
  --set DATABASES.default.PASSWORD "${TETHYS_DB_PASSWORD:?TETHYS_DB_PASSWORD is required (from tethys-db-app)}"
)
if [ -n "${TETHYS_DB_HOST:-}" ]; then
  set_args+=(--set DATABASES.default.HOST "$TETHYS_DB_HOST")
fi
# Supabase pooler (Supavisor) identifies the tenant from the username suffix: USER must be
# "<role>.<project_ref>" (e.g. tethys_default.xxxx) or you get "no tenant identifier provided".
if [ -n "${TETHYS_DB_USERNAME:-}" ]; then
  set_args+=(--set DATABASES.default.USER "$TETHYS_DB_USERNAME")
fi
if [ -n "${TETHYS_DB_PORT:-}" ]; then
  set_args+=(--set DATABASES.default.PORT "$TETHYS_DB_PORT")
fi
if [ -n "${TETHYS_DB_NAME:-}" ]; then
  set_args+=(--set DATABASES.default.NAME "$TETHYS_DB_NAME")
fi

tethys settings "${set_args[@]}"

# S3 static via django-storages (only when configured -- no-op for the local/workshop path).
# collectstatic (in publish-static.sh) uploads to S3 under the "static/" prefix; CloudFront serves
# /static/* from this bucket. The prefix is FIXED to "static" (not INIT_VERSION) so it matches the
# CloudFront "/static/*" cache behavior AND the tethysdash React bundle's hardcoded /static/ paths.
if [ -n "${STATIC_S3_BUCKET:-}" ]; then
  loc="static"
  s3_args=(
    # static files -> S3 under "static/" (collectstatic uploads here; CloudFront /static/* serves it)
    --set STORAGES.staticfiles.BACKEND "portal_storage.PortalStaticS3Storage"
    --set STORAGES.staticfiles.OPTIONS.bucket_name "$STATIC_S3_BUCKET"
    --set STORAGES.staticfiles.OPTIONS.region_name "${AWS_REGION:-us-east-1}"
    --set STORAGES.staticfiles.OPTIONS.location "$loc"
    --set STORAGES.staticfiles.OPTIONS.querystring_auth false
    # media (user/app uploads) -> S3 under "media/" (durable; the portal is stateless, no local disk).
    # CloudFront /media/* serves it. Same bucket, different prefix.
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