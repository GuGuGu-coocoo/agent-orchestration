---
name: phase-runner
description: Use when the Codex/Astra Supervisor is asked to execute one Phase from an existing roadmap by decomposing it into atomic Tasks, handing exactly one Task at a time to the cheap-worker skill, reviewing each report, and stopping at the human checkpoint. Covers phase intake, upfront task queue planning, task handoff, ACCEPT/REWORK/ESCALATE review, phase-level verification, RUN_STATE bookkeeping and resume. It is neither a worker nor a second agent and never launches another Supervisor session.
metadata:
  short-description: Run a roadmap Phase with the cheap worker
---

# phase-runner

`phase-runner` is the **current Codex/Astra Supervisor's** standard workflow for
completing one Phase with the `cheap-worker` skill. It is a playbook, not a program:
it never starts a second Codex CLI, never spawns recursive agents, and never lets a
worker plan.

```
Phase C
  -> Supervisor investigates + plans once (upfront)
  -> TASK_QUEUE.json
  -> C01 -> cheap-worker -> Supervisor review -> ACCEPT/REWORK/ESCALATE
  -> C02 -> cheap-worker -> Supervisor review
  -> ...
  -> Phase-level verification
  -> Human checkpoint -> STOP (awaiting_human_qa)
```

## Non-negotiables

1. **The worker never plans.** It receives `.agent/current/TASK.md` and nothing else.
2. **One Task at a time.** Never hand a queue or a Phase description to the worker.
3. **The Supervisor owns the queue.** Only the Supervisor edits `TASK_QUEUE.json`.
4. **Never ask the human "continue?" between Tasks.** ACCEPT means move to the next
   Task automatically. The human is only interrupted for product decisions, unsafe
   scope, or the phase checkpoint.
5. **Files are the source of truth.** `.agent/*.json` + `.agent/phases/**` survive
   session loss, terminal close and reboot. Chat history is not state.
6. **V1 has no automation glue:** the Supervisor performs each loop step explicitly
   with its own tools. Do not build daemons, schedulers, watchers or swarms.
7. **One Task = one OpenCode session.** The worker runs on the shared background
   service so the human can watch it in OpenCode Desktop; never pass `--standalone`
   or `--model`, and give each session a clear title.
8. **Wake-up handoff needs an exact target.** `worker-notify.sh` runs the worker in
   the background and wakes a session with `codex queue`. The target must be named
   by the human (`--codex-thread`) or provided as `CODEX_THREAD_ID`; the helper
   never guesses, and falls back to blocking mode when no target exists.

## Background handoff (wake-up mode)

Wake-up needs an exact target: the human names this session (e.g. `编排`) or the
runtime provides `CODEX_THREAD_ID`. There is no auto-detection - the helper refuses
to guess (exit 14) and you use blocking mode instead.

Handoff: run `worker-notify.sh --codex-thread "<id-or-name>" ...`, report the plan in
one line and end your turn. You will receive a short `[worker-notify]` message when
the Task ends:

- `完成` -> do the normal review (step 13-14) and hand off the next Task.
- `需要你决策` -> read `ESCALATION.md`, resolve or ask the human, then continue.
- anything else (exit 5/6/7/2/3) -> inspect the named report/state first; do not
  retry blindly. Exit 15 means the wake-up itself failed: the message is in
  `.agent/current/NOTIFY_FAILED.md`.

Prerequisites: the ChatGPT/Codex desktop app stays running **with the target session
open** (an open session can be woken by `codex queue`; a closed or archived one
cannot).

If the app was closed or the target could not be reached, the helper writes
`.agent/current/NOTIFY_FAILED.md` with the message and a hint; read it on your next
turn to see what ended. Keep wake-up messages short - they enter this conversation
as a user message and cost tokens on every wake-up.

## Workflow

### 0. Intake (once per phase)

