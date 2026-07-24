#!/usr/bin/env bash
# DB engine source of truth
: "${TETHYS_DB_ENGINE:=django.db.backends.postgresql}"
case "$TETHYS_DB_ENGINE" in
  *sqlite3) DB_IS_SERVER=0 ;;
  *)        DB_IS_SERVER=1 ;;
esac

# sqlite path
case "${TETHYS_DB_NAME:-}" in
  /*) SQLITE_PATH="$TETHYS_DB_NAME" ;;
  *)  SQLITE_PATH="${TETHYS_PERSIST:-/home/tethys/persist}/tethys_platform.sqlite" ;;
esac

export DB_IS_SERVER SQLITE_PATH TETHYS_DB_ENGINE
