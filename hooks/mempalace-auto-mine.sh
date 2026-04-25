#!/bin/bash
# mempalace-auto-mine: SessionStart hook. For every project Claude Code
# opens, ensure MemPalace has indexed its content. Mirrors the
# code-review-graph SessionStart pattern:
#
#   - if mempalace.yaml exists in cwd → mine (incremental, idempotent)
#   - elif .git exists in cwd        → init --yes then mine
#   - else                           → no-op (not a tracked project)
#
# Runs in BACKGROUND with disowned subshell so it never blocks session
# startup. First-time mining of a new project takes 30-90s; we fire and
# forget. Logs to ~/.claude-dual/mempalace-auto-mine.log so you can see
# what it did when you next look.
#
# Skip rules:
#   - no mempalace CLI on PATH (graceful no-op)
#   - cwd is HOME directory (refuse to mine $HOME)
#   - cwd already mining (a stale .lock file is auto-cleaned after 1h)

set -eu

MEMPALACE_BIN="$HOME/Library/Python/3.9/bin/mempalace"
LOG_FILE="$HOME/.claude-dual/mempalace-auto-mine.log"
LOCK_DIR="$HOME/.claude-dual/mempalace-locks"

# Graceful no-op if mempalace isn't installed.
[ -x "$MEMPALACE_BIN" ] || exit 0

cwd="$(pwd)"

# Don't mine the home directory or root — too broad, would inhale everything.
case "$cwd" in
  "$HOME"|"$HOME/"|"/"|"")
    exit 0
    ;;
esac

# Need either an existing mempalace.yaml or a .git directory; otherwise
# this isn't a project we should be indexing.
if [ ! -f "$cwd/mempalace.yaml" ] && [ ! -d "$cwd/.git" ]; then
  exit 0
fi

mkdir -p "$LOCK_DIR"
# Lock file name is a sanitized version of cwd so concurrent sessions in
# the same project don't fight.
lock_name="$(echo "$cwd" | tr '/' '_' | tr -cd '[:alnum:]_-')"
lock_file="$LOCK_DIR/$lock_name.lock"

# Auto-clean stale locks (>1 hour old).
if [ -f "$lock_file" ]; then
  if [ "$(find "$lock_file" -mmin +60 2>/dev/null | wc -l | tr -d ' ')" = "1" ]; then
    rm -f "$lock_file"
  else
    # Another mine is in flight or recent — skip.
    exit 0
  fi
fi

# Background mine: don't block session startup. Touch the lock first so
# concurrent SessionStart hooks see it.
touch "$lock_file"
(
  trap 'rm -f "$lock_file"' EXIT INT TERM
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "[$ts] $cwd — start" >>"$LOG_FILE"

  if [ -f "$cwd/mempalace.yaml" ]; then
    "$MEMPALACE_BIN" mine "$cwd" >>"$LOG_FILE" 2>&1 || echo "[$ts] mine failed" >>"$LOG_FILE"
  else
    "$MEMPALACE_BIN" init --yes "$cwd" >>"$LOG_FILE" 2>&1 || { echo "[$ts] init failed" >>"$LOG_FILE"; exit 0; }
    "$MEMPALACE_BIN" mine "$cwd" >>"$LOG_FILE" 2>&1 || echo "[$ts] mine failed" >>"$LOG_FILE"
  fi

  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $cwd — done" >>"$LOG_FILE"
) </dev/null >/dev/null 2>&1 &
disown 2>/dev/null || true

# Hook exits immediately (within ~50ms). Background process continues.
exit 0
