# 测试

[← 返回 README](../../README.zh-CN.md) · [English](../en/testing.md) · [Français](../fr/testing.md)

本项目如何被验证、这些测试套件能证明什么，以及它们**刻意不**证明什么。

## 离线套件

```sh
tests/smoke/run-offline.sh                  # 无模型调用、无需凭据（约 380 项检查）
```

`tests/smoke/` 会在系统临时目录下创建一次性 git 仓库，并运行**本源码树**里的脚本 ——
绝不运行 `~/.agents/skills` 里的，所以开发中的改动会在安装之前先被验证。测试不安装
任何东西，也不触碰真实项目。

离线套件用一个**确定性的假 worker** 驱动每个脚本，因此不需要模型、凭据或网络。它覆盖：

- doctor、SKILL.md frontmatter，以及"任何脚本都不传 `--model` / 不用 `--standalone`"
  这条保证；
- run-worker 的安全测试链：报告合法性、过期报告隔离、锁身份（包括存活的 worker pid
  与 `--break-lock`）、真实的 `SIGTERM` 取消仍然保留锁、TASK.md/REVIEW.md 校验、
  脏 baseline、cwd 固定；
- **Phase 循环的端到端**（对假 worker）：三个 Task 自动连跑、guarded/checkpoint 停止、
  escalation 停止、Phase 验证失败、review 与人工闸门、以及续跑；
- 证据闸门本身：验证重跑、diff 作用域、未勾选的验收标准、Supervisor 产物被篡改；
- `check-state.sh` 的 fail-closed 判定矩阵；
- 安装/卸载边界，包括用 fixture HOME 证明安装器让其他 skill 逐字节不变。

它需要 `opencode` 在 `PATH` 上，因为 `doctor.sh` 会检查真实的 CLI。它不产生任何模型
调用。

## Live 套件

```sh
tests/smoke/run-live.sh                     # 全部 live 测试（用 OpenCode 默认模型）
tests/smoke/run-live.sh d                   # 只跑某一套（a、b、c、d、e）
SMOKE_KEEP_REPOS=1 tests/smoke/run-live.sh  # 保留下生成的仓库
```

Live 测试使用 OpenCode 配置的默认模型 —— 测试侧没有模型覆盖，和 worker 本身完全一致。
它们会对瞬时供应商配额错误（HTTP 429）重试，否则就大声失败；从不静默通过。

| 套件 | 证明什么 |
| --- | --- |
| `a` | 一个 implement Task 端到端：编辑、运行、验证、RESULT.md、干净的 diff |
| `b` | investigate 模式：报告发现，业务代码零改动 |
| `c` | 一个真正自相矛盾的冻结测试强制产生 `ESCALATION.md`，不编辑文件，退出码 10 |
| `d` | 用真实模型、真实 `run-phase.sh` 跑三个 bounded Tasks：一个 Task 一个 session、逐 Task 证据闸门、自动连跑、停在 `awaiting_phase_review`，然后走 review 与 QA 闸门 |
| `e` | 一个被中断的 `in_progress` Task 由真实循环续跑（已完成的 Task 永不重跑、空白 TASK.md 被重建、过期报告被隔离） |

每次 worker 运行都会在共享后台服务上创建一个有标题的 OpenCode session，所以 live 测试
的运行过程也能在 OpenCode Desktop 里看到。

想在不改全局配置的前提下对特定模型跑 live 测试，可以把 `TMPDIR` 指向一个带项目级
OpenCode 配置的目录：

```sh
mkdir -p /tmp/oc-live/.opencode
printf '{"model":"<provider/model>"}' > /tmp/oc-live/.opencode/opencode.json
TMPDIR=/tmp/oc-live tests/smoke/run-live.sh
```

## 测试能证明什么、不能证明什么

- **离线套件**证明的是*脚本*的行为：证据闸门、状态机、停止规则、续跑。它用的是假
  worker，所以对模型质量没有任何结论。
- **Live 套件**证明同一套流程在真实模型下可用，一个 Task 一个 session。
- 两者都**不能**证明 Codex 会遵守 `phase-runner/SKILL.md` —— 那段文字是靠人阅读来
  评审的。脚本只强制那些不能依赖自觉的部分：不做逐 Task review、
  `awaiting_phase_review` → `awaiting_human_qa` 闸门、以及拒绝启动下一个 Phase。

## CI

[`.github/workflows/ci.yml`](../../.github/workflows/ci.yml) 会在每次 push 和 PR 时，
在 `ubuntu-latest` 与 `macos-latest` 上运行离线套件。它会安装真实的 OpenCode CLI
（doctor 需要检查它），并在任务失败时把 `tests/smoke/.out` 作为 artifact 上传。

这两个 runner 覆盖了项目支持的两代 bash：macOS 上的 bash 3.2 与 Linux 上的 bash 5。

## 环境说明

套件会创建一次性仓库并在其中提交 fixture。如果沙箱拒绝创建提交（被 gated 的 `git`
shim），需要真实 `HEAD` 的那些检查会被报告为 `SKIP` 而不是失败 —— 摘要行会显示
`N passed, M failed, K skipped`。其余检查仍必须全部通过。

输出（worker JSON 事件日志、循环日志、doctor 输出）会落在 `tests/smoke/.out/`，
随时可以删除。
