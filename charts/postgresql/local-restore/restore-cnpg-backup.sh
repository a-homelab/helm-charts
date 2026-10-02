#!/usr/bin/env bash
# Extracts a CloudNativePG / Barman cloud base backup tarball into ./pg_data
# so it can be booted by `docker compose up`.
#
# Usage:
#   ./restore-cnpg-backup.sh <source> [dest-dir]
#
# <source> may be:
#   - a local file path
#   - an s3:// URL, streamed via `aws s3 cp - `
#
# The tarball is what Barman cloud stores at
#   <bucket>/<server>/base/<backup-id>/data.tar.gz
#
# Example:
#   ./restore-cnpg-backup.sh \
#     s3://profitmind-postgres-backups/myapp-postgresql/base/20260410T184843/data.tar.gz
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <path-or-s3-url> [dest-dir]" >&2
  exit 1
fi

SOURCE="$1"
DEST="${2:-./pg_data}"

if [ -e "$DEST" ] && [ -n "$(ls -A "$DEST" 2>/dev/null || true)" ]; then
  echo "$DEST is not empty. Remove it or pass a different destination." >&2
  exit 1
fi

mkdir -p "$DEST"

case "$SOURCE" in
  s3://*)
    if ! command -v aws >/dev/null 2>&1; then
      echo "aws not found; install the AWS CLI to use s3:// sources." >&2
      exit 1
    fi
    echo "Streaming $SOURCE -> $DEST"
    # `cp - ` to stdout rather than a temp file, so a 40GB base backup is never
    # written twice.
    aws s3 cp "$SOURCE" - | tar -xf - -C "$DEST"
    ;;
  *)
    if [ ! -f "$SOURCE" ]; then
      echo "Backup file not found: $SOURCE" >&2
      exit 1
    fi
    echo "Extracting $SOURCE -> $DEST"
    tar -xf "$SOURCE" -C "$DEST"
    ;;
esac

# Some tarballs wrap the data dir in a subdirectory. Flatten if needed.
if [ ! -f "$DEST/PG_VERSION" ]; then
  FOUND="$(find "$DEST" -maxdepth 4 -name PG_VERSION -print -quit)"
  if [ -z "$FOUND" ]; then
    echo "PG_VERSION not found in extracted archive." >&2
    exit 1
  fi
  DATA_SUBDIR="$(dirname "$FOUND")"
  echo "Flattening $DATA_SUBDIR -> $DEST"
  (cd "$DATA_SUBDIR" && tar -cf - .) | (cd "$DEST" && tar -xf -)
  find "$DEST" -mindepth 1 -type d -empty -delete
fi

echo "Done. Next: docker compose up -d"
