#!/bin/bash
# rotate-audit-log: rotate ~/.claude-dual/audit.jsonl daily, keep 30 days,
# emit a SHA-256 checksum sidecar for each rotated file so corruption can
# be detected post-hoc.
#
# Run on a daily schedule (e.g. via LaunchAgent / cron / claude-dual
# startup). Idempotent: running twice in the same day is a no-op after
# the first rotation.

set -eu

AUDIT_DIR="${HOME}/.claude-dual"
AUDIT_FILE="${AUDIT_DIR}/audit.jsonl"
ARCHIVE_DIR="${AUDIT_DIR}/audit-archive"
RETENTION_DAYS=30

mkdir -p "$ARCHIVE_DIR"

[ -f "$AUDIT_FILE" ] || { echo "no audit log to rotate"; exit 0; }

# Skip if file is empty or under 1KB — nothing meaningful to rotate.
size=$(wc -c <"$AUDIT_FILE" | tr -d ' ')
[ "$size" -lt 1024 ] && { echo "audit log too small to rotate ($size bytes)"; exit 0; }

# Use yesterday's date as the archive name (we rotate when the day rolls
# over; the file we're archiving contains *yesterday's* completed traffic).
# But for simplicity in the daily cron model, name by today's date — it's
# the day the rotation happened.
archive_date=$(date -u +%Y-%m-%d)
archive_name="audit-${archive_date}.jsonl"
archive_path="${ARCHIVE_DIR}/${archive_name}"

# IMPORTANT: the proxy holds an open write fd on AUDIT_FILE. POSIX
# semantics: an open fd points at the *inode*, not the directory entry.
# That means `mv $AUDIT_FILE $archive_path` would move the inode the
# proxy is writing to into the archive — every subsequent write would
# corrupt the archive instead of going to the new live file.
#
# Correct pattern: APPEND to the archive, then TRUNCATE the live file
# in place. Truncation keeps the inode (and the proxy's fd) valid; the
# fd simply sees the file shrink to zero. Subsequent proxy writes land
# at offset 0 of the same inode — i.e. the new live file.
#
# Idempotency: running twice in a day means the second batch concatenates
# onto the existing archive rather than creating audit-DATE-2.jsonl
# proliferation.
cat "$AUDIT_FILE" >> "$archive_path"
: >"$AUDIT_FILE"
chmod 600 "$AUDIT_FILE" 2>/dev/null || true

# Compute SHA-256 checksum sidecar for the rotated file. ALWAYS rewrite
# it — both on the initial rotation and on any subsequent same-day
# appends — so the sidecar always matches the current archive bytes.
# Without this re-computation, a same-day re-rotation invalidates the
# previous checksum (the file grew, the checksum didn't update).
checksum=$(shasum -a 256 "$archive_path" | awk '{print $1}')
echo "$checksum  $archive_name" >"${archive_path}.sha256"

# Compress old archives (>1 day old, .jsonl only).
find "$ARCHIVE_DIR" -name 'audit-*.jsonl' -type f -mtime +0 -exec gzip -f {} \; 2>/dev/null || true
# Re-checksum gzipped files (the gzip changes the bytes; sidecar should
# track the live archive form).
for gz in "$ARCHIVE_DIR"/audit-*.jsonl.gz; do
  [ -e "$gz" ] || continue
  base=$(basename "$gz")
  if [ ! -f "${gz}.sha256" ] || [ "$gz" -nt "${gz}.sha256" ]; then
    sum=$(shasum -a 256 "$gz" | awk '{print $1}')
    echo "$sum  $base" >"${gz}.sha256"
    # Remove the now-stale uncompressed sidecar.
    rm -f "${ARCHIVE_DIR}/${base%.gz}.sha256"
  fi
done

# Retention: delete archives older than RETENTION_DAYS days.
find "$ARCHIVE_DIR" -name 'audit-*.jsonl*' -type f -mtime +"$RETENTION_DAYS" -delete 2>/dev/null || true
find "$ARCHIVE_DIR" -name 'audit-*.sha256'  -type f -mtime +"$RETENTION_DAYS" -delete 2>/dev/null || true

echo "rotated $size bytes into ${archive_name}, checksum recorded"
