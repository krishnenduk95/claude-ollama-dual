#!/usr/bin/env bash
# claude-dual installer — macOS + Linux
# Wires up: proxy (with npm deps), launcher, persistent service (LaunchAgent / systemd),
# 4 GLM subagents, /orchestrate slash command, global CLAUDE.md delegation rule,
# and sets effortLevel: xhigh in ~/.claude/settings.json. Safe to re-run.
#
# Windows users: run `install.ps1` in PowerShell instead.

set -e

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; N='\033[0m'
say() { printf "${B}[claude-dual]${N} %s\n" "$*"; }
ok()  { printf "  ${G}✓${N} %s\n" "$*"; }
warn(){ printf "  ${Y}!${N} %s\n" "$*"; }
die() { printf "  ${R}✗${N} %s\n" "$*"; exit 1; }

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Platform detection ─────────────────────────────────────────────
OS="$(uname -s)"
case "$OS" in
  Darwin)  PLATFORM="macos" ;;
  Linux)   PLATFORM="linux" ;;
  MINGW*|MSYS*|CYGWIN*)
    die "Windows detected. Please run install.ps1 in PowerShell: .\\install.ps1" ;;
  *)
    die "Unsupported OS: $OS" ;;
esac
say "installing claude-dual on $PLATFORM"

# ── Prerequisites ──────────────────────────────────────────────────
command -v node >/dev/null 2>&1 || die "Node.js not found. Install from https://nodejs.org (v18+)"
NODE_MAJOR=$(node -v | sed 's/v//' | cut -d. -f1)
[ "$NODE_MAJOR" -ge 18 ] || die "Node.js 18+ required (have $NODE_MAJOR). Upgrade via nvm or nodejs.org."
ok "Node.js $(node -v)"

command -v ollama >/dev/null 2>&1 || die "Ollama not found. Install from https://ollama.com"
ok "Ollama $(ollama -v 2>&1 | head -1 | awk '{print $NF}')"

command -v claude >/dev/null 2>&1 || die "Claude Code CLI not found. Install: https://docs.claude.com/en/docs/claude-code"
ok "Claude Code $(claude --version 2>&1 | head -1)"

curl -sf http://localhost:11434/api/tags >/dev/null 2>&1 \
  && ok "Ollama daemon reachable on :11434" \
  || warn "Ollama daemon not running — start it with: ollama serve"

# ── GLM model ──────────────────────────────────────────────────────
say "checking glm-5.1:cloud model"
if ollama list 2>/dev/null | grep -q 'glm-5.1:cloud'; then
  ok "glm-5.1:cloud already pulled"
else
  warn "glm-5.1:cloud not found — pulling now (requires Ollama Cloud signin)"
  ollama pull glm-5.1:cloud || die "Failed to pull glm-5.1:cloud. Sign in with: ollama signin"
  ok "pulled glm-5.1:cloud"
fi

# ── Install files ──────────────────────────────────────────────────
say "installing files"

mkdir -p "$HOME/.claude-dual" "$HOME/.claude/agents" "$HOME/.claude/commands" "$HOME/.local/bin"

cp "$REPO_DIR/proxy/proxy.js"         "$HOME/.claude-dual/proxy.js";      ok "proxy → ~/.claude-dual/proxy.js"
cp "$REPO_DIR/proxy/package.json"     "$HOME/.claude-dual/package.json";  ok "package.json → ~/.claude-dual/package.json"
cp "$REPO_DIR/hooks/delegation-enforcer.sh" "$HOME/.claude-dual/delegation-enforcer.sh"
chmod +x "$HOME/.claude-dual/delegation-enforcer.sh";                     ok "delegation enforcer → ~/.claude-dual/delegation-enforcer.sh"

# Install npm deps for structured logging + metrics (optional but recommended)
if command -v npm >/dev/null 2>&1; then
  say "installing proxy dependencies (pino, prom-client)"
  (cd "$HOME/.claude-dual" && npm install --omit=dev --no-audit --no-fund --silent 2>/dev/null) \
    && ok "deps installed" \
    || warn "npm install failed — proxy will fall back to basic logging (still functional)"
else
  warn "npm not found — proxy will fall back to basic logging (still functional)"
fi

cp "$REPO_DIR/agents/glm-worker.md"   "$HOME/.claude/agents/";            ok "agent → ~/.claude/agents/glm-worker.md"
cp "$REPO_DIR/agents/glm-explorer.md" "$HOME/.claude/agents/";            ok "agent → ~/.claude/agents/glm-explorer.md"
cp "$REPO_DIR/agents/glm-reviewer.md" "$HOME/.claude/agents/";            ok "agent → ~/.claude/agents/glm-reviewer.md"
cp "$REPO_DIR/agents/glm-analyst.md"  "$HOME/.claude/agents/";            ok "agent → ~/.claude/agents/glm-analyst.md"
cp "$REPO_DIR/commands/orchestrate.md" "$HOME/.claude/commands/";         ok "slash → ~/.claude/commands/orchestrate.md"
cp "$REPO_DIR/bin/claude-dual"         "$HOME/.local/bin/claude-dual"
chmod +x "$HOME/.local/bin/claude-dual";                                  ok "launcher → ~/.local/bin/claude-dual"

