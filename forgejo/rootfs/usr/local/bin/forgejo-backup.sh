#!/usr/bin/env bash
# Dumps the forgejo database to /config/backups/ and prunes old dumps.
# Reads retention from /data/options.json (HA writes this) — falls back to 7 days.

set -euo pipefail

# Cron invokes this with a minimal environment (no PATH). Set one explicitly
# so jq, su-exec, pg_dump, gzip, find, date, stat are reachable.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

BACKUP_DIR=/config/backups
RETENTION_DAYS=$(jq -r '.backup_retention_days // 7' /data/options.json 2>/dev/null || echo 7)

mkdir -p "$BACKUP_DIR"

TIMESTAMP=$(date +%F_%H-%M)
DUMP_FILE="$BACKUP_DIR/forgejo-${TIMESTAMP}.sql.gz"

echo "[backup] starting dump to $DUMP_FILE"
if su-exec postgres pg_dump -h /tmp -U postgres -d forgejo | gzip > "$DUMP_FILE"; then
  SIZE=$(stat -c %s "$DUMP_FILE" 2>/dev/null || stat -f %z "$DUMP_FILE")
  echo "[backup] OK: $DUMP_FILE ($SIZE bytes)"
else
  echo "[backup] FAILED dumping forgejo database" >&2
  rm -f "$DUMP_FILE"
  exit 1
fi

echo "[backup] pruning dumps older than ${RETENTION_DAYS} days"
find "$BACKUP_DIR" -maxdepth 1 -name 'forgejo-*.sql.gz' -mtime "+${RETENTION_DAYS}" -print -delete || true

echo "[backup] done"
