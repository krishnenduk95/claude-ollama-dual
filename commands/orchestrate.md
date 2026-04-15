---
description: Kick off the dual-model (Opus plans, GLM executes, Opus reviews) workflow on the current request
---

You are running in **dual-model orchestration mode**. The user's request is: $ARGUMENTS

Follow this workflow rigidly:

## 1. Understand

- If the request has ambiguity that materially changes the implementation, ask at most 3–5 clarifying questions in a single message. Otherwise skip to step 2.
- If a `plans/` directory exists, check whether this request extends existing plans.

## 2. Plan

- Write one or more plan files under `plans/NNN-<slug>.md` using the template at `plans/TEMPLATE.md`. If the template doesn't exist in the project, use the same structure from memory.
- Each plan task must be tagged `[OPUS]` or `[GLM]`. Tag `[GLM]` for anything a junior engineer with a good spec could do. Tag `[OPUS]` for architecture, security, hard debugging, review, integration.
- Each `[GLM]` task must include: exact file list, context files to read, acceptance criteria, constraints, verification command.
- Tell the user what you've planned (one-sentence summary per plan file) before executing.

## 3. Explore (optional, if codebase is unfamiliar)

- Dispatch `glm-explorer` subagents in parallel to map the parts of the codebase relevant to the plans.
- Fold their findings into the plans before execution.

## 4. Execute

- For each independent `[GLM]` task, dispatch `glm-worker` in parallel (single message, multiple Agent tool calls).
- For each `[OPUS]` task, do it yourself.
- Pass each `glm-worker` a brief that references the exact plan file (e.g., `Execute tasks 1 and 2 of plans/002-auth.md. Read the full plan before starting.`) plus any extra context.

## 5. Review

- For each returned worker output: either review it yourself (security/auth/billing/migrations/data) or dispatch `glm-reviewer` for routine review, then adjudicate.
- Reject with a specific fix brief; accept to move on.

## 6. Integrate & verify

- Resolve merge conflicts and cross-feature glue yourself.
- Run the full test suite and (if UI) start the dev server and exercise the feature.
- Report to the user with: plans executed, files changed, test output, anything to verify manually.

Do not pause between steps for approval unless you hit a decision with meaningful tradeoffs or a destructive/irreversible action.
