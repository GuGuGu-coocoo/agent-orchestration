# Smoke tests

All tests build throwaway git repositories under the system temp directory. They
never read or modify a real project. Nothing is installed and nothing is
committed to this repository.

| Script | What it covers | Model calls |
| --- | --- | --- |
| `run-offline.sh` | script-level contracts with fake workers: doctor, frontmatter, fail-fast, dry-run, status, collect-result, archive, worker-notify (message wording per exit code, fake-codex delivery, NOTIFY_FAILED hints, exit 14/15, detached notify), session identity (explicit flag / `CODEX_THREAD_ID` / archived / refusal to guess), the run-worker safety harness (fake opencode: report validation, stale-report quarantine, lock identity incl. surviving worker pid and `--break-lock`, TASK.md + list-placeholder + REVIEW.md validation, dirty baseline + BASELINE.patch, cwd pinning), check-state fail-closed cases, install/uninstall boundaries (fresh HOME, symlink escape, source-copy refusal), sibling skills untouched | no |
| `run-a-single-task.sh` | A: one implement Task ("hello" -> "hello worker"): edit, run, verify, RESULT.md, clean diff | yes |
| `run-b-investigate.sh` | B: investigate mode: finding reported, zero business code changes | yes |
| `run-c-escalation.sh` | C: a genuinely contradictory frozen stdout test forces ESCALATION.md, no edits, exit 10 (the fixture is proven contradictory before the run) | yes |
| `run-d-phase-runner.sh` | D: 3-Task queue executed by the deterministic driver, resume from A02, archive-then-done, real phase verification; `--rework` forces a corrective round on the same Task before ACCEPT | yes |
| `run-e-resume.sh` | E: an interrupted `in_progress` Task is resumed (A01 never re-run); `--template` covers the blank-TASK.md window | yes |
| `run-live.sh` | convenience wrapper: `a`, `b`, `c`, `d`, `e`, or all | - |
| `run-all.sh` | offline, then all live | - |

The `lib/phase-driver.sh` used by D/E is a **deterministic test double** for the
Codex Supervisor, not the Supervisor itself. It proves what the scripts do under a
given sequence; it cannot prove that Codex follows the skill text. Mock/fake
verification and live-model verification are labelled separately in the output.

## Running

```sh
tests/smoke/run-offline.sh
tests/smoke/run-all.sh
tests/smoke/run-live.sh d
tests/smoke/run-d-phase-runner.sh --rework

# keep the generated repos for inspection
SMOKE_KEEP_REPOS=1 tests/smoke/run-live.sh
```

Live tests use OpenCode's configured default model (there is no test-side model
override). If your default model is not reachable, live tests fail with the
provider error - that is the same behavior the worker would have.

To run live tests against a specific model without changing your global config,
point `TMPDIR` at a directory with a project-local OpenCode config (OpenCode's
config discovery walks up from each repo):

```sh
mkdir -p /tmp/oc-live/.opencode
printf '{"model":"<provider/model>"}' > /tmp/oc-live/.opencode/opencode.json
TMPDIR=/tmp/oc-live tests/smoke/run-live.sh
```

This is test scaffolding only - the worker itself never passes `--model`.

Outputs (worker JSON event logs, driver logs, doctor output) land in
`tests/smoke/.out/` and can be deleted at any time.

Each worker run creates one titled OpenCode session (`cheap-worker · <task> · ...`)
on the shared background service, so live test runs are also visible in OpenCode
Desktop.

## The phase driver

`lib/phase-driver.sh` is a deterministic stand-in for the Codex Supervisor used by
test D. It implements the phase-runner loop - render TASK.md, run the worker,
check acceptance, ACCEPT/REWORK, archive, next Task - without an LLM. The real
Supervisor behavior (Codex reading `phase-runner/SKILL.md`) is exercised by using
the installed skills in a real project.
