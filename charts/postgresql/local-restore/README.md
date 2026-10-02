# Untested local salvage tools

Copied from Netail gitops commit 97e4f079366331422c5376854b3213d87af7f9e7,
with local-only port binding and an explicit image requirement. These scripts have
NOT been tested against homelab backups. Syntax checks do not establish recovery
correctness. Prefer pg_dump/pg_restore or a CNPG recovery with WAL replay.

The sanitizer rewrites PostgreSQL configuration; it does not anonymize data.
It removes backup_label and runs pg_resetwal, skipping WAL recovery. A physical
base backup may be inconsistent or corrupt without its required WAL. Use only a
disposable copy for salvage, never the original backup or a production data
volume. The local database accepts unauthenticated connections on localhost.
Do not expose it to the network. No restore is executed by this chart.

Set POSTGRES_IMAGE to an image matching the backup's PostgreSQL major and required
extensions before running Docker Compose. Verify the image supplies bash, gosu,
and pg_resetwal; custom images may need adaptation. The container PGDATA is
explicitly set, independent of the PostgreSQL image's default layout.

---

# local-restore

Boots a local Postgres from a CloudNativePG / Barman cloud base backup, for
dev inspection of production data.

## Usage

From this directory:

```sh
# 1. Extract the Barman cloud data tarball into ./pg_data
#    (either a local file or a s3:// URL; the S3 form is streamed)
./restore-cnpg-backup.sh s3://<bucket>/<server>/base/<backup-id>/data.tar.gz
# or: ./restore-cnpg-backup.sh /path/to/data.tar.gz

# 2. Set POSTGRES_IMAGE to the matching major/extensions image, then start postgres
docker compose up -d

# 3. Connect (trust auth, no password)
psql -h localhost -U postgres
```

`s3://` sources require the AWS CLI to be installed and authenticated with
read access to the bucket.

To reset and start over:

```sh
docker compose down
rm -rf ./pg_data
```

## How it works

`restore-cnpg-backup.sh` unpacks the tarball (flattening any wrapper dir) into
`./pg_data`, which both compose services bind-mount.

The `sanitize` service is a one-shot init container that rewrites the
CNPG-specific config so it runs under a vanilla `postgres` image:

- rewrites `custom.conf` / `override.conf` to drop `/controller` paths and
  disable SSL
- replaces `pg_hba.conf` with `trust`/`md5` rules (no cert auth)
- removes `backup_label` and runs `pg_resetwal -f`

It exits when done. The `db` service waits for it via
`depends_on: service_completed_successfully` and then runs as a stock
`$POSTGRES_IMAGE` container with no entrypoint override.

The `pg_resetwal` step is what makes this dev-only. Barman cloud base backups
do not ship WAL inline (WAL lives under a separate `wals/` prefix in the
object store), so we skip recovery instead of replaying. Skipping WAL can lose committed transactions and leave inconsistent or corrupt
data, including changes needed to make the base backup consistent. Do not use
this for a real restore.

A `.cnpg-sanitized` marker skips subsequent sanitizer runs. The marker does not
prove data consistency or successful recovery.

## Files

- `docker-compose.yaml` - `sanitize` init container + `db` postgres service
- `restore-cnpg-backup.sh` - host-side tarball extractor
- `sanitize.sh` - runs inside the init container to rewrite config and reset WAL
