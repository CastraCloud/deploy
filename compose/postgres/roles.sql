-- Creates the two database roles Castra runs as. Safe to run again (it re-applies passwords and grants).
--
--   castra_owner  owns the schema and runs migrations. Never used by the running application.
--   castra_app    used by every other role. Not a superuser, does not bypass row-level security,
--                 and can only read and write rows: no DDL, no TRUNCATE.
--
-- Run as the Postgres superuser, connected to the Castra database, with psql variables:
--   psql -v ON_ERROR_STOP=1 -v owner_password=... -v app_password=... -f roles.sql
-- The compose init script (init/01-castra-roles.sh) does this on first start.

SET castra.owner_password = :'owner_password';
SET castra.app_password = :'app_password';

DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'castra_owner') THEN
    CREATE ROLE castra_owner LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'castra_app') THEN
    CREATE ROLE castra_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
  END IF;
  EXECUTE format('ALTER ROLE castra_owner PASSWORD %L', current_setting('castra.owner_password'));
  EXECUTE format('ALTER ROLE castra_app PASSWORD %L', current_setting('castra.app_password'));
  -- The migrator keeps its bookkeeping in its own "drizzle" schema, which needs CREATE on the database.
  EXECUTE format('GRANT CONNECT, CREATE ON DATABASE %I TO castra_owner', current_database());
  EXECUTE format('GRANT CONNECT ON DATABASE %I TO castra_app', current_database());
  EXECUTE format('REVOKE ALL ON DATABASE %I FROM PUBLIC', current_database());
END
$$;

ALTER SCHEMA public OWNER TO castra_owner;
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO castra_app;

-- Tables, sequences and functions are created by castra_owner in later migrations, so the grants
-- are default privileges for that role. Without these, new tables would be invisible to castra_app.
ALTER DEFAULT PRIVILEGES FOR ROLE castra_owner IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO castra_app;
ALTER DEFAULT PRIVILEGES FOR ROLE castra_owner IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO castra_app;

-- Tables that already exist (re-running on a populated database).
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO castra_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO castra_app;
