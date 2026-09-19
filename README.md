# agent-orchestration

Global, cross-project Agent Orchestration Skills for a three-layer workflow:

```
Human        -> product intent, roadmap confirmation, manual QA
Codex/Astra  -> phase planning, task decomposition, architecture, review, next-task decisions
cheap worker -> exactly ONE implementation task at a time
```

Two OpenCode skills are managed here and installed to `~/.agents/skills/`:

| Skill | Role | Location after install |
| --- | --- | --- |
| `cheap-worker` | executes one Task, writes RESULT/ESCALATION | `~/.agents/skills/cheap-worker` |
| `phase-runner` | Supervisor playbook for running a Phase | `~/.agents/skills/phase-runner` |

The most important rule: **the cheap worker never plans a Phase.** A Phase is
investigated and decomposed by Codex/Astra; the worker only ever sees
`.agent/current/TASK.md`.

## Architecture

```
roadmap
  -> Codex/Astra (phase-runner):  plan Phase into TASK_QUEUE.json  (once, upfront)
      -> TASK C01 -> cheap-worker session in OpenCode Desktop -> RESULT/ESCALATION -> Codex review
          -> ACCEPT  -> archive, next Task automatically
          -> REWORK  -> REVIEW.md corrections, same Task again
          -> ESCALATE-> Codex resolves; human only for product decisions
      -> TASK C02 -> ...
  -> phase-level verification
  -> RUN_STATE.json: awaiting_human_qa
  -> STOP (human tests manually)
```

Files, not chat history, are the source of truth for resume. Each Task is one
OpenCode session on the shared background service, so the human can watch it in
OpenCode Desktop while Codex supervises.

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
│   │   │   ├── worker-notify.sh       # run one Task in background + wake Codex
│   │   │   ├── status.sh              # read-only status of the current Task
│   │   │   ├── collect-result.sh      # print RESULT/ESCALATION (+ git diff)
│   │   │   └── archive-task.sh        # move finished Task artifacts to history
│   │   ├── references/
│   │   │   ├── worker-contract.md     # normative worker contract + report formats
│   │   │   ├── worker-prompt.md       # prompt template used by run-worker.sh
│   │   │   ├── escalation-policy.md   # when and how to stop
│   │   │   └── safety-policy.md       # default safety boundaries
│   │   └── assets/templates/
│   │       ├── TASK.md
│   │       ├── RESULT.md
│   │       ├── ESCALATION.md
│   │       └── STATE.json
│   └── phase-runner/
│       ├── SKILL.md
│       ├── references/
│       │   ├── phase-planning.md      # how to decompose a Phase
│       │   ├── task-review.md         # ACCEPT / REWORK / ESCALATE
│       │   ├── roadmap-policy.md      # finding and respecting the roadmap
│       │   └── human-checkpoint.md    # stopping and waiting for QA
│       └── assets/templates/
│           ├── PHASE.md
│           ├── TASK_QUEUE.json
│           └── RUN_STATE.json
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

## cheap-worker usage

The Supervisor (Codex) writes `.agent/current/TASK.md`, then:

```sh
cd /path/to/target-project

~/.agents/skills/cheap-worker/scripts/doctor.sh
~/.agents/skills/cheap-worker/scripts/run-worker.sh --mode implement \
  --title "Add retry queue"
```

`--title` is optional and is the short Task title; the session title becomes
`cheap-worker · <task-id> · <title>` (or `cheap-worker · <task-id>` when omitted,
derived from the Objective). The model is whatever OpenCode itself is configured
to use - the script never passes `--model` and never uses `--standalone`.

`run-worker.sh` exit codes:

| Code | Meaning |
| --- | --- |
| 0 | fresh, valid `RESULT.md` from this run |
| 5 | valid `RESULT.md` but opencode exited non-zero (review before accepting) |
| 10 | valid `ESCALATION.md`, Supervisor decision required |
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
  ~10s of waiting) and **always keeps the lock**; killing the CLI is not proof that
  a shared-service execution stopped, so the next run must verify and pass
  `--break-lock`.
- previous `RESULT.md`/`ESCALATION.md`/`BASELINE.*` are quarantined to
  `.agent/history/attempts/<task>/` so a stale report can never be mistaken for
  this run's output
- `TASK.md` must contain the required sections (Task ID, Mode, Objective,
  Acceptance Criteria, Required Verification, Allowed Changes, Forbidden Changes)
  with real content - list placeholders such as `- <...>` / `- [ ] <...>` count as
  missing; `--task-id`/`--mode` must match the file; a `REVIEW.md` must carry the
  same Task ID
- `--allow-dirty` records the pre-run tracked/staged/untracked status in
  `.agent/current/BASELINE.md` plus `git diff HEAD --binary` in `BASELINE.patch`
  (tracked content only; untracked file **contents** and repositories without a
  commit are outside this guarantee)
