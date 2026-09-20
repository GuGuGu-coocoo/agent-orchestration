# Testing · 测试 · Tests

**Languages:** [简体中文](#简体中文) · [English](#english) · [Français](#français)

---

## 简体中文

[← 返回 README](../README.md#简体中文) · [English](testing.md#english) · [Français](testing.md#français)

本项目如何被验证、这些测试套件能证明什么，以及它们**刻意不**证明什么。

### 离线套件

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

### Live 套件

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

### 测试能证明什么、不能证明什么

- **离线套件**证明的是*脚本*的行为：证据闸门、状态机、停止规则、续跑。它用的是假
  worker，所以对模型质量没有任何结论。
- **Live 套件**证明同一套流程在真实模型下可用，一个 Task 一个 session。
- 两者都**不能**证明 Codex 会遵守 `phase-runner/SKILL.md` —— 那段文字是靠人阅读来
  评审的。脚本只强制那些不能依赖自觉的部分：不做逐 Task review、
  `awaiting_phase_review` → `awaiting_human_qa` 闸门、以及拒绝启动下一个 Phase。

### CI

[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) 会在每次 push 和 PR 时，
在 `ubuntu-latest` 与 `macos-latest` 上运行离线套件。它会安装真实的 OpenCode CLI
（doctor 需要检查它），并在任务失败时把 `tests/smoke/.out` 作为 artifact 上传。

这两个 runner 覆盖了项目支持的两代 bash：macOS 上的 bash 3.2 与 Linux 上的 bash 5。

### 环境说明

套件会创建一次性仓库并在其中提交 fixture。如果沙箱拒绝创建提交（被 gated 的 `git`
shim），需要真实 `HEAD` 的那些检查会被报告为 `SKIP` 而不是失败 —— 摘要行会显示
`N passed, M failed, K skipped`。其余检查仍必须全部通过。

输出（worker JSON 事件日志、循环日志、doctor 输出）会落在 `tests/smoke/.out/`，
随时可以删除。

---

## English

[← Back to README](../README.md#english) · [简体中文](testing.md#简体中文) · [Français](testing.md#français)

How this project is verified, what the suites prove, and what they deliberately
do not.

### The offline suite

```sh
tests/smoke/run-offline.sh                  # no model calls, no credentials (~380 checks)
```

`tests/smoke/` creates throwaway git repositories under the system temp
directory and runs the scripts from **this source tree** — never from
`~/.agents/skills`, so a development checkout is verified before it is
installed. Nothing is installed, and no real project is touched.

The offline suite drives every script with a **deterministic fake worker**, so
it needs no model, no credentials and no network. It covers:

- the doctor, the SKILL.md frontmatter, and the guarantee that no script ever
  passes `--model` or `--standalone`;
- the run-worker safety harness: report validation, stale-report quarantine,
  lock identity (including a surviving worker pid and `--break-lock`), real
  `SIGTERM` cancellation keeping the lock, TASK.md/REVIEW.md validation, dirty
  baselines, cwd pinning;
- **the Phase loop end to end** against the fake worker: auto-continue over
  three Tasks, guarded/checkpoint stops, an escalation stop, a failing Phase
  verification, the review and human gates, and resume;
- the evidence gate itself: verification re-runs, diff scope, unticked criteria,
  and Supervisor-artifact tampering;
- the `check-state.sh` fail-closed matrix;
- install/uninstall boundaries, including a fixture-HOME proof that the
  installer leaves other skills byte-identical.

It needs `opencode` on `PATH`, because `doctor.sh` checks the real CLI. It makes
no model calls.

### The live suite

```sh
tests/smoke/run-live.sh                     # all live tests (OpenCode default model)
tests/smoke/run-live.sh d                   # one suite (a, b, c, d, e)
SMOKE_KEEP_REPOS=1 tests/smoke/run-live.sh  # keep the generated repos
```

Live tests use OpenCode's configured default model — there is no test-side model
override, exactly like the worker itself. They retry transient provider quota
errors (HTTP 429) and otherwise fail loudly; they never silently pass.

| Suite | What it proves |
| --- | --- |
| `a` | one implement Task end to end: edit, run, verify, RESULT.md, clean diff |
| `b` | investigate mode: a finding reported, zero business-code changes |
| `c` | a genuinely contradictory frozen test forces `ESCALATION.md`, no edits, exit 10 |
| `d` | three bounded Tasks through the real `run-phase.sh` with the real model: one session each, evidence gate per Task, automatic continuation, STOP at `awaiting_phase_review`, then the review and QA gates |
| `e` | an interrupted `in_progress` Task is resumed by the real loop (done Tasks never re-run, blank TASK.md rebuilt, stale report quarantined) |

Each worker run creates one titled OpenCode session on the shared background
service, so live test runs are also visible in OpenCode Desktop.

To run live tests against a specific model without touching your global config,
point `TMPDIR` at a directory with a project-local OpenCode config:

```sh
mkdir -p /tmp/oc-live/.opencode
printf '{"model":"<provider/model>"}' > /tmp/oc-live/.opencode/opencode.json
TMPDIR=/tmp/oc-live tests/smoke/run-live.sh
```

### What the suites do and do not prove

- The **offline suite** proves what the *scripts* do: the evidence gate, the
  state machine, the stops, the resume. It uses a fake worker, so it says
  nothing about model quality.
- The **live suite** proves that the same flow works with a real model, one
  session per Task.
- Neither proves that Codex *follows* `phase-runner/SKILL.md`; that text is
  reviewed by reading it. The scripts enforce the parts that must not depend on
  discipline: no per-Task review, the `awaiting_phase_review` →
  `awaiting_human_qa` gates, and the refusal to start the next Phase.

### CI

[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) runs the offline
suite on `ubuntu-latest` and `macos-latest` for every push and pull request. It
installs the real OpenCode CLI (the doctor checks it) and uploads
`tests/smoke/.out` as an artifact when a job fails.

The two runners cover both bash generations the project supports: bash 3.2 on
macOS and bash 5 on Linux.

### Environment notes

The suite creates throwaway repos and commits fixtures in them. If the sandbox
refuses to create commits (a gated `git` shim), the checks that need a real
`HEAD` are reported as `SKIP` instead of failing — the summary line then reads
`N passed, M failed, K skipped`. Everything else must still pass.

Outputs (worker JSON event logs, loop logs, doctor output) land in
`tests/smoke/.out/` and can be deleted at any time.

---

## Français

[← Retour au README](../README.md#français) · [English](testing.md#english) · [简体中文](testing.md#简体中文)

Comment ce projet est vérifié, ce que les suites prouvent, et ce qu'elles ne
prouvent délibérément pas.

### La suite hors ligne

```sh
tests/smoke/run-offline.sh                  # aucun appel de modèle, aucun identifiant (~380 contrôles)
```

`tests/smoke/` crée des dépôts git jetables dans le répertoire temporaire du
système et exécute les scripts **de cet arbre source** — jamais ceux de
`~/.agents/skills`, afin qu'un checkout de développement soit vérifié avant
d'être installé. Rien n'est installé, et aucun vrai projet n'est touché.

La suite hors ligne pilote chaque script avec un **faux worker déterministe** :
elle n'a donc besoin ni de modèle, ni d'identifiants, ni de réseau. Elle couvre :

- le doctor, le frontmatter des SKILL.md, et la garantie qu'aucun script ne passe
  `--model` ou `--standalone` ;
- le harnais de sécurité de run-worker : validation des rapports, mise en
  quarantaine des rapports périmés, identité du verrou (y compris un pid de
  worker survivant et `--break-lock`), une annulation réelle par `SIGTERM` qui
  garde le verrou, la validation de TASK.md/REVIEW.md, les baselines modifiées,
  le verrouillage du cwd ;
- **la boucle de Phase de bout en bout** face au faux worker : enchaînement
  automatique sur trois Tâches, arrêts guarded/checkpoint, arrêt sur escalade,
  vérification de Phase en échec, les portes de revue et humaines, et la reprise ;
- la porte de preuves elle-même : rejeu des vérifications, portée du diff,
  critères non cochés, et altération des artefacts du Supervisor ;
- la matrice de verdicts *fail-closed* de `check-state.sh` ;
- les frontières d'installation/désinstallation, dont une preuve, sur un HOME
  factice, que l'installateur laisse les autres skills identiques octet pour
  octet.

Elle a besoin d'`opencode` dans le `PATH`, parce que `doctor.sh` contrôle le vrai
CLI. Elle ne fait aucun appel de modèle.

### La suite live

```sh
tests/smoke/run-live.sh                     # tous les tests live (modèle par défaut d'OpenCode)
tests/smoke/run-live.sh d                   # une seule suite (a, b, c, d, e)
SMOKE_KEEP_REPOS=1 tests/smoke/run-live.sh  # conserve les dépôts générés
```

Les tests live utilisent le modèle par défaut configuré dans OpenCode — il n'y a
aucune substitution de modèle côté test, exactement comme le worker lui-même. Ils
réessaient les erreurs transitoires de quota du fournisseur (HTTP 429) et
échouent bruyamment sinon ; ils ne passent jamais en silence.

| Suite | Ce qu'elle prouve |
| --- | --- |
| `a` | une Tâche d'implémentation de bout en bout : édition, exécution, vérification, RESULT.md, diff propre |
| `b` | le mode investigate : un constat rapporté, zéro modification du code métier |
| `c` | un test gelé réellement contradictoire force `ESCALATION.md`, aucune édition, sortie 10 |
| `d` | trois Tâches bornées via le vrai `run-phase.sh` avec le vrai modèle : une session chacune, la porte de preuves par Tâche, l'enchaînement automatique, l'ARRÊT à `awaiting_phase_review`, puis les portes de revue et de QA |
| `e` | une Tâche `in_progress` interrompue est reprise par la vraie boucle (les Tâches faites ne sont jamais rejouées, un TASK.md vide est reconstruit, un rapport périmé est mis en quarantaine) |

Chaque exécution de worker crée une session OpenCode titrée sur le service
d'arrière-plan partagé, donc les exécutions live sont aussi visibles dans
OpenCode Desktop.

Pour lancer les tests live contre un modèle précis sans toucher à votre
configuration globale, pointez `TMPDIR` vers un dossier contenant une
configuration OpenCode locale au projet :

```sh
mkdir -p /tmp/oc-live/.opencode
printf '{"model":"<provider/model>"}' > /tmp/oc-live/.opencode/opencode.json
TMPDIR=/tmp/oc-live tests/smoke/run-live.sh
```

### Ce que les suites prouvent et ne prouvent pas

- La **suite hors ligne** prouve ce que font les *scripts* : la porte de preuves,
  la machine à états, les arrêts, la reprise. Elle utilise un faux worker, donc
  elle ne dit rien de la qualité du modèle.
- La **suite live** prouve que le même flux fonctionne avec un vrai modèle, une
  session par Tâche.
- Ni l'une ni l'autre ne prouve que Codex *suit* `phase-runner/SKILL.md` ; ce
  texte se révise par lecture. Les scripts imposent les parties qui ne doivent pas
  dépendre de la discipline : pas de revue par Tâche, les portes
  `awaiting_phase_review` → `awaiting_human_qa`, et le refus de démarrer la Phase
  suivante.

### CI

[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) exécute la suite hors
ligne sur `ubuntu-latest` et `macos-latest` à chaque push et chaque pull request.
Elle installe le vrai CLI OpenCode (le doctor le contrôle) et téléverse
`tests/smoke/.out` comme artefact quand un job échoue.

Les deux runners couvrent les deux générations de bash que le projet prend en
charge : bash 3.2 sur macOS et bash 5 sur Linux.

### Notes d'environnement

La suite crée des dépôts jetables et y commite des fixtures. Si le bac à sable
refuse de créer des commits (un shim `git` restreint), les contrôles qui exigent
un vrai `HEAD` sont rapportés en `SKIP` au lieu d'échouer — la ligne de résumé
affiche alors `N passed, M failed, K skipped`. Tout le reste doit passer.

Les sorties (journaux d'événements JSON du worker, journaux de la boucle, sortie
du doctor) atterrissent dans `tests/smoke/.out/` et peuvent être supprimées à
tout moment.
