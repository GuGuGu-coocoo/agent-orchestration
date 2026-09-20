---
name: phase-runner
description: Use when the Codex/Astra Supervisor has to run one Phase from an existing roadmap. Covers requirement intake, roadmap reading, architecture decisions, planning the Phase into bounded Tasks with machine-checkable verification, handing the whole Phase to the OpenCode phase loop (run-phase.sh) once, resolving checkpoints/escalations, the Phase-level integration review, the human QA gate, RUN_STATE bookkeeping and resume. It never reviews every Task and never starts the next Phase by itself. It is neither a worker nor a second agent and never launches another Supervisor session.
metadata:
  short-description: Plan a Phase, run it, review it at Phase level
---

# phase-runner

`phase-runner` is the **current Codex/Astra Supervisor's** standard workflow for
one Phase of a roadmap. It is a playbook, not a program: it never starts a second
Codex CLI, never spawns recursive agents, and never lets a worker plan.

```
Phase C
  -> Codex plans once: PHASE.md + TASK_QUEUE.json (bounded Tasks, verification, risk)
  -> OpenCode phase loop (run-phase.sh), one Task = one session:
       Task -> implement -> self-verify -> evidence gate -> next Task ...
       stop on checkpoint / escalation / end of Phase
  -> awaiting_phase_review  (STOP: Codex phase-level integration review)
  -> awaiting_human_qa      (STOP: the human decides)
  -> next Phase only after the human confirms
```

## Non-negotiables

1. **The worker never plans.** It receives `.agent/current/TASK.md` and nothing else.
2. **Codex plans and reviews; OpenCode executes and verifies.** There is **no
   per-Task Codex review**. The Task-level acceptance decision is the
   deterministic evidence gate in `run-phase.sh` (re-run verification + diff
   scope + ticked criteria).
3. **One Task = one OpenCode session.** Never pass `--standalone` or `--model`;
   the model is whatever OpenCode is configured to use.
4. **Codex owns the queue.** Only Codex edits `TASK_QUEUE.json` and `PHASE.md`;
   only the loop writes `.agent/current/`.
5. **A Phase always ends in a STOP.** All Tasks done is `awaiting_phase_review`,
   never the next Phase and never human QA directly.
6. **`awaiting_human_qa` is a hard gate.** The next Phase starts only after the
   human confirms; `run-phase.sh` refuses to run until then.
7. **Files are the source of truth.** `.agent/*.json` + `.agent/phases/**` survive
   session loss, terminal close and reboot. Chat history is not state.
8. **No automation glue.** No daemons, schedulers, watchers, DAGs, parallel
   workers or custom UIs. The loop is one bash script; Codex is the Supervisor.

## What Codex owns

| Owns | Does not own |
| --- | --- |
| requirement discussion, roadmap, architecture decisions | Task-level implementation |
| Phase planning and Task decomposition | Task-level verification (the gate does it) |
| resolving checkpoints and escalations | deciding "is this Task done?" per Task |
| the Phase-level integration review | running the Task loop |
| deciding to enter human QA | starting the next Phase without the human |

## Workflow

### 0. Intake (once per phase)

1. Read `AGENTS.md` (project rules win over these defaults).
2. Find the roadmap: `ROADMAP.md`, `docs/ROADMAP.md`, `docs/roadmap.md`,
   `.agent/ROADMAP.md`, or a pointer inside `AGENTS.md`. If several exist, pick the
   current one by content/recency; ask the human only if genuinely ambiguous.
3. Inspect the repo: `git status`, `git rev-parse HEAD`, `git log --oneline -10`,
   `.agent/` contents, existing phase dirs. On resume, read `.agent/RUN_STATE.json`
   first (and run `check-state.sh`, see Resume).
4. Restate the target Phase and the human checkpoint out loud (2-5 lines).

### 1. Plan the Phase once, into a machine-runnable queue

