# How it works · 工作原理 · Fonctionnement

**Languages:** [English](#english) · [简体中文](#简体中文) · [Français](#français)

---

## English

[← Back to README](../README.md#english) · [简体中文](how-it-works.md#简体中文) · [Français](how-it-works.md#français)

This document explains the machinery: the Phase loop, the evidence gate, the
state machine, the files on disk, and what happens when something goes wrong.

### Architecture

```
roadmap
  -> Codex (phase-runner): plan the Phase ONCE
       PHASE.md + TASK_QUEUE.json   (bounded Tasks, risk class, verification)
  -> OpenCode phase loop (run-phase.sh), one Task = one OpenCode session:
       render TASK.md -> worker implements + self-verifies -> evidence gate
         gate = RESULT.md DONE + criteria ticked
                + required verification commands re-run green
                + diff inside Allowed Changes
                + Supervisor artifacts untouched
       PASS  -> archive, mark done, next Task automatically
       STOP  -> checkpoint | escalate | guarded Task review
  -> awaiting_phase_review   (STOP: Codex Phase-level integration review)
  -> awaiting_human_qa       (STOP: the human decides)
  -> the next Phase is a deliberate new decision
```

Files, not chat history, are the source of truth for resume. Each Task is one
OpenCode session on the shared background service, so the human can watch it in
OpenCode Desktop while the loop runs.

### The evidence gate

This is the core idea: **the loop decides, not the worker.** For every Task the
loop re-runs, itself, deterministically:

- `RESULT.md` is fresh, belongs to this Task, says `Status: DONE`, and has no
  unticked criteria;
- every `verification` command from the queue re-runs and meets its expectation
  (`exit 0`, `exit N`, or `contains:<text>`);
- every file git reports as dirty (tracked, staged, deleted, untracked) is
  fingerprinted — content, file mode and existence — before and after the Task,
  and the two snapshots are compared path by path: a second edit to a file that
  was **already dirty** when the Task started is caught too (nothing is
  subtracted); tool artifacts such as `__pycache__`/`.pytest_cache` are ignored;
- `TASK_QUEUE.json`, `RUN_STATE.json`, `PHASE.md` and `TASK.md` were not touched
  by the worker.

The outcome is written to `.agent/current/VERIFY.md` and copied to
`.agent/phases/<P>/history/VERIFY-<task>.md`. PASS archives the Task and
continues; FAIL or any stop hands over to Codex. A worker's own "DONE" is never
enough.

Because verification lives in the queue, it is also reviewable: you can read
exactly what will be proven before the Task runs.

### When the loop stops (checkpoint / escalation rules)

Stops are not failures: they are where Codex is supposed to spend tokens.

- **guarded Task** (`risk: guarded` — architecture, public API, schema or data
  migration, security, permissions, credentials, deployment): it runs, then the
  loop stops for a Codex review before the next Task.
- **worker `CHECKPOINT`**: the worker needs a decision (those same topics, scope
  growth, unverifiable acceptance, product intent, material uncertainty).
- **worker `ESCALATE` / failed evidence gate**: two attempts failed, the Task is
  contradictory, or the verification does not pass.
- **plumbing**: no/conflicting/stale report, worker lock, unproven stale lock,
  `opencode` non-zero exit, inconsistent state.
- **end of Phase** (always): `awaiting_phase_review`, never the next Phase.

### State machine

`RUN_STATE.json.status` is one of:

| Status | Meaning | Who moves it on |
| --- | --- | --- |
| `idle` | planned but not running / human gate cleared | `run-phase.sh` starts |
| `running` | the loop is executing Tasks | the loop |
| `checkpoint` | the loop stopped for a Codex decision (`stop_reason`) | Codex, then `run-phase.sh` |
| `escalated` | a Task is blocked; the loop refuses to continue | Codex (queue), then `run-phase.sh` |
| `awaiting_phase_review` | all Tasks done, Phase verification passed | Codex: `phase-gate.sh review-pass/fail` |
| `awaiting_human_qa` | the review passed; the human decides | the human: `phase-gate.sh qa-pass/fail` |

`check-state.sh` prints one verdict for resume: `RUNNING`, `QUEUE_COMPLETE`,
`EMPTY`, `CHECKPOINT`, `ESCALATED`, `AWAITING_PHASE_REVIEW`,
`AWAITING_HUMAN_QA`, `WORKER_RUNNING`, `STALE_LOCK` or `INCONSISTENT`
(exit `0` = actionable, `1` = stop).

`STALE_LOCK` means a worker/phase lock has no live pid, which is **not** proof
that the run stopped: verify nothing is running, then pass `--break-lock`.
`INCONSISTENT` is reported **before** `STALE_LOCK`, so a stale lock can never
hide a state problem.

### Project runtime directory

First use in a target project creates:

```
.agent/
├── RUN_STATE.json         # phase, current task, status, stop_reason
├── current/
│   ├── TASK.md            # the one Task being executed (rendered from the queue)
│   ├── RESULT.md          # after a successful worker run
│   ├── ESCALATION.md      # after a CHECKPOINT / ESCALATE stop
│   ├── VERIFY.md          # deterministic evidence-gate result (written by the loop)
│   ├── REVIEW.md          # Codex corrections for a re-run (only when reworking)
│   ├── STATE.json         # run id, task, status, baseline, session id
│   ├── .worker.lock       # single-worker lock (wrapper pid + worker pid)
│   ├── .phase.lock        # single-loop lock
│   └── logs/              # raw opencode JSON event streams + loop logs
├── phases/<PHASE>/
│   ├── PHASE.md
│   ├── TASK_QUEUE.json    # the machine-readable plan (Codex owns this file)
│   ├── PHASE_REVIEW.md    # the Phase verification run(s)
│   └── history/           # TASK-<id>.md, VERIFY-<id>.md per Task
└── history/               # archives: <stamp>-<task>/ with RESULT, VERIFY, diff base
```

`.agent/` is runtime state only. Architecture, roadmap, product and design docs
stay in their normal locations (`ROADMAP.md`, `docs/`, `AGENTS.md`). If the
project has an `AGENTS.md`, the worker must read it.

Add `.agent/` to the target project's `.gitignore` — it is state, not source.

### Resume

State lives in files:

- `.agent/RUN_STATE.json` — phase/task/status/stop_reason of the whole run
- `.agent/phases/<PHASE>/TASK_QUEUE.json` — the plan and per-Task history
- `.agent/current/STATE.json` — current Task, baseline, session id, last result
- `.agent/current/VERIFY.md` — the evidence-gate result of the last run

On resume run `check-state.sh` first; then `run-phase.sh` continues from the
recorded `in_progress` Task. It re-renders `TASK.md` from the queue, so a blank
or stale `TASK.md` repairs itself. Completed Tasks are never re-run.

### Human checkpoint

When the last Task is done, the loop stops at `awaiting_phase_review`. Codex
does the integration review, and only `review-pass` moves the state to
`awaiting_human_qa`. Then Codex reports, and **stops**: no next Phase, no extra
Tasks. After you test, `qa-pass` (or `qa-fail` for defects) records the verdict.

The human gate is not optional and cannot be skipped by the loop.

---

## 简体中文

[← 返回 README](../README.md#简体中文) · [English](how-it-works.md#english) · [Français](how-it-works.md#français)

本文解释背后的机制：Phase 循环、证据闸门、状态机、磁盘上的文件，以及出错时会发生什么。

### 架构

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

### 证据闸门

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

### 循环何时停止（checkpoint / escalation 规则）

停止不是失败：它们正是 Codex 应该花 token 的地方。

- **guarded Task**（`risk: guarded` —— 架构、公开 API、schema/数据迁移、安全、
  权限、凭据、部署）：先执行，然后循环在下一个 Task 之前停下，等 Codex review。
- **worker `CHECKPOINT`**：worker 需要一个决策（同样是那些主题、范围蔓延、无法验证的
  验收、产品意图、重大不确定性）。
- **worker `ESCALATE` / 证据闸门失败**：两次尝试都失败、Task 自相矛盾，或验证不通过。
- **管道故障**：没有报告 / 报告冲突 / 报告过期、worker 锁、无法证明的过期锁、
  `opencode` 非零退出、状态不一致。
- **Phase 结束**（总会发生）：`awaiting_phase_review`，绝不直接进入下一个 Phase。

### 状态机

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

### 项目运行时目录

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

### 续跑

状态存在于文件里：

- `.agent/RUN_STATE.json` —— 整个运行的 phase/task/status/stop_reason
- `.agent/phases/<PHASE>/TASK_QUEUE.json` —— 计划与逐 Task 历史
- `.agent/current/STATE.json` —— 当前 Task、baseline、session id、上次结果
- `.agent/current/VERIFY.md` —— 上次运行的证据闸门结果

续跑时先运行 `check-state.sh`；然后 `run-phase.sh` 会从记录为 `in_progress` 的 Task
继续。它会从队列重新渲染 `TASK.md`，所以空白或过期的 TASK.md 能自我修复。已完成的
Task 永不重跑。

### 人工检查点

最后一个 Task 完成后，循环停在 `awaiting_phase_review`。Codex 做集成 review，只有
`review-pass` 才会把状态推进到 `awaiting_human_qa`。然后 Codex 汇报，并**停下**：
不进入下一个 Phase，不追加额外的 Task。你测试之后，`qa-pass`（或针对缺陷的
`qa-fail`）记录结论。

人工闸门不可省略，循环也无法跳过它。

---

## Français

[← Retour au README](../README.md#français) · [English](how-it-works.md#english) · [简体中文](how-it-works.md#简体中文)

Ce document explique la mécanique : la boucle de Phase, la porte de preuves, la
machine à états, les fichiers sur le disque, et ce qui se passe quand quelque
chose va mal.

### Architecture

```
roadmap
  -> Codex (phase-runner) : planifier la Phase UNE SEULE FOIS
       PHASE.md + TASK_QUEUE.json   (Tâches bornées, classe de risque, vérification)
  -> Boucle de Phase OpenCode (run-phase.sh), une Tâche = une session OpenCode :
       rendre TASK.md -> le worker implémente + s'auto-vérifie -> porte de preuves
         porte = RESULT.md DONE + critères cochés
                 + commandes de vérification rejouées au vert
                 + diff à l'intérieur des Allowed Changes
                 + artefacts du Supervisor intacts
       SUCCÈS -> archivage, marquage done, Tâche suivante automatiquement
       ARRÊT  -> checkpoint | escalade | revue d'une Tâche guarded
  -> awaiting_phase_review   (ARRÊT : revue d'intégration Codex au niveau Phase)
  -> awaiting_human_qa       (ARRÊT : c'est l'humain qui décide)
  -> la Phase suivante est une décision nouvelle et délibérée
```

Ce sont les fichiers, et non l'historique de conversation, qui font foi pour la
reprise. Chaque Tâche est une session OpenCode sur le service d'arrière-plan
partagé, donc l'humain peut la regarder dans OpenCode Desktop pendant que la
boucle tourne.

### La porte de preuves

C'est l'idée centrale : **c'est la boucle qui décide, pas le worker.** Pour chaque
Tâche, la boucle rejoue elle-même, de façon déterministe :

- `RESULT.md` est frais, appartient à cette Tâche, porte `Status: DONE`, et aucun
  critère n'est resté décoché ;
- chaque commande `verification` de la file est rejouée et satisfait son attente
  (`exit 0`, `exit N`, ou `contains:<text>`) ;
- chaque fichier que git signale comme modifié (suivi, indexé, supprimé, non
  suivi) est empreinté — contenu, mode de fichier et existence — avant et après
  la Tâche, et les deux instantanés sont comparés chemin par chemin : une seconde
  modification d'un fichier **déjà modifié** au début de la Tâche est donc
  rattrapée elle aussi (rien n'est soustrait) ; les artefacts d'outils comme
  `__pycache__`/`.pytest_cache` sont ignorés ;
- `TASK_QUEUE.json`, `RUN_STATE.json`, `PHASE.md` et `TASK.md` n'ont pas été
  touchés par le worker.

Le résultat est écrit dans `.agent/current/VERIFY.md` et copié dans
`.agent/phases/<P>/history/VERIFY-<task>.md`. Un succès archive la Tâche et
continue ; un échec ou n'importe quel arrêt est remis à Codex. Un « DONE »
revendiqué par le worker ne suffit jamais.

Comme la vérification vit dans la file, elle est aussi **vérifiable par
lecture** : vous pouvez lire exactement ce qui sera prouvé avant que la Tâche ne
tourne.

### Quand la boucle s'arrête (règles checkpoint / escalade)

Les arrêts ne sont pas des échecs : c'est là que Codex est censé dépenser des
tokens.

- **Tâche guarded** (`risk: guarded` — architecture, API publique, schéma ou
  migration de données, sécurité, permissions, identifiants, déploiement) : elle
  s'exécute, puis la boucle s'arrête pour une revue Codex avant la Tâche suivante.
- **`CHECKPOINT` du worker** : le worker a besoin d'une décision (les mêmes sujets,
  une dérive du périmètre, une acceptation invérifiable, l'intention produit, une
  incertitude importante).
- **`ESCALATE` du worker / échec de la porte de preuves** : deux tentatives ont
  échoué, la Tâche est contradictoire, ou la vérification ne passe pas.
- **Infrastructure** : rapport absent/contradictoire/périmé, verrou de worker,
  verrou périmé non prouvé, sortie non nulle d'`opencode`, état incohérent.
- **Fin de Phase** (toujours) : `awaiting_phase_review`, jamais la Phase suivante.

### Machine à états

`RUN_STATE.json.status` vaut l'un de :

| Statut | Signification | Qui le fait avancer |
| --- | --- | --- |
| `idle` | planifié mais pas lancé / porte humaine franchie | `run-phase.sh` démarre |
| `running` | la boucle exécute les Tâches | la boucle |
| `checkpoint` | la boucle s'est arrêtée pour une décision Codex (`stop_reason`) | Codex, puis `run-phase.sh` |
| `escalated` | une Tâche est bloquée ; la boucle refuse de continuer | Codex (file), puis `run-phase.sh` |
| `awaiting_phase_review` | toutes les Tâches sont faites, vérification de Phase passée | Codex : `phase-gate.sh review-pass/fail` |
| `awaiting_human_qa` | la revue est passée ; l'humain décide | l'humain : `phase-gate.sh qa-pass/fail` |

`check-state.sh` affiche un verdict unique pour la reprise : `RUNNING`,
`QUEUE_COMPLETE`, `EMPTY`, `CHECKPOINT`, `ESCALATED`, `AWAITING_PHASE_REVIEW`,
`AWAITING_HUMAN_QA`, `WORKER_RUNNING`, `STALE_LOCK` ou `INCONSISTENT`
(`exit 0` = actionnable, `1` = arrêt).

`STALE_LOCK` signifie qu'un verrou worker/phase n'a pas de pid vivant, ce qui
**ne prouve pas** que l'exécution s'est arrêtée : vérifiez que rien ne tourne,
puis passez `--break-lock`. `INCONSISTENT` est signalé **avant** `STALE_LOCK`,
donc un verrou périmé ne peut jamais masquer un problème d'état.

### Répertoire d'exécution du projet

La première utilisation dans un projet cible crée :

```
.agent/
├── RUN_STATE.json         # phase, tâche courante, statut, stop_reason
├── current/
│   ├── TASK.md            # la Tâche en cours (rendue depuis la file)
│   ├── RESULT.md          # après une exécution réussie du worker
│   ├── ESCALATION.md      # après un arrêt CHECKPOINT / ESCALATE
│   ├── VERIFY.md          # résultat déterministe de la porte de preuves (écrit par la boucle)
│   ├── REVIEW.md          # corrections Codex pour une reprise (uniquement en cas de rework)
│   ├── STATE.json         # id d'exécution, tâche, statut, baseline, id de session
│   ├── .worker.lock       # verrou mono-worker (pid du wrapper + pid du worker)
│   ├── .phase.lock        # verrou mono-boucle
│   └── logs/              # flux d'événements JSON bruts d'opencode + journaux de la boucle
├── phases/<PHASE>/
│   ├── PHASE.md
│   ├── TASK_QUEUE.json    # le plan lisible par machine (ce fichier appartient à Codex)
│   ├── PHASE_REVIEW.md    # la ou les exécutions de vérification de Phase
│   └── history/           # TASK-<id>.md, VERIFY-<id>.md par Tâche
└── history/               # archives : <stamp>-<task>/ avec RESULT, VERIFY, base de diff
```

`.agent/` n'est que de l'état d'exécution. L'architecture, la roadmap, les
documents produit et de conception restent à leur emplacement habituel
(`ROADMAP.md`, `docs/`, `AGENTS.md`). Si le projet a un `AGENTS.md`, le worker
doit le lire.

Ajoutez `.agent/` au `.gitignore` du projet cible — c'est de l'état, pas du code.

### Reprise

L'état vit dans les fichiers :

- `.agent/RUN_STATE.json` — phase/tâche/statut/stop_reason de toute l'exécution
- `.agent/phases/<PHASE>/TASK_QUEUE.json` — le plan et l'historique par Tâche
- `.agent/current/STATE.json` — Tâche courante, baseline, id de session, dernier résultat
- `.agent/current/VERIFY.md` — le résultat de la porte de preuves de la dernière exécution

En reprise, lancez d'abord `check-state.sh` ; ensuite `run-phase.sh` continue à
partir de la Tâche `in_progress` enregistrée. Il rend à nouveau `TASK.md` depuis
la file, donc un `TASK.md` vide ou périmé se répare tout seul. Les Tâches
terminées ne sont jamais rejouées.

### Point de contrôle humain

Quand la dernière Tâche est faite, la boucle s'arrête à `awaiting_phase_review`.
Codex fait la revue d'intégration, et seul `review-pass` fait passer l'état à
`awaiting_human_qa`. Ensuite Codex fait son rapport, et **s'arrête** : pas de
Phase suivante, pas de Tâches supplémentaires. Après vos tests, `qa-pass` (ou
`qa-fail` pour les défauts) enregistre le verdict.

La porte humaine n'est pas facultative et la boucle ne peut pas la contourner.
