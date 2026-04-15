# Plan: <feature slug>

**Owner:** Opus (plan author)
**Executor:** [OPUS] or [GLM] (per subtask below)
**Depends on:** <plan filenames, or none>
**Status:** draft | ready | in-progress | review | done

## Goal

One sentence: what this plan accomplishes. Must be observable — a user or test can confirm it.

## Context files (read first)

- `path/to/file.ts` — why it matters
- `path/to/other.ts` — why it matters

## Tasks

### 1. <short task name>  [GLM | OPUS]

**Files to create/edit:**
- `path/to/new.ts` (create)
- `path/to/existing.ts` (edit)

**What to do:**
- concrete step
- concrete step

**Acceptance:**
- test: `npm test -- path/to/test` must pass
- behavior: <specific observable thing>

**Constraints:**
- no new dependencies
- match style of `path/to/neighbor.ts`
- do not touch `path/to/other.ts`

**Verification command:**
```
<exact command the worker must run and paste output from>
```

### 2. <next task>  [GLM | OPUS]
...

## Out of scope

- explicitly list things this plan does NOT address so nothing creeps in

## Risks / open questions

- <things Opus should watch for during review>
