**English** | [简体中文](README.zh-CN.md) | [Français](README.fr.md)

# agent-orchestration

[![CI](https://github.com/GuGuGu-coocoo/agent-orchestration/actions/workflows/ci.yml/badge.svg)](https://github.com/GuGuGu-coocoo/agent-orchestration/actions/workflows/ci.yml)

Two OpenCode skills that turn one expensive planning session into a supervised
pipeline of cheap, **verified** implementation Tasks.

**The problem.** Running a long build with a single agent means one context
window has to hold the plan, the code, the tests and the mistakes. It gets
slow, expensive, and quietly unreliable.

**The split.** Codex plans a Phase. OpenCode executes it, one Task per session,
and proves each Task is done. The human decides what "done" means.

```
Human          -> intent, roadmap, manual QA
Codex/Astra    -> requirements, architecture, Phase planning, Phase-level review
OpenCode loop  -> executes the Phase's bounded Tasks: one session per Task,
                  verifies each Task itself, auto-continues, stops on risk
```

## Highlights

**Verification is a gate, not a claim.** After every Task the loop re-runs the
Task's own verification commands, checks that the diff stayed inside the allowed
files, and confirms its own plan files were not touched. A worker saying "DONE"
is never enough — see [the evidence gate](docs/en/how-it-works.md#the-evidence-gate).

**Codex never reviews a Task.** Codex plans the Phase once, then spends tokens
only where they matter: checkpoints, escalations, the Phase-level integration
review, and the human QA gate. A Phase is bounded by construction.

**One hand-off per Phase.** You either block once or detach once. There is no
per-Task orchestration, no polling, no third process to babysit.

**It fails closed.** A live or unprovable lock, a malformed plan, a stale report
or an inconsistent state all stop the run *before* anything is written. A
refusal leaves the project byte-identical.

**Files are the source of truth.** Every decision lives in `.agent/`, so a run
survives a crash, a reboot or a new session — no chat history required.

**No daemon, no database, no dashboard.** Two skills, some shell, and the
OpenCode shared service you already have.

## The two skills

| Skill | Role | Scripts |
| --- | --- | --- |
| **`cheap-worker`** | Runs exactly one Task in its own OpenCode session and writes a `RESULT.md` or an `ESCALATION.md`. Used by the loop, or standalone. | `run-worker.sh`, `worker-notify.sh`, `doctor.sh`, `status.sh`, `check-state.sh`, `collect-result.sh`, `archive-task.sh` |
| **`phase-runner`** | The loop (`run-phase.sh`) that drives Task after Task behind the evidence gate, plus the Codex playbook for supervising one Phase and the Phase/QA gate recorder (`phase-gate.sh`). | `run-phase.sh`, `phase-gate.sh` |

## Quick start

**1. Install the skills**

```sh
git clone https://github.com/GuGuGu-coocoo/agent-orchestration
cd agent-orchestration
./scripts/install-skills.sh --dry-run   # preview
./scripts/install-skills.sh             # install to ~/.agents/skills/
```

**2. Check the environment**

```sh
cd /path/to/target-project
~/.agents/skills/cheap-worker/scripts/doctor.sh
```

**3. Plan a Phase (Codex), then run it once**

Codex reads `phase-runner/SKILL.md`, writes `PHASE.md` + `TASK_QUEUE.json`, and
hands the whole Phase to the loop a single time:

```sh
~/.agents/skills/phase-runner/scripts/run-phase.sh            # blocking
~/.agents/skills/cheap-worker/scripts/worker-notify.sh --phase --codex-thread "orchestration"
```

Either way it is **one hand-off for the whole Phase**. When the last Task is
done the loop stops at `awaiting_phase_review`; Codex reviews, you test, and
`phase-gate.sh qa-pass` records your verdict. It never starts the next Phase.

**Running a single Task by hand**

```sh
~/.agents/skills/cheap-worker/scripts/run-worker.sh --mode implement --title "Add retry queue"
```

## Requirements

| Dependency | Needed for | Notes |
| --- | --- | --- |
| [OpenCode](https://opencode.ai) v2 (`opencode`) | running Tasks: one session per Task | on `PATH`, authenticated |
| `git` | baselines, diffs, the scope check | every target project is a repo |
| `jq` | all state files | required, no fallback |
| `bash` | all scripts | bash 3.2+ |
| `python3` | verification commands in Python projects | optional |
| Codex desktop app | background hand-off + wake-up | optional; blocking needs none |

### Platform support

| Platform | Status |
| --- | --- |
| macOS | developed and tested here |
| Linux | exercised by CI (`ubuntu-latest`) |
| Windows | not supported natively — use WSL (untested). Native Git Bash is not supported. |

## Documentation

| Document | What is in it |
| --- | --- |
| [How it works](docs/en/how-it-works.md) | Architecture, the evidence gate, the state machine, `.agent/`, stops, resume, the human checkpoint |
| [Reference](docs/en/reference.md) | Every command and flag, all exit codes, safety behaviours, model selection, Desktop observability, Codex integration, known limitations |
| [Testing](docs/en/testing.md) | The offline and live smoke suites, what they do and do not prove, CI |

Translations: [简体中文](README.zh-CN.md) · [Français](README.fr.md) — the linked
documents have `zh-CN` and `fr` counterparts in the same directory.

## License

[MIT](LICENSE)