1. Read `AGENTS.md` (project rules win over these defaults).
2. Find the roadmap: `ROADMAP.md`, `docs/ROADMAP.md`, `docs/roadmap.md`,
   `.agent/ROADMAP.md`, or a pointer inside `AGENTS.md`. If several exist, pick the
   current one by content/recency; ask the human only if genuinely ambiguous.
3. Inspect the repo: `git status`, `git rev-parse HEAD`, `git log --oneline -10`,
   `.agent/` contents, existing phase dirs. On resume, read
   `.agent/RUN_STATE.json` first - it may say the phase is already running.
4. Restate the target Phase and the human checkpoint out loud (2-5 lines).

### 1. Plan upfront

5. Investigate the code needed to understand the Phase (read-only).
6. Decompose the Phase into atomic Tasks now: each Task = one coherent, verifiable
   change a cheap worker can finish in one run. Write them down with acceptance
   criteria and required verification.
7. Create:
   - `.agent/phases/<PHASE>/PHASE.md` (from the template)
   - `.agent/phases/<PHASE>/TASK_QUEUE.json` (from the template)
   - `.agent/phases/<PHASE>/history/`
8. Update `.agent/RUN_STATE.json` (`current_phase`, `current_task`, `status`).
9. Tell the human the plan in one short block, then start Task 1 without waiting for
   a "continue".

Details and sizing rules: `references/phase-planning.md`.

### 2. Task loop (repeat until the queue is done)

10. Render the next `pending` Task into `.agent/current/TASK.md` using the TASK
    contract (keep a copy in `.agent/phases/<PHASE>/history/`), then mark it
    `in_progress` in `TASK_QUEUE.json` and `RUN_STATE.json`. Render first, mark
    second: an interruption then leaves a Task that is still `pending`, not a
    queue entry pointing at a template. Write both JSON files via temp file +
    rename.
11. Record the git baseline: `git status`, `git rev-parse HEAD`. If the previous
    accepted Task was not committed (the normal case: the worker never commits),
    pass `--allow-dirty`; `run-worker.sh` records the pre-run dirty evidence in
    `.agent/current/BASELINE.md`, and the review must compare against it so that
    old changes are not mistaken for this Task's diff.
12. Hand off the Task to the worker - exactly one Task at a time - in one of two modes:
    - **Blocking (default, always safe)**:
      `~/.agents/skills/cheap-worker/scripts/run-worker.sh --mode <mode> --task-id <id> --title "<queue title>" [--allow-dirty]`
      This blocks until the worker finishes, then continue in the same turn.
    - **Background + wake-up (only with an exact target)**:
      `~/.agents/skills/cheap-worker/scripts/worker-notify.sh --codex-thread "<id-or-name>" --mode <mode> --task-id <id> --title "<queue title>" [--allow-dirty]`
      Use it when the human named this session (or the runtime sets
      `CODEX_THREAD_ID`). It returns immediately, you end your turn, and `codex
      queue` wakes that session when the worker is done. The helper never guesses a
      session: without an exact target it exits `14` - fall back to blocking.
    Model choice belongs to OpenCode's own configuration; neither script passes
    `--model` and neither starts a private server. One Task = one OpenCode session,
    visible in OpenCode Desktop.
    Worker exit codes: `0` fresh valid RESULT, `5` RESULT but opencode failed
    (review carefully), `10` ESCALATION, `6` stale/mismatched report, `7` another
    worker is running, `8` stale lock needs `--break-lock`, `2/3/4` plumbing
    failures. The script validates TASK.md (required sections, real Task ID,
    matching `--mode`/`--task-id`, REVIEW.md identity) and quarantines previous
    reports to `.agent/history/attempts/<task>/` before each run.
13. Review the result per `references/task-review.md`: read `TASK.md`, `RESULT.md`,
    `git diff --stat`/`git diff`, `BASELINE.md`, test output, plus only the files
    that changed. `check-state.sh` prints the cross-file consistency verdict when
    something looks off.
