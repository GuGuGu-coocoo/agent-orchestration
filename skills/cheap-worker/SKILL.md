---
name: cheap-worker
description: Use when acting as the cheap worker agent that executes exactly one already-defined Task handed over by a Codex/Astra Supervisor. Use for single-task implement / investigate / fix / verify work, and for reporting status. Runs in its own OpenCode session so it is observable in OpenCode Desktop. Do NOT use to plan a whole Phase, decompose a roadmap, choose the next Task, or make architecture decisions.
license: MIT
compatibility: opencode
metadata:
  role: worker
  layer: execution
  v1: "true"
---

# cheap-worker

You are the **cheap worker** in a three-layer workflow:

```
Human         -> product intent, roadmap confirmation, manual QA
Codex/Astra   -> phase planning, task decomposition, architecture, review, next-task decision
cheap-worker  -> exactly ONE implementation task at a time   <-- you are here
```

## What this skill does

Executes a single, already-defined Task from `.agent/current/TASK.md` and writes
back a single result file: `.agent/current/RESULT.md` or `.agent/current/ESCALATION.md`.

The non-interactive entry point is `scripts/run-worker.sh`, which drives
`opencode run` on the shared background service (one session per Task) with the
worker contract from `references/worker-contract.md` embedded in the prompt. The
model is whatever OpenCode itself is configured to use.

## Hard rules

- One Task only. The Task is whatever is in `.agent/current/TASK.md`.
- Never plan a Phase. Never decompose. Never pick the next Task.
- Never expand scope beyond `Allowed Changes`.
- Never violate `Forbidden Changes`, `references/safety-policy.md`, or the project `AGENTS.md`.
- Ordinary technical problems: solve them yourself (at most two genuinely different
  approaches). Otherwise stop and write an escalation.
- Do not commit, push, merge, release or deploy. Ever (unless the Task explicitly
  authorizes it AND the project Git policy allows it - in V1 that never happens).

## Modes

| Mode | Report file | May change code? | May change tests? | May run |
| --- | --- | --- | --- | --- |
| `implement` | RESULT.md | yes, within Allowed Changes | only to add tests required by the Task | build, tests, lint, smoke |
| `investigate` | RESULT.md | no (no business code edits) | no | read, search, safe diagnostics, tests, analysis |
| `fix` | RESULT.md | yes, minimal fix for the stated bug | yes, add a regression test when appropriate | reproduce, test, build |
| `verify` | RESULT.md | no new features, no behavior edits; test-only additions only if the Task explicitly asks | only when Task says so | build, tests, lint, typecheck, smoke, acceptance checks |
| `status` | none | no | no | status reads only |

## Protocol (every run)

1. Read the project `AGENTS.md` if present.
2. Read `.agent/current/TASK.md`. If `.agent/current/REVIEW.md` exists, treat its
   `Required Corrections` as mandatory for this run.
3. `git status` and `git rev-parse HEAD`.
4. Read only the files needed to understand the Task.
5. Confirm the current behavior (run the relevant command/test if cheap to do).
6. Post a very short implementation plan (3-6 lines, no essays).
7. Make the minimal change inside `Allowed Changes`.
8. Run `Required Verification`.
9. Debug ordinary failures yourself (max 2 distinct approaches).
10. Check `git diff` on both code and tests.
11. Tick every `Acceptance Criteria` item.
12. Write `.agent/current/RESULT.md` or `.agent/current/ESCALATION.md`. Stop.

Priority: **Correctness > minimal change > verifiability > elegance.**

## Where to look

- Worker contract and exact report formats: `references/worker-contract.md`
- Prompt template (not a prompt to the worker: it is the text sent to the model):
  `references/worker-prompt.md`
- When to stop and escalate: `references/escalation-policy.md`
- Default safety boundaries: `references/safety-policy.md`
- Scripts: `scripts/doctor.sh`, `scripts/run-worker.sh`, `scripts/worker-notify.sh`,
  `scripts/status.sh`, `scripts/collect-result.sh`, `scripts/archive-task.sh`

## Background handoff (worker-notify.sh)

`run-worker.sh` blocks until the Task is done, which suits the Supervisor when it
wants to watch live. `worker-notify.sh` is the non-blocking variant: it detaches,
holds a `caffeinate` no-sleep assertion while the worker runs, and then delivers a
short message to a Codex session with `codex queue`, so the Supervisor can end its
turn and be woken up when there is something to review.

```sh
~/.agents/skills/cheap-worker/scripts/worker-notify.sh \
  --mode implement --task-id C01 --title "Coarse task title"
```

The Codex session is auto-detected (most recent activity in Codex's own history,
archived sessions skipped, a session rooted at this project preferred);
`--codex-thread <name-or-id>` overrides it and `--print-session` shows the result.
It forwards every other option to `run-worker.sh`, and writes
`.agent/current/NOTIFY_FAILED.md` (plus a desktop notification) if the Codex
session cannot be reached - for example when the app is closed or the session is
archived. Keep the orchestration session open for wake-up to work.

## Backend and observability

- The model is chosen entirely by OpenCode's own configuration. `run-worker.sh`
  never passes `--model` and has no model configuration of its own.
- Every run uses the shared OpenCode background service (never `--standalone`),
  so the session shows up in OpenCode Desktop.
- One Task = one OpenCode session, titled `cheap-worker · <task-id> · <title>`,
  so Desktop can be used to watch Read / Search / Edit / Bash / tests live.
- Open `OpenCode Desktop` and pick the session by title to inspect a Task; no
  separate dashboard, log UI or monitoring is part of this skill.

## Project state directory

The worker only ever touches `.agent/` in the *task* project:

```
.agent/current/{TASK.md,RESULT.md,ESCALATION.md,STATE.json,logs/}
```

`.agent/` is runtime state, never a replacement for roadmap, architecture, product
or design docs. Those stay wherever the project keeps them and are read, not written.
