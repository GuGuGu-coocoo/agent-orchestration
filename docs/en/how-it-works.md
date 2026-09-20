# How it works

[← Back to README](../../README.md) · [简体中文](../zh-CN/how-it-works.md) · [Français](../fr/how-it-works.md)

This document explains the machinery: the Phase loop, the evidence gate, the
state machine, the files on disk, and what happens when something goes wrong.

## Architecture

```
roadmap
  -> Codex (phase-runner): plan the Phase ONCE
       PHASE.md + TASK_QUEUE.json   (bounded Tasks, risk class, verification)
  -> OpenCode phase loop (run-phase.sh), one Task = one OpenCode session:
       render TASK.md -> worker implements + self-verifies -> evidence gate
         gate = RESULT.md DONE + criteria ticked
                + required verification commands re-run green
                + diff inside Allowed Changes
                + Supervisor artifacts untouched
       PASS  -> archive, mark done, next Task automatically
       STOP  -> checkpoint | escalate | guarded Task review
  -> awaiting_phase_review   (STOP: Codex Phase-level integration review)
  -> awaiting_human_qa       (STOP: the human decides)
  -> the next Phase is a deliberate new decision
```

Files, not chat history, are the source of truth for resume. Each Task is one
OpenCode session on the shared background service, so the human can watch it in
OpenCode Desktop while the loop runs.

## The evidence gate

This is the core idea: **the loop decides, not the worker.** For every Task the
loop re-runs, itself, deterministically:

- `RESULT.md` is fresh, belongs to this Task, says `Status: DONE`, and has no
  unticked criteria;
- every `verification` command from the queue re-runs and meets its expectation
  (`exit 0`, `exit N`, or `contains:<text>`);
- every file git reports as dirty (tracked, staged, deleted, untracked) is
  fingerprinted — content, file mode and existence — before and after the Task,
  and the two snapshots are compared path by path: a second edit to a file that
  was **already dirty** when the Task started is caught too (nothing is
  subtracted); tool artifacts such as `__pycache__`/`.pytest_cache` are ignored;
- `TASK_QUEUE.json`, `RUN_STATE.json`, `PHASE.md` and `TASK.md` were not touched
  by the worker.

The outcome is written to `.agent/current/VERIFY.md` and copied to
`.agent/phases/<P>/history/VERIFY-<task>.md`. PASS archives the Task and
continues; FAIL or any stop hands over to Codex. A worker's own "DONE" is never
enough.

Because verification lives in the queue, it is also reviewable: you can read
exactly what will be proven before the Task runs.

## When the loop stops (checkpoint / escalation rules)

Stops are not failures: they are where Codex is supposed to spend tokens.

- **guarded Task** (`risk: guarded` — architecture, public API, schema or data
  migration, security, permissions, credentials, deployment): it runs, then the
  loop stops for a Codex review before the next Task.
- **worker `CHECKPOINT`**: the worker needs a decision (those same topics, scope
  growth, unverifiable acceptance, product intent, material uncertainty).
- **worker `ESCALATE` / failed evidence gate**: two attempts failed, the Task is
  contradictory, or the verification does not pass.
- **plumbing**: no/conflicting/stale report, worker lock, unproven stale lock,
  `opencode` non-zero exit, inconsistent state.
- **end of Phase** (always): `awaiting_phase_review`, never the next Phase.

## State machine

`RUN_STATE.json.status` is one of:

| Status | Meaning | Who moves it on |
| --- | --- | --- |
| `idle` | planned but not running / human gate cleared | `run-phase.sh` starts |
| `running` | the loop is executing Tasks | the loop |
| `checkpoint` | the loop stopped for a Codex decision (`stop_reason`) | Codex, then `run-phase.sh` |
| `escalated` | a Task is blocked; the loop refuses to continue | Codex (queue), then `run-phase.sh` |
| `awaiting_phase_review` | all Tasks done, Phase verification passed | Codex: `phase-gate.sh review-pass/fail` |
| `awaiting_human_qa` | the review passed; the human decides | the human: `phase-gate.sh qa-pass/fail` |

`check-state.sh` prints one verdict for resume: `RUNNING`, `QUEUE_COMPLETE`,
`EMPTY`, `CHECKPOINT`, `ESCALATED`, `AWAITING_PHASE_REVIEW`,
`AWAITING_HUMAN_QA`, `WORKER_RUNNING`, `STALE_LOCK` or `INCONSISTENT`
(exit `0` = actionable, `1` = stop).

`STALE_LOCK` means a worker/phase lock has no live pid, which is **not** proof
that the run stopped: verify nothing is running, then pass `--break-lock`.
`INCONSISTENT` is reported **before** `STALE_LOCK`, so a stale lock can never
hide a state problem.

## Project runtime directory

First use in a target project creates:

```
.agent/
├── RUN_STATE.json         # phase, current task, status, stop_reason
├── current/
│   ├── TASK.md            # the one Task being executed (rendered from the queue)
│   ├── RESULT.md          # after a successful worker run
│   ├── ESCALATION.md      # after a CHECKPOINT / ESCALATE stop
│   ├── VERIFY.md          # deterministic evidence-gate result (written by the loop)
│   ├── REVIEW.md          # Codex corrections for a re-run (only when reworking)
│   ├── STATE.json         # run id, task, status, baseline, session id
│   ├── .worker.lock       # single-worker lock (wrapper pid + worker pid)
│   ├── .phase.lock        # single-loop lock
│   └── logs/              # raw opencode JSON event streams + loop logs
├── phases/<PHASE>/
│   ├── PHASE.md
│   ├── TASK_QUEUE.json    # the machine-readable plan (Codex owns this file)
│   ├── PHASE_REVIEW.md    # the Phase verification run(s)
│   └── history/           # TASK-<id>.md, VERIFY-<id>.md per Task
└── history/               # archives: <stamp>-<task>/ with RESULT, VERIFY, diff base
```

`.agent/` is runtime state only. Architecture, roadmap, product and design docs
stay in their normal locations (`ROADMAP.md`, `docs/`, `AGENTS.md`). If the
project has an `AGENTS.md`, the worker must read it.

Add `.agent/` to the target project's `.gitignore` — it is state, not source.

## Resume

State lives in files:

- `.agent/RUN_STATE.json` — phase/task/status/stop_reason of the whole run
- `.agent/phases/<PHASE>/TASK_QUEUE.json` — the plan and per-Task history
- `.agent/current/STATE.json` — current Task, baseline, session id, last result
- `.agent/current/VERIFY.md` — the evidence-gate result of the last run

On resume run `check-state.sh` first; then `run-phase.sh` continues from the
recorded `in_progress` Task. It re-renders `TASK.md` from the queue, so a blank
or stale `TASK.md` repairs itself. Completed Tasks are never re-run.

## Human checkpoint

When the last Task is done, the loop stops at `awaiting_phase_review`. Codex
does the integration review, and only `review-pass` moves the state to
`awaiting_human_qa`. Then Codex reports, and **stops**: no next Phase, no extra
Tasks. After you test, `qa-pass` (or `qa-fail` for defects) records the verdict.

The human gate is not optional and cannot be skipped by the loop.