14. Decide exactly one of:
    - **ACCEPT** -> `archive-task.sh --yes --decision ACCEPT` first, then mark the
      Task `done` in the queue (never `done` without an archive); select the next
      pending Task; continue without asking the human.
    - **REWORK** -> write `.agent/current/REVIEW.md` with concrete required
      corrections (same Task ID), keep the Task `in_progress`, re-run steps 12-13.
    - **ESCALATE** -> the Supervisor resolves technical/architectural blockers
      itself (adjust plan, split Task, add context, change approach). Ask the human
      only for genuine product decisions. Record the decision in the queue history.
15. If new evidence invalidates a future Task, revise the queue now and append the
    reason to `TASK_QUEUE.json` -> `adjustments`. Never silently drop a Task.
16. If `run-worker.sh` returns `7`, another worker is running: do not start a
    second one. Run `check-state.sh`, wait for the report or wake-up, then review.

### 3. Phase completion

17. All Tasks `done`? Run the Phase Acceptance Criteria from `PHASE.md` and the
    Required Phase Verification (full test suite, build, lint, smoke, manual checks
    that don't need the human). This is a real run, not a status flip.
18. Fix only via new Tasks - never by skipping verification.
19. Write a short Phase summary into `PHASE.md` (`## Result`) and archive the phase
    in `TASK_QUEUE.json` (`status: done`).
20. Update `.agent/RUN_STATE.json`: `status: awaiting_human_qa`,
    `human_checkpoint: after_phase_<X>`, `current_phase`, `current_task` frozen.
21. **STOP.** Report to the human what changed, what was verified, what to test
    manually, and what the next Phase would be. Do not start the next Phase.

## Human checkpoint

`references/human-checkpoint.md` defines what may and may not be done between
`awaiting_human_qa` and the human's verdict. In short: no product work, no next
Phase, no "helpful" extra Tasks. Answer questions, fix defects the human reports
(through new Tasks), and wait.

## Resume

Any time a session starts, before anything else:

1. Run `~/.agents/skills/cheap-worker/scripts/check-state.sh` in the project. It
   cross-checks the lock, queue, `RUN_STATE.json`, the current TASK/STATE and the
   reports, and prints a single verdict. An `INCONSISTENT` verdict is blocking:
   fix the listed items (or run the reconciliation named in the message) before
   acting. `check-state.sh` is fail-closed on unreadable JSON; it is a diagnostic,
   not a substitute for reading the files it points at.
2. Read `.agent/RUN_STATE.json` and `.agent/phases/<phase>/TASK_QUEUE.json`.

| check-state verdict | action |
| --- | --- |
| `WORKER_RUNNING` | do not start another worker; wait for the report or the `[worker-notify]` message |
| `INCONSISTENT` | fix the listed issues first (rewrite TASK.md from the saved definition, archive missing done Tasks, resolve double reports) |
| `REVIEW_OR_RESUME` | report ready -> review (step 13); no report -> re-run the same Task (`run-worker.sh --allow-dirty`) |
| `NEXT` | hand off the pending Task (step 10) |
| `PHASE_COMPLETE` | run the phase final review (step 17), then stop at the checkpoint |
| `EMPTY` | no queue: start from phase intake |

Never restart a completed Task. Never re-plan from scratch if the queue is valid;
only revise pending Tasks with recorded reasons.

## Reference index

| File | Purpose |
| --- | --- |
| `references/phase-planning.md` | how to decompose a Phase into atomic Tasks |
| `references/task-review.md` | ACCEPT / REWORK / ESCALATE decision procedure |
| `references/roadmap-policy.md` | finding and respecting the roadmap, scope rules |
| `references/human-checkpoint.md` | what "stop and wait" means in practice |
| `assets/templates/PHASE.md` | phase document template |
| `assets/templates/TASK_QUEUE.json` | task queue template |
| `assets/templates/RUN_STATE.json` | run state / resume template |
| `../cheap-worker/SKILL.md` | the worker side of the contract |