- `check-state.sh` is fail-closed: empty/unreadable/misspelled state is an issue,
  not a default; it distinguishes actionable verdicts (`NEXT`, `REVIEW_OR_RESUME`,
  `PHASE_COMPLETE`) from stop verdicts (`WORKER_RUNNING`, `ESCALATED`, `BLOCKED`,
  `CHECKPOINT`, `INCONSISTENT`)
- opencode always runs with `cwd` = project root, even when invoked elsewhere

Other helper scripts:

```sh
~/.agents/skills/cheap-worker/scripts/status.sh
~/.agents/skills/cheap-worker/scripts/check-state.sh    # resume consistency verdict
~/.agents/skills/cheap-worker/scripts/collect-result.sh --diff
~/.agents/skills/cheap-worker/scripts/archive-task.sh --yes --decision ACCEPT

# non-blocking variant: run in background and wake a Codex session when done
~/.agents/skills/cheap-worker/scripts/worker-notify.sh \
  --mode implement --task-id C01 --title "Add retry queue"
```

## phase-runner usage

After install, in an OpenCode/Codex session, say something like:

> 用 $phase-runner 按现有 roadmap 开发到 Phase C。
> 你负责拆 Task、逐个调用 $cheap-worker 并验收。
> 普通技术问题不要问我。
> Phase C 自动验收通过后停止，我来人工测试。

The Supervisor then follows `skills/phase-runner/SKILL.md`: intake, upfront
planning, the one-Task-at-a-time worker loop, review decisions, phase
verification, and the human checkpoint. It never asks "continue?" between Tasks.

## Model selection

By default V1 has **no model layer**: `run-worker.sh` never passes `--model`, and
the worker uses whatever OpenCode's own configuration selects (`~/.config/opencode/opencode.json`
-> `"model"`, or the Desktop/TUI selector).

Optional (opt-in) **priority list with quota-only fallback**:

```sh
export CHEAP_WORKER_MODELS="opencode/muse-spark-1.3-contributor-free deepseek/deepseek-flash"
```

- The first model is tried first; **only a quota/rate-limit failure** (a
  `provider.quota` event in the run log, e.g. HTTP 429) switches to the next one.
  Other failures do not silently switch models.
- All IDs are validated against `opencode models` before the run (retried a few
  times, because that list can be transiently empty); a typo fails fast.
- Every attempt is logged (`worker-<run>-<task>-aN.jsonl`); `STATE.json` records
  the model that produced the report and how many attempts were made.
- `doctor.sh` validates the list when the variable is set.

There is still no router, no pool and no other automatic switching. Never put API
keys in this repo or in a skill.

### Privacy warning for free models

The free Zen models are free because they collect data: Muse Spark Contributor
Free trains Meta models on your prompts/completions, and the NVIDIA free endpoints
are trial-only ("do not submit personal or confidential data"). Do **not** point
`CHEAP_WORKER_MODELS` at free models for confidential or private repositories;
DeepSeek/Zen paid models follow zero-retention policies.

## OpenCode Desktop observability

Every worker run is a normal OpenCode session on the **shared background service**,
so you can watch it in OpenCode Desktop:

- One Task = one session, titled `cheap-worker · C01 · Add retry queue`.
- The session shows the model output, Read / Search / Edit / Bash / test steps and
  the final report, exactly as it happened.
- `run-worker.sh` never starts a private server (`--standalone` is not used), so
  the session is the same one Desktop already sees.
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

The Supervisor plans the Phase and hands off each Task with `worker-notify.sh`
(background, explicit session target) or `run-worker.sh` (blocking). Without a
session target the blocking mode is the safe default; there is no auto-detection.

### Two handoff modes

| Mode | Command | Codex behavior | Use when |
| --- | --- | --- | --- |
| Blocking | `run-worker.sh ...` | waits inside the turn, then continues | default; always available |
| Background + wake-up | `worker-notify.sh --codex-thread <id-or-name> ...` | returns immediately and ends the turn; `codex queue` wakes that session when the Task ends | you want to leave the machine and a target session is known |

Wake-up details:

- The target must be **exact**: `--codex-thread <id-or-name>`, or `CODEX_THREAD_ID`
  when the calling runtime provides it. There is **no guessing from local history**
  (a wrong guess would wake another conversation); without a target the helper
  fails closed (`exit 14`) and the Supervisor stays in blocking mode.
- `exit 15` means the worker finished but the wake-up could not be delivered:
  the message is preserved in `.agent/current/NOTIFY_FAILED.md`.
- Requires the ChatGPT/Codex desktop app to stay open **with the target session
  open**: an open session can be woken; a closed or archived one cannot.
- The wake-up message is a short `[worker-notify] ...` user message in the same
  session. It enters the context, so keep it short.
