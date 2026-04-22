#!/usr/bin/env bash
# Runs only on first cluster init — Postgres' entrypoint skips this
# directory when PGDATA is already populated.
set -euo pipefail

DUMP=/dump/dump
if [ ! -s "$DUMP" ]; then
  echo "No dump file at $DUMP; nothing to restore."
  exit 0
fi

echo "Restoring from $DUMP..."
du -sh "$DUMP"
if gunzip -t "$DUMP" 2>/dev/null; then
  echo "Detected: gzip-compressed plain SQL"
  zcat "$DUMP" | psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"
elif pg_restore -l "$DUMP" >/dev/null 2>&1; then
  echo "Detected: pg_dump custom format"
  pg_restore -v --no-owner --no-privileges --exit-on-error -U "$POSTGRES_USER" -d "$POSTGRES_DB" "$DUMP"
else
  echo "Detected: plain SQL"
  psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -f "$DUMP"
fi

# Sentinel — only written on full success. Checked by entrypoint-wrapper.sh
# on subsequent starts to detect partial-restore states.
touch "$PGDATA/.restore_complete"
echo "Restore complete; sentinel written."

rm -f "$DUMP"
echo "Removed $DUMP."