5. Investigate the code the Phase touches (read-only).
6. Decompose the Phase into bounded Tasks. For **every** Task write:
   - `allowed_changes` / `forbidden_changes` (paths or globs - the gate checks the diff),
   - `acceptance_criteria` (observable, one per line),
   - `verification`: at least one exact, non-interactive command **the gate will
     re-run** (`{"cmd": "...", "expect": "exit 0"}`); a Task without that cannot
     run,
   - `risk`: `low` for ordinary work, `guarded` for architecture / public API /
     schema / data migration / security / permissions / credentials / deployment
     (the loop stops for a Codex review right after a guarded Task is accepted).
7. Create/update:
   - `.agent/phases/<PHASE>/PHASE.md` (from the template; `## Required Phase
     Verification` must match the queue's `phase_verification`),
   - `.agent/phases/<PHASE>/TASK_QUEUE.json` (from the template),
   - `.agent/RUN_STATE.json` (`current_phase`, `current_task: ""`, `status: idle`).
8. Tell the human the plan in one short block, then start the loop. Details and
   sizing rules: `references/phase-planning.md`.

### 2. Hand the whole Phase to the OpenCode loop - once

9. Run the loop. It executes one OpenCode worker session per Task, verifies each
   Task with the evidence gate, auto-accepts and continues; it stops only at a
   checkpoint, an escalation, or the end of the Phase.

   ```sh
   # blocking (Codex waits; always available)
   ~/.agents/skills/phase-runner/scripts/run-phase.sh --root "$PWD"

   # background + wake-up: Codex ends its turn and is woken when the loop STOPS
   ~/.agents/skills/cheap-worker/scripts/worker-notify.sh \
     --phase --codex-thread "<id-or-name>"
   ```

   Useful flags: `--max-tasks N` (safety cap), `--dry-run` (print the queue
   without running), `--break-lock` (after a crash, once nothing is running),
   `--no-check-state` (skip the resume diagnostic).

   Wake-up prerequisites: the human named this session (`--codex-thread`) or the
   runtime provides `CODEX_THREAD_ID`; the ChatGPT/Codex app must stay open with
   the target session open. Without an exact target the helper exits `14` - use
   blocking mode. An undelivered message is kept in
   `.agent/current/NOTIFY_FAILED.md`.

10. The loop's exit codes tell you what happened (it also writes
    `.agent/RUN_STATE.json`):

    | exit | RUN_STATE.status | meaning |
    | --- | --- | --- |
    | 0 | `awaiting_phase_review` | all Tasks done + Phase verification passed: do the phase review |
    | 2 | `checkpoint` | Codex decision needed (`stop_reason` says what) |
    | 3 | `escalated` | a Task is blocked; Codex must resolve it |
    | 4 | `awaiting_phase_review` / `awaiting_human_qa` | nothing to run: the Phase is at a gate |
    | 5 | `checkpoint` | inconsistent/plumbing state (report, lock, state) |
    | 1 | - | invalid invocation, plan or state |

### 3. React to the stop (the only places Codex spends tokens)

- **`awaiting_phase_review`** -> the Phase-level integration review:
  read `PHASE_REVIEW.md`, every archived `RESULT.md`/`VERIFY.md`, the full
  `git diff`, re-run the Phase verification, then:
  ```sh
  ~/.agents/skills/phase-runner/scripts/phase-gate.sh review-pass --summary "..."
  ~/.agents/skills/phase-runner/scripts/phase-gate.sh review-fail --reason "..."
  ```
  `review-fail` reopens the queue so you can append corrective Tasks and run the
  loop again. `review-pass` re-runs the Phase verification for real and moves to
  `awaiting_human_qa`. Procedure: `references/phase-review.md`.

- **`checkpoint`** -> read `stop_reason` + `.agent/current/` (and
  `ESCALATION.md` when the worker asked a question), then decide: revise the Task
  in the queue, split it, write `.agent/current/REVIEW.md` corrections (same Task
  ID) for the same Task, or ask the human for a genuine product decision. Then
  run the loop again. Procedure: `references/checkpoint-handling.md`.