- While the worker runs, the helper holds a `caffeinate -i` assertion so the Mac
  does not idle-sleep. It cannot prevent lid-close sleep: for unattended runs, plug
  in and keep the lid open.

How the loop actually runs:

- In blocking mode, Codex blocks on the shell call and continues in the same turn
  when it returns - that is what makes "ACCEPT -> next Task" automatic.
- In wake-up mode, Codex ends its turn immediately; the `codex queue` message
  starts a new turn in the same session so Codex can review and hand off the next
  Task. No polling, no third process.
- Implementation tokens are paid by OpenCode's model, not by Codex; Codex only
  spends on phase/task planning, the small handoff commands, and reviewing
  RESULT/diff/test output. That is the intended usage saving.
- Worker sessions are visible in OpenCode Desktop, not in Codex.

## Project runtime directory

First use in a target project creates:

```
.agent/
├── RUN_STATE.json         # target phase, current phase/task, status
├── current/
│   ├── TASK.md            # the one Task being executed
│   ├── RESULT.md          # after a successful run
│   ├── ESCALATION.md      # after an escalation
│   ├── REVIEW.md          # Supervisor rework notes (only when reworking)
│   ├── STATE.json         # task id, mode, status, baseline, session id
│   └── logs/              # raw opencode JSON event streams (debug aid)
├── phases/<PHASE>/
│   ├── PHASE.md
│   ├── TASK_QUEUE.json
│   └── history/           # archived Task artifacts (optional, simple)
└── history/               # archive-task.sh output (optional, simple)
```

`.agent/` is runtime state only. Architecture, roadmap, product and design docs
stay in their normal locations (`ROADMAP.md`, `docs/`, `AGENTS.md`). If the
project has an `AGENTS.md`, the worker must read it.

## Smoke tests

`tests/smoke/` creates throwaway git repos under the system temp directory. It
never touches real projects. See `tests/smoke/README.md`.

```sh
tests/smoke/run-offline.sh                  # no model calls (183 checks)
tests/smoke/run-live.sh                     # all live tests (OpenCode default model)
SMOKE_KEEP_REPOS=1 tests/smoke/run-live.sh  # keep the generated repos
```

Live tests use OpenCode's configured default model and retry transient provider
quota errors (HTTP 429); otherwise they fail loudly. They never silently pass.

## Resume

State lives in files:

- `.agent/RUN_STATE.json` - phase/task/status of the whole run
- `.agent/phases/<PHASE>/TASK_QUEUE.json` - the Task queue and its history
- `.agent/current/STATE.json` - current Task, baseline, session id, last result

On resume the Supervisor reads these first and continues from the recorded
`in_progress` Task. Completed Tasks are never re-run. See
`skills/phase-runner/SKILL.md` section "Resume".

## Human checkpoint

When the human asks to stop after a Phase, the Supervisor finishes the Phase,
runs the phase verification, writes `RUN_STATE.json` with
`status: awaiting_human_qa`, reports, and stops. It does not start the next Phase.
Defects reported during manual QA become new Tasks with the same loop. See
`skills/phase-runner/references/human-checkpoint.md`.

## Known limitations (V1)

- Model choice is entirely OpenCode's: if the configured default model is slow,
  rate-limited or unreachable, the worker fails with a plumbing error (exit 2)
  and the Supervisor decides. There is no fallback and no router.
- The Supervisor loop is played by the current Codex/Astra session; there is no
  separate orchestrator daemon. Wake-up mode requires the ChatGPT/Codex desktop app
  to stay open with the orchestration session open (its daemon owns the session and
  the message queue; closed or archived sessions cannot be woken).
- Session wake-up requires an **exact** target (`--codex-thread` or
  `CODEX_THREAD_ID`); the helper refuses to guess from Codex's local history, so
  without a target the Supervisor falls back to blocking mode.
- `run-worker.sh` has no built-in wall-clock timeout (OpenCode's own behavior and
  the caller's timeout apply). `worker-notify.sh` solves the timeout problem by
  detaching, but it cannot prevent lid-close sleep or a manual shutdown, and
  a worker that is still alive behind a dead wrapper blocks new runs until the
  lock is cleared with `--break-lock`.
- Reports are model-written Markdown; they can be wrong. The diff and command
  output are the evidence.
- The worker prompt embeds the contract, so the worker never needs to read the
  skill directory. This is deliberate: OpenCode's `external_directory` permission
  defaults to `ask`, which auto-rejects in non-interactive runs.
- The installer's `rsync --delete` mirror mode assumes the target directory is
  fully managed by this project (it is marked as such). `--target` is test-only.
- macOS bash 3.2 compatible; not tested on Windows.

## Development rules

- One Task = one coherent change.
- The worker never edits its own TASK.md, the queue, or `RUN_STATE.json`.
- The Supervisor never lets a worker plan.
- Do not add databases, queues, daemons, dashboards or recursive agents to V1.
