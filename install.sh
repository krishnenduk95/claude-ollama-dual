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

# Hard requirement: python3 is used by every hook. Without it they silently
# no-op and the stack degrades to v1.0 behavior (no learnings, no quota, no
# drift detection, no routing stats). Fail loudly rather than half-install.
command -v python3 >/dev/null 2>&1 || die "python3 not found. All hooks (learnings, quota, drift, routing stats) require python3. Install via: brew install python3 (macOS) or apt install python3 (Linux)"
PY_MAJOR=$(python3 -c 'import sys;print(sys.version_info.major)')
PY_MINOR=$(python3 -c 'import sys;print(sys.version_info.minor)')
if [ "$PY_MAJOR" -lt 3 ] || { [ "$PY_MAJOR" -eq 3 ] && [ "$PY_MINOR" -lt 7 ]; }; then
  die "python3 too old: $(python3 --version). Need 3.7+. Upgrade via: brew upgrade python3 / apt install python3.11"
fi
ok "python3 $(python3 --version 2>&1 | awk '{print $NF}')"

# jq is optional but strongly recommended — without it we can't merge into
# existing settings.json. Warn clearly so users know what they're missing.
if command -v jq >/dev/null 2>&1; then
  ok "jq $(jq --version 2>&1)"
else
  warn "jq not found — if you already have a ~/.claude/settings.json, hook wiring will be skipped and you'll need to add hooks manually. Install: brew install jq (macOS) or apt install jq (Linux)"
fi

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
cp "$REPO_DIR/hooks/deep-reason-detector.sh" "$HOME/.claude-dual/deep-reason-detector.sh"
chmod +x "$HOME/.claude-dual/deep-reason-detector.sh";                    ok "deep-reason detector → ~/.claude-dual/deep-reason-detector.sh"
cp "$REPO_DIR/hooks/best-of-n-detector.sh" "$HOME/.claude-dual/best-of-n-detector.sh"
chmod +x "$HOME/.claude-dual/best-of-n-detector.sh";                      ok "best-of-n detector → ~/.claude-dual/best-of-n-detector.sh"
cp "$REPO_DIR/hooks/compute-routing-stats.sh" "$HOME/.claude-dual/compute-routing-stats.sh"
chmod +x "$HOME/.claude-dual/compute-routing-stats.sh";                   ok "routing stats compute → ~/.claude-dual/compute-routing-stats.sh"
cp "$REPO_DIR/hooks/inject-routing-stats.sh" "$HOME/.claude-dual/inject-routing-stats.sh"
chmod +x "$HOME/.claude-dual/inject-routing-stats.sh";                    ok "routing stats injector → ~/.claude-dual/inject-routing-stats.sh"
cp "$REPO_DIR/hooks/write-learning.sh"  "$HOME/.claude-dual/write-learning.sh"
chmod +x "$HOME/.claude-dual/write-learning.sh";                          ok "learnings writer → ~/.claude-dual/write-learning.sh"
cp "$REPO_DIR/hooks/fetch-learnings.sh" "$HOME/.claude-dual/fetch-learnings.sh"
chmod +x "$HOME/.claude-dual/fetch-learnings.sh";                         ok "learnings fetcher → ~/.claude-dual/fetch-learnings.sh"
cp "$REPO_DIR/hooks/verify-learnings.sh" "$HOME/.claude-dual/verify-learnings.sh"
chmod +x "$HOME/.claude-dual/verify-learnings.sh";                        ok "learnings verifier → ~/.claude-dual/verify-learnings.sh"
cp "$REPO_DIR/hooks/compute-quota.sh" "$HOME/.claude-dual/compute-quota.sh"
chmod +x "$HOME/.claude-dual/compute-quota.sh";                           ok "quota compute → ~/.claude-dual/compute-quota.sh"
cp "$REPO_DIR/hooks/plan-drift.sh" "$HOME/.claude-dual/plan-drift.sh"
chmod +x "$HOME/.claude-dual/plan-drift.sh";                              ok "plan-drift detector → ~/.claude-dual/plan-drift.sh"

# Seed quota-limits.json on first install (user can tune)
if [ ! -f "$HOME/.claude-dual/quota-limits.json" ]; then
  cp "$REPO_DIR/quota-limits.defaults.json" "$HOME/.claude-dual/quota-limits.json"
  ok "quota limits seeded → ~/.claude-dual/quota-limits.json (tune per your plan)"
else
  ok "quota limits already present → ~/.claude-dual/quota-limits.json"
fi

# ── Learnings fabric: create memory dir + seed if empty ───────────
mkdir -p "$HOME/.claude-dual/memory"
LEARN_FILE="$HOME/.claude-dual/memory/learnings.jsonl"
if [ ! -f "$LEARN_FILE" ] || [ ! -s "$LEARN_FILE" ]; then
  "$HOME/.claude-dual/write-learning.sh" "bootstrap" "init" "success" "learnings fabric initialized on install" "" "init,bootstrap" >/dev/null 2>&1 || true
  ok "learnings fabric seeded → ~/.claude-dual/memory/learnings.jsonl"
else
  ok "learnings fabric already present → ~/.claude-dual/memory/learnings.jsonl"
fi

# ── Knowledge packs (SaaS subagents consult these) ─────────────────
if [ -d "$REPO_DIR/knowledge" ]; then
  mkdir -p "$HOME/.claude-dual/knowledge"
  cp -R "$REPO_DIR/knowledge/." "$HOME/.claude-dual/knowledge/"
  ok "knowledge packs → ~/.claude-dual/knowledge/"
fi

