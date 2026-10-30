#!/usr/bin/env bash
set -euo pipefail

# Build verb: run a command against a throwaway sqlite DB (see README).

[ "$#" -gt 0 ] || { echo "usage: build-db.sh <command> [args...]" >&2; exit 2; }

cfg="${TETHYS_HOME:-/home/tethys/portal}/portal_config.yml"
tmp="$(mktemp -d)"

# restore the portal config + drop the DB on exit
cp "$cfg" "$tmp/portal_config.yml"
trap 'cp "$tmp/portal_config.yml" "$cfg"; rm -rf "$tmp"' EXIT

tethys settings --set DATABASES.default.ENGINE django.db.backends.sqlite3 \
  --set DATABASES.default.NAME "$tmp/build.sqlite3"
tethys db migrate

"$@"
