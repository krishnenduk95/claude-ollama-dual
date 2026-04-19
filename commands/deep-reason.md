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
