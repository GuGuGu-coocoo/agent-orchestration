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
| 7 | another worker is already running for this project |

Safety behaviours on every run:

- a project-level lock (`.agent/current/.worker.lock`) refuses a second worker;
  a stale lock (dead pid) is moved to `.agent/history/attempts/stale-locks/`
  before the new run
- previous `RESULT.md`/`ESCALATION.md`/`BASELINE.md` are quarantined to
  `.agent/history/attempts/<task>/` so a stale report can never be mistaken for
  this run's output
- `TASK.md` must contain the required sections (Task ID, Mode, Objective,
  Acceptance Criteria, Required Verification, Allowed Changes, Forbidden Changes)
  with real content; `--task-id`/`--mode` must match the file
- `--allow-dirty` records the pre-run dirty evidence (tracked, staged, untracked)
  into `.agent/current/BASELINE.md`, so an accepted-but-uncommitted Task is not
  confused with the next Task's changes
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

V1 has **no model layer of its own**. `run-worker.sh` never passes `--model`; the
worker uses whatever OpenCode's own configuration selects:

- Global config: `~/.config/opencode/opencode.json` -> `"model"`
- Or the OpenCode Desktop / TUI model selector (sessions can differ)

Check the available model IDs with `opencode models`, and change the default in
OpenCode's own config if you want a different worker. There is no fallback, no
router, no project-level model config and no automatic switching - by design.

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

Then in a new Codex conversation, you only need one sentence:

> 用 $phase-runner 做到 Phase C。

The Supervisor takes it from there: it plans the Phase, hands off each Task with
`worker-notify.sh` (background, auto-detected session, no naming needed), and wakes
up in the same session to review. Ask for the blocking mode only when you want to
watch a Task live.

### Two handoff modes

| Mode | Command | Codex behavior | Use when |
| --- | --- | --- | --- |
| Background + wake-up | `worker-notify.sh ...` (session auto-detected) | returns immediately and ends the turn; `codex queue` wakes the SAME session when the Task ends | unattended / long Tasks (default) |
| Blocking | `run-worker.sh ...` | waits inside the turn, then continues | watching live |

Wake-up details:

- The Codex session is auto-detected **only when unambiguous** (exactly one
  recently active, non-archived session; a unique project-cwd match decides when
  several are recent). Ambiguity fails fast (`exit 13`) / no candidate (`exit 14`):
  rerun with an explicit `--codex-thread <id-or-name>`, or use the blocking mode.
  `--print-session` shows what would be detected.
- Requires the ChatGPT/Codex desktop app to stay open **with the orchestration
  session open**: an open session can be woken; a closed or archived one cannot
  (the message waits in the queue, and the helper writes `NOTIFY_FAILED.md` with a
  hint when delivery fails).
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
tests/smoke/run-offline.sh                  # no model calls (93 checks)
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
- Session auto-detection reads Codex's own local state DBs. It refuses ambiguous
  cases instead of guessing, but it is the most fragile part of the design; passing
  an explicit session id (or using blocking mode) is always stronger.
- `run-worker.sh` has no built-in wall-clock timeout (OpenCode's own behavior and
  the caller's timeout apply). `worker-notify.sh` solves the timeout problem by
  detaching, but it cannot prevent lid-close sleep or a manual shutdown.
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
