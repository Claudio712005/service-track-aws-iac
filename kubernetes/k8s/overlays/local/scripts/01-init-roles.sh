#!/bin/bash

set -euo pipefail

: "${FLYWAY_DB_USER:?FLYWAY_DB_USER não definida}"
: "${FLYWAY_DB_PASSWORD:?FLYWAY_DB_PASSWORD não definida}"
: "${APP_DB_USER:?APP_DB_USER não definida}"
: "${APP_DB_PASSWORD:?APP_DB_PASSWORD não definida}"

SUPERUSER="${PGUSER:-${POSTGRES_USER:-postgres}}"
DB="${PGDATABASE:-${POSTGRES_DB:-postgres}}"

psql -v ON_ERROR_STOP=1 --username "$SUPERUSER" --dbname "$DB" \
  -v flyway_user="$FLYWAY_DB_USER"  -v flyway_pass="$FLYWAY_DB_PASSWORD" \
  -v app_user="$APP_DB_USER"        -v app_pass="$APP_DB_PASSWORD" <<-'EOSQL'

	SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'flyway_user', :'flyway_pass')
	 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'flyway_user')
	\gexec
	SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'app_user', :'app_pass')
	 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'app_user')
	\gexec

	GRANT :"flyway_user" TO CURRENT_USER;
	GRANT :"app_user"    TO CURRENT_USER;

	REVOKE CREATE ON SCHEMA public FROM PUBLIC;

	GRANT USAGE, CREATE ON SCHEMA public TO :"flyway_user";
	GRANT USAGE            ON SCHEMA public TO :"app_user";

	GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES    IN SCHEMA public TO :"app_user";
	GRANT USAGE, SELECT                  ON ALL SEQUENCES IN SCHEMA public TO :"app_user";

	ALTER DEFAULT PRIVILEGES FOR ROLE :"flyway_user" IN SCHEMA public
	  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"app_user";
	ALTER DEFAULT PRIVILEGES FOR ROLE :"flyway_user" IN SCHEMA public
	  GRANT USAGE, SELECT ON SEQUENCES TO :"app_user";

EOSQL

echo "[init-roles] flyway_user e app_user provisionados."
