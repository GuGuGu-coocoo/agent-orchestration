# agent-orchestration

Global, cross-project Agent Orchestration Skills for a three-layer workflow where
**OpenCode does the Task-level work and verification, and Codex supervises at
Phase level**:

```
Human          -> product intent, roadmap confirmation, manual QA
Codex/Astra    -> requirements, architecture, roadmap, Phase planning,
                  Phase-level review, escalation handling, human-QA decision
OpenCode loop  -> executes the Phase's bounded Tasks, one session per Task,
                  verifies each Task itself, auto-continues, stops on risk
```

Two OpenCode skills are managed here and installed to `~/.agents/skills/`:

| Skill | Role | Location after install |
| --- | --- | --- |
| `cheap-worker` | executes one Task, writes RESULT/ESCALATION | `~/.agents/skills/cheap-worker` |
| `phase-runner` | the Phase loop + the Codex playbook for one Phase | `~/.agents/skills/phase-runner` |

The most important rule: **the worker never plans a Phase, and Codex never
reviews a Task.** Codex plans the Phase once into `TASK_QUEUE.json`; the loop
(`run-phase.sh`) executes it and accepts each Task with a deterministic evidence
gate.

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

## Repository layout

```
agent-orchestration/
├── README.md
├── .gitignore
├── scripts/
│   ├── install-skills.sh              # install/update the two managed skills
│   └── uninstall-managed-skills.sh    # remove exactly the two managed skills
├── skills/
│   ├── cheap-worker/
│   │   ├── SKILL.md
│   │   ├── scripts/
│   │   │   ├── doctor.sh              # environment health check
│   │   │   ├── run-worker.sh          # run exactly one Task (blocking)
│   │   │   ├── worker-notify.sh       # run one Task OR a whole Phase in background + wake Codex
│   │   │   ├── status.sh              # read-only status (Phase + Task)
│   │   │   ├── check-state.sh         # resume verdict / consistency check
│   │   │   ├── collect-result.sh      # print RESULT/ESCALATION + VERIFY evidence
│   │   │   └── archive-task.sh        # move finished Task artifacts to history
│   │   ├── references/
│   │   │   ├── worker-contract.md     # normative worker contract + report formats
│   │   │   ├── worker-prompt.md       # prompt template used by run-worker.sh
│   │   │   ├── escalation-policy.md   # CHECKPOINT vs ESCALATE, when to stop
│   │   │   └── safety-policy.md       # default safety boundaries
│   │   └── assets/templates/
│   │       ├── TASK.md  RESULT.md  ESCALATION.md  STATE.json
│   └── phase-runner/
│       ├── SKILL.md                   # the Codex playbook for one Phase
│       ├── scripts/
│       │   ├── run-phase.sh           # THE LOOP: Task after Task, evidence gate
│       │   └── phase-gate.sh          # Phase review / human QA gate recorder
│       ├── references/
│       │   ├── phase-planning.md      # decompose a Phase into runnable Tasks
│       │   ├── phase-review.md        # the Phase-level integration review
│       │   ├── checkpoint-handling.md # resolving checkpoint / escalation stops
│       │   ├── roadmap-policy.md      # finding and respecting the roadmap
│       │   └── human-checkpoint.md    # stop and wait for the human
│       └── assets/templates/
│           ├── PHASE.md  TASK_QUEUE.json  RUN_STATE.json
└── tests/smoke/                       # throwaway-repo tests, never the user's projects
```

## Install

```sh
./scripts/install-skills.sh --dry-run      # preview
./scripts/install-skills.sh                # install/update
./scripts/install-skills.sh --force        # replace even unmarked same-named dirs (backs them up first)
```

The installer only ever syncs `skills/cheap-worker` and `skills/phase-runner` into
`~/.agents/skills/`. It does not read, move or delete any other skill. It is
idempotent, verifies `SKILL.md` after install, and writes a
`.installed-by-agent-orchestration` marker into each managed directory.

