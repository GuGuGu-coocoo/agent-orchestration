# Reference · 参考手册 · Référence

**Languages:** [English](#english) · [简体中文](#简体中文) · [Français](#français)

---

## English

[← Back to README](../README.md#english) · [简体中文](reference.md#简体中文) · [Français](reference.md#français)

Every command, flag and exit code, plus the safety behaviours, model selection
and the known limitations of V1.

### Running a Phase

Codex plans the Phase (see `skills/phase-runner/SKILL.md`), then hands the whole
Phase to the loop **once**:

```sh
cd /path/to/target-project

~/.agents/skills/phase-runner/scripts/run-phase.sh          # blocking
~/.agents/skills/phase-runner/scripts/run-phase.sh --dry-run  # print the plan only

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

#### Refusals and locking

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

#### Recording the Phase review and QA

```sh
~/.agents/skills/phase-runner/scripts/phase-gate.sh review-pass --summary "..."
~/.agents/skills/phase-runner/scripts/phase-gate.sh review-fail --reason "..."   # add corrective Tasks, continue
~/.agents/skills/phase-runner/scripts/phase-gate.sh qa-pass --note "..."         # after the human confirmed
~/.agents/skills/phase-runner/scripts/phase-gate.sh qa-fail --note "..."         # convert defects into Tasks
```

### Running a single Task (cheap-worker)

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

#### Helper scripts

```sh
~/.agents/skills/cheap-worker/scripts/status.sh              # read-only Phase + Task status
~/.agents/skills/cheap-worker/scripts/check-state.sh         # resume verdict
~/.agents/skills/cheap-worker/scripts/collect-result.sh --diff
~/.agents/skills/cheap-worker/scripts/archive-task.sh --yes --decision ACCEPT
```

### Model selection

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

### OpenCode Desktop observability

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

### Using with Codex (desktop app)

`phase-runner` is the Supervisor skill, so Codex needs it; `cheap-worker` stays
in `~/.agents/skills/` where the OpenCode worker picks it up (Codex never loads
it).

```sh
ln -sfn ~/.agents/skills/phase-runner ~/.codex/skills/phase-runner
```

Then in a new Codex conversation:

> Use $phase-runner to build to Phase C.
> My session name is `orchestration` (for background wake-up; omit it to use blocking mode).

#### Two handoff modes

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

### Known limitations (V1)

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
  natively. See [Platform support](../README.md#english).

### Development rules

- One Task = one coherent change with one verification story.
- The worker never edits its own TASK.md, the queue, or `RUN_STATE.json` (the
  evidence gate fails the Task if it does).
- Codex never reviews a Task result and never edits code inside the loop: a fix
  is a Task like any other.
- A Phase always ends at `awaiting_phase_review`; the human gate is not optional.
- Do not add databases, queues, daemons, dashboards, DAGs, parallel workers or
  recursive agents to V1.

---

## 简体中文

[← 返回 README](../README.md#简体中文) · [English](reference.md#english) · [Français](reference.md#français)

全部命令、选项与退出码，外加安全行为、模型选择，以及 V1 的已知限制。

### 运行一个 Phase

Codex 先规划 Phase（见 `skills/phase-runner/SKILL.md`），然后把整个 Phase
**一次性**交给循环：

```sh
cd /path/to/target-project

~/.agents/skills/phase-runner/scripts/run-phase.sh          # 阻塞
~/.agents/skills/phase-runner/scripts/run-phase.sh --dry-run  # 只打印计划

~/.agents/skills/cheap-worker/scripts/worker-notify.sh --phase --codex-thread "orchestration"
```

| 退出码 | 含义 |
| --- | --- |
| 0 | Phase 进入 `awaiting_phase_review`（停止：等 Codex review） |
| 1 | 调用非法、计划非法，或状态闸门拒绝 |
| 2 | 停在 checkpoint（需要 Codex 决策） |
| 3 | 停在 escalation（被阻塞） |
| 4 | 拒绝运行：Phase 正处于某个闸门（`awaiting_phase_review` / `awaiting_human_qa`） |
| 5 | 在循环开始前就拒绝（有活跃 worker/loop、状态不一致），或停在状态不一致/管道故障 —— **拒绝永不改动任何文件** |

选项：

| 选项 | 作用 |
| --- | --- |
| `--root DIR` | 对另一个项目根目录操作 |
| `--max-tasks N` | 本次调用最多执行多少个 Task（安全上限） |
| `--dry-run` | 只做校验并打印计划，然后停止 |
| `--no-check-state` | 跳过 `check-state.sh` 预检（专家用法） |
| `--break-lock` | 由人显式确认"确实没有东西在跑"；授权恢复**两把**过期锁（循环的 `.phase.lock` 和过期的 `.worker.lock`，后者会转发给 `run-worker.sh`） |

#### 拒绝与加锁

在触碰任何东西之前，循环会（1）只读地校验计划与状态，（2）拒绝活跃的**或无法证明
已死**的 worker 锁，（3）询问 `check-state.sh` 是否有 worker 或另一个循环在运行 ——
**拒绝会让整个 `.agent/` 目录树保持逐字节不变**（不写 `RUN_STATE.json`、不重写
`TASK.md`、不产生新日志）——（4）获取自己的 `.phase.lock`，只有在这之后，才会修复
缺失/模板化的 `TASK.md`，或隔离另一个 Task 遗留的报告。

没有活跃 pid 的锁**绝不会**被假定为已死：共享服务里的执行可能比本地 wrapper 活得更
久。请自行确认（`check-state.sh` 判定为 `STALE_LOCK`、再看 `ps`），然后才传
`--break-lock`；`run-worker.sh` 会在启动前把过期锁移到
`.agent/history/attempts/stale-locks/`。活跃 pid 永远优先 —— `--break-lock` 无法
覆盖它。

`--break-lock` **只**授权锁的恢复。它绝不绕过状态校验：当 `check-state.sh` 报告
`INCONSISTENT`（`current/STATE.json` 非法、报告互相冲突等）时，无论有没有这个标志，
运行都会在任何写入之前被拒绝；只有 pre-flight 自己能修复的 TASK/报告身份问题才会走
reconciliation，而且之后会重新校验。

#### 记录 Phase review 与人工 QA

```sh
~/.agents/skills/phase-runner/scripts/phase-gate.sh review-pass --summary "..."
~/.agents/skills/phase-runner/scripts/phase-gate.sh review-fail --reason "..."   # 追加修正 Tasks，继续
~/.agents/skills/phase-runner/scripts/phase-gate.sh qa-pass --note "..."         # 人确认之后
~/.agents/skills/phase-runner/scripts/phase-gate.sh qa-fail --note "..."         # 把缺陷转成 Tasks
```

### 运行单个 Task（cheap-worker）

循环会自动驱动它；你也可以手动跑一个 Task：

```sh
cd /path/to/target-project
~/.agents/skills/cheap-worker/scripts/doctor.sh
~/.agents/skills/cheap-worker/scripts/run-worker.sh --mode implement --title "Add retry queue"
```

`--title` 可选；session 标题会变成 `cheap-worker · <task-id> · <title>`。

| 退出码 | 含义 |
| --- | --- |
| 0 | 本次运行产生了全新且合法的 `RESULT.md` |
| 5 | `RESULT.md` 合法但 opencode 非零退出（验收前请复核） |
| 10 | 合法的 `ESCALATION.md`（`## Class`：CHECKPOINT 或 ESCALATE） |
| 1 | 前置条件失败（TASK.md 缺失/非法/不一致；工作区脏且没给 `--allow-dirty`） |
| 2 | opencode 失败且未写任何报告 |
| 3 | opencode 结束但未写任何报告 |
| 4 | 两份报告都合法（互相矛盾） |
| 6 | 报告过期、格式错误，或属于另一个 Task |
| 7 | 已有另一个 worker（或其残留进程）在运行 |
| 8 | 无法证明过期锁已死；确认后用 `--break-lock` 重跑 |

每次运行的安全行为：

- 项目级锁（`.agent/current/.worker.lock`）同时记录 **wrapper pid 与 worker pid**，
  拒绝第二个 worker（`7`），并且**绝不自动接管过期锁**：确认没有东西在跑之后再用
  `--break-lock`（`8`）。被取消的运行（Ctrl-C / SIGTERM）会尝试停止它的 worker
  （TERM 加最多约 10 秒等待），并且**永远保留这把锁**。
- 上一次的 `RESULT.md`/`ESCALATION.md`/`VERIFY.md`/`BASELINE.*` 会被隔离到
  `.agent/history/attempts/<task>/`，因此过期报告永远不会被误认成本次输出
- `TASK.md` 必须包含必需章节且内容真实（`- <...>` 这类列表占位符视为缺失）；
  `--task-id`/`--mode` 必须与文件一致；`REVIEW.md` 必须带同一个 Task ID
- `--allow-dirty` 会把运行前的已跟踪/已暂存/未跟踪状态记入
  `.agent/current/BASELINE.md`，并把 `git diff HEAD --binary` 存入 `BASELINE.patch`
- 无论从哪里调用，opencode 始终以项目根目录为 `cwd` 运行

#### 辅助脚本

```sh
~/.agents/skills/cheap-worker/scripts/status.sh              # 只读的 Phase + Task 状态
~/.agents/skills/cheap-worker/scripts/check-state.sh         # 续跑判定
~/.agents/skills/cheap-worker/scripts/collect-result.sh --diff
~/.agents/skills/cheap-worker/scripts/archive-task.sh --yes --decision ACCEPT
```

### 模型选择

V1 **没有自己的模型层**。`run-worker.sh` 和 `run-phase.sh` 都不传 `--model`；worker
使用 OpenCode 自身配置选出的模型：

- 全局配置：`~/.config/opencode/opencode.json` -> `"model"`
- 或 OpenCode Desktop / TUI 的模型选择器（各 session 可以不同）

没有回退、没有路由、没有项目级模型配置、没有自动切换 —— 这是刻意设计的。用
`opencode models` 查看可用模型 ID。想让它想得更久，可以在同一份配置里设置模型自己的
effort，例如：

```jsonc
{
  "providers": {
    "opencode-go": {
      "models": { "deepseek-v4.1-flash": { "settings": { "reasoningEffort": "max" } } }
    }
  }
}
```

### OpenCode Desktop 可观测性

每个 Task 都是**共享后台服务**上的一个普通 OpenCode session，所以你可以在 OpenCode
Desktop 里观看：

- 一个 Task = 一个 session，标题为 `cheap-worker · C01 · Add retry queue`。
- session 里能看到模型输出、Read / Search / Edit / Bash / 测试步骤以及最终报告，和
  实际发生的过程完全一致。
- 两个脚本都不会启动私有服务（不使用 `--standalone`），所以这就是 Desktop 已经看到的
  那个 session。
- `status.sh` 会打印记录在 `.agent/current/STATE.json` 里的 session id。
- 没有单独的 dashboard、日志 UI 或监控组件需要维护。

用 `opencode service status` 检查服务（`doctor.sh` 会替你检查）。

### 配合 Codex（桌面应用）使用

`phase-runner` 是 Supervisor skill，所以 Codex 需要它；`cheap-worker` 留在
`~/.agents/skills/` 供 OpenCode worker 取用（Codex 从不加载它）。

```sh
ln -sfn ~/.agents/skills/phase-runner ~/.codex/skills/phase-runner
```

然后在一个新的 Codex 对话里：

> 用 $phase-runner 做到 Phase C。
> 我的会话名是 `orchestration`（用于后台唤醒；不写就用 blocking 模式）。

#### 两种交接模式

| 模式 | 命令 | Codex 行为 | 适用场景 |
| --- | --- | --- | --- |
| 阻塞 | `run-phase.sh` | 在回合内等待，随后做 Phase review | 默认；始终可用 |
| 后台 + 唤醒 | `worker-notify.sh --phase --codex-thread <id-or-name>` | 立即返回并结束回合；循环**停止**时由 `codex queue` 唤醒该 session | 你想离开机器，且已知目标 session |

无论哪种模式，整个 Phase **只交接一次**：绝不要每个 Task 跑一次循环，也绝不要在循环
运行时轮询 `status.sh` / `check-state.sh`（`--max-tasks N` 是安全上限，不是节奏）。
运行中的循环会一直回答 `WORKER_RUNNING` 直到停止，而通知器每次停止只唤醒 Supervisor
一次。

唤醒细节：

- 目标必须**精确**：`--codex-thread <id-or-name>`，或调用方运行时提供的
  `CODEX_THREAD_ID`。**绝不从本地历史猜测**；没有目标时该工具会 fail closed
  （`exit 14`），改用阻塞模式。
- Codex **每次停止只被唤醒一次**，而不是每个 Task 一次：phase review、checkpoint、
  escalation 或管道停止。
- `exit 15` 表示循环已结束但唤醒未能送达：消息保留在
  `.agent/current/NOTIFY_FAILED.md`。
- 需要 ChatGPT/Codex 桌面应用保持打开，且**目标 session 处于打开状态**。循环运行
  期间，该工具会持有一个 `caffeinate -i` 断言（因此它无法阻止合盖休眠）。

### 已知限制（V1）

- 模型选择完全归 OpenCode：如果配置的默认模型很慢、被限流或不可达，worker 会以管道
  错误失败，循环停在 checkpoint。没有回退，也没有路由器。
- Supervisor 就是当前的 Codex/Astra session；没有独立的编排守护进程。唤醒模式要求
  ChatGPT/Codex 桌面应用保持打开，且编排 session 处于打开状态。
- `run-worker.sh` 没有内置的墙钟超时（OpenCode 自身的行为与调用方超时生效）。
  `worker-notify.sh` 通过脱离前台解决了超时问题，但无法阻止合盖休眠或手动关机。
- 报告是模型写的 Markdown，可能是错的。重跑的验证、diff 作用域与 diff 本身才是证据。
- worker 提示词内嵌了契约，所以 worker 不需要读取 skill 目录（OpenCode 的
  `external_directory` 权限默认是 `ask`）。
- 验证命令来自队列，并通过 `bash -c` 在项目根目录运行：它们必须非交互、确定性，并且
  足够快。
- 安装器的 `rsync --delete` 镜像模式假定目标目录完全由本项目托管。`--target` 仅供
  测试使用。
- 兼容 bash 3.2（macOS）并在 Linux 上经 CI 测试；原生不支持 Windows。见
  [平台支持](../README.md#简体中文)。

### 开发规则

- 一个 Task = 一个内聚的改动，配一套验证说明。
- worker 绝不编辑自己的 TASK.md、队列或 `RUN_STATE.json`（一旦这么做，证据闸门会让
  该 Task 失败）。
- Codex 绝不 review 单个 Task 的结果，也绝不在循环内部改代码：修复就是另一个 Task。
- 一个 Phase 总是结束于 `awaiting_phase_review`；人工闸门不可省略。
- 不要给 V1 引入数据库、队列、守护进程、dashboard、DAG、并行 worker 或递归 agent。

---

## Français

[← Retour au README](../README.md#français) · [English](reference.md#english) · [简体中文](reference.md#简体中文)

Toutes les commandes, options et codes de sortie, plus les comportements de
sécurité, le choix du modèle et les limites connues de la V1.

### Lancer une Phase

Codex planifie la Phase (voir `skills/phase-runner/SKILL.md`), puis confie toute
la Phase à la boucle **une seule fois** :

```sh
cd /path/to/target-project

~/.agents/skills/phase-runner/scripts/run-phase.sh          # bloquant
~/.agents/skills/phase-runner/scripts/run-phase.sh --dry-run  # affiche seulement le plan

~/.agents/skills/cheap-worker/scripts/worker-notify.sh --phase --codex-thread "orchestration"
```

| Code | Signification |
| --- | --- |
| 0 | la Phase a atteint `awaiting_phase_review` (ARRÊT : revue Codex) |
| 1 | invocation invalide, plan invalide, ou une porte d'état a refusé |
| 2 | arrêt sur un checkpoint (décision Codex requise) |
| 3 | arrêt sur une escalade (bloqué) |
| 4 | refus : la Phase est à une porte (`awaiting_phase_review` / `awaiting_human_qa`) |
| 5 | refus avant le démarrage de la boucle (worker/boucle vivant, état incohérent) ou arrêt sur un état incohérent/défaillance d'infrastructure — un **refus ne modifie jamais aucun fichier** |

Options :

| Option | Effet |
| --- | --- |
| `--root DIR` | opérer sur une autre racine de projet |
| `--max-tasks N` | plafond de sécurité du nombre de Tâches pour cette invocation |
| `--dry-run` | valider et afficher le plan, puis s'arrêter |
| `--no-check-state` | ignorer le pré-vol `check-state.sh` (usage expert) |
| `--break-lock` | la confirmation humaine explicite que rien ne tourne ; autorise la récupération des **deux** verrous périmés (le `.phase.lock` de la boucle et un `.worker.lock` périmé, transmis à `run-worker.sh`) |

#### Refus et verrouillage

Avant de toucher quoi que ce soit, la boucle (1) valide le plan et l'état en
lecture seule, (2) refuse un verrou de worker vivant **ou dont le caractère
périmé n'est pas prouvable**, (3) demande à `check-state.sh` si un worker ou une
autre boucle est en cours — **un refus laisse tout l'arbre `.agent/` identique
octet pour octet** (aucune écriture de `RUN_STATE.json`, aucune réécriture de
`TASK.md`, aucun nouveau journal) — (4) prend son propre `.phase.lock`, et
seulement ensuite répare un `TASK.md` manquant ou resté au gabarit, ou met en
quarantaine un rapport laissé par une autre Tâche.

Un verrou sans pid vivant n'est jamais présumé mort : une exécution dans le
service partagé peut survivre à son wrapper local. Vérifiez vous-même (verdict
`STALE_LOCK` de `check-state.sh`, puis `ps`), et alors seulement passez
`--break-lock` ; `run-worker.sh` déplace le verrou périmé vers
`.agent/history/attempts/stale-locks/` avant de démarrer. Un pid vivant gagne
toujours — `--break-lock` ne le remplace jamais.

`--break-lock` autorise **uniquement** la récupération du verrou. Il ne
contourne jamais la validation d'état : quand `check-state.sh` signale
`INCONSISTENT` (un `current/STATE.json` invalide, des rapports contradictoires,
...), l'exécution est refusée avant toute écriture, avec ou sans ce drapeau ;
seuls les problèmes d'identité Tâche/rapport que le pré-vol peut réparer lui-même
passent par la réconciliation, et ils sont revérifiés ensuite.

#### Enregistrer la revue de Phase et la QA

```sh
~/.agents/skills/phase-runner/scripts/phase-gate.sh review-pass --summary "..."
~/.agents/skills/phase-runner/scripts/phase-gate.sh review-fail --reason "..."   # ajoute des Tâches correctives, continue
~/.agents/skills/phase-runner/scripts/phase-gate.sh qa-pass --note "..."         # après confirmation humaine
~/.agents/skills/phase-runner/scripts/phase-gate.sh qa-fail --note "..."         # convertit les défauts en Tâches
```

### Lancer une seule Tâche (cheap-worker)

La boucle le pilote automatiquement ; vous pouvez aussi lancer une Tâche à la
main :

```sh
cd /path/to/target-project
~/.agents/skills/cheap-worker/scripts/doctor.sh
~/.agents/skills/cheap-worker/scripts/run-worker.sh --mode implement --title "Add retry queue"
```

`--title` est facultatif ; le titre de session devient
`cheap-worker · <task-id> · <title>`.

| Code | Signification |
| --- | --- |
| 0 | `RESULT.md` frais et valide, produit par cette exécution |
| 5 | `RESULT.md` valide mais opencode s'est terminé avec un code non nul (à relire avant d'accepter) |
| 10 | `ESCALATION.md` valide (`## Class` : CHECKPOINT ou ESCALATE) |
| 1 | échec d'une précondition (TASK.md manquant/invalide/incohérent, arbre modifié sans `--allow-dirty`) |
| 2 | opencode a échoué et n'a écrit aucun rapport |
| 3 | opencode s'est terminé mais n'a écrit aucun rapport |
| 4 | les deux rapports sont valides (incohérent) |
| 6 | le rapport est périmé, malformé, ou concerne une autre Tâche |
| 7 | un autre worker (ou un processus worker survivant) tourne déjà |
| 8 | le verrou périmé n'a pas pu être prouvé mort ; relancez avec `--break-lock` après vérification |

Comportements de sécurité à chaque exécution :

- un verrou au niveau du projet (`.agent/current/.worker.lock`) enregistre **à la
  fois le pid du wrapper et celui du worker**, refuse un second worker (`7`), et
  **ne reprend jamais automatiquement un verrou périmé** : utilisez
  `--break-lock` après avoir vérifié que rien ne tourne (`8`). Une exécution
  annulée (Ctrl-C / SIGTERM) tente d'arrêter son worker (TERM plus jusqu'à
  environ 10 s d'attente) et **garde toujours le verrou**.
- les `RESULT.md`/`ESCALATION.md`/`VERIFY.md`/`BASELINE.*` précédents sont mis en
  quarantaine dans `.agent/history/attempts/<task>/`, afin qu'un rapport périmé
  ne puisse jamais être pris pour la sortie de cette exécution
- `TASK.md` doit contenir les sections requises avec un contenu réel (les gabarits
  de liste comme `- <...>` comptent comme manquants) ; `--task-id`/`--mode`
  doivent correspondre au fichier ; un `REVIEW.md` doit porter le même
  identifiant de Tâche
- `--allow-dirty` enregistre l'état suivi/indexé/non suivi d'avant l'exécution
  dans `.agent/current/BASELINE.md`, plus `git diff HEAD --binary` dans
  `BASELINE.patch`
- opencode s'exécute toujours avec `cwd` = racine du projet, même invoqué ailleurs

#### Scripts utilitaires

```sh
~/.agents/skills/cheap-worker/scripts/status.sh              # état Phase + Tâche en lecture seule
~/.agents/skills/cheap-worker/scripts/check-state.sh         # verdict de reprise
~/.agents/skills/cheap-worker/scripts/collect-result.sh --diff
~/.agents/skills/cheap-worker/scripts/archive-task.sh --yes --decision ACCEPT
```

### Choix du modèle

La V1 n'a **aucune couche de modèle qui lui soit propre**. Ni `run-worker.sh` ni
`run-phase.sh` ne passent `--model` ; le worker utilise ce que la configuration
d'OpenCode sélectionne :

- Configuration globale : `~/.config/opencode/opencode.json` -> `"model"`
- Ou le sélecteur de modèle d'OpenCode Desktop / du TUI (les sessions peuvent différer)

Il n'y a ni repli, ni routeur, ni configuration de modèle au niveau projet, ni
bascule automatique — c'est délibéré. Vérifiez les identifiants de modèle
disponibles avec `opencode models`. Pour qu'il réfléchisse davantage, réglez
l'effort du modèle dans la même configuration, par exemple :

```jsonc
{
  "providers": {
    "opencode-go": {
      "models": { "deepseek-v4.1-flash": { "settings": { "reasoningEffort": "max" } } }
    }
  }
}
```

### Observabilité dans OpenCode Desktop

Chaque Tâche est une session OpenCode normale sur le **service d'arrière-plan
partagé**, donc vous pouvez la regarder dans OpenCode Desktop :

- Une Tâche = une session, titrée `cheap-worker · C01 · Add retry queue`.
- La session montre la sortie du modèle, les étapes Read / Search / Edit / Bash /
  tests et le rapport final, exactement comme cela s'est produit.
- Aucun des deux scripts ne démarre de serveur privé (`--standalone` n'est pas
  utilisé), donc c'est bien la session que Desktop voit déjà.
- `status.sh` affiche l'identifiant de session enregistré dans
  `.agent/current/STATE.json`.
- Il n'y a aucun tableau de bord, aucune UI de journaux, aucun composant de
  supervision à maintenir.

Vérifiez le service avec `opencode service status` (le script `doctor.sh` s'en
charge pour vous).

### Utilisation avec Codex (application de bureau)

`phase-runner` est le skill du Supervisor, donc Codex en a besoin ; `cheap-worker`
reste dans `~/.agents/skills/` où le worker OpenCode le récupère (Codex ne le
charge jamais).

```sh
ln -sfn ~/.agents/skills/phase-runner ~/.codex/skills/phase-runner
```

Puis dans une nouvelle conversation Codex :

> Utilise $phase-runner pour construire jusqu'à la Phase C.
> Le nom de ma session est `orchestration` (pour le réveil en arrière-plan ; omets-le pour le mode bloquant).

#### Deux modes de passation

| Mode | Commande | Comportement de Codex | Quand l'utiliser |
| --- | --- | --- | --- |
| Bloquant | `run-phase.sh` | attend dans le tour, puis fait la revue de Phase | par défaut ; toujours disponible |
| Arrière-plan + réveil | `worker-notify.sh --phase --codex-thread <id-or-name>` | rend la main immédiatement et termine le tour ; `codex queue` réveille cette session quand la boucle **s'arrête** | vous voulez quitter la machine et une session cible est connue |

Quel que soit le mode, c'est **une seule passation pour toute la Phase** : ne
lancez jamais la boucle une fois par Tâche et ne sondez jamais `status.sh` /
`check-state.sh` pendant qu'elle tourne (`--max-tasks N` est un plafond de
sécurité, pas un rythme). Une boucle en cours répond `WORKER_RUNNING` jusqu'à son
arrêt, et le notificateur réveille le Supervisor exactement une fois par arrêt.

Détails du réveil :

- La cible doit être **exacte** : `--codex-thread <id-or-name>`, ou
  `CODEX_THREAD_ID` quand le runtime appelant le fournit. Il n'y a **aucune
  devinette à partir de l'historique local** ; sans cible, l'outil échoue de
  façon sûre (`exit 14`) et le mode bloquant est utilisé.
- Codex est réveillé **une fois par arrêt**, pas une fois par Tâche : revue de
  Phase, checkpoint, escalade ou arrêt d'infrastructure.
- `exit 15` signifie que la boucle s'est terminée mais que le réveil n'a pas pu
  être délivré : le message est conservé dans `.agent/current/NOTIFY_FAILED.md`.
- Nécessite que l'application de bureau ChatGPT/Codex reste ouverte **avec la
  session cible ouverte**. Pendant que la boucle tourne, l'outil maintient une
  assertion `caffeinate -i` (il ne peut donc pas empêcher la veille à la
  fermeture du capot).

### Limites connues (V1)

- Le choix du modèle appartient entièrement à OpenCode : si le modèle par défaut
  configuré est lent, limité en débit ou injoignable, le worker échoue avec une
  erreur d'infrastructure et la boucle s'arrête sur un checkpoint. Il n'y a ni
  repli ni routeur.
- Le Supervisor est la session Codex/Astra courante ; il n'y a pas de démon
  d'orchestration séparé. Le mode réveil exige que l'application de bureau
  ChatGPT/Codex reste ouverte avec la session d'orchestration ouverte.
- `run-worker.sh` n'a pas de délai maximal intégré (le comportement d'OpenCode et
  le délai de l'appelant s'appliquent). `worker-notify.sh` résout le problème du
  délai en se détachant, mais il ne peut pas empêcher la veille à la fermeture du
  capot ni un arrêt manuel.
- Les rapports sont du Markdown écrit par un modèle ; ils peuvent être faux. La
  vérification rejouée, la portée du diff et le diff lui-même sont les preuves.
- Le prompt du worker embarque le contrat, donc le worker n'a jamais besoin de
  lire le dossier du skill (la permission `external_directory` d'OpenCode vaut
  `ask` par défaut).
- Les commandes de vérification viennent de la file et s'exécutent via `bash -c`
  à la racine du projet : elles doivent être non interactives, déterministes et
  raisonnablement rapides.
- Le mode miroir `rsync --delete` de l'installateur suppose que le dossier cible
  est entièrement géré par ce projet. `--target` est réservé aux tests.
- Compatible bash 3.2 (macOS) et testé par la CI sur Linux ; Windows n'est pas
  pris en charge nativement. Voir
  [Support des plateformes](../README.md#français).

### Règles de développement

- Une Tâche = un changement cohérent avec une seule histoire de vérification.
- Le worker ne modifie jamais son propre TASK.md, la file, ni `RUN_STATE.json`
  (la porte de preuves fait échouer la Tâche s'il le fait).
- Codex ne révise jamais le résultat d'une Tâche et ne modifie jamais de code à
  l'intérieur de la boucle : une correction est une Tâche comme une autre.
- Une Phase se termine toujours à `awaiting_phase_review` ; la porte humaine n'est
  pas facultative.
- N'ajoutez pas à la V1 de bases de données, files d'attente, démons, tableaux de
  bord, DAG, workers parallèles ou agents récursifs.
