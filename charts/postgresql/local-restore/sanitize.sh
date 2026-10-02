#!/usr/bin/env bash
# Sanitizes a CloudNativePG base backup so it can boot under vanilla postgres.
#
# CNPG injects config that depends on the /controller sidecar (SSL certs,
# unix socket, archive/restore commands, streaming_replica cert auth). None
# of that exists in a plain postgres container, so we rewrite the config
# files and reset the WAL. Runs as a one-shot init container; the `db`
# service waits for this to complete and then starts normally.
#
# Idempotent via a marker file; safe to re-run.
set -euo pipefail

PGDATA="${PGDATA:-/var/lib/postgresql/18/docker}"
MARKER="$PGDATA/.cnpg-sanitized"

if [ ! -f "$PGDATA/PG_VERSION" ]; then
  echo "No PG_VERSION at $PGDATA. Did you extract the backup into ./pg_data?" >&2
  exit 1
fi

if [ -f "$MARKER" ]; then
  echo "Already sanitized, nothing to do."
  exit 0
fi

echo "Sanitizing CNPG backup at $PGDATA..."

cat > "$PGDATA/custom.conf" <<'CONF'
archive_mode = 'off'
cluster_name = 'cnpg-restore'
dynamic_shared_memory_type = 'posix'
hot_standby = 'on'
listen_addresses = '*'
log_destination = 'stderr'
logging_collector = 'off'
max_parallel_workers = '32'
max_replication_slots = '32'
max_worker_processes = '32'
port = '5432'
shared_memory_type = 'mmap'
ssl = 'off'
wal_keep_size = '512MB'
wal_level = 'logical'
wal_log_hints = 'on'
CONF

: > "$PGDATA/override.conf"

# Trust everything: POSTGRES_PASSWORD only applies at initdb time, which
# we skip since we're mounting a pre-populated data dir. We don't know the
# production postgres role password, so trust auth is the pragmatic choice
# for a local dev copy.
cat > "$PGDATA/pg_hba.conf" <<'HBA'
local   all             all                                     trust
host    all             all             127.0.0.1/32            trust
host    all             all             ::1/128                 trust
host    all             all             all                     trust
HBA

cat > "$PGDATA/pg_ident.conf" <<'IDENT'
# MAPNAME       SYSTEM-USERNAME         PG-USERNAME
IDENT

# Barman cloud base backups ship only the data dir; WAL files live under
# a separate object store prefix. Without them we cannot replay from the
# backup_label checkpoint, so drop the label and let pg_resetwal synthesize
# a fresh control file. This is destructive (any in-flight transactions at
# backup time are lost) but fine for a local dev copy.
rm -f "$PGDATA/backup_label" "$PGDATA/backup_label.old"
rm -f "$PGDATA"/cnpg_initialized-*

# Barman cloud backups omit pg_wal contents; pg_resetwal requires these
# subdirs to exist even when empty. `summaries` was added in Postgres 17.
mkdir -p "$PGDATA/pg_wal/archive_status" "$PGDATA/pg_wal/summaries"

chown -R postgres:postgres "$PGDATA"
chmod 0700 "$PGDATA"

echo "Resetting WAL..."
gosu postgres pg_resetwal -f "$PGDATA"

touch "$MARKER"
chown postgres:postgres "$MARKER"
echo "Done."