## Uninstall

```sh
./scripts/uninstall-managed-skills.sh --dry-run
./scripts/uninstall-managed-skills.sh --yes
```

Exact literal paths only, explicit confirmation required, refuses unmarked
directories unless `--force`, and never removes `~/.agents/skills` itself.
If you linked the skill into Codex, remove that link too:

```sh
rm ~/.codex/skills/phase-runner
```

## Running a Phase

Codex plans the Phase (see `skills/phase-runner/SKILL.md`), then hands the whole
Phase to the loop **once**:

```sh
cd /path/to/target-project

~/.agents/skills/phase-runner/scripts/run-phase.sh          # blocking
~/.agents/skills/phase-runner/scripts/run-phase.sh --dry-run  # print the plan only

# background + wake Codex only when the loop STOPS (phase review / checkpoint / escalation)
~/.agents/skills/cheap-worker/scripts/worker-notify.sh --phase --codex-thread "编排"
```

`run-phase.sh` exit codes:

| Code | Meaning |
| --- | --- |
| 0 | the Phase reached `awaiting_phase_review` (STOP: Codex review) |
| 1 | invalid invocation, invalid plan, or a state gate refused |
| 2 | stopped at a checkpoint (Codex decision needed) |
| 3 | stopped at an escalation (blocked) |
| 4 | refused: the Phase is at a gate (`awaiting_phase_review` / `awaiting_human_qa`) |
| 5 | refused before the loop started (live worker/loop, inconsistent state) or stopped at an inconsistent/plumbing state — a **refusal never changes any file** |

Flags: `--root DIR`, `--max-tasks N` (safety cap), `--dry-run`, `--no-check-state`,
`--break-lock` (the explicit human confirmation that nothing is running: it
authorizes the recovery of **both** stale locks - the loop's `.phase.lock` and a
stale `.worker.lock`, which is forwarded to `run-worker.sh`).

Before it touches anything, the loop (1) validates the plan and the state
read-only, (2) refuses a live **or unprovable-stale worker lock**, (3) asks
`check-state.sh` whether a worker or another loop is live — **a refusal leaves the
whole `.agent/` tree byte-identical** (no `RUN_STATE.json` write, no `TASK.md`
rewrite, no new log) — (4) takes its own `.phase.lock`, and only then repairs a
missing/template `TASK.md` or quarantines a report left over from another Task.

A lock with no live pid is never assumed dead: a shared-service execution can
outlive its local wrapper. Verify yourself (`check-state.sh` verdict `STALE_LOCK`,
`ps`), and only then pass `--break-lock`; `run-worker.sh` moves the stale lock to
`.agent/history/attempts/stale-locks/` before starting. A live pid always wins —
`--break-lock` never overrides it.

`--break-lock` authorizes **only** the lock recovery. It never bypasses state
validation: when `check-state.sh` reports `INCONSISTENT` (an invalid
`current/STATE.json`, conflicting reports, ...) the run is refused before any
write, with or without the flag; only the TASK/report identity issues that the
pre-flight can repair itself go through reconciliation, and they are re-checked
afterwards.

The Phase review is recorded with:

```sh
~/.agents/skills/phase-runner/scripts/phase-gate.sh review-pass --summary "..."
~/.agents/skills/phase-runner/scripts/phase-gate.sh review-fail --reason "..."   # add corrective Tasks, continue
~/.agents/skills/phase-runner/scripts/phase-gate.sh qa-pass --note "..."         # after the human confirmed
~/.agents/skills/phase-runner/scripts/phase-gate.sh qa-fail --note "..."         # convert defects into Tasks
```

## The evidence gate (why Codex does not review each Task)

For every Task the loop re-runs, itself, deterministically:

- `RESULT.md` is fresh, belongs to this Task, `Status: DONE`, no unticked criteria;
- every `verification` command from the queue re-runs and meets its expectation
  (`exit 0`, `exit N`, or `contains:<text>`);
