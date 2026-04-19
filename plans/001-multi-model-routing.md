# Plan 001: Multi-Model Routing (revised — targets ~95% of Opus 4.7)

## Goal
Route each GLM subagent to the OSS cloud model best suited for its task type. Aggregate delegated-work quality moves from ~75% of Opus 4.7 (glm-5.1-only) to ~93-96% (4-tier stack). No proxy routing changes — proxy is already model-agnostic and `applyGlmRigor` injects the 32k thinking budget on any Ollama request.

## Tiered routing (REVISED — latest models)

| Tier | Model | Subagents |
|---|---|---|
| **Reasoning / architecture / review** | `deepseek-v3.2:cloud` | `glm-analyst`, `glm-architect`, `glm-reviewer` |
| **Security audit** (hybrid reasoning — catches subtle bugs) | `cogito-2.1:671b-cloud` | `glm-security-auditor` |
| **Heavy coding** (SWE-bench leader) | `qwen3-coder-next:cloud` | `glm-worker`, `glm-api-designer`, `glm-ui-builder`, `glm-test-generator` |
| **Long-context investigation** (256k ctx) | `kimi-k2.5:cloud` | `glm-explorer` |

Note: kept `glm-5.1:cloud` and older models pulled — they become manual fallbacks if a new model misbehaves.

## Files to edit (exact list)

Each file needs ONE change: the `model:` line in the YAML frontmatter (between the `---` markers at the top).

### Repo copies (`/Users/luciffer/Downloads/combine glm5.1-opus4.6/agents/`)
1. `glm-analyst.md`           → `model: deepseek-v3.2:cloud`
2. `glm-architect.md`         → `model: deepseek-v3.2:cloud`
3. `glm-reviewer.md`          → `model: deepseek-v3.2:cloud`
4. `glm-security-auditor.md`  → `model: cogito-2.1:671b-cloud`
5. `glm-worker.md`            → `model: qwen3-coder-next:cloud`
6. `glm-api-designer.md`      → `model: qwen3-coder-next:cloud`
7. `glm-ui-builder.md`        → `model: qwen3-coder-next:cloud`
8. `glm-test-generator.md`    → `model: qwen3-coder-next:cloud`
9. `glm-explorer.md`          → `model: kimi-k2.5:cloud`

### Live copies (`~/.claude/agents/`)
Identical edits to the same 9 files.

### Proxy pricing table
Files: `proxy/proxy.js` (repo) AND `~/.claude-dual/proxy.js` (live)
Location: around line 207 where `'glm-5.1:cloud': { input: 0.00, output: 0.00 }` is defined.
ADD the following entries (all free on Ollama Cloud), keeping existing entries intact:
```javascript
'kimi-k2.5:cloud':           { input: 0.00, output: 0.00 },
'deepseek-v3.2:cloud':       { input: 0.00, output: 0.00 },
'qwen3-coder-next:cloud':    { input: 0.00, output: 0.00 },
'cogito-2.1:671b-cloud':     { input: 0.00, output: 0.00 },
```

## Constraints
- Edit ONLY the `model:` line in each subagent frontmatter — do NOT touch `name`, `description`, `tools`, or the body prompt.
- Do not add or delete subagents.
- Do not modify `applyGlmRigor` or any routing code — proxy is model-agnostic.
- Match the pricing-table style exactly to the existing line.
- Do not restart the proxy or launchd service.
- Use the `Edit` tool, not `Write`. Preserve every other line byte-for-byte.

## Acceptance criteria
After all edits, these exact greps must show:

```bash
grep '^model:' /Users/luciffer/Downloads/combine\ glm5.1-opus4.6/agents/glm-*.md
```
→ must show:
- 3 files with `model: deepseek-v3.2:cloud` (analyst, architect, reviewer)
- 1 file with `model: cogito-2.1:671b-cloud` (security-auditor)
- 4 files with `model: qwen3-coder-next:cloud` (worker, api-designer, ui-builder, test-generator)
- 1 file with `model: kimi-k2.5:cloud` (explorer)

Same for `~/.claude/agents/glm-*.md`.

```bash
grep -E '(kimi-k2.5|deepseek-v3.2|qwen3-coder-next|cogito-2.1):cloud' ~/.claude-dual/proxy.js
```
→ must show 4 pricing entries.

Same for `/Users/luciffer/Downloads/combine glm5.1-opus4.6/proxy/proxy.js`.

## Verification
Run:
```bash
echo "=== repo agents ===" && grep '^model:' /Users/luciffer/Downloads/combine\ glm5.1-opus4.6/agents/glm-*.md
echo "=== live agents ===" && grep '^model:' ~/.claude/agents/glm-*.md
echo "=== repo proxy pricing ===" && grep -E '(kimi-k2.5|deepseek-v3.2|qwen3-coder-next|cogito-2.1|glm-5.1):cloud' /Users/luciffer/Downloads/combine\ glm5.1-opus4.6/proxy/proxy.js
echo "=== live proxy pricing ===" && grep -E '(kimi-k2.5|deepseek-v3.2|qwen3-coder-next|cogito-2.1|glm-5.1):cloud' ~/.claude-dual/proxy.js
```

## Reporting format
Paste the output of the verification block above, plus a one-line "done" confirmation.