# Install npm deps for structured logging + metrics (optional but recommended)
if command -v npm >/dev/null 2>&1; then
  say "installing proxy dependencies (pino, prom-client)"
  (cd "$HOME/.claude-dual" && npm install --omit=dev --no-audit --no-fund --silent 2>/dev/null) \
    && ok "deps installed" \
    || warn "npm install failed — proxy will fall back to basic logging (still functional)"
else
  warn "npm not found — proxy will fall back to basic logging (still functional)"
fi

cp "$REPO_DIR/agents/glm-worker.md"           "$HOME/.claude/agents/";    ok "agent → ~/.claude/agents/glm-worker.md"
cp "$REPO_DIR/agents/glm-explorer.md"         "$HOME/.claude/agents/";    ok "agent → ~/.claude/agents/glm-explorer.md"
cp "$REPO_DIR/agents/glm-reviewer.md"         "$HOME/.claude/agents/";    ok "agent → ~/.claude/agents/glm-reviewer.md"
cp "$REPO_DIR/agents/glm-analyst.md"          "$HOME/.claude/agents/";    ok "agent → ~/.claude/agents/glm-analyst.md"
cp "$REPO_DIR/agents/glm-architect.md"        "$HOME/.claude/agents/";    ok "agent → ~/.claude/agents/glm-architect.md"
cp "$REPO_DIR/agents/glm-api-designer.md"     "$HOME/.claude/agents/";    ok "agent → ~/.claude/agents/glm-api-designer.md"
cp "$REPO_DIR/agents/glm-ui-builder.md"       "$HOME/.claude/agents/";    ok "agent → ~/.claude/agents/glm-ui-builder.md"
cp "$REPO_DIR/agents/glm-test-generator.md"   "$HOME/.claude/agents/";    ok "agent → ~/.claude/agents/glm-test-generator.md"
cp "$REPO_DIR/agents/glm-security-auditor.md" "$HOME/.claude/agents/";    ok "agent → ~/.claude/agents/glm-security-auditor.md"
cp "$REPO_DIR/commands/orchestrate.md"  "$HOME/.claude/commands/";        ok "slash → ~/.claude/commands/orchestrate.md"
cp "$REPO_DIR/commands/saas-build.md"   "$HOME/.claude/commands/";        ok "slash → ~/.claude/commands/saas-build.md"
cp "$REPO_DIR/commands/deep-reason.md"  "$HOME/.claude/commands/";        ok "slash → ~/.claude/commands/deep-reason.md"
cp "$REPO_DIR/commands/best-of-n.md"    "$HOME/.claude/commands/";        ok "slash → ~/.claude/commands/best-of-n.md"
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
    jq '
      . + {"effortLevel":"xhigh","alwaysThinkingEnabled":false,"model":"claude-opus-4-7"}
      | .hooks.PreToolUse = (
          (.hooks.PreToolUse // [])
          + [{"matcher":"Read|Edit|Write|Grep|Glob","hooks":[{"type":"command","command":"~/.claude-dual/delegation-enforcer.sh","timeout":5000}]}]
          | unique_by(.matcher)
        )
      | .hooks.UserPromptSubmit = (
          (.hooks.UserPromptSubmit // [])
          + [{"matcher":"","hooks":[
                {"type":"command","command":"~/.claude-dual/deep-reason-detector.sh","timeout":3000},
                {"type":"command","command":"~/.claude-dual/best-of-n-detector.sh","timeout":3000},
                {"type":"command","command":"~/.claude-dual/fetch-learnings.sh","timeout":3000}
              ]}]
          | unique_by(.matcher)
        )
      | .hooks.SessionStart = (
          (.hooks.SessionStart // [])
          + [{"matcher":"","hooks":[
                {"type":"command","command":"~/.claude-dual/inject-routing-stats.sh","timeout":5000}
              ]}]
          | unique_by(.matcher)
        )
      | .hooks.PostToolUse = (
          (.hooks.PostToolUse // [])
          + [{"matcher":"Bash","hooks":[
                {"type":"command","command":"~/.claude-dual/verify-learnings.sh","timeout":5000}
              ]}]
          | unique_by(.matcher)
        )
      | .hooks.SubagentStop = (
          (.hooks.SubagentStop // [])
          + [{"matcher":"","hooks":[
                {"type":"command","command":"~/.claude-dual/plan-drift.sh","timeout":5000}
              ]}]
          | unique_by(.matcher)
        )
    ' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
    ok "effortLevel set to xhigh (jq)"
  else
    warn "jq not installed — can't merge into existing $SETTINGS"
    warn "  Manually add: \"effortLevel\":\"xhigh\", \"model\":\"claude-opus-4-7\""
    warn "  Manually wire hooks: PreToolUse (delegation-enforcer), UserPromptSubmit (deep-reason + best-of-n + fetch-learnings), SessionStart (inject-routing-stats), PostToolUse/Bash (verify-learnings), SubagentStop (plan-drift)"
    warn "  Or: backup settings.json, rm it, re-run installer to get the bootstrap template"
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
    ],
    "UserPromptSubmit": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "~/.claude-dual/deep-reason-detector.sh", "timeout": 3000 },
          { "type": "command", "command": "~/.claude-dual/best-of-n-detector.sh", "timeout": 3000 },
          { "type": "command", "command": "~/.claude-dual/fetch-learnings.sh", "timeout": 3000 }
        ]
      }
    ],
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "~/.claude-dual/inject-routing-stats.sh", "timeout": 5000 }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "~/.claude-dual/verify-learnings.sh", "timeout": 5000 }
        ]
      }
    ],
    "SubagentStop": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "~/.claude-dual/plan-drift.sh", "timeout": 5000 }
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
