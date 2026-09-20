# agent-orchestration

[![CI](https://github.com/GuGuGu-coocoo/agent-orchestration/actions/workflows/ci.yml/badge.svg)](https://github.com/GuGuGu-coocoo/agent-orchestration/actions/workflows/ci.yml)

**Languages:** [简体中文](#简体中文) · [English](#english) · [Français](#français)

---

## 简体中文

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

### 功能
**验证是闸门，不是声明。** 每个 Task 结束后，循环会重跑该 Task 自己的验证命令、
检查 diff 是否越界、确认自己的计划文件没被改动。worker 说一句 "DONE" 永远不够
—— 见[证据闸门](docs/how-it-works.md#简体中文)。

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

### 两个 skill 分别做什么

| Skill | 职责 | 脚本 |
| --- | --- | --- |
| **`cheap-worker`** | 在自己的 OpenCode session 里**只执行一个 Task**，产出 `RESULT.md` 或 `ESCALATION.md`。既可以由循环调用，也可以单独使用。 | `run-worker.sh`、`worker-notify.sh`、`doctor.sh`、`status.sh`、`check-state.sh`、`collect-result.sh`、`archive-task.sh` |
| **`phase-runner`** | 驱动 Task 逐个通过证据闸门的循环（`run-phase.sh`），以及 Codex 监督单个 Phase 的 playbook 和 Phase/QA 闸门记录器（`phase-gate.sh`）。 | `run-phase.sh`、`phase-gate.sh` |

### 快速开始

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

### 依赖要求

| 依赖 | 用途 | 说明 |
| --- | --- | --- |
| [OpenCode](https://opencode.ai) v2（`opencode`） | 执行 Task：一个 Task 一个 session | 在 `PATH` 上且已认证 |
| `git` | baseline、diff、作用域检查 | 每个目标项目都是仓库 |
| `jq` | 所有状态文件 | 必需，无回退 |
| `bash` | 全部脚本 | bash 3.2+ |
| `python3` | Python 项目的验证命令 | 可选 |
| Codex 桌面应用 | 后台交接 + 唤醒 | 可选；阻塞模式不需要 |

#### 平台支持

| 平台 | 状态 |
| --- | --- |
| macOS | 在本平台开发并测试 |
| Linux | CI 覆盖（`ubuntu-latest`） |
| Windows | 原生不支持 —— 请用 WSL（未经验证）。不支持原生 Git Bash。 |

### 文档

| 文档 | 内容 |
| --- | --- |
| [工作原理](docs/how-it-works.md#简体中文) | 架构、证据闸门、状态机、`.agent/`、停止规则、续跑、人工检查点 |
| [参考手册](docs/reference.md#简体中文) | 全部命令与选项、所有退出码、安全行为、模型选择、Desktop 可观测性、Codex 集成、已知限制 |
| [测试](docs/testing.md#简体中文) | 离线与 live 测试套件、它们能证明什么、不能证明什么、CI |

[English](#english) · [Français](#français) · [回到顶部](#agent-orchestration)

### 许可

[MIT](LICENSE)

---

## English

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

### Features
**Verification is a gate, not a claim.** After every Task the loop re-runs the
Task's own verification commands, checks that the diff stayed inside the allowed
files, and confirms its own plan files were not touched. A worker saying "DONE"
is never enough — see [the evidence gate](docs/how-it-works.md#english).

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

### The two skills

| Skill | Role | Scripts |
| --- | --- | --- |
| **`cheap-worker`** | Runs exactly one Task in its own OpenCode session and writes a `RESULT.md` or an `ESCALATION.md`. Used by the loop, or standalone. | `run-worker.sh`, `worker-notify.sh`, `doctor.sh`, `status.sh`, `check-state.sh`, `collect-result.sh`, `archive-task.sh` |
| **`phase-runner`** | The loop (`run-phase.sh`) that drives Task after Task behind the evidence gate, plus the Codex playbook for supervising one Phase and the Phase/QA gate recorder (`phase-gate.sh`). | `run-phase.sh`, `phase-gate.sh` |

### Quick start

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

### Requirements

| Dependency | Needed for | Notes |
| --- | --- | --- |
| [OpenCode](https://opencode.ai) v2 (`opencode`) | running Tasks: one session per Task | on `PATH`, authenticated |
| `git` | baselines, diffs, the scope check | every target project is a repo |
| `jq` | all state files | required, no fallback |
| `bash` | all scripts | bash 3.2+ |
| `python3` | verification commands in Python projects | optional |
| Codex desktop app | background hand-off + wake-up | optional; blocking needs none |

#### Platform support

| Platform | Status |
| --- | --- |
| macOS | developed and tested here |
| Linux | exercised by CI (`ubuntu-latest`) |
| Windows | not supported natively — use WSL (untested). Native Git Bash is not supported. |

### Documentation

| Document | What is in it |
| --- | --- |
| [How it works](docs/how-it-works.md#english) | Architecture, the evidence gate, the state machine, `.agent/`, stops, resume, the human checkpoint |
| [Reference](docs/reference.md#english) | Every command and flag, all exit codes, safety behaviours, model selection, Desktop observability, Codex integration, known limitations |
| [Testing](docs/testing.md#english) | The offline and live smoke suites, what they do and do not prove, CI |

All three languages live in this file: [English](#english) ·
[简体中文](#简体中文) · [Français](#français). Each linked document carries the
same three sections.

### License

[MIT](LICENSE)

---

## Français

Deux skills OpenCode qui transforment une session de planification coûteuse en
une chaîne de Tâches d'implémentation bon marché et **vérifiées**.

**Le problème.** Mener une longue construction avec un seul agent oblige un
unique contexte à porter à la fois le plan, le code, les tests et les erreurs.
Cela devient lent, cher, et discrètement peu fiable.

**Le découpage.** Codex planifie une Phase. OpenCode l'exécute, une Tâche par
session, et prouve que chaque Tâche est terminée. C'est l'humain qui définit ce
que « terminé » veut dire.

```
Humain         -> intention, roadmap, QA manuelle
Codex/Astra    -> exigences, architecture, planification des Phases, revue de Phase
Boucle OpenCode -> exécute les Tâches bornées de la Phase : une session par Tâche,
                  se vérifie elle-même, enchaîne, s'arrête au risque
```

### Fonctionnalités
**La vérification est une porte, pas une déclaration.** Après chaque Tâche, la
boucle rejoue les commandes de vérification de la Tâche elle-même, vérifie que le
diff est resté dans les fichiers autorisés, et confirme que ses propres fichiers
de plan n'ont pas été touchés. Un worker qui dit « DONE » ne suffit jamais — voir
[la porte de preuves](docs/how-it-works.md#français).

**Codex ne révise jamais une Tâche.** Codex planifie la Phase une fois, puis
dépense des tokens là où cela compte : checkpoints, escalades, revue
d'intégration au niveau Phase, et la porte QA humaine. Une Phase est bornée par
construction.

**Une seule passation par Phase.** Soit vous bloquez une fois, soit vous vous
détachez une fois. Pas d'orchestration par Tâche, pas de sondage, pas de
troisième processus à surveiller.

**Ça échoue en refusant.** Un verrou vivant ou non prouvable, un plan malformé, un
rapport périmé ou un état incohérent arrêtent l'exécution *avant* toute écriture.
Un refus laisse le projet identique octet pour octet.

**Les fichiers font foi.** Chaque décision vit dans `.agent/`, donc une exécution
survit à un crash, un redémarrage ou une nouvelle session — sans historique de
conversation.

**Pas de démon, pas de base de données, pas de tableau de bord.** Deux skills, du
shell, et le service partagé OpenCode que vous avez déjà.

### Les deux skills

| Skill | Rôle | Scripts |
| --- | --- | --- |
| **`cheap-worker`** | Exécute exactement une Tâche dans sa propre session OpenCode et écrit un `RESULT.md` ou un `ESCALATION.md`. Utilisé par la boucle, ou seul. | `run-worker.sh`, `worker-notify.sh`, `doctor.sh`, `status.sh`, `check-state.sh`, `collect-result.sh`, `archive-task.sh` |
| **`phase-runner`** | La boucle (`run-phase.sh`) qui enchaîne les Tâches derrière la porte de preuves, plus le playbook Codex pour superviser une Phase et l'enregistreur de portes Phase/QA (`phase-gate.sh`). | `run-phase.sh`, `phase-gate.sh` |

### Démarrage rapide

**1. Installer les skills**

```sh
git clone https://github.com/GuGuGu-coocoo/agent-orchestration
cd agent-orchestration
./scripts/install-skills.sh --dry-run   # aperçu
./scripts/install-skills.sh             # installe dans ~/.agents/skills/
```

**2. Vérifier l'environnement**

```sh
cd /path/to/target-project
~/.agents/skills/cheap-worker/scripts/doctor.sh
```

**3. Faire planifier une Phase (Codex), puis la lancer une seule fois**

Codex lit `phase-runner/SKILL.md`, écrit `PHASE.md` + `TASK_QUEUE.json`, et confie
toute la Phase à la boucle en une seule fois :

```sh
~/.agents/skills/phase-runner/scripts/run-phase.sh            # bloquant
~/.agents/skills/cheap-worker/scripts/worker-notify.sh --phase --codex-thread "orchestration"
```

Dans les deux cas, c'est **une seule passation pour toute la Phase**. Quand la
dernière Tâche est faite, la boucle s'arrête à `awaiting_phase_review` ; Codex
fait la revue, vous testez, et `phase-gate.sh qa-pass` enregistre votre verdict.
Elle ne démarre jamais la Phase suivante.

**Lancer une seule Tâche à la main**

```sh
~/.agents/skills/cheap-worker/scripts/run-worker.sh --mode implement --title "Add retry queue"
```

### Prérequis

| Dépendance | Nécessaire pour | Remarques |
| --- | --- | --- |
| [OpenCode](https://opencode.ai) v2 (`opencode`) | exécuter les Tâches : une session par Tâche | dans le `PATH`, authentifié |
| `git` | baselines, diffs, contrôle de portée | chaque projet cible est un dépôt |
| `jq` | tous les fichiers d'état | obligatoire, sans repli |
| `bash` | tous les scripts | bash 3.2+ |
| `python3` | commandes de vérification des projets Python | facultatif |
| l'application de bureau Codex | passation en arrière-plan + réveil | facultatif ; le mode bloquant s'en passe |

#### Support des plateformes

| Plateforme | État |
| --- | --- |
| macOS | développé et testé ici |
| Linux | couvert par la CI (`ubuntu-latest`) |
| Windows | non pris en charge nativement — utilisez WSL (non testé). Git Bash natif n'est pas pris en charge. |

### Documentation

| Document | Contenu |
| --- | --- |
| [Fonctionnement](docs/how-it-works.md#français) | Architecture, la porte de preuves, la machine à états, `.agent/`, les arrêts, la reprise, le point de contrôle humain |
| [Référence](docs/reference.md#français) | Toutes les commandes et options, tous les codes de sortie, les comportements de sécurité, le choix du modèle, l'observabilité Desktop, l'intégration Codex, les limites connues |
| [Tests](docs/testing.md#français) | Les suites hors ligne et live, ce qu'elles prouvent et ne prouvent pas, la CI |

[English](#english) · [简体中文](#简体中文) · [Haut de page](#agent-orchestration)

### Licence

[MIT](LICENSE)
