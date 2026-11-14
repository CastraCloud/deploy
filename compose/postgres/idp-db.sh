#!/bin/sh
# Creates the keycloak role and database for the bundled identity provider (identity profile). Safe to run
# on every start: it only creates what is missing and re-applies the password. Connects as the Postgres
# superuser through the PG* variables the idp-db-init service sets.
set -eu

: "${KEYCLOAK_DB_PASSWORD:?set KEYCLOAK_DB_PASSWORD in .env to use the identity profile}"
: "${OIDC_CLIENT_SECRET:?set OIDC_CLIENT_SECRET in .env to use the identity profile}"

psql -v ON_ERROR_STOP=1 -v kc_password="$KEYCLOAK_DB_PASSWORD" << 'SQL'
SET castra.kc_password = :'kc_password';
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'keycloak') THEN
    CREATE ROLE keycloak LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE;
  END IF;
  EXECUTE format('ALTER ROLE keycloak PASSWORD %L', current_setting('castra.kc_password'));
END
$$;
SELECT 'CREATE DATABASE keycloak OWNER keycloak' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'keycloak')
\gexec
REVOKE ALL ON DATABASE keycloak FROM PUBLIC;
SQL
