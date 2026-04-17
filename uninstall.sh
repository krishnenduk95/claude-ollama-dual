#!/usr/bin/env bash
# claude-dual uninstaller — reverses install.sh on macOS + Linux
#
# Windows users: run `.\service\windows\uninstall-service.ps1` and delete files
# under %USERPROFILE%\.claude-dual\ and %USERPROFILE%\.claude\agents\glm-*.md.

set -e

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; N='\033[0m'
say() { printf "${B}[claude-dual]${N} %s\n" "$*"; }
ok()  { printf "  ${G}✓${N} %s\n" "$*"; }
warn(){ printf "  ${Y}!${N} %s\n" "$*"; }
die() { printf "  ${R}✗${N} %s\n" "$*"; exit 1; }

OS="$(uname -s)"
case "$OS" in
  Darwin)  PLATFORM="macos" ;;
  Linux)   PLATFORM="linux" ;;
  MINGW*|MSYS*|CYGWIN*) die "Windows — run service\\windows\\uninstall-service.ps1 instead" ;;
  *) die "Unsupported OS: $OS" ;;
esac

say "uninstalling claude-dual on $PLATFORM"

# Ask before wiping ~/.claude-dual (it has audit logs + proxy logs)
if [ -d "$HOME/.claude-dual" ]; then
  if [ -t 0 ]; then
    printf "${Y}?${N} Delete ~/.claude-dual/ (contains audit trail and logs)? [y/N] "
    read -r confirm
    [ "$confirm" = "y" ] || [ "$confirm" = "Y" ] || { say "keeping ~/.claude-dual/"; KEEP_DUAL=1; }
  else
    warn "non-interactive shell — keeping ~/.claude-dual/ for safety (delete manually if you want)"
    KEEP_DUAL=1
  fi
fi

# ── Stop and remove the service ────────────────────────────────────
if [ "$PLATFORM" = "macos" ]; then
  PLIST="$HOME/Library/LaunchAgents/com.claude-dual-proxy.plist"
  if [ -f "$PLIST" ]; then
    launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    ok "LaunchAgent removed"
  else
    ok "LaunchAgent already absent"
  fi

elif [ "$PLATFORM" = "linux" ]; then
  UNIT="$HOME/.config/systemd/user/claude-dual-proxy.service"
  if [ -f "$UNIT" ] && command -v systemctl >/dev/null 2>&1; then
    systemctl --user disable --now claude-dual-proxy.service 2>/dev/null || true
    rm -f "$UNIT"
    systemctl --user daemon-reload 2>/dev/null || true
    ok "systemd unit removed"
  else
    ok "systemd unit already absent"
  fi
fi

# ── Remove files ───────────────────────────────────────────────────
[ "${KEEP_DUAL:-}" != "1" ] && [ -d "$HOME/.claude-dual" ] && rm -rf "$HOME/.claude-dual" && ok "removed ~/.claude-dual/"

# Remove launcher
[ -f "$HOME/.local/bin/claude-dual" ] && rm -f "$HOME/.local/bin/claude-dual" && ok "removed ~/.local/bin/claude-dual"

# Remove agent + command files
for f in glm-worker glm-explorer glm-reviewer glm-analyst; do
  [ -f "$HOME/.claude/agents/$f.md" ] && rm -f "$HOME/.claude/agents/$f.md" && ok "removed agent: $f"
done
[ -f "$HOME/.claude/commands/orchestrate.md" ] && rm -f "$HOME/.claude/commands/orchestrate.md" && ok "removed /orchestrate command"

# ── Manual cleanup notice ──────────────────────────────────────────
echo
warn "Manual steps (not automated to avoid breaking your config):"
echo "  1. Remove the 'Dual-Model Orchestration (Opus ↔ GLM)' section from ~/.claude/CLAUDE.md"
echo "  2. Revert 'effortLevel' in ~/.claude/settings.json if you want to restore default"
echo "  3. Clean up any Ollama model: ollama rm glm-5.1:cloud  (optional)"
echo

printf "${G}────────────────────────────────────────────────────────${N}\n"
printf "${G}  claude-dual uninstalled${N}\n"
printf "${G}────────────────────────────────────────────────────────${N}\n"
