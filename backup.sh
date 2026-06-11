#!/bin/sh
# Off-box backup for a single-node Garage deployment (replication factor 1).
#
# With RF=1 the node's meta/data volumes are the ONLY copy of every object —
# including customer contracts. This script takes a consistent metadata
# snapshot via the garage CLI, then tars the snapshot plus the data directory
# to BACKUP_DIR. Ship BACKUP_DIR off the machine (rsync/restic/rclone to
# another host or S3) — a backup on the same disk protects against nothing.
#
# Run from the docker host via cron, e.g.:
#   17 3 * * * CONTAINER=garage BACKUP_DIR=/var/backups/garage /opt/garage-deploy/backup.sh
#
# Restore: stop the container, extract the tarball over the meta/data volumes,
# start the container. Test this at least once before you need it.
set -eu

CONTAINER="${CONTAINER:-garage}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/garage}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
META_DIR="${GARAGE_METADATA_DIR:-/var/lib/garage/meta}"
DATA_DIR="${GARAGE_DATA_DIR:-/var/lib/garage/data}"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$BACKUP_DIR/garage-$STAMP.tar.gz"

mkdir -p "$BACKUP_DIR"

# 1. Consistent LMDB metadata snapshot (written to <meta>/snapshots inside the volume)
docker exec "$CONTAINER" /garage meta snapshot

# 2. Tar meta + data from inside the container's volumes
docker exec "$CONTAINER" tar -czf - "$META_DIR" "$DATA_DIR" > "$OUT"

# 3. Prune old backups
find "$BACKUP_DIR" -name 'garage-*.tar.gz' -mtime "+$RETENTION_DAYS" -delete

echo "backup written: $OUT ($(du -h "$OUT" | cut -f1))"
