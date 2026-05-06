#!/usr/bin/env bashio
# shellcheck shell=bash
# Initialize PostgreSQL data directory and create the forgejo database/user on first run.

set -euo pipefail

PGDATA=/data/postgres
PG_BIN=/usr/bin
PASSWORD_FILE=/data/.db_password

# Ensure /data exists and is writable
mkdir -p /data

# Generate DB password if missing
if [[ ! -f "$PASSWORD_FILE" ]]; then
  bashio::log.info "Generating PostgreSQL password for user 'forgejo'..."
  head -c 32 /dev/urandom | base64 | tr -d '+/=' | head -c 32 > "$PASSWORD_FILE"
  chmod 600 "$PASSWORD_FILE"
fi

# Initialize PGDATA if missing
if [[ ! -f "$PGDATA/PG_VERSION" ]]; then
  bashio::log.info "Initializing PostgreSQL data directory at $PGDATA..."
  mkdir -p "$PGDATA"
  chown -R postgres:postgres "$PGDATA"
  chmod 0700 "$PGDATA"

  su-exec postgres "$PG_BIN/initdb" \
    --pgdata="$PGDATA" \
    --auth-local=trust \
    --auth-host=scram-sha-256 \
    --encoding=UTF8 \
    --locale=C

  # Configure postgres to bind only to 127.0.0.1 (and unix socket)
  cat > "$PGDATA/postgresql.auto.conf" <<'EOF'
listen_addresses = '127.0.0.1'
unix_socket_directories = '/tmp'
shared_buffers = '128MB'
EOF
  chown postgres:postgres "$PGDATA/postgresql.auto.conf"

  bashio::log.info "Starting temporary postgres to create database/user..."
  su-exec postgres "$PG_BIN/pg_ctl" -D "$PGDATA" -o "-h '' -k /tmp" -w start

  PASSWORD=$(cat "$PASSWORD_FILE")
  su-exec postgres psql -h /tmp -d postgres <<EOF
CREATE ROLE forgejo WITH LOGIN PASSWORD '$PASSWORD';
CREATE DATABASE forgejo OWNER forgejo ENCODING 'UTF8' LC_COLLATE='C' LC_CTYPE='C' TEMPLATE template0;
EOF

  bashio::log.info "Stopping temporary postgres..."
  su-exec postgres "$PG_BIN/pg_ctl" -D "$PGDATA" -m fast -w stop

  bashio::log.info "PostgreSQL initialization complete."
else
  bashio::log.info "PostgreSQL data directory already exists at $PGDATA - skipping init."
  chown -R postgres:postgres "$PGDATA"
fi

# Always ensure /data/forgejo and /config/backups exist
mkdir -p /data/forgejo /config/backups
chown -R git:git /data/forgejo
chown postgres:postgres /config/backups
chmod 0750 /config/backups
