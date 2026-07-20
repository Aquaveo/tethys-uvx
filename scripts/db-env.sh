#!/usr/bin/env bash
# db-env.sh -- single source of truth for the DB engine. SOURCED (not executed) by the init/serve
# scripts so the sqlite/postgres branch is decided in exactly one place.
#
# Two supported flavors:
#   sqlite  -- a local file, no server (great for a single-container local/dev portal)
#   server  -- a networked DB reached over host/port/creds (postgres)
#
# Exports:
#   DB_IS_SERVER  1 = needs host/port/creds + a readiness probe (postgres); 0 = sqlite (a file)
#   SQLITE_PATH   the sqlite DB file (only meaningful when DB_IS_SERVER=0)
: "${TETHYS_DB_ENGINE:=django.db.backends.postgresql}"
case "$TETHYS_DB_ENGINE" in
  *sqlite3) DB_IS_SERVER=0 ;;
  *)        DB_IS_SERVER=1 ;;
esac

# A sqlite NAME is a file path: honor an absolute one, else default under TETHYS_PERSIST -- a mounted
# volume, so the DB (and its run-once markers) survive container replacement like the data beside it.
case "${TETHYS_DB_NAME:-}" in
  /*) SQLITE_PATH="$TETHYS_DB_NAME" ;;
  *)  SQLITE_PATH="${TETHYS_PERSIST:-/home/tethys/persist}/tethys_platform.sqlite" ;;
esac

export DB_IS_SERVER SQLITE_PATH TETHYS_DB_ENGINE
