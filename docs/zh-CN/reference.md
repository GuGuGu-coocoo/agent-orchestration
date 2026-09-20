# 参考手册

[← 返回 README](../../README.zh-CN.md) · [English](../en/reference.md) · [Français](../fr/reference.md)

全部命令、选项与退出码，外加安全行为、模型选择，以及 V1 的已知限制。

## 运行一个 Phase

Codex 先规划 Phase（见 `skills/phase-runner/SKILL.md`），然后把整个 Phase
**一次性**交给循环：

```sh
cd /path/to/target-project

~/.agents/skills/phase-runner/scripts/run-phase.sh          # 阻塞
~/.agents/skills/phase-runner/scripts/run-phase.sh --dry-run  # 只打印计划

# 后台运行 + 仅当循环“停止”时唤醒 Codex（phase review / checkpoint / escalation）
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

### 拒绝与加锁

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

### 记录 Phase review 与人工 QA

```sh
~/.agents/skills/phase-runner/scripts/phase-gate.sh review-pass --summary "..."
~/.agents/skills/phase-runner/scripts/phase-gate.sh review-fail --reason "..."   # 追加修正 Tasks，继续
~/.agents/skills/phase-runner/scripts/phase-gate.sh qa-pass --note "..."         # 人确认之后
~/.agents/skills/phase-runner/scripts/phase-gate.sh qa-fail --note "..."         # 把缺陷转成 Tasks
```

## 运行单个 Task（cheap-worker）

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

### 辅助脚本

```sh
~/.agents/skills/cheap-worker/scripts/status.sh              # 只读的 Phase + Task 状态
~/.agents/skills/cheap-worker/scripts/check-state.sh         # 续跑判定
~/.agents/skills/cheap-worker/scripts/collect-result.sh --diff
~/.agents/skills/cheap-worker/scripts/archive-task.sh --yes --decision ACCEPT
```

## 模型选择

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

## OpenCode Desktop 可观测性

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

## 配合 Codex（桌面应用）使用

`phase-runner` 是 Supervisor skill，所以 Codex 需要它；`cheap-worker` 留在
`~/.agents/skills/` 供 OpenCode worker 取用（Codex 从不加载它）。

```sh
ln -sfn ~/.agents/skills/phase-runner ~/.codex/skills/phase-runner
```

然后在一个新的 Codex 对话里：

> 用 $phase-runner 做到 Phase C。
> 我的会话名是 `orchestration`（用于后台唤醒；不写就用 blocking 模式）。

### 两种交接模式

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

## 已知限制（V1）

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
  [平台支持](../../README.zh-CN.md#平台支持)。

## 开发规则

- 一个 Task = 一个内聚的改动，配一套验证说明。
- worker 绝不编辑自己的 TASK.md、队列或 `RUN_STATE.json`（一旦这么做，证据闸门会让
  该 Task 失败）。
- Codex 绝不 review 单个 Task 的结果，也绝不在循环内部改代码：修复就是另一个 Task。
- 一个 Phase 总是结束于 `awaiting_phase_review`；人工闸门不可省略。
- 不要给 V1 引入数据库、队列、守护进程、dashboard、DAG、并行 worker 或递归 agent。
