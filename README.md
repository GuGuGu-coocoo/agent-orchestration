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
      -> TASK C01 -> cheap-worker -> RESULT/ESCALATION -> Codex review
          -> ACCEPT  -> archive, next Task automatically
          -> REWORK  -> REVIEW.md corrections, same Task again
          -> ESCALATE-> Codex resolves; human only for product decisions
      -> TASK C02 -> ...
  -> phase-level verification
  -> RUN_STATE.json: awaiting_human_qa
  -> STOP (human tests manually)
```

Files, not chat history, are the source of truth for resume.

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
│   │   │   ├── run-worker.sh          # run exactly one Task via `opencode run`
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

## cheap-worker usage

The Supervisor (Codex) writes `.agent/current/TASK.md`, then:

```sh
cd /path/to/target-project

# optional environment
export CHEAP_WORKER_MODEL="opencode/muse-spark-1.3-contributor-free"

~/.agents/skills/cheap-worker/scripts/doctor.sh
~/.agents/skills/cheap-worker/scripts/run-worker.sh --mode implement
```

`run-worker.sh` exit codes:

| Code | Meaning |
| --- | --- |
| 0 | `RESULT.md` written (DONE) |
| 10 | `ESCALATION.md` written, Supervisor decision required |
| 1 | precondition/invocation failure |
| 2 | opencode failed and wrote no report |
| 3 | opencode finished but wrote no report |
| 4 | both reports exist (inconsistent) |

Other helper scripts:

```sh
~/.agents/skills/cheap-worker/scripts/status.sh
~/.agents/skills/cheap-worker/scripts/collect-result.sh --diff
~/.agents/skills/cheap-worker/scripts/archive-task.sh --yes --decision ACCEPT
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

## Worker model switching

Model IDs must always be verified on this machine first:

```sh
opencode models
```

Current verified IDs on this machine (OpenCode v2.0.8):

- free worker / default: `opencode/muse-spark-1.3-contributor-free`
- paid worker / fallback: `deepseek/deepseek-flash` (display name "DeepSeek V4.1 Flash")

Switch by environment variable (no code change, no hardcoded backend):

```sh
export CHEAP_WORKER_MODEL="deepseek/deepseek-flash"
# or per run:
~/.agents/skills/cheap-worker/scripts/run-worker.sh --mode fix --model deepseek/deepseek-flash
```

If the variable is unset, `run-worker.sh` falls back to
`opencode/muse-spark-1.3-contributor-free`. V1 has **no automatic fallback** by
design; choose the model explicitly. Never put API keys in this repo or in a
skill; OpenCode keeps credentials in its own auth store.

## Project runtime directory

First use in a target project creates:

```
.agent/
├── current/
│   ├── TASK.md
│   ├── RESULT.md          (after a successful run)
│   ├── ESCALATION.md      (after an escalation)
│   ├── REVIEW.md          (Supervisor rework notes)
│   ├── STATE.json
│   └── logs/
├── phases/<PHASE>/{PHASE.md,TASK_QUEUE.json,history/}
├── history/
└── RUN_STATE.json
```

`.agent/` is runtime state only. Architecture, roadmap, product and design docs
stay in their normal locations (`ROADMAP.md`, `docs/`, `AGENTS.md`). If the
project has an `AGENTS.md`, the worker must read it.

## Smoke tests

`tests/smoke/` creates throwaway git repos under the system temp directory. It
never touches real projects. See `tests/smoke/README.md`.

```sh
tests/smoke/run-offline.sh                            # no model calls
tests/smoke/run-live.sh                               # all live tests (DeepSeek by default)
SMOKE_MODEL=opencode/muse-spark-1.3-contributor-free \
  tests/smoke/run-live.sh                             # free model (may hit free-tier rate limits)
SMOKE_KEEP_REPOS=1 tests/smoke/run-live.sh            # keep the generated repos
```

Live tests retry transient provider quota errors (HTTP 429) automatically and
otherwise fail loudly. They never silently pass.

## Resume

State lives in files:

- `.agent/RUN_STATE.json` - phase/task/status of the whole run
- `.agent/phases/<PHASE>/TASK_QUEUE.json` - the Task queue and its history
- `.agent/current/STATE.json` - current Task, model, baseline, last result

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

- No automatic model fallback, no worker pool, no parallel workers. If the model
  returns a quota error (`429`), the worker stops with exit code 2 and the
  Supervisor decides (the smoke tests retry quota errors for convenience).
- The Supervisor loop is played by the current Codex/Astra session; there is no
  separate orchestrator daemon.
- `run-worker.sh` has no built-in wall-clock timeout (OpenCode's own behavior and
  the caller's timeout apply).
- Reports are model-written Markdown; they can be wrong. The diff and command
  output are the evidence.
- The worker prompt embeds the contract, so the worker never needs to read the
  skill directory. This is deliberate: OpenCode's `external_directory` permission
  defaults to `ask`, which auto-rejects in non-interactive runs.
- The installer's `rsync --delete` mirror mode assumes the target directory is
  fully managed by this project (it is marked as such).
- macOS bash 3.2 compatible; not tested on Windows.

## Development rules

- One Task = one coherent change.
- The worker never edits its own TASK.md, the queue, or `RUN_STATE.json`.
- The Supervisor never lets a worker plan.
- Do not add databases, queues, daemons, dashboards or recursive agents to V1.
