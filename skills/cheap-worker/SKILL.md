---
name: cheap-worker
description: Use when acting as the cheap worker agent that executes exactly one already-defined Task handed over by the Phase loop or by Codex. Use for single-task implement / investigate / fix / verify work: implement, run the Task's Required Verification, report real evidence, and stop. Runs in its own OpenCode session so it is observable in OpenCode Desktop. Do NOT use to plan a whole Phase, decompose a roadmap, choose the next Task, or make architecture decisions.
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
Codex/Astra   -> requirements, architecture, roadmap, Phase planning, Phase review
cheap-worker  -> exactly ONE implementation Task at a time   <-- you are here
OpenCode loop -> runs Task after Task, verifies each one, stops on risk
```

## What this skill does

Executes a single, already-defined Task from `.agent/current/TASK.md`, runs its
Required Verification for real, and writes back one report file:
`.agent/current/RESULT.md` or `.agent/current/ESCALATION.md`.

The non-interactive entry point is `scripts/run-worker.sh`, which drives
`opencode run` on the shared background service (one session per Task) with the
worker contract from `references/worker-contract.md` embedded in the prompt. The
model is whatever OpenCode itself is configured to use.

What happens after the report is not the worker's business: `run-phase.sh`
re-runs the Task's Required Verification as a deterministic evidence gate, and
only then archives the Task and continues. Codex is involved per Phase, not per
Task.

## Hard rules

- One Task only. The Task is whatever is in `.agent/current/TASK.md`.
- Never plan a Phase. Never decompose. Never pick the next Task.
- Never expand scope beyond `Allowed Changes`; never touch `Forbidden Changes`.
- Run every command in `Required Verification` exactly as written and report what
  actually happened. A claimed result that was not produced cannot pass the gate.
- Ordinary technical problems: solve them yourself (at most two genuinely
  different approaches). Otherwise stop and write an escalation.
- Stop with `Class CHECKPOINT` when a decision is needed (architecture, public
  API, schema, security, deployment, scope growth, uncertainty); stop with
  `Class ESCALATE` when blocked. See `references/escalation-policy.md`.
- Do not edit `.agent/current/TASK.md`, the queue, or `RUN_STATE.json` - they
  belong to Codex. The evidence gate fails the Task if they change.
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
8. Run `Required Verification` exactly as written; keep the real output.
9. Debug ordinary failures yourself (max 2 distinct approaches).
10. Check `git diff` on both code and tests.
11. Tick every `Acceptance Criteria` item - or escalate instead of ticking a
    criterion you did not satisfy.
12. Write `.agent/current/RESULT.md` or `.agent/current/ESCALATION.md`. Stop.

Priority: **Correctness > minimal change > verifiability > elegance.**

## Where to look

- Worker contract and exact report formats: `references/worker-contract.md`
- Prompt template (not a prompt to the worker: it is the text sent to the model):
  `references/worker-prompt.md`
- When to stop (CHECKPOINT vs ESCALATE): `references/escalation-policy.md`
- Default safety boundaries: `references/safety-policy.md`
- Scripts: `scripts/doctor.sh`, `scripts/run-worker.sh`, `scripts/worker-notify.sh`,
  `scripts/status.sh`, `scripts/check-state.sh`, `scripts/collect-result.sh`,
  `scripts/archive-task.sh`

## Safety behaviours (hard-enforced)

- A project-level lock records the wrapper pid **and** the worker pid, refuses a
  second worker (`exit 7`), and never takes over a stale lock automatically
  (`exit 8`; clear it with `--break-lock` after verifying nothing runs).
  `run-phase.sh` checks the same lock **before it writes anything**, so an
  unconfirmed stale worker lock aborts the loop with the project unchanged instead
  of failing halfway through the Task handoff. A
  cancelled run (Ctrl-C / SIGTERM) attempts to stop its worker (TERM + up to ~10s),
  **keeps the lock**, and records the cancellation; killing the CLI is not proof
  that a shared-service execution stopped.
- Previous `RESULT.md`/`ESCALATION.md`/`VERIFY.md`/`BASELINE.*` are quarantined to
  `.agent/history/attempts/<task>/` before every run, so a stale report can never
  be mistaken for the current run's output.
- The report must be fresh and carry this Task ID; `RESULT.md` must say `DONE`.
  Anything else exits `6` (invalid report) or `5` (valid RESULT but opencode
  failed) instead of claiming success.
- `TASK.md` is validated (required sections, real Task ID, no placeholders) and
  `--task-id`/`--mode` must match the file; `REVIEW.md` must carry the same Task ID.
- `--allow-dirty` records the pre-run tracked/staged/untracked evidence in
  `.agent/current/BASELINE.md` plus the full patch in `BASELINE.patch`.
- opencode always runs with `cwd` = project root.
- Wake-up targets are exact (`--codex-thread` or `CODEX_THREAD_ID`); the helper
  never guesses a session and exits `14`/`15` when it cannot deliver.

## Background handoff (worker-notify.sh)

`run-worker.sh` blocks until the Task is done. `worker-notify.sh` is the
non-blocking variant: it detaches, holds a `caffeinate` no-sleep assertion, and
then delivers a short message to a Codex session with `codex queue`.

```sh
# one Task
~/.agents/skills/cheap-worker/scripts/worker-notify.sh \
  --codex-thread "编排" --mode implement --task-id C01 --title "Coarse task title"

# a whole Phase loop: Codex is only woken when the loop stops
~/.agents/skills/cheap-worker/scripts/worker-notify.sh \
  --phase --codex-thread "编排"
```

The target session must be exact (`--codex-thread <id-or-name>`, or
`CODEX_THREAD_ID` when the runtime provides it); the helper never guesses from
Codex's local history. Without a target it exits `14` and the blocking script is
used instead. It forwards every other option to the runner, and writes
`.agent/current/NOTIFY_FAILED.md` (plus a desktop notification) and exits `15` if
the wake-up cannot be delivered.

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

The worker only ever touches the files the Task allows, plus its own report:

```
.agent/current/{TASK.md,RESULT.md,ESCALATION.md,STATE.json,logs/}
.agent/current/VERIFY.md     <- written by run-phase.sh, not by the worker
```

`.agent/` is runtime state, never a replacement for roadmap, architecture, product
or design docs. Those stay wherever the project keeps them and are read, not written.
