# Reference

[← Back to README](../../README.md) · [简体中文](../zh-CN/reference.md) · [Français](../fr/reference.md)

Every command, flag and exit code, plus the safety behaviours, model selection
and the known limitations of V1.

## Running a Phase

Codex plans the Phase (see `skills/phase-runner/SKILL.md`), then hands the whole
Phase to the loop **once**:

```sh
cd /path/to/target-project

~/.agents/skills/phase-runner/scripts/run-phase.sh          # blocking
~/.agents/skills/phase-runner/scripts/run-phase.sh --dry-run  # print the plan only

# background + wake Codex only when the loop STOPS (phase review / checkpoint / escalation)
~/.agents/skills/cheap-worker/scripts/worker-notify.sh --phase --codex-thread "orchestration"
```

| Exit code | Meaning |
| --- | --- |
| 0 | the Phase reached `awaiting_phase_review` (STOP: Codex review) |
| 1 | invalid invocation, invalid plan, or a state gate refused |
| 2 | stopped at a checkpoint (Codex decision needed) |
| 3 | stopped at an escalation (blocked) |
| 4 | refused: the Phase is at a gate (`awaiting_phase_review` / `awaiting_human_qa`) |
| 5 | refused before the loop started (live worker/loop, inconsistent state) or stopped at an inconsistent/plumbing state — a **refusal never changes any file** |

Flags:

| Flag | Effect |
| --- | --- |
| `--root DIR` | operate on another project root |
| `--max-tasks N` | safety cap on how many Tasks this invocation may run |
| `--dry-run` | validate and print the plan, then stop |
| `--no-check-state` | skip the `check-state.sh` pre-flight (expert use) |
| `--break-lock` | the explicit human confirmation that nothing is running; authorizes recovery of **both** stale locks (the loop's `.phase.lock` and a stale `.worker.lock`, forwarded to `run-worker.sh`) |

### Refusals and locking

Before it touches anything, the loop (1) validates the plan and the state
read-only, (2) refuses a live **or unprovable-stale worker lock**, (3) asks
`check-state.sh` whether a worker or another loop is live — **a refusal leaves
the whole `.agent/` tree byte-identical** (no `RUN_STATE.json` write, no
`TASK.md` rewrite, no new log) — (4) takes its own `.phase.lock`, and only then
repairs a missing/template `TASK.md` or quarantines a report left over from
another Task.

A lock with no live pid is never assumed dead: a shared-service execution can
outlive its local wrapper. Verify yourself (`check-state.sh` verdict
`STALE_LOCK`, `ps`), and only then pass `--break-lock`; `run-worker.sh` moves the
stale lock to `.agent/history/attempts/stale-locks/` before starting. A live pid
always wins — `--break-lock` never overrides it.

`--break-lock` authorizes **only** the lock recovery. It never bypasses state
validation: when `check-state.sh` reports `INCONSISTENT` (an invalid
`current/STATE.json`, conflicting reports, ...) the run is refused before any
write, with or without the flag; only the TASK/report identity issues that the
pre-flight can repair itself go through reconciliation, and they are re-checked
afterwards.

### Recording the Phase review and QA

```sh
~/.agents/skills/phase-runner/scripts/phase-gate.sh review-pass --summary "..."
~/.agents/skills/phase-runner/scripts/phase-gate.sh review-fail --reason "..."   # add corrective Tasks, continue
~/.agents/skills/phase-runner/scripts/phase-gate.sh qa-pass --note "..."         # after the human confirmed
~/.agents/skills/phase-runner/scripts/phase-gate.sh qa-fail --note "..."         # convert defects into Tasks
```

## Running a single Task (cheap-worker)

The loop drives this automatically; you can also run one Task by hand:

```sh
cd /path/to/target-project
~/.agents/skills/cheap-worker/scripts/doctor.sh
~/.agents/skills/cheap-worker/scripts/run-worker.sh --mode implement --title "Add retry queue"
```

`--title` is optional; the session title becomes
`cheap-worker · <task-id> · <title>`.

| Exit code | Meaning |
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
  pid and the worker pid**, refuses a second worker (`7`), and **never takes over
  a stale lock automatically**: use `--break-lock` after verifying nothing runs
  (`8`). A cancelled run (Ctrl-C / SIGTERM) attempts to stop its worker (TERM
  plus up to ~10 s of waiting) and **always keeps the lock**.
- previous `RESULT.md`/`ESCALATION.md`/`VERIFY.md`/`BASELINE.*` are quarantined
  to `.agent/history/attempts/<task>/`, so a stale report can never be mistaken
  for this run's output
- `TASK.md` must contain the required sections with real content (list
  placeholders such as `- <...>` count as missing); `--task-id`/`--mode` must
  match the file; a `REVIEW.md` must carry the same Task ID
- `--allow-dirty` records the pre-run tracked/staged/untracked status in
  `.agent/current/BASELINE.md` plus `git diff HEAD --binary` in `BASELINE.patch`
- opencode always runs with `cwd` = project root, even when invoked elsewhere

### Helper scripts

```sh
~/.agents/skills/cheap-worker/scripts/status.sh              # read-only Phase + Task status
~/.agents/skills/cheap-worker/scripts/check-state.sh         # resume verdict
~/.agents/skills/cheap-worker/scripts/collect-result.sh --diff
~/.agents/skills/cheap-worker/scripts/archive-task.sh --yes --decision ACCEPT
```

## Model selection

V1 has **no model layer of its own**. Neither `run-worker.sh` nor `run-phase.sh`
passes `--model`; the worker uses whatever OpenCode's own configuration selects:

- Global config: `~/.config/opencode/opencode.json` -> `"model"`
- Or the OpenCode Desktop / TUI model selector (sessions can differ)

There is no fallback, no router, no project-level model config and no automatic
switching — by design. Check the available model IDs with `opencode models`.
To reason harder, set the model's own effort in the same config, for example:

```jsonc
{
  "providers": {
    "opencode-go": {
      "models": { "deepseek-v4.1-flash": { "settings": { "reasoningEffort": "max" } } }
    }
  }
}
```

## OpenCode Desktop observability

Every Task is a normal OpenCode session on the **shared background service**, so
you can watch it in OpenCode Desktop:

- One Task = one session, titled `cheap-worker · C01 · Add retry queue`.
- The session shows the model output, Read / Search / Edit / Bash / test steps
  and the final report, exactly as it happened.
- Neither script starts a private server (`--standalone` is not used), so the
  session is the same one Desktop already sees.
- `status.sh` prints the session id recorded in `.agent/current/STATE.json`.
- There is no separate dashboard, log UI or monitoring component to maintain.

Check the service with `opencode service status` (`doctor.sh` does it for you).

## Using with Codex (desktop app)

`phase-runner` is the Supervisor skill, so Codex needs it; `cheap-worker` stays
in `~/.agents/skills/` where the OpenCode worker picks it up (Codex never loads
it).

```sh
ln -sfn ~/.agents/skills/phase-runner ~/.codex/skills/phase-runner
```

Then in a new Codex conversation:

> Use $phase-runner to build to Phase C.
> My session name is `orchestration` (for background wake-up; omit it to use blocking mode).

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

- The target must be **exact**: `--codex-thread <id-or-name>`, or
  `CODEX_THREAD_ID` when the calling runtime provides it. There is **no guessing
  from local history**; without a target the helper fails closed (`exit 14`) and
  blocking mode is used.
- Codex is woken **once per stop**, not once per Task: phase review, checkpoint,
  escalation or plumbing stop.
- `exit 15` means the loop finished but the wake-up could not be delivered: the
  message is preserved in `.agent/current/NOTIFY_FAILED.md`.
- Requires the ChatGPT/Codex desktop app to stay open **with the target session
  open**. While the loop runs, the helper holds a `caffeinate -i` assertion (so
  it cannot prevent lid-close sleep).

## Known limitations (V1)

- Model choice is entirely OpenCode's: if the configured default model is slow,
  rate-limited or unreachable, the worker fails with a plumbing error and the
  loop stops at a checkpoint. There is no fallback and no router.
- The Supervisor is the current Codex/Astra session; there is no separate
  orchestrator daemon. Wake-up mode requires the ChatGPT/Codex desktop app to
  stay open with the orchestration session open.
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
- Bash 3.2 compatible (macOS) and CI-tested on Linux; Windows is unsupported
  natively. See [Platform support](../../README.md#platform-support).

## Development rules

- One Task = one coherent change with one verification story.
- The worker never edits its own TASK.md, the queue, or `RUN_STATE.json` (the
  evidence gate fails the Task if it does).
- Codex never reviews a Task result and never edits code inside the loop: a fix
  is a Task like any other.
- A Phase always ends at `awaiting_phase_review`; the human gate is not optional.
- Do not add databases, queues, daemons, dashboards, DAGs, parallel workers or
  recursive agents to V1.
