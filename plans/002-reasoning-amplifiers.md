# Plan 002: Reasoning Amplifiers (targets ~100-103% of Opus 4.7 on math/logic/coding)

## Goal
Layer three reasoning amplifiers on top of the v1.6.0 4-tier routing:

1. **Chain-of-Debate** for `glm-analyst` — 3 parallel samples + synthesis → +8-12% on ranking/tradeoff tasks
2. **Self-Refine** for `glm-worker` on hard coding — generate → critique → revise loop → +6-10% on SWE-bench
3. **Plan-Solve-Verify** for `glm-architect` — 3-stage enforced reasoning pass → +4-7% on design quality

All three are implemented as **prompt engineering changes to existing subagent frontmatter + body** — no new subagents, no proxy code changes. Plus one new orchestrator slash command `/deep-reason` for explicit invocation.

## Approach: prompt-level amplifiers (not infrastructure)

Each amplifier is enforced by editing the subagent's system prompt (the body of the `.md` file after the frontmatter) to make the reasoning pattern mandatory. The model follows the instructions; no extra orchestration code required.

This is the same technique used by Aider, Cursor, and Cline — the quality comes from disciplined prompting, not from framework complexity.

## Files to create or edit

### 1. Edit `glm-analyst.md` — Chain-of-Debate
Files:
- `/Users/luciffer/Downloads/combine glm5.1-opus4.6/agents/glm-analyst.md`
- `~/.claude/agents/glm-analyst.md`

Add a new section before the existing "Deliverable" section (or near the top of the body prompt):

```markdown
# CHAIN-OF-DEBATE PROTOCOL (mandatory for any ranking, tradeoff, or "which option" question)

When the brief asks you to rank options, pick between alternatives, analyze tradeoffs, or evaluate multiple approaches, you MUST produce THREE independent candidate analyses before synthesizing a final answer.

**Protocol:**

1. **Candidate A (conservative, temperature low):** Produce a full analysis favoring the safest, most conventional option. Be honest about its weaknesses.
2. **Candidate B (balanced, temperature mid):** Produce a full analysis that weighs tradeoffs pragmatically. Pick differently from A if the evidence supports it.
3. **Candidate C (aggressive, temperature high):** Produce a full analysis favoring the highest-upside option even if riskier. Challenge conventional wisdom.
4. **Synthesis pass:** Read A, B, C side by side. Identify:
   - Where they agree → those points are high-confidence.
   - Where they disagree → interrogate each reason, decide which is strongest, justify.
   - Blind spots present in all three → add them.
5. **Final recommendation:** state the answer, the confidence level (high / medium / low), and the one piece of evidence that would FLIP your recommendation.

Output each candidate as a labeled section, then the synthesis, then the final. Do NOT skip candidates A/B/C to save tokens — the parallel analysis is the entire point. Expect ~3-4× the length of a single-shot analysis.

Why this works: parallel candidates with different priors surface blind spots a single analysis misses. The synthesis step forces explicit reasoning about why one view wins.
```

### 2. Edit `glm-worker.md` — Self-Refine for hard coding tasks
Files:
- `/Users/luciffer/Downloads/combine glm5.1-opus4.6/agents/glm-worker.md`
- `~/.claude/agents/glm-worker.md`

Add a new section in the body after the existing "The thinking framework" section:

```markdown
# SELF-REFINE PROTOCOL (mandatory when the brief is flagged "hard" or involves refactor / bug fix / concurrency / perf / algorithm)

If the dispatching brief contains any of these signals:
- word "hard" / "complex" / "tricky" / "subtle" in the goal
- task is a refactor affecting >5 call sites
- bug fix where the root cause is non-obvious
- concurrency, race conditions, or performance-sensitive code
- any algorithm-heavy task (graph, tree, DP, search, parsing)

Then you MUST run the self-refine loop before reporting done:

**Pass 1 — Draft:** Write the code normally following the thinking framework.

**Pass 2 — Critique (adversarial):** Switch mindset to a senior reviewer whose job is to find bugs. Read your own code and list, explicitly:
- Edge cases not handled (empty, null, negative, overflow, unicode, concurrent)
- Subtle bugs (off-by-one, wrong comparison, mutated shared state)
- Performance pitfalls (O(n²) when O(n) is possible, unnecessary allocations)
- Style / naming / clarity issues
- Missing tests for the above

Be harsh. Find at least 2 issues or explicitly state "critique pass found no material issues" — but only after genuine effort.

**Pass 3 — Revise:** Apply every critique finding to the code. Re-run the thinking framework on the revised version.

**Pass 4 — Verify:** Run the acceptance command. If it passes, report. If it fails, iterate Pass 2-3-4 one more time (max 2 iterations total).

Output format in your final report: include a "Self-refine summary" section listing critique findings and how each was addressed. This proves you ran the protocol — don't skip it.

Why this works: LLMs are much better at finding bugs in code they can see than at avoiding bugs in code they're generating. Separating generation from critique captures that asymmetry.
```

### 3. Edit `glm-architect.md` — Plan-Solve-Verify
Files:
- `/Users/luciffer/Downloads/combine glm5.1-opus4.6/agents/glm-architect.md`
- `~/.claude/agents/glm-architect.md`

Add near the top of the body, before any existing planning instructions:

