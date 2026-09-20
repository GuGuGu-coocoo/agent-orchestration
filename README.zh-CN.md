[English](README.md) | **简体中文** | [Français](README.fr.md)

# agent-orchestration

[![CI](https://github.com/GuGuGu-coocoo/agent-orchestration/actions/workflows/ci.yml/badge.svg)](https://github.com/GuGuGu-coocoo/agent-orchestration/actions/workflows/ci.yml)

跨项目、全局安装的 Agent 编排 Skills，三层工作流：**OpenCode 负责 Task
级的执行与验证，Codex 在 Phase 级监督**：

```
Human          -> 产品意图、roadmap 确认、人工 QA
Codex/Astra    -> 需求、架构、roadmap、Phase 规划、
                  Phase 级 review、升级处理、人工 QA 决策
OpenCode loop  -> 执行 Phase 内的 bounded Tasks，一个 Task 一个 session，
                  自行验证，自动继续，遇险停止
```

这里维护两个 OpenCode skill，安装到 `~/.agents/skills/`：

| Skill | 职责 | 安装位置 |
| --- | --- | --- |
| `cheap-worker` | 执行单个 Task，写 RESULT/ESCALATION | `~/.agents/skills/cheap-worker` |
| `phase-runner` | Phase 循环 + Codex 执行单个 Phase 的 playbook | `~/.agents/skills/phase-runner` |

最重要的一条规则：**worker 从不规划 Phase，Codex 从不 review 单个 Task。**
Codex 把 Phase 一次性规划成 `TASK_QUEUE.json`；循环（`run-phase.sh`）执行它，
并用确定性的证据闸门逐个验收 Task。

## 架构

```
roadmap
  -> Codex (phase-runner)：把 Phase 规划一次
       PHASE.md + TASK_QUEUE.json   （bounded Tasks、风险等级、验证方式）
  -> OpenCode phase 循环（run-phase.sh），一个 Task = 一个 OpenCode session：
       渲染 TASK.md -> worker 实现 + 自验证 -> 证据闸门
         闸门 = RESULT.md DONE + 验收标准已勾选
                + 必需的验证命令重跑通过
                + diff 在 Allowed Changes 范围内
                + Supervisor 产物未被改动
       通过  -> 归档、标记 done、自动进入下一个 Task
       停止  -> checkpoint | escalate | guarded Task review
  -> awaiting_phase_review   （停止：Codex 做 Phase 级集成 review）
  -> awaiting_human_qa       （停止：由人决定）
  -> 下一个 Phase 是一个全新的、深思熟虑的决定
```

断点续跑的依据是**文件，而不是聊天记录**。每个 Task 都是共享后台服务上的一个
OpenCode session，因此循环运行时人可以在 OpenCode Desktop 里实时观看。

## 仓库结构

```
agent-orchestration/
├── README.md  README.zh-CN.md  README.fr.md
├── .gitignore
├── scripts/
│   ├── install-skills.sh              # 安装/更新这两个受管 skill
│   └── uninstall-managed-skills.sh    # 只删除这两个受管 skill
├── skills/
│   ├── cheap-worker/
│   │   ├── SKILL.md
│   │   ├── scripts/
│   │   │   ├── doctor.sh              # 环境健康检查
│   │   │   ├── run-worker.sh          # 只执行一个 Task（阻塞）
│   │   │   ├── worker-notify.sh       # 后台执行一个 Task 或整个 Phase，并唤醒 Codex
│   │   │   ├── status.sh              # 只读状态（Phase + Task）
│   │   │   ├── check-state.sh         # 续跑判定 / 一致性检查
│   │   │   ├── collect-result.sh      # 打印 RESULT/ESCALATION + VERIFY 证据
│   │   │   └── archive-task.sh        # 把已完成的 Task 产物移入 history
│   │   ├── references/
│   │   │   ├── worker-contract.md     # worker 契约与报告格式（规范性）
│   │   │   ├── worker-prompt.md       # run-worker.sh 使用的提示词模板
│   │   │   ├── escalation-policy.md   # CHECKPOINT 与 ESCALATE 的区别、何时停止
│   │   │   └── safety-policy.md       # 默认安全边界
│   │   └── assets/templates/
│   │       ├── TASK.md  RESULT.md  ESCALATION.md  STATE.json
│   └── phase-runner/
│       ├── SKILL.md                   # Codex 执行单个 Phase 的 playbook
│       ├── scripts/
│       │   ├── run-phase.sh           # 核心循环：逐个 Task，证据闸门
│       │   └── phase-gate.sh          # Phase review / 人工 QA 闸门记录器
│       ├── references/
│       │   ├── phase-planning.md      # 把 Phase 拆成可运行的 Tasks
│       │   ├── phase-review.md        # Phase 级集成 review
│       │   ├── checkpoint-handling.md # 处理 checkpoint / escalation 停止
│       │   ├── roadmap-policy.md      # 找到并尊重 roadmap
│       │   └── human-checkpoint.md    # 停下并等待人工
│       └── assets/templates/
│           ├── PHASE.md  TASK_QUEUE.json  RUN_STATE.json
└── tests/smoke/                       # 临时仓库测试，绝不触碰用户项目
```

## 依赖要求

| 依赖 | 用途 | 说明 |
| --- | --- | --- |
| [OpenCode](https://opencode.ai) v2（`opencode`） | 执行 Task：每个 Task 在共享后台服务上一个 session | 必须在 `PATH` 上且已认证 |
| `git` | baseline、diff 与作用域检查 | 每个目标项目都是仓库 |
| `jq` | 所有状态文件都用它读写 | 必需，无回退 |
| `bash` | 全部脚本 | 兼容 bash 3.2+；macOS 自带 bash 可用 |
| `python3` | Python 项目的验证命令 | 可选 |
| Codex 桌面应用 | 后台交接与唤醒（`worker-notify.sh`） | 可选；阻塞模式不需要 Codex |

### 平台支持

| 平台 | 状态 |
| --- | --- |
| macOS | 在本平台开发并测试（系统自带 bash 3.2） |
| Linux | CI 覆盖（`ubuntu-latest`，bash 5） |
| Windows | 原生不支持。请用 WSL —— 理论上可用，但未经验证。不支持原生 Git Bash：其进程存活检测（`kill -0`）与信号处理不可靠。 |

脚本在 GNU 与 BSD 存在差异之处都避开了单平台专属用法（`stat`、
`shasum` 与 `sha256sum`、`sed -i`），所以同一份代码可在 macOS 和 Linux 上运行。

## 安装

```sh
./scripts/install-skills.sh --dry-run      # 预览
./scripts/install-skills.sh                # 安装/更新
./scripts/install-skills.sh --force        # 连未标记的同名目录也替换（替换前先备份）
```

安装器只会把 `skills/cheap-worker` 和 `skills/phase-runner` 同步到
`~/.agents/skills/`。它不读取、不移动、不删除任何其他 skill。它是幂等的，安装后
会校验 `SKILL.md`，并在每个受管目录写入 `.installed-by-agent-orchestration`
标记文件。

## 卸载

```sh
./scripts/uninstall-managed-skills.sh --dry-run
./scripts/uninstall-managed-skills.sh --yes
```

只接受字面路径、必须显式确认、除非加 `--force` 否则拒绝处理未标记目录，且永远
不会删除 `~/.agents/skills` 本身。如果你把 skill 链接进了 Codex，也要删掉那个
链接：

```sh
rm ~/.codex/skills/phase-runner
```

## 运行一个 Phase

Codex 先规划 Phase（见 `skills/phase-runner/SKILL.md`），然后把整个 Phase
**一次性**交给循环：

```sh
cd /path/to/target-project

~/.agents/skills/phase-runner/scripts/run-phase.sh          # 阻塞
~/.agents/skills/phase-runner/scripts/run-phase.sh --dry-run  # 只打印计划

# 后台运行 + 仅当循环“停止”时唤醒 Codex（phase review / checkpoint / escalation）
~/.agents/skills/cheap-worker/scripts/worker-notify.sh --phase --codex-thread "编排"
```

`run-phase.sh` 退出码：

| 退出码 | 含义 |
| --- | --- |
| 0 | Phase 进入 `awaiting_phase_review`（停止：等 Codex review） |
| 1 | 调用非法、计划非法，或状态闸门拒绝 |
| 2 | 停在 checkpoint（需要 Codex 决策） |
| 3 | 停在 escalation（被阻塞） |
| 4 | 拒绝运行：Phase 正处于某个闸门（`awaiting_phase_review` / `awaiting_human_qa`） |
| 5 | 在循环开始前就拒绝（有活跃 worker/loop、状态不一致），或停在状态不一致/管道故障 —— **拒绝永不改动任何文件** |

选项：`--root DIR`、`--max-tasks N`（安全上限）、`--dry-run`、
`--no-check-state`、`--break-lock`（由人显式确认"确实没有东西在跑"：它授权恢复
**两把**过期锁 —— 循环自己的 `.phase.lock` 和过期的 `.worker.lock`，后者会转发给
`run-worker.sh`）。

在触碰任何东西之前，循环会（1）只读地校验计划与状态，（2）拒绝活跃的**或无法证明
已死**的 worker 锁，（3）询问 `check-state.sh` 是否有 worker 或另一个循环在运行 ——
**拒绝会让整个 `.agent/` 目录树保持逐字节不变**（不写 `RUN_STATE.json`、不重写
`TASK.md`、不产生新日志）——（4）获取自己的 `.phase.lock`，只有在这之后，才会修复
缺失/模板化的 `TASK.md`，或隔离另一个 Task 遗留的报告。

没有活跃 pid 的锁**绝不会**被假定为已死：共享服务里的执行可能比本地 wrapper 活得
更久。请自行确认（`check-state.sh` 判定为 `STALE_LOCK`、再看 `ps`），然后才传
`--break-lock`；`run-worker.sh` 会在启动前把过期锁移到
`.agent/history/attempts/stale-locks/`。活跃 pid 永远优先 —— `--break-lock`
无法覆盖它。

`--break-lock` **只**授权锁的恢复。它绝不绕过状态校验：当 `check-state.sh` 报告
`INCONSISTENT`（`current/STATE.json` 非法、报告互相冲突等）时，无论有没有这个
标志，运行都会在任何写入之前被拒绝；只有 pre-flight 自己能修复的 TASK/报告身份
问题才会走 reconciliation，而且之后会重新校验。

Phase review 通过下面的方式记录：

```sh
~/.agents/skills/phase-runner/scripts/phase-gate.sh review-pass --summary "..."
~/.agents/skills/phase-runner/scripts/phase-gate.sh review-fail --reason "..."   # 追加修正 Tasks，继续
~/.agents/skills/phase-runner/scripts/phase-gate.sh qa-pass --note "..."         # 人确认之后
~/.agents/skills/phase-runner/scripts/phase-gate.sh qa-fail --note "..."         # 把缺陷转成 Tasks
```

## 证据闸门（为什么 Codex 不逐个 review Task）

对每一个 Task，循环都会**自己、确定性地**重跑：

- `RESULT.md` 是本次运行产生的、属于这个 Task、`Status: DONE`、没有未勾选的验收标准；
- 队列里每条 `verification` 命令都会重跑并满足其期望（`exit 0`、`exit N`
  或 `contains:<text>`）；
- git 报告的每一个脏文件（已跟踪、已暂存、已删除、未跟踪）都会被指纹化 ——
  内容、文件权限与是否存在 —— 在 Task 前后各拍一次快照，然后逐个路径比对：
  因此**在 Task 开始时就已脏**的文件被再次修改也能抓到（不做任何减法）；
  `__pycache__`/`.pytest_cache` 之类的工具产物会被忽略；
- `TASK_QUEUE.json`、`RUN_STATE.json`、`PHASE.md` 与 `TASK.md` 没有被 worker 改动。

结论写入 `.agent/current/VERIFY.md`，并复制到
`.agent/phases/<P>/history/VERIFY-<task>.md`；通过则归档该 Task 并继续，
失败/任何停止都交给 Codex。worker 自称的 "DONE" 永远不够。

## cheap-worker 用法（单个 Task）

循环会自动驱动它；你也可以手动跑一个 Task：

```sh
cd /path/to/target-project
~/.agents/skills/cheap-worker/scripts/doctor.sh
~/.agents/skills/cheap-worker/scripts/run-worker.sh --mode implement --title "Add retry queue"
```

`--title` 可选；session 标题会变成 `cheap-worker · <task-id> · <title>`。
模型完全由 OpenCode 自身的配置决定 —— 脚本从不传 `--model`，也从不使用
`--standalone`。

`run-worker.sh` 退出码：

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

- 项目级锁（`.agent/current/.worker.lock`）同时记录 **wrapper pid 与 worker
  pid**，拒绝第二个 worker（`7`），并且**绝不自动接管过期锁**：确认没有东西在跑
  之后再用 `--break-lock`（`8`）。被取消的运行（Ctrl-C / SIGTERM）会尝试停止它的
  worker（TERM 加最多约 10 秒等待），并且**永远保留这把锁**。
- 上一次的 `RESULT.md`/`ESCALATION.md`/`VERIFY.md`/`BASELINE.*` 会被隔离到
  `.agent/history/attempts/<task>/`，因此过期报告永远不会被误认成本次输出
- `TASK.md` 必须包含必需章节且内容真实（`- <...>` 这类列表占位符视为缺失）；
  `--task-id`/`--mode` 必须与文件一致；`REVIEW.md` 必须带同一个 Task ID
- `--allow-dirty` 会把运行前的已跟踪/已暂存/未跟踪状态记入
  `.agent/current/BASELINE.md`，并把 `git diff HEAD --binary` 存入 `BASELINE.patch`
- 无论从哪里调用，opencode 始终以项目根目录为 `cwd` 运行

其他辅助脚本：

```sh
~/.agents/skills/cheap-worker/scripts/status.sh
~/.agents/skills/cheap-worker/scripts/check-state.sh    # 续跑判定
~/.agents/skills/cheap-worker/scripts/collect-result.sh --diff
~/.agents/skills/cheap-worker/scripts/archive-task.sh --yes --decision ACCEPT
```

## phase-runner 用法

安装之后，在 OpenCode/Codex session 里说类似这样的话：

> 用 $phase-runner 按现有 roadmap 开发到 Phase C。
> 你负责需求和 Phase planning，把 Phase 拆成 bounded Tasks 后交给 run-phase.sh 跑。
> 不要逐个 Task review；Phase 完成后做 integration review，然后停下等我人工测试。

Supervisor 随后遵循 `skills/phase-runner/SKILL.md`：需求接收、一次性规划、整个
Phase 只交接一次、处理 checkpoint/escalation 停止、Phase 级 review、人工检查点。
它从不在 Task 之间问"要继续吗"，也从不 review 单个 Task 的结果。

## 模型选择

V1 **没有自己的模型层**。`run-worker.sh` 和 `run-phase.sh` 都不传 `--model`；
worker 使用 OpenCode 自身配置选出的模型：

- 全局配置：`~/.config/opencode/opencode.json` -> `"model"`
- 或 OpenCode Desktop / TUI 的模型选择器（各 session 可以不同）

没有回退、没有路由、没有项目级模型配置、没有自动切换 —— 这是刻意设计的。用
`opencode models` 查看可用模型 ID。

## OpenCode Desktop 可观测性

每个 Task 都是**共享后台服务**上的一个普通 OpenCode session，所以你可以在
OpenCode Desktop 里观看：

- 一个 Task = 一个 session，标题为 `cheap-worker · C01 · Add retry queue`。
- session 里能看到模型输出、Read / Search / Edit / Bash / 测试步骤以及最终报告，
  和实际发生的过程完全一致。
- 两个脚本都不会启动私有服务（不使用 `--standalone`），所以这就是 Desktop 已经
  看到的那个 session。
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
> 我的会话名是 `编排`（用于后台唤醒；不写就用 blocking 模式）。

### 两种交接模式

| 模式 | 命令 | Codex 行为 | 适用场景 |
| --- | --- | --- | --- |
| 阻塞 | `run-phase.sh` | 在回合内等待，随后做 Phase review | 默认；始终可用 |
| 后台 + 唤醒 | `worker-notify.sh --phase --codex-thread <id-or-name>` | 立即返回并结束回合；循环**停止**时由 `codex queue` 唤醒该 session | 你想离开机器，且已知目标 session |

无论哪种模式，整个 Phase **只交接一次**：绝不要每个 Task 跑一次循环，也绝不要在
循环运行时轮询 `status.sh` / `check-state.sh`（`--max-tasks N` 是安全上限，不是
节奏）。运行中的循环会一直回答 `WORKER_RUNNING` 直到停止，而通知器每次停止只唤醒
Supervisor 一次。

唤醒细节：

- 目标必须**精确**：`--codex-thread <id-or-name>`，或调用方运行时提供的
  `CODEX_THREAD_ID`。**绝不从本地历史猜测**；没有目标时该工具会 fail closed
  （`exit 14`），改用阻塞模式。
- Codex **每次停止只被唤醒一次**，而不是每个 Task 一次：phase review、
  checkpoint、escalation 或管道停止。
- `exit 15` 表示循环已结束但唤醒未能送达：消息保留在
  `.agent/current/NOTIFY_FAILED.md`。
- 需要 ChatGPT/Codex 桌面应用保持打开，且**目标 session 处于打开状态**。循环运行
  期间，该工具会持有一个 `caffeinate -i` 断言。

## 项目运行时目录

在目标项目里首次使用会创建：

```
.agent/
├── RUN_STATE.json         # phase、当前 task、status、stop_reason
├── current/
│   ├── TASK.md            # 正在执行的这一个 Task（由队列渲染而来）
│   ├── RESULT.md          # worker 成功运行之后
│   ├── ESCALATION.md      # 发生 CHECKPOINT / ESCALATE 停止之后
│   ├── VERIFY.md          # 确定性证据闸门的结果（由循环写入）
│   ├── REVIEW.md          # Codex 为重跑给出的修正意见（仅在返工时）
│   ├── STATE.json         # run id、task、status、baseline、session id
│   ├── .worker.lock       # 单 worker 锁（wrapper pid + worker pid）
│   ├── .phase.lock        # 单循环锁
│   └── logs/              # opencode JSON 事件原始流 + 循环日志
├── phases/<PHASE>/
│   ├── PHASE.md
│   ├── TASK_QUEUE.json    # 机器可读的计划（该文件归 Codex 所有）
│   ├── PHASE_REVIEW.md    # Phase 验证的运行记录
│   └── history/           # 每个 Task 的 TASK-<id>.md、VERIFY-<id>.md
└── history/               # 归档：<stamp>-<task>/，含 RESULT、VERIFY、diff 基线
```

`.agent/` 只是运行时状态。架构、roadmap、产品与设计文档留在它们本来的位置
（`ROADMAP.md`、`docs/`、`AGENTS.md`）。如果项目有 `AGENTS.md`，worker 必须读它。

## 状态机

`RUN_STATE.json.status` 取值之一：

| 状态 | 含义 | 由谁推进 |
| --- | --- | --- |
| `idle` | 已规划但未运行 / 人工闸门已放行 | `run-phase.sh` 启动 |
| `running` | 循环正在执行 Tasks | 循环 |
| `checkpoint` | 循环停下等 Codex 决策（`stop_reason`） | Codex，然后 `run-phase.sh` |
| `escalated` | 某个 Task 被阻塞；循环拒绝继续 | Codex（队列），然后 `run-phase.sh` |
| `awaiting_phase_review` | 所有 Tasks 完成，Phase 验证通过 | Codex：`phase-gate.sh review-pass/fail` |
| `awaiting_human_qa` | review 通过；由人决定 | 人：`phase-gate.sh qa-pass/fail` |

`check-state.sh` 为续跑打印唯一判定：`RUNNING`、`QUEUE_COMPLETE`、`EMPTY`、
`CHECKPOINT`、`ESCALATED`、`AWAITING_PHASE_REVIEW`、`AWAITING_HUMAN_QA`、
`WORKER_RUNNING`、`STALE_LOCK` 或 `INCONSISTENT`（退出 `0` = 可行动，`1` = 停止）。
`STALE_LOCK` 表示 worker/phase 锁没有活跃 pid，这**并不**证明运行已停止：请确认
没有东西在跑，然后用 `--break-lock`。`INCONSISTENT` 会在 `STALE_LOCK` **之前**
报告，因此过期锁永远无法掩盖状态问题。

## 循环何时停止（checkpoint / escalation 规则）

停止不是失败：它们正是 Codex 应该花 token 的地方。

- **guarded Task**（`risk: guarded` —— 架构、公开 API、schema/数据迁移、安全、
  权限、凭据、部署）：先执行，然后循环在下一个 Task 之前停下，等 Codex review。
- **worker `CHECKPOINT`**：worker 需要一个决策（同样是那些主题、范围蔓延、无法
  验证的验收、产品意图、重大不确定性）。
- **worker `ESCALATE` / 证据闸门失败**：两次尝试都失败、Task 自相矛盾，或验证不通过。
- **管道故障**：没有报告/报告冲突/报告过期、worker 锁、无法证明的过期锁、
  `opencode` 非零退出、状态不一致。
- **Phase 结束**（总会发生）：`awaiting_phase_review`，绝不直接进入下一个 Phase。

## 冒烟测试

`tests/smoke/` 会在系统临时目录下创建一次性 git 仓库，并运行**本源码树**里的脚本。
它绝不触碰真实项目，也绝不安装任何东西。见 `tests/smoke/README.md`。

```sh
tests/smoke/run-offline.sh                  # 无模型调用、无需凭据（约 380 项检查）
tests/smoke/run-live.sh                     # 全部 live 测试（用 OpenCode 默认模型）
SMOKE_KEEP_REPOS=1 tests/smoke/run-live.sh  # 保留下生成的仓库
```

`run-offline.sh` 是本项目的契约，CI 会在 Linux 与 macOS 上运行它
（`.github/workflows/ci.yml`）。它需要 `opencode` 在 `PATH` 上，因为 doctor 会检查
真实的 CLI；但它不产生任何模型调用：它驱动的每个 worker 都是确定性的假实现。

Live 测试使用 OpenCode 配置的默认模型，并会对瞬时供应商配额错误（HTTP 429）重试；
否则就大声失败。它们从不静默通过。

## 续跑

状态存在于文件里：

- `.agent/RUN_STATE.json` - 整个运行的 phase/task/status/stop_reason
- `.agent/phases/<PHASE>/TASK_QUEUE.json` - 计划与逐 Task 历史
- `.agent/current/STATE.json` - 当前 Task、baseline、session id、上次结果
- `.agent/current/VERIFY.md` - 上次运行的证据闸门结果

续跑时先运行 `check-state.sh`；然后 `run-phase.sh` 会从记录为 `in_progress` 的
Task 继续（它会从队列重新渲染 `TASK.md`，所以空白或过期的 TASK.md 能自我修复）。
已完成的 Task 永不重跑。

## 人工检查点

最后一个 Task 完成后，循环停在 `awaiting_phase_review`。Codex 做集成 review，
只有 `review-pass` 才会把状态推进到 `awaiting_human_qa`。然后 Codex 汇报，并
**停下**：不进入下一个 Phase，不追加额外的 Task。人工测试之后，`qa-pass`（或
针对缺陷的 `qa-fail`）记录结论。见
`skills/phase-runner/references/human-checkpoint.md`。

## 已知限制（V1）

- 模型选择完全归 OpenCode：如果配置的默认模型很慢、被限流或不可达，worker 会以
  管道错误失败，循环停在 checkpoint。没有回退，也没有路由器。
- Supervisor 就是当前的 Codex/Astra session；没有独立的编排守护进程。唤醒模式要求
  ChatGPT/Codex 桌面应用保持打开，且编排 session 处于打开状态。
- `run-worker.sh` 没有内置的墙钟超时（OpenCode 自身的行为与调用方超时生效）。
  `worker-notify.sh` 通过脱离前台解决了超时问题，但无法阻止合盖休眠或手动关机。
- 报告是模型写的 Markdown，可能是错的。重跑的验证、diff 作用域与 diff 本身才是证据。
- worker 提示词内嵌了契约，所以 worker 不需要读取 skill 目录（OpenCode 的
  `external_directory` 权限默认是 `ask`）。
- 验证命令来自队列，并通过 `bash -c` 在项目根目录运行：它们必须非交互、确定性，
  并且足够快。
- 安装器的 `rsync --delete` 镜像模式假定目标目录完全由本项目托管。`--target`
  仅供测试使用。
- 兼容 bash 3.2（macOS）并在 Linux 上经 CI 测试；原生不支持 Windows
  （见[平台支持](#平台支持)）。

## 开发规则

- 一个 Task = 一个内聚的改动，配一套验证说明。
- worker 绝不编辑自己的 TASK.md、队列或 `RUN_STATE.json`（一旦这么做，证据闸门会
  让该 Task 失败）。
- Codex 绝不 review 单个 Task 的结果，也绝不在循环内部改代码：修复就是另一个 Task。
- 一个 Phase 总是结束于 `awaiting_phase_review`；人工闸门不可省略。
- 不要给 V1 引入数据库、队列、守护进程、dashboard、DAG、并行 worker 或递归 agent。
