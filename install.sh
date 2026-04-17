#!/usr/bin/env bash
# claude-dual installer (macOS)
# Wires up: proxy, launcher, LaunchAgent, 4 GLM subagents, /orchestrate slash command,
# and the global CLAUDE.md delegation rule. Safe to re-run.

set -e

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; N='\033[0m'
say() { printf "${B}[claude-dual]${N} %s\n" "$*"; }
ok()  { printf "  ${G}✓${N} %s\n" "$*"; }
warn(){ printf "  ${Y}!${N} %s\n" "$*"; }
die() { printf "  ${R}✗${N} %s\n" "$*"; exit 1; }

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── OS ─────────────────────────────────────────────────────────────
[ "$(uname)" = "Darwin" ] || die "macOS-only installer (LaunchAgent used for persistence). Linux users: adapt the LaunchAgent step to systemd."

# ── Prerequisites ──────────────────────────────────────────────────
say "checking prerequisites"

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
  || warn "Ollama daemon not running — start it with: ollama serve  (or open the Ollama app)"

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

mkdir -p "$HOME/.claude-dual" "$HOME/.claude/agents" "$HOME/.claude/commands" "$HOME/.local/bin" "$HOME/Library/LaunchAgents"

cp "$REPO_DIR/proxy/proxy.js"        "$HOME/.claude-dual/proxy.js";       ok "proxy → ~/.claude-dual/proxy.js"
cp "$REPO_DIR/agents/glm-worker.md"   "$HOME/.claude/agents/";            ok "agent → ~/.claude/agents/glm-worker.md"
cp "$REPO_DIR/agents/glm-explorer.md" "$HOME/.claude/agents/";            ok "agent → ~/.claude/agents/glm-explorer.md"
cp "$REPO_DIR/agents/glm-reviewer.md" "$HOME/.claude/agents/";            ok "agent → ~/.claude/agents/glm-reviewer.md"
cp "$REPO_DIR/agents/glm-analyst.md"  "$HOME/.claude/agents/";            ok "agent → ~/.claude/agents/glm-analyst.md"
cp "$REPO_DIR/commands/orchestrate.md" "$HOME/.claude/commands/";         ok "slash → ~/.claude/commands/orchestrate.md"
cp "$REPO_DIR/bin/claude-dual"         "$HOME/.local/bin/claude-dual"
chmod +x "$HOME/.local/bin/claude-dual";                                  ok "launcher → ~/.local/bin/claude-dual"

# ── LaunchAgent (persistent proxy) ────────────────────────────────
say "installing LaunchAgent"
PLIST="$HOME/Library/LaunchAgents/com.claude-dual-proxy.plist"
sed "s|__HOME__|$HOME|g" "$REPO_DIR/launchagent/com.claude-dual-proxy.plist.template" > "$PLIST"
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load -w "$PLIST"
ok "LaunchAgent loaded: com.claude-dual-proxy"

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
    jq '. + {"effortLevel":"xhigh","alwaysThinkingEnabled":true}' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
    ok "effortLevel set to xhigh (jq)"
  else
    warn "jq not installed — add \"effortLevel\":\"xhigh\" manually to $SETTINGS"
  fi
else
  printf '{\n  "alwaysThinkingEnabled": true,\n  "effortLevel":"xhigh"\n}\n' > "$SETTINGS"
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
if lsof -iTCP:3456 -sTCP:LISTEN >/dev/null 2>&1; then
  ok "proxy listening on :3456"
else
  warn "proxy NOT listening — check: tail ~/.claude-dual/proxy.err.log"
fi

# ── Done ───────────────────────────────────────────────────────────
echo
printf "${G}────────────────────────────────────────────────────────${N}\n"
printf "${G}  claude-dual installed${N}\n"
printf "${G}────────────────────────────────────────────────────────${N}\n"
echo
echo "  Run:     claude-dual"
echo "  Test:    claude-dual -p 'Reply: OK' --model claude-opus-4-7"
echo "  Watch:   tail -f ~/.claude-dual/proxy.log"
echo "  Uninstall: see README.md"
echo