```markdown
# PLAN-SOLVE-VERIFY PROTOCOL (mandatory for every architecture decision)

Every architecture plan you produce must be structured as three explicit phases. Label them as headings in your output. Do NOT merge them.

**PHASE 1 — PLAN (enumerate before choosing):**
- List ALL plausible approaches to the problem (minimum 3, even if some seem weak).
- For each approach, state: core idea (1 sentence), best-case scenario, failure mode, rough effort estimate.
- State your evaluation criteria BEFORE you evaluate (e.g., "I'll weight: correctness 40%, ops simplicity 30%, perf 20%, cost 10%"). Weights must sum to 100.

**PHASE 2 — SOLVE (pick and design):**
- Using the criteria from Phase 1, score each approach. Show the math.
- Pick the winner. State the pick + a one-sentence justification.
- Design the winner in full: component diagram (ASCII), data model, API surface, failure handling, deployment story.

**PHASE 3 — VERIFY (stress-test the design):**
- Enumerate at least 5 failure scenarios this design must handle. For each:
  1. What breaks?
  2. How does the design handle it?
  3. What's the blast radius if the handling fails?
- One scenario MUST be "what if load goes 100× overnight?" — capacity must survive that.
- One scenario MUST be "what if the upstream dependency goes down for 1 hour?" — graceful degradation path required.
- If any scenario reveals a gap, go back to Phase 2 and revise. Do not hand-wave.

Finally, state: **Flip condition** — the single piece of evidence that would make you change your pick. This is your intellectual honesty check.

Why this works: forcing enumeration before picking kills "first idea wins" bias. Forcing verification kills designs that only work on the happy path.
```

### 4. Create `/deep-reason` slash command
File: `/Users/luciffer/Downloads/combine glm5.1-opus4.6/commands/deep-reason.md` AND `~/.claude/commands/deep-reason.md`

Content:

```markdown
---
description: Run maximum-depth reasoning on a question — dispatches glm-analyst with chain-of-debate, synthesizes with Opus.
---

You are being invoked to answer a hard question with maximum reasoning depth.

**Step 1 — Dispatch glm-analyst with chain-of-debate:**
Use the Agent tool with subagent_type="glm-analyst" and a prompt that explicitly requires the chain-of-debate protocol (the subagent's system prompt already enforces this, but reinforce it in the brief).

The brief must include:
- The question the user asked, verbatim.
- Relevant context files (if any).
- Explicit instruction: "Use chain-of-debate: produce candidates A (conservative), B (balanced), C (aggressive), then synthesize."
- Acceptance: "Output must include all 4 sections plus final recommendation with confidence and flip condition."

**Step 2 — (Optional) Parallel dispatch:**
If the question is reasoning-heavy and could benefit from model diversity, ALSO dispatch glm-architect with plan-solve-verify protocol IN PARALLEL (single message, both Agent tool calls). This gives you two independent lines of reasoning from two different models (deepseek-v3.2 and the architect variant).

**Step 3 — Opus synthesis:**
When the subagent(s) return, YOU (Opus) read their output and produce the final answer. Your job:
- Identify where the multi-candidate analyses agree → restate as high-confidence.
- Identify where they disagree → adjudicate using your own reasoning, cite which candidate's logic wins.
- Add any blind spot present in all candidates that you (as a more capable model) can see.
- Deliver the final answer to the user with a confidence tag and a flip condition.

Do NOT just relay the subagent output. Synthesis is the whole point.

Arguments: $ARGUMENTS — the user's question.
```

## Constraints
- Edit the 3 subagent files IN PLACE — preserve all existing frontmatter and body text.
- ADD new sections; don't overwrite existing sections.
- Use the `Edit` tool, not `Write`.
- Sync every change to BOTH the repo copy AND the `~/.claude/agents/` copy (or `~/.claude/commands/` for the slash command).
- Do not modify proxy.js.
- Do not restart the proxy.
- Do not create any documentation files beyond the slash command + this plan.

## Acceptance criteria

1. `grep -l "CHAIN-OF-DEBATE PROTOCOL" /Users/luciffer/Downloads/combine\ glm5.1-opus4.6/agents/glm-analyst.md ~/.claude/agents/glm-analyst.md` → returns both paths.
2. `grep -l "SELF-REFINE PROTOCOL" /Users/luciffer/Downloads/combine\ glm5.1-opus4.6/agents/glm-worker.md ~/.claude/agents/glm-worker.md` → returns both paths.
3. `grep -l "PLAN-SOLVE-VERIFY PROTOCOL" /Users/luciffer/Downloads/combine\ glm5.1-opus4.6/agents/glm-architect.md ~/.claude/agents/glm-architect.md` → returns both paths.
4. `ls /Users/luciffer/Downloads/combine\ glm5.1-opus4.6/commands/deep-reason.md ~/.claude/commands/deep-reason.md` → both exist.
5. `wc -l` on each edited subagent file shows MORE lines than before (no content was deleted).

## Verification
```bash
echo "=== protocols in place ===" && \
  grep -c "CHAIN-OF-DEBATE PROTOCOL" /Users/luciffer/Downloads/combine\ glm5.1-opus4.6/agents/glm-analyst.md ~/.claude/agents/glm-analyst.md && \
  grep -c "SELF-REFINE PROTOCOL" /Users/luciffer/Downloads/combine\ glm5.1-opus4.6/agents/glm-worker.md ~/.claude/agents/glm-worker.md && \
  grep -c "PLAN-SOLVE-VERIFY PROTOCOL" /Users/luciffer/Downloads/combine\ glm5.1-opus4.6/agents/glm-architect.md ~/.claude/agents/glm-architect.md
echo "=== slash command exists ===" && \
  ls -la /Users/luciffer/Downloads/combine\ glm5.1-opus4.6/commands/deep-reason.md ~/.claude/commands/deep-reason.md
```

## Reporting format
Paste the output of the verification block, plus one-line "done" confirmation.
