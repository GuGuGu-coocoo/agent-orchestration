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
  `scripts/status.sh`, `scripts/check-state.sh`, `scripts/collect-result.sh`,
  `scripts/archive-task.sh`

## Safety behaviours (hard-enforced)

- A project-level lock records the wrapper pid **and** the worker pid, refuses a
  second worker (`exit 7`), and never takes over a stale lock automatically
  (`exit 8`; clear it with `--break-lock` after verifying nothing runs). A
  cancelled run (Ctrl-C / SIGTERM) attempts to stop its worker (TERM + up to ~10s),
  **keeps the lock**, and records the cancellation; killing the CLI is not proof
  that a shared-service execution stopped.
- Previous `RESULT.md`/`ESCALATION.md`/`BASELINE.*` are quarantined to
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

`run-worker.sh` blocks until the Task is done, which suits the Supervisor when it
wants to watch live. `worker-notify.sh` is the non-blocking variant: it detaches,
holds a `caffeinate` no-sleep assertion while the worker runs, and then delivers a
short message to a Codex session with `codex queue`, so the Supervisor can end its
turn and be woken up when there is something to review.

```sh
~/.agents/skills/cheap-worker/scripts/worker-notify.sh \
  --codex-thread "编排" --mode implement --task-id C01 --title "Coarse task title"
```

The target session must be exact (`--codex-thread <id-or-name>`, or
`CODEX_THREAD_ID` when the runtime provides it); the helper never guesses from
Codex's local history. Without a target it exits `14` and the Supervisor uses
blocking mode instead. It forwards every other option to `run-worker.sh`, and
writes `.agent/current/NOTIFY_FAILED.md` (plus a desktop notification) and exits
`15` if the wake-up cannot be delivered. Keep the orchestration session open for
wake-up to work.

## Backend and observability

- By default the model is chosen entirely by OpenCode's own configuration;
  `run-worker.sh` passes no `--model` unless you opt in.
- Optional priority list with **quota-only** fallback:

  ```sh
  export CHEAP_WORKER_MODELS="opencode/muse-spark-1.3-contributor-free deepseek/deepseek-flash"
  ```

  Only a quota/rate-limit failure (`provider.quota`, e.g. HTTP 429) moves to the
  next model; other failures do not switch. Entries are validated against
  `opencode models` first, every attempt is logged
  (`worker-<run>-<task>-aN.jsonl`), and `STATE.json` records the model that
  produced the report plus the attempt count.
- **Privacy:** the free models collect data (Muse Spark Contributor Free trains
  Meta models; the NVIDIA free endpoints are trial-only: "do not submit personal
  or confidential data"). Do not use a free-first list on confidential repos.
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