- every file git reports as dirty (tracked, staged, deleted, untracked) is
  fingerprinted — content, file mode and existence — before and after the Task,
  and the two snapshots are compared per path: a second edit to a file that was
  **already dirty** when the Task started is caught too (nothing is subtracted);
  tool artifacts such as `__pycache__`/`.pytest_cache` are ignored;
- `TASK_QUEUE.json`, `RUN_STATE.json`, `PHASE.md` and `TASK.md` were not touched by
  the worker.

The outcome is written to `.agent/current/VERIFY.md` and copied to
`.agent/phases/<P>/history/VERIFY-<task>.md`; PASS archives the Task and continues,
FAIL/any stop hands over to Codex. A worker's own "DONE" is never enough.

## cheap-worker usage (single Task)

The loop drives this automatically; you can also run one Task by hand:

```sh
cd /path/to/target-project
~/.agents/skills/cheap-worker/scripts/doctor.sh
~/.agents/skills/cheap-worker/scripts/run-worker.sh --mode implement --title "Add retry queue"
```

`--title` is optional; the session title becomes
`cheap-worker · <task-id> · <title>`. The model is whatever OpenCode itself is
configured to use - the script never passes `--model` and never uses
`--standalone`.

`run-worker.sh` exit codes:

| Code | Meaning |
| --- | --- |
| 0 | fresh, valid `RESULT.md` from this run |
| 5 | valid `RESULT.md` but opencode exited non-zero (review before accepting) |
| 10 | valid `ESCALATION.md` (`## Class`: CHECKPOINT or ESCALATE) |
| 1 | precondition failure (missing/invalid/inconsistent TASK.md, dirty tree without `--allow-dirty`) |
| 2 | opencode failed and wrote no report |
| 3 | opencode finished but wrote no report |
| 4 | both reports valid (inconsistent) |
| 6 | report is stale, malformed, or for another Task |
| 7 | another worker (or a surviving worker process) is already running |
| 8 | stale lock could not be proven dead; re-run with `--break-lock` after checking |

Safety behaviours on every run:

- a project-level lock (`.agent/current/.worker.lock`) records **both the wrapper
  pid and the worker pid**, refuses a second worker (`7`), and **never takes over a
  stale lock automatically**: use `--break-lock` after verifying nothing runs (`8`).
  A cancelled run (Ctrl-C / SIGTERM) attempts to stop its worker (TERM plus up to
  ~10s of waiting) and **always keeps the lock**.
- previous `RESULT.md`/`ESCALATION.md`/`VERIFY.md`/`BASELINE.*` are quarantined to
  `.agent/history/attempts/<task>/` so a stale report can never be mistaken for
  this run's output
- `TASK.md` must contain the required sections with real content (list placeholders
  such as `- <...>` count as missing); `--task-id`/`--mode` must match the file; a
  `REVIEW.md` must carry the same Task ID
- `--allow-dirty` records the pre-run tracked/staged/untracked status in
  `.agent/current/BASELINE.md` plus `git diff HEAD --binary` in `BASELINE.patch`
- opencode always runs with `cwd` = project root, even when invoked elsewhere

Other helper scripts:

```sh
~/.agents/skills/cheap-worker/scripts/status.sh
~/.agents/skills/cheap-worker/scripts/check-state.sh    # resume verdict
~/.agents/skills/cheap-worker/scripts/collect-result.sh --diff
~/.agents/skills/cheap-worker/scripts/archive-task.sh --yes --decision ACCEPT
```

## phase-runner usage

After install, in an OpenCode/Codex session, say something like:

> 用 $phase-runner 按现有 roadmap 开发到 Phase C。
> 你负责需求和 Phase planning，把 Phase 拆成 bounded Tasks 后交给 run-phase.sh 跑。
> 不要逐个 Task review；Phase 完成后做 integration review，然后停下等我人工测试。

