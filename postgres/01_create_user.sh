#!/bin/bash
# Creates the non-superuser playground role used by the API.
# Runs only on first database init (empty volume), so CREATE ROLE is safe once.
set -euo pipefail

if [ -z "${PLAYGROUND_PASSWORD:-}" ]; then
  echo "PLAYGROUND_PASSWORD is required" >&2
  exit 1
fi

psql -v ON_ERROR_STOP=1 \
  --username "$POSTGRES_USER" \
  --dbname "$POSTGRES_DB" \
  --set=pwd="$PLAYGROUND_PASSWORD" <<'EOSQL'
CREATE ROLE playground LOGIN PASSWORD :'pwd'
  NOSUPERUSER
  NOCREATEDB
  NOCREATEROLE
  NOINHERIT
  NOREPLICATION;

GRANT CONNECT ON DATABASE playground TO playground;
GRANT USAGE, CREATE ON SCHEMA public TO playground;
EOSQL
