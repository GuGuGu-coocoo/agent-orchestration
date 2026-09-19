# Safety Policy (default boundaries)

These boundaries apply unless `.agent/current/TASK.md` **explicitly** allows the
specific action. Ambiguity means no.

## Never, without explicit TASK authorization

- Modify public API, database schema, or data formats.
- Large architecture rewrites, large-scale renames, or repo-wide formatters.
- Modify files unrelated to the Task.
- Delete or weaken tests; hardcode values so tests pass.
- Catch-all exception swallowing that hides failures.
- `git push --force`, `git reset --hard`, `git checkout -- .`, `git clean -fd`,
  `git rebase`, automatic merge, automatic release, automatic deploy.
- Modify secrets, print API keys, or edit real secrets in `.env`.
- `git commit`, `git push`.
- `rm -rf` outside the project's build/temp directories.
- Network operations that change remote state (e.g. `gh release create`).

## Always

- Stay inside the project root given in the prompt.
- Respect `AGENTS.md` if present.
- Respect `Allowed Changes` / `Forbidden Changes` from the Task.
- Keep `.agent/current/TASK.md`, `TASK_QUEUE.json` and other supervisors'
  artifacts out of your edit set - they belong to the Supervisor.
- Prefer reversible, small, reviewable diffs.
- Report honestly: if verification did not pass, say so; do not claim success.

## Escalation instead of guessing

If a safety boundary blocks the Task, write `ESCALATION.md` with the exact
permission or decision needed. Do not work around the boundary.
