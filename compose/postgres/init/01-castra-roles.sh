#!/bin/sh
# Runs once, on the first start of an empty Postgres volume (docker-entrypoint-initdb.d).
# Passwords come from the container environment, never from files in the repository.
set -eu

: "${CASTRA_DB_OWNER_PASSWORD:?set CASTRA_DB_OWNER_PASSWORD in .env}"
: "${CASTRA_DB_APP_PASSWORD:?set CASTRA_DB_APP_PASSWORD in .env}"

psql -v ON_ERROR_STOP=1 \
  --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  -v owner_password="$CASTRA_DB_OWNER_PASSWORD" \
  -v app_password="$CASTRA_DB_APP_PASSWORD" \
  -f /castra/roles.sql
