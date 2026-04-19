---
description: Verifier-gated best-of-N — dispatch glm-worker 3× with varied approaches, score with glm-reviewer, pick winner. Use on hard tasks where correctness dominates cost.
argument-hint: <task brief — file paths, acceptance criteria, constraints>
---

# Best-of-N (verifier-gated)

You are Opus 4.7. The user wants the highest-quality output on this task, not the fastest. Run the verifier-gated best-of-N protocol.

## The brief
$ARGUMENTS

## Protocol (execute in order)

### 1. Write the shared brief
Draft ONE precise brief — goal, exact file list, context files, acceptance criteria, constraints, verification command — in plans/best-of-n-<slug>.md. All three workers read the same plan so differences come from approach, not spec interpretation.

### 2. Dispatch 3 workers in parallel (single message, 3 Agent tool calls)
Send three `glm-worker` dispatches in ONE message with three Agent tool-use blocks. Each gets the same plan file but a different approach hint appended to the prompt:

- **Candidate A (conservative):** "Favor the most conventional, boring solution. Prefer stdlib over dependencies. Prefer simple over clever. If the canonical pattern for this problem exists in the codebase, use it."
- **Candidate B (pragmatic):** "Balance tradeoffs. Pick the solution a senior engineer would ship today — not theoretically perfect, but robust and clear. Use a third-party lib if it's genuinely better than rolling your own."
- **Candidate C (principled):** "Optimize for long-term maintainability. Prefer pure functions, explicit types, small surface area. Willing to add slightly more code up-front if it makes the invariants obvious."

Each candidate runs the full self-refine protocol independently. Each writes to a DIFFERENT worktree or branch so outputs don't collide (use git worktree add ../bon-A, ../bon-B, ../bon-C — or have each write to candidates/A/, candidates/B/, candidates/C/ inside the plan directory).

### 3. Dispatch glm-reviewer to score all three
Once all three workers report, dispatch ONE `glm-reviewer` with a brief that says:

> "Score three candidate implementations of the same brief (candidates/A, /B, /C) on correctness, readability, test-worthiness, and adherence to acceptance criteria. Use a 0–10 scale per dimension, show the math, pick a winner, and list the one piece of evidence that would flip your pick."

Give the reviewer the original plan file + all three candidate paths.

### 4. Opus adjudicates
Read the reviewer's report. Don't rubber-stamp — you're the final arbiter. Check:
- Did the reviewer actually test the acceptance command on each candidate, or just read the code? Demand test output.
- Does the winner's self-refine summary show substantive critique, or shallow "looks fine"?
- Any candidate touching auth/crypto/billing/PII? You personally re-review those lines — glm-reviewer doesn't have the bar.

### 5. Merge the winner, discard losers
- Move winning files into position (from candidates/X/ → real paths in repo).
- Delete the worktrees/branches/directories for losers.
- Commit ONLY the winner's changes. Do NOT leave loser files behind — they create confusion in `git log` and future searches.

### 6. Write learnings
After merge, append ONE learning via the Bash tool:
```bash
~/.claude-dual/write-learning.sh "opus-bon" "<task-type-slug>" "success" "BoN picked candidate X over Y/Z — decider: <one-sentence-reason>" "" "best-of-n,<domain-tags>"
```

## When NOT to use this

- Trivial edits (typo, single-line rename). BoN burns 3× the quota for zero gain.
- UI polish where taste dominates and there's no test to score on. Use one good worker + your review.
- Prototype / spike code. The cost of "correct" isn't worth it yet.
- Anything where the acceptance criteria aren't precise enough to compare candidates against objectively.

## When this is the right call

- Algorithm-heavy code (graph, DP, parsing, search).
- Concurrency-sensitive code where subtle bugs are likely.
- Refactor that touches >5 call sites.
- Bug fix where the root cause is unclear and multiple hypotheses are plausible.
- New security-sensitive logic (you'll still review yourself, but 3 candidates surface more issues).
- Anywhere you'd normally spend an extra 30 min second-guessing — BoN makes the second-guess explicit and cheap.

## Reporting back to the user

One short message: "Ran best-of-N. Picked candidate X because Y. Merged into \<paths\>." Don't dump the losers or the reviewer's full scoresheet unless asked.
