[English](README.md) | **简体中文** | [Français](README.fr.md)

# agent-orchestration

[![CI](https://github.com/GuGuGu-coocoo/agent-orchestration/actions/workflows/ci.yml/badge.svg)](https://github.com/GuGuGu-coocoo/agent-orchestration/actions/workflows/ci.yml)

两个 OpenCode skill，把一次昂贵的规划会话，变成一条**可监督、可验证**的廉价实现流水线。

**问题。** 用一个 agent 跑长任务，意味着同一个上下文窗口要同时装下计划、代码、
测试和犯过的错。结果就是又慢、又贵，而且会不知不觉地不可靠。

**解法。** Codex 规划一个 Phase，OpenCode 执行它 —— 一个 Task 一个 session ——
并且**证明**每个 Task 真的做完了。而"什么叫做完"由人来定义。

```
Human          -> 产品意图、roadmap、人工 QA
Codex/Astra    -> 需求、架构、Phase 规划、Phase 级 review
OpenCode loop  -> 执行 Phase 内的 bounded Tasks：一个 Task 一个 session，
                  自行验证，自动继续，遇险停止
```

## 亮点

**验证是闸门，不是声明。** 每个 Task 结束后，循环会重跑该 Task 自己的验证命令、
检查 diff 是否越界、确认自己的计划文件没被改动。worker 说一句 "DONE" 永远不够
—— 见[证据闸门](docs/zh-CN/how-it-works.md#证据闸门)。

**Codex 从不 review 单个 Task。** Codex 只规划一次 Phase，然后把 token 花在真正
值钱的地方：checkpoint、escalation、Phase 级集成 review，以及人工 QA 闸门。一个
Phase 在结构上就是有边界的。

**一个 Phase 只交接一次。** 要么阻塞一次，要么脱离一次。没有逐 Task 的编排、
没有轮询、没有第三个进程要照看。

**它 fail closed。** 活跃或无法证明已死的锁、非法的计划、过期的报告、状态不一致
—— 都会在**任何写入之前**停下。拒绝会让项目保持逐字节不变。

**文件是唯一事实来源。** 所有决策都在 `.agent/` 里，所以一次运行能扛过崩溃、重启
或换 session —— 不依赖聊天记录。

**没有守护进程、没有数据库、没有 dashboard。** 两个 skill、一些 shell，加上你本来
就有的 OpenCode 共享服务。

## 两个 skill 分别做什么

| Skill | 职责 | 脚本 |
| --- | --- | --- |
| **`cheap-worker`** | 在自己的 OpenCode session 里**只执行一个 Task**，产出 `RESULT.md` 或 `ESCALATION.md`。既可以由循环调用，也可以单独使用。 | `run-worker.sh`、`worker-notify.sh`、`doctor.sh`、`status.sh`、`check-state.sh`、`collect-result.sh`、`archive-task.sh` |
| **`phase-runner`** | 驱动 Task 逐个通过证据闸门的循环（`run-phase.sh`），以及 Codex 监督单个 Phase 的 playbook 和 Phase/QA 闸门记录器（`phase-gate.sh`）。 | `run-phase.sh`、`phase-gate.sh` |

## 快速开始

**1. 安装 skills**

```sh
git clone https://github.com/GuGuGu-coocoo/agent-orchestration
cd agent-orchestration
./scripts/install-skills.sh --dry-run   # 预览
./scripts/install-skills.sh             # 安装到 ~/.agents/skills/
```

**2. 检查环境**

```sh
cd /path/to/target-project
~/.agents/skills/cheap-worker/scripts/doctor.sh
```

**3. 让 Codex 规划一个 Phase，然后交接一次**

Codex 读取 `phase-runner/SKILL.md`，写出 `PHASE.md` + `TASK_QUEUE.json`，然后把
整个 Phase 一次性交给循环：

```sh
~/.agents/skills/phase-runner/scripts/run-phase.sh            # 阻塞
~/.agents/skills/cheap-worker/scripts/worker-notify.sh --phase --codex-thread "orchestration"
```

无论哪种方式，**整个 Phase 只交接一次**。最后一个 Task 完成后，循环停在
`awaiting_phase_review`；Codex 做 review，你来测试，`phase-gate.sh qa-pass` 记录
你的结论。它绝不会自动开始下一个 Phase。

**手动跑单个 Task**

```sh
~/.agents/skills/cheap-worker/scripts/run-worker.sh --mode implement --title "Add retry queue"
```

## 依赖要求

| 依赖 | 用途 | 说明 |
| --- | --- | --- |
| [OpenCode](https://opencode.ai) v2（`opencode`） | 执行 Task：一个 Task 一个 session | 在 `PATH` 上且已认证 |
| `git` | baseline、diff、作用域检查 | 每个目标项目都是仓库 |
| `jq` | 所有状态文件 | 必需，无回退 |
| `bash` | 全部脚本 | bash 3.2+ |
| `python3` | Python 项目的验证命令 | 可选 |
| Codex 桌面应用 | 后台交接 + 唤醒 | 可选；阻塞模式不需要 |

### 平台支持

| 平台 | 状态 |
| --- | --- |
| macOS | 在本平台开发并测试 |
| Linux | CI 覆盖（`ubuntu-latest`） |
| Windows | 原生不支持 —— 请用 WSL（未经验证）。不支持原生 Git Bash。 |

## 文档

| 文档 | 内容 |
| --- | --- |
| [工作原理](docs/zh-CN/how-it-works.md) | 架构、证据闸门、状态机、`.agent/`、停止规则、续跑、人工检查点 |
| [参考手册](docs/zh-CN/reference.md) | 全部命令与选项、所有退出码、安全行为、模型选择、Desktop 可观测性、Codex 集成、已知限制 |
| [测试](docs/zh-CN/testing.md) | 离线与 live 测试套件、它们能证明什么、不能证明什么、CI |

其他语言：[English](README.md) · [Français](README.fr.md)

## 许可

[MIT](LICENSE)