The Supervisor then follows `skills/phase-runner/SKILL.md`: intake, upfront
planning, one hand-off of the whole Phase, resolving checkpoint/escalation stops,
the Phase-level review, and the human checkpoint. It never asks "continue?"
between Tasks and never reviews a Task result.

## Model selection

V1 has **no model layer of its own**. Neither `run-worker.sh` nor `run-phase.sh`
passes `--model`; the worker uses whatever OpenCode's own configuration selects:

- Global config: `~/.config/opencode/opencode.json` -> `"model"`
- Or the OpenCode Desktop / TUI model selector (sessions can differ)

There is no fallback, no router, no project-level model config and no automatic
switching - by design. Check the available model IDs with `opencode models`.

## OpenCode Desktop observability

Every Task is a normal OpenCode session on the **shared background service**, so
you can watch it in OpenCode Desktop:

- One Task = one session, titled `cheap-worker · C01 · Add retry queue`.
- The session shows the model output, Read / Search / Edit / Bash / test steps and
  the final report, exactly as it happened.
- Neither script starts a private server (`--standalone` is not used), so the
  session is the same one Desktop already sees.
- `status.sh` prints the session id recorded in `.agent/current/STATE.json`.
- There is no separate dashboard, log UI or monitoring component to maintain.

Check the service with `opencode service status` (the `doctor.sh` script does it
for you).

## Using with Codex (desktop app)

`phase-runner` is the Supervisor skill, so Codex needs it; `cheap-worker` stays in
`~/.agents/skills/` where the OpenCode worker picks it up (Codex never loads it).

```sh
ln -sfn ~/.agents/skills/phase-runner ~/.codex/skills/phase-runner
```

Then in a new Codex conversation:

> 用 $phase-runner 做到 Phase C。
> 我的会话名是 `编排`（用于后台唤醒；不写就用 blocking 模式）。

### Two handoff modes

| Mode | Command | Codex behavior | Use when |
| --- | --- | --- | --- |
| Blocking | `run-phase.sh` | waits inside the turn, then does the Phase review | default; always available |
| Background + wake-up | `worker-notify.sh --phase --codex-thread <id-or-name>` | returns immediately and ends the turn; `codex queue` wakes that session when the loop **stops** | you want to leave the machine and a target session is known |

Either mode is **one handoff for the whole Phase**: never run the loop once per
Task and never poll `status.sh` / `check-state.sh` while it runs (`--max-tasks N`
is a safety cap, not a rhythm). A running loop answers `WORKER_RUNNING` until it
stops, and the notifier wakes the Supervisor exactly once per stop.

Wake-up details:

- The target must be **exact**: `--codex-thread <id-or-name>`, or `CODEX_THREAD_ID`
  when the calling runtime provides it. There is **no guessing from local history**;
  without a target the helper fails closed (`exit 14`) and blocking mode is used.
- Codex is woken **once per stop**, not once per Task: phase review, checkpoint,
  escalation or plumbing stop.
- `exit 15` means the loop finished but the wake-up could not be delivered: the
  message is preserved in `.agent/current/NOTIFY_FAILED.md`.
- Requires the ChatGPT/Codex desktop app to stay open **with the target session
  open**. While the loop runs, the helper holds a `caffeinate -i` assertion.

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

`check-state.sh` prints one verdict for resume: `RUNNING`, `QUEUE_COMPLETE`, `EMPTY`,
`CHECKPOINT`, `ESCALATED`, `AWAITING_PHASE_REVIEW`, `AWAITING_HUMAN_QA`,
`WORKER_RUNNING`, `STALE_LOCK` or `INCONSISTENT` (exit `0` = actionable, `1` = stop).
`STALE_LOCK` means a worker/phase lock has no live pid, which is **not** proof that
the run stopped: verify nothing is running, then `--break-lock`. `INCONSISTENT` is
reported **before** `STALE_LOCK`, so a stale lock can never hide a state problem.

## When the loop stops (checkpoint / escalation rules)

Stops are not failures: they are where Codex is supposed to spend tokens.