- **`escalated`** -> the Task is `escalated` in the queue and blocks the loop.
  Resolve it in the queue (revise / split / drop with an `adjustments` entry),
  then run the loop again.

- **`awaiting_human_qa`** -> stop and report. Nothing runs until the human
  answers. Record the verdict:
  ```sh
  ~/.agents/skills/phase-runner/scripts/phase-gate.sh qa-pass --note "..."
  ~/.agents/skills/phase-runner/scripts/phase-gate.sh qa-fail --note "..."   # defects -> new Tasks
  ```

### 4. Human QA gate

`references/human-checkpoint.md` defines what may and may not be done between
`awaiting_human_qa` and the human's verdict. In short: no product work, no next
Phase, no "helpful" extra Tasks. Answer questions, turn reported defects into
Tasks, and wait. **The next Phase starts only after the human confirms.**

## Resume

Any time a session starts, before anything else:

1. Run `~/.agents/skills/cheap-worker/scripts/check-state.sh` in the project. It
   cross-checks the locks, queue, `RUN_STATE.json`, the current TASK/STATE and the
   reports, and prints a single verdict. An `INCONSISTENT` verdict is blocking:
   fix the listed items before acting.
2. Read `.agent/RUN_STATE.json` (`status`, `current_task`, `stop_reason`) and
   `.agent/phases/<phase>/TASK_QUEUE.json`.

| check-state verdict | action |
| --- | --- |
| `WORKER_RUNNING` | a worker or the loop is alive: do not start another; wait for the report or the `[phase-notify]` message |
| `STALE_LOCK` | a worker/phase lock has no live pid, which is **not** proof the run stopped: verify (`ps`, the recorded pids), then re-run with `--break-lock` (never implied) |
| `INCONSISTENT` | fix the listed issues first (rewrite TASK.md from the queue, resolve double reports, archive missing done Tasks) |
| `ESCALATED` | resolve the escalated Task in the queue, then run the loop |
| `CHECKPOINT` | a Codex decision is pending: read `.agent/current/` and `stop_reason` |
| `AWAITING_PHASE_REVIEW` | do the Phase-level integration review (`phase-gate.sh`) |
| `AWAITING_HUMAN_QA` | stop; the human decides; nothing runs before that |
| `RUNNING` | continue hand-offs with `run-phase.sh` (it resumes the `in_progress` Task) |
| `QUEUE_COMPLETE` | no runnable Task left: run `run-phase.sh` for the Phase verification, or append a corrective Task |
| `EMPTY` | no queue state: plan the Phase (or the next Phase after human QA) |

Exit codes: `0` = actionable, `1` = stop.

Never restart a completed Task. Never re-plan from scratch if the queue is valid;
only revise pending Tasks with recorded reasons. `run-phase.sh` re-renders
`.agent/current/TASK.md` from the queue definition, so a blank or stale TASK.md is
repaired automatically on resume.

## Reference index

| File | Purpose |
| --- | --- |
| `references/phase-planning.md` | how to decompose a Phase into runnable Tasks (queue schema, risk classes, verification) |
| `references/phase-review.md` | the Phase-level integration review and the `phase-gate.sh` decision |
| `references/checkpoint-handling.md` | resolving checkpoint / escalation stops |
| `references/roadmap-policy.md` | finding and respecting the roadmap, scope rules |
| `references/human-checkpoint.md` | what "stop and wait for the human" means in practice |
| `assets/templates/PHASE.md` | phase document template |
| `assets/templates/TASK_QUEUE.json` | task queue template (machine-readable Task definitions) |
| `assets/templates/RUN_STATE.json` | run state / resume template |
| `../cheap-worker/SKILL.md` | the worker side of the contract |