# ── Persistent service (platform-specific) ─────────────────────────
if [ "$PLATFORM" = "macos" ]; then
  say "installing LaunchAgent (macOS)"
  mkdir -p "$HOME/Library/LaunchAgents"
  PLIST="$HOME/Library/LaunchAgents/com.claude-dual-proxy.plist"
  sed "s|__HOME__|$HOME|g" "$REPO_DIR/launchagent/com.claude-dual-proxy.plist.template" > "$PLIST"
  launchctl unload "$PLIST" 2>/dev/null || true
  launchctl load -w "$PLIST"
  ok "LaunchAgent loaded: com.claude-dual-proxy"

elif [ "$PLATFORM" = "linux" ]; then
  say "installing systemd user unit (Linux)"
  if ! command -v systemctl >/dev/null 2>&1; then
    warn "systemctl not found. Skipping service install — run proxy manually with: node ~/.claude-dual/proxy.js"
  else
    mkdir -p "$HOME/.config/systemd/user"
    cp "$REPO_DIR/service/linux/claude-dual-proxy.service" "$HOME/.config/systemd/user/"
    systemctl --user daemon-reload
    systemctl --user enable --now claude-dual-proxy.service
    ok "systemd unit loaded: claude-dual-proxy.service"
    # Enable lingering so the service runs at boot even without login (optional)
    if command -v loginctl >/dev/null 2>&1; then
      loginctl enable-linger "$USER" 2>/dev/null || warn "couldn't enable linger (service stops on logout — sudo loginctl enable-linger $USER to fix)"
    fi
  fi
fi

# ── Append delegation rule to global CLAUDE.md ─────────────────────
say "wiring global delegation rule"
CLAUDE_MD="$HOME/.claude/CLAUDE.md"
touch "$CLAUDE_MD"
if grep -q "Dual-Model Orchestration (Opus ↔ GLM)" "$CLAUDE_MD" 2>/dev/null; then
  ok "delegation rule already present in ~/.claude/CLAUDE.md"
else
  cat "$REPO_DIR/claude-md/dual-model-orchestration.md" >> "$CLAUDE_MD"
  ok "delegation rule appended to ~/.claude/CLAUDE.md"
fi

# ── settings.json: effortLevel xhigh (Opus 4.7's new top-effort tier) ─
SETTINGS="$HOME/.claude/settings.json"
say "setting effortLevel: xhigh in ~/.claude/settings.json"
if [ -s "$SETTINGS" ]; then
  if grep -q '"effortLevel": *"xhigh"' "$SETTINGS"; then
    ok "effortLevel already xhigh"
  elif command -v jq >/dev/null 2>&1; then
    tmp="$(mktemp)"
    jq '. + {"effortLevel":"xhigh","alwaysThinkingEnabled":false,"model":"claude-opus-4-7"} | .hooks.PreToolUse = ((.hooks.PreToolUse // []) + [{"matcher":"Read|Edit|Write|Grep|Glob","hooks":[{"type":"command","command":"~/.claude-dual/delegation-enforcer.sh","timeout":5000}]}] | unique_by(.matcher))' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
    ok "effortLevel set to xhigh (jq)"
  else
    warn "jq not installed — add \"effortLevel\":\"xhigh\" manually to $SETTINGS"
  fi
else
  cat > "$SETTINGS" <<'EOF'
{
  "alwaysThinkingEnabled": false,
  "effortLevel": "xhigh",
  "model": "claude-opus-4-7",
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Read|Edit|Write|Grep|Glob",
        "hooks": [
          { "type": "command", "command": "~/.claude-dual/delegation-enforcer.sh", "timeout": 5000 }
        ]
      }
    ]
  }
}
EOF
  ok "created settings.json with effortLevel: xhigh"
fi

# ── PATH check ─────────────────────────────────────────────────────
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ok "~/.local/bin already on PATH" ;;
  *) warn "~/.local/bin is NOT on PATH. Add to your shell rc: export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

# ── Verify ─────────────────────────────────────────────────────────
say "verifying"
sleep 2
PORT_CHECK=""
if command -v lsof >/dev/null 2>&1; then
  lsof -iTCP:3456 -sTCP:LISTEN >/dev/null 2>&1 && PORT_CHECK="ok"
elif command -v ss >/dev/null 2>&1; then
  ss -ltn 2>/dev/null | grep -q ':3456' && PORT_CHECK="ok"
elif command -v netstat >/dev/null 2>&1; then
  netstat -tln 2>/dev/null | grep -q ':3456' && PORT_CHECK="ok"
fi
[ "$PORT_CHECK" = "ok" ] && ok "proxy listening on :3456" || warn "proxy NOT listening — check ~/.claude-dual/proxy.err.log"

# ── Health check ──────────────────────────────────────────────────
if command -v curl >/dev/null 2>&1; then
  health=$(curl -sf http://127.0.0.1:3456/health 2>/dev/null || echo "")
  [ -n "$health" ] && ok "health endpoint: $health" || warn "health endpoint not responding yet"
fi

# ── Done ───────────────────────────────────────────────────────────
echo
printf "${G}────────────────────────────────────────────────────────${N}\n"
printf "${G}  claude-dual installed (${PLATFORM})${N}\n"
printf "${G}────────────────────────────────────────────────────────${N}\n"
echo
echo "  Run:        claude-dual"
echo "  Test:       claude-dual -p 'Reply: OK' --model claude-opus-4-7"
echo "  Watch log:  tail -f ~/.claude-dual/proxy.log"
echo "  Health:     curl http://127.0.0.1:3456/health"
echo "  Metrics:    curl http://127.0.0.1:3456/metrics"
echo "  Cost:       curl http://127.0.0.1:3456/cost"
echo "  Uninstall:  ./uninstall.sh"
echo