- **guarded Task** (`risk: guarded` - architecture, public API, schema/data
  migration, security, permissions, credentials, deployment): runs, then the loop
  stops for a Codex review before the next Task.
- **worker `CHECKPOINT`**: the worker needs a decision (those same topics, scope
  growth, unverifiable acceptance, product intent, material uncertainty).
- **worker `ESCALATE` / failed evidence gate**: two attempts failed, the Task is
  contradictory, or the verification does not pass.
- **plumbing**: no/conflicting/stale report, worker lock, unproven stale lock,
  `opencode` non-zero exit, inconsistent state.
- **end of Phase** (always): `awaiting_phase_review`, never the next Phase.

## Smoke tests

`tests/smoke/` creates throwaway git repos under the system temp directory and
runs the scripts from **this source tree**. It never touches real projects and
never installs anything. See `tests/smoke/README.md`.

```sh
tests/smoke/run-offline.sh                  # no model calls (266 checks)
tests/smoke/run-live.sh                     # all live tests (OpenCode default model)
SMOKE_KEEP_REPOS=1 tests/smoke/run-live.sh  # keep the generated repos
```

Live tests use OpenCode's configured default model and retry transient provider
quota errors (HTTP 429); otherwise they fail loudly. They never silently pass.

## Resume

State lives in files:

- `.agent/RUN_STATE.json` - phase/task/status/stop_reason of the whole run
- `.agent/phases/<PHASE>/TASK_QUEUE.json` - the plan and per-Task history
- `.agent/current/STATE.json` - current Task, baseline, session id, last result
- `.agent/current/VERIFY.md` - the evidence-gate result of the last run

On resume run `check-state.sh` first; then `run-phase.sh` continues from the
recorded `in_progress` Task (it re-renders `TASK.md` from the queue, so a blank or
stale TASK.md repairs itself). Completed Tasks are never re-run.

## Human checkpoint

When the last Task is done, the loop stops at `awaiting_phase_review`. Codex does
the integration review, and only `review-pass` moves the state to
`awaiting_human_qa`. Then Codex reports, and **stops**: no next Phase, no extra
Tasks. After the human tests, `qa-pass` (or `qa-fail` for defects) records the
verdict. See `skills/phase-runner/references/human-checkpoint.md`.

## Known limitations (V1)

- Model choice is entirely OpenCode's: if the configured default model is slow,
  rate-limited or unreachable, the worker fails with a plumbing error and the loop
  stops at a checkpoint. There is no fallback and no router.
- The Supervisor is the current Codex/Astra session; there is no separate
  orchestrator daemon. Wake-up mode requires the ChatGPT/Codex desktop app to stay
  open with the orchestration session open.
- `run-worker.sh` has no built-in wall-clock timeout (OpenCode's own behavior and
  the caller's timeout apply). `worker-notify.sh` solves the timeout problem by
  detaching, but it cannot prevent lid-close sleep or a manual shutdown.
- Reports are model-written Markdown; they can be wrong. The re-run verification,
  the diff scope and the diff itself are the evidence.
- The worker prompt embeds the contract, so the worker never needs to read the
  skill directory (OpenCode's `external_directory` permission defaults to `ask`).
- Verification commands come from the queue and run via `bash -c` in the project
  root: they must be non-interactive, deterministic and reasonably fast.
- The installer's `rsync --delete` mirror mode assumes the target directory is
  fully managed by this project. `--target` is test-only.
- macOS bash 3.2 compatible; not tested on Windows.

## Development rules

- One Task = one coherent change with one verification story.
- The worker never edits its own TASK.md, the queue, or `RUN_STATE.json` (the
  evidence gate fails the Task if it does).
- Codex never reviews a Task result and never edits code inside the loop: a fix is
  a Task like any other.
- A Phase always ends at `awaiting_phase_review`; the human gate is not optional.
- Do not add databases, queues, daemons, dashboards, DAGs, parallel workers or
  recursive agents to V1.
