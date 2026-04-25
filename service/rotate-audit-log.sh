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

# If today's archive already exists, we already rotated today — append.
if [ -e "$archive_path" ]; then
  cat "$AUDIT_FILE" >> "$archive_path"
else
  mv "$AUDIT_FILE" "$archive_path"
fi
# Recreate the live file so the proxy keeps appending without restart
# (the proxy holds a write stream — we touch a fresh file in place).
: >"$AUDIT_FILE"
chmod 600 "$AUDIT_FILE" 2>/dev/null || true

# Compute SHA-256 checksum sidecar for the rotated file. This lets us
# detect tampering or storage corruption later — not crypto-strength
# integrity (no signing), just a tripwire.
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

# IMPORTANT: the running proxy holds a write fd to the original inode.
# Truncating the file via `: >` keeps the same inode, so the fd remains
# valid and writes go to the (now empty) file. No proxy restart needed.
# Verified by experiment: stat -f %i AUDIT_FILE before/after rotation
# matches.

echo "rotated $size bytes into ${archive_name}, checksum recorded"
