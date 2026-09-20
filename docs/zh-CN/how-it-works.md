# 工作原理

[← 返回 README](../../README.zh-CN.md) · [English](../en/how-it-works.md) · [Français](../fr/how-it-works.md)

本文解释背后的机制：Phase 循环、证据闸门、状态机、磁盘上的文件，以及出错时会发生什么。

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

## 证据闸门

这是核心思想：**由循环判定，而不是 worker 自报。** 对每一个 Task，循环都会自己、
确定性地重跑：

- `RESULT.md` 是本次运行产生的、属于这个 Task、写着 `Status: DONE`，且没有未勾选的
  验收标准；
- 队列里每条 `verification` 命令都会重跑并满足其期望（`exit 0`、`exit N` 或
  `contains:<text>`）；
- git 报告的每一个脏文件（已跟踪、已暂存、已删除、未跟踪）都会被指纹化 —— 内容、
  文件权限与是否存在 —— 在 Task 前后各拍一次快照，然后逐个路径比对：因此**在 Task
  开始时就已脏**的文件被再次修改也能抓到（不做任何减法）；`__pycache__` /
  `.pytest_cache` 之类的工具产物会被忽略；
- `TASK_QUEUE.json`、`RUN_STATE.json`、`PHASE.md` 与 `TASK.md` 没有被 worker 改动。

结论写入 `.agent/current/VERIFY.md`，并复制到
`.agent/phases/<P>/history/VERIFY-<task>.md`。通过则归档该 Task 并继续；失败或任何
停止都交给 Codex。worker 自称的 "DONE" 永远不够。

因为验证方式写在队列里，它也是**可审阅的**：Task 运行之前，你就能读到一个 Task 到底
会被什么证明。

## 循环何时停止（checkpoint / escalation 规则）

停止不是失败：它们正是 Codex 应该花 token 的地方。

- **guarded Task**（`risk: guarded` —— 架构、公开 API、schema/数据迁移、安全、
  权限、凭据、部署）：先执行，然后循环在下一个 Task 之前停下，等 Codex review。
- **worker `CHECKPOINT`**：worker 需要一个决策（同样是那些主题、范围蔓延、无法验证的
  验收、产品意图、重大不确定性）。
- **worker `ESCALATE` / 证据闸门失败**：两次尝试都失败、Task 自相矛盾，或验证不通过。
- **管道故障**：没有报告 / 报告冲突 / 报告过期、worker 锁、无法证明的过期锁、
  `opencode` 非零退出、状态不一致。
- **Phase 结束**（总会发生）：`awaiting_phase_review`，绝不直接进入下一个 Phase。

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

`STALE_LOCK` 表示 worker/phase 锁没有活跃 pid，这**并不**证明运行已停止：请确认没有
东西在跑，然后传 `--break-lock`。`INCONSISTENT` 会在 `STALE_LOCK` **之前**报告，
因此过期锁永远无法掩盖状态问题。

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

请把 `.agent/` 加进目标项目的 `.gitignore` —— 它是状态，不是源码。

## 续跑

状态存在于文件里：

- `.agent/RUN_STATE.json` —— 整个运行的 phase/task/status/stop_reason
- `.agent/phases/<PHASE>/TASK_QUEUE.json` —— 计划与逐 Task 历史
- `.agent/current/STATE.json` —— 当前 Task、baseline、session id、上次结果
- `.agent/current/VERIFY.md` —— 上次运行的证据闸门结果

续跑时先运行 `check-state.sh`；然后 `run-phase.sh` 会从记录为 `in_progress` 的 Task
继续。它会从队列重新渲染 `TASK.md`，所以空白或过期的 TASK.md 能自我修复。已完成的
Task 永不重跑。

## 人工检查点

最后一个 Task 完成后，循环停在 `awaiting_phase_review`。Codex 做集成 review，只有
`review-pass` 才会把状态推进到 `awaiting_human_qa`。然后 Codex 汇报，并**停下**：
不进入下一个 Phase，不追加额外的 Task。你测试之后，`qa-pass`（或针对缺陷的
`qa-fail`）记录结论。

人工闸门不可省略，循环也无法跳过它。
