[English](README.md) | [简体中文](README.zh-CN.md) | **Français**

# agent-orchestration

[![CI](https://github.com/GuGuGu-coocoo/agent-orchestration/actions/workflows/ci.yml/badge.svg)](https://github.com/GuGuGu-coocoo/agent-orchestration/actions/workflows/ci.yml)

Des skills d'orchestration d'agents, globaux et multi-projets, pour un flux de
travail à trois niveaux où **OpenCode fait le travail et la vérification au
niveau Tâche, et où Codex supervise au niveau Phase** :

```
Humain         -> intention produit, validation de la roadmap, QA manuelle
Codex/Astra    -> exigences, architecture, roadmap, planification des Phases,
                  revue au niveau Phase, traitement des escalades, décision QA
Boucle OpenCode -> exécute les Tâches bornées de la Phase, une session par Tâche,
                  se vérifie elle-même, enchaîne automatiquement, s'arrête au risque
```

Deux skills OpenCode sont gérés ici et installés dans `~/.agents/skills/` :

| Skill | Rôle | Emplacement après installation |
| --- | --- | --- |
| `cheap-worker` | exécute une Tâche, écrit RESULT/ESCALATION | `~/.agents/skills/cheap-worker` |
| `phase-runner` | la boucle de Phase + le playbook Codex pour une Phase | `~/.agents/skills/phase-runner` |

La règle la plus importante : **le worker ne planifie jamais une Phase, et Codex
ne révise jamais une Tâche.** Codex planifie la Phase une seule fois dans
`TASK_QUEUE.json` ; la boucle (`run-phase.sh`) l'exécute et accepte chaque Tâche
via une porte de preuves déterministe.

## Architecture

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

## Arborescence du dépôt

```
agent-orchestration/
├── README.md  README.zh-CN.md  README.fr.md
├── .gitignore
├── scripts/
│   ├── install-skills.sh              # installer/mettre à jour les deux skills gérés
│   └── uninstall-managed-skills.sh    # supprimer exactement ces deux skills
├── skills/
│   ├── cheap-worker/
│   │   ├── SKILL.md
│   │   ├── scripts/
│   │   │   ├── doctor.sh              # contrôle de santé de l'environnement
│   │   │   ├── run-worker.sh          # exécute exactement une Tâche (bloquant)
│   │   │   ├── worker-notify.sh       # une Tâche OU une Phase en arrière-plan + réveil de Codex
│   │   │   ├── status.sh              # état en lecture seule (Phase + Tâche)
│   │   │   ├── check-state.sh         # verdict de reprise / contrôle de cohérence
│   │   │   ├── collect-result.sh      # affiche RESULT/ESCALATION + les preuves VERIFY
│   │   │   └── archive-task.sh        # déplace les artefacts d'une Tâche terminée vers history
│   │   ├── references/
│   │   │   ├── worker-contract.md     # contrat normatif du worker + formats de rapport
│   │   │   ├── worker-prompt.md       # gabarit de prompt utilisé par run-worker.sh
│   │   │   ├── escalation-policy.md   # CHECKPOINT vs ESCALATE, quand s'arrêter
│   │   │   └── safety-policy.md       # limites de sécurité par défaut
│   │   └── assets/templates/
│   │       ├── TASK.md  RESULT.md  ESCALATION.md  STATE.json
│   └── phase-runner/
│       ├── SKILL.md                   # le playbook Codex pour une Phase
│       ├── scripts/
│       │   ├── run-phase.sh           # LA BOUCLE : Tâche après Tâche, porte de preuves
│       │   └── phase-gate.sh          # enregistreur de la revue de Phase / du QA humain
│       ├── references/
│       │   ├── phase-planning.md      # décomposer une Phase en Tâches exécutables
│       │   ├── phase-review.md        # la revue d'intégration au niveau Phase
│       │   ├── checkpoint-handling.md # traiter les arrêts checkpoint / escalade
│       │   ├── roadmap-policy.md      # trouver et respecter la roadmap
│       │   └── human-checkpoint.md    # s'arrêter et attendre l'humain
│       └── assets/templates/
│           ├── PHASE.md  TASK_QUEUE.json  RUN_STATE.json
└── tests/smoke/                       # tests sur dépôts jetables, jamais vos projets
```

## Prérequis

| Dépendance | Nécessaire pour | Remarques |
| --- | --- | --- |
| [OpenCode](https://opencode.ai) v2 (`opencode`) | exécuter les Tâches : une session par Tâche sur le service d'arrière-plan partagé | doit être dans le `PATH` et authentifié |
| `git` | les baselines, les diffs et le contrôle de portée | chaque projet cible est un dépôt |
| `jq` | tous les fichiers d'état sont lus et écrits avec lui | obligatoire, sans repli |
| `bash` | tous les scripts | compatible bash 3.2+ ; le bash système de macOS convient |
| `python3` | les commandes de vérification des projets Python | facultatif |
| l'application de bureau Codex | la passation en arrière-plan et le réveil (`worker-notify.sh`) | facultatif ; le mode bloquant n'a pas besoin de Codex |

### Support des plateformes

| Plateforme | État |
| --- | --- |
| macOS | développé et testé ici (bash 3.2 du système) |
| Linux | couvert par la CI (`ubuntu-latest`, bash 5) |
| Windows | non pris en charge nativement. Utilisez WSL — cela devrait fonctionner, mais ce n'est pas testé. Git Bash natif n'est pas pris en charge : la détection de processus vivants (`kill -0`) et la gestion des signaux y sont peu fiables. |

Les scripts évitent les options propres à GNU ou à BSD là où les deux diffèrent
(`stat`, `shasum` vs `sha256sum`, `sed -i`), donc le même code tourne sur macOS
et sur Linux.

## Installation

```sh
./scripts/install-skills.sh --dry-run      # aperçu
./scripts/install-skills.sh                # installer/mettre à jour
./scripts/install-skills.sh --force        # remplace même les dossiers homonymes non marqués (sauvegarde d'abord)
```

L'installateur ne synchronise jamais que `skills/cheap-worker` et
`skills/phase-runner` vers `~/.agents/skills/`. Il ne lit, ne déplace et ne
supprime aucun autre skill. Il est idempotent, vérifie `SKILL.md` après
l'installation, et écrit un marqueur `.installed-by-agent-orchestration` dans
chaque dossier géré.

## Désinstallation

```sh
./scripts/uninstall-managed-skills.sh --dry-run
./scripts/uninstall-managed-skills.sh --yes
```

Uniquement des chemins littéraux, confirmation explicite obligatoire, refus des
dossiers non marqués sauf avec `--force`, et `~/.agents/skills` n'est jamais
supprimé. Si vous avez lié le skill dans Codex, supprimez aussi ce lien :

```sh
rm ~/.codex/skills/phase-runner
```

## Lancer une Phase

Codex planifie la Phase (voir `skills/phase-runner/SKILL.md`), puis confie toute
la Phase à la boucle **une seule fois** :

```sh
cd /path/to/target-project

~/.agents/skills/phase-runner/scripts/run-phase.sh          # bloquant
~/.agents/skills/phase-runner/scripts/run-phase.sh --dry-run  # affiche seulement le plan

# arrière-plan + réveil de Codex uniquement quand la boucle S'ARRÊTE (revue de Phase / checkpoint / escalade)
~/.agents/skills/cheap-worker/scripts/worker-notify.sh --phase --codex-thread "编排"
```

Codes de sortie de `run-phase.sh` :

| Code | Signification |
| --- | --- |
| 0 | la Phase a atteint `awaiting_phase_review` (ARRÊT : revue Codex) |
| 1 | invocation invalide, plan invalide, ou une porte d'état a refusé |
| 2 | arrêt sur un checkpoint (décision Codex requise) |
| 3 | arrêt sur une escalade (bloqué) |
| 4 | refus : la Phase est à une porte (`awaiting_phase_review` / `awaiting_human_qa`) |
| 5 | refus avant le démarrage de la boucle (worker/boucle vivant, état incohérent) ou arrêt sur un état incohérent/défaillance d'infrastructure — **un refus ne modifie jamais aucun fichier** |

Options : `--root DIR`, `--max-tasks N` (plafond de sécurité), `--dry-run`,
`--no-check-state`, `--break-lock` (la confirmation humaine explicite que rien
ne tourne : elle autorise la récupération des **deux** verrous périmés — le
`.phase.lock` de la boucle et un `.worker.lock` périmé, ce dernier étant
transmis à `run-worker.sh`).

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
seuls les problèmes d'identité Tâche/rapport que le pré-vol peut réparer
lui-même passent par la réconciliation, et ils sont revérifiés ensuite.

La revue de Phase s'enregistre avec :

```sh
~/.agents/skills/phase-runner/scripts/phase-gate.sh review-pass --summary "..."
~/.agents/skills/phase-runner/scripts/phase-gate.sh review-fail --reason "..."   # ajoute des Tâches correctives, continue
~/.agents/skills/phase-runner/scripts/phase-gate.sh qa-pass --note "..."         # après confirmation humaine
~/.agents/skills/phase-runner/scripts/phase-gate.sh qa-fail --note "..."         # convertit les défauts en Tâches
```

## La porte de preuves (pourquoi Codex ne révise pas chaque Tâche)

Pour chaque Tâche, la boucle rejoue elle-même, de façon déterministe :

- `RESULT.md` est frais, appartient à cette Tâche, porte `Status: DONE`, et
  aucun critère n'est resté décoché ;
- chaque commande `verification` de la file est rejouée et satisfait son
  attente (`exit 0`, `exit N`, ou `contains:<text>`) ;
- chaque fichier que git signale comme modifié (suivi, indexé, supprimé, non
  suivi) est empreinté — contenu, mode de fichier et existence — avant et après
  la Tâche, et les deux instantanés sont comparés chemin par chemin : une
  seconde modification d'un fichier **déjà modifié** au début de la Tâche est
  donc rattrapée elle aussi (rien n'est soustrait) ; les artefacts d'outils
  comme `__pycache__`/`.pytest_cache` sont ignorés ;
- `TASK_QUEUE.json`, `RUN_STATE.json`, `PHASE.md` et `TASK.md` n'ont pas été
  touchés par le worker.

Le résultat est écrit dans `.agent/current/VERIFY.md` et copié dans
`.agent/phases/<P>/history/VERIFY-<task>.md` ; un succès archive la Tâche et
continue, un échec ou n'importe quel arrêt est remis à Codex. Un « DONE »
revendiqué par le worker ne suffit jamais.

## Utilisation de cheap-worker (une seule Tâche)

La boucle le pilote automatiquement ; vous pouvez aussi lancer une Tâche à la
main :

```sh
cd /path/to/target-project
~/.agents/skills/cheap-worker/scripts/doctor.sh
~/.agents/skills/cheap-worker/scripts/run-worker.sh --mode implement --title "Add retry queue"
```

`--title` est facultatif ; le titre de session devient
`cheap-worker · <task-id> · <title>`. Le modèle est celui que la configuration
d'OpenCode sélectionne — le script ne passe jamais `--model` et n'utilise jamais
`--standalone`.

Codes de sortie de `run-worker.sh` :

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
- `TASK.md` doit contenir les sections requises avec un contenu réel (les
  gabarits de liste comme `- <...>` comptent comme manquants) ;
  `--task-id`/`--mode` doivent correspondre au fichier ; un `REVIEW.md` doit
  porter le même identifiant de Tâche
- `--allow-dirty` enregistre l'état suivi/indexé/non suivi d'avant l'exécution
  dans `.agent/current/BASELINE.md`, plus `git diff HEAD --binary` dans
  `BASELINE.patch`
- opencode s'exécute toujours avec `cwd` = racine du projet, même invoqué ailleurs

Autres scripts utilitaires :

```sh
~/.agents/skills/cheap-worker/scripts/status.sh
~/.agents/skills/cheap-worker/scripts/check-state.sh    # verdict de reprise
~/.agents/skills/cheap-worker/scripts/collect-result.sh --diff
~/.agents/skills/cheap-worker/scripts/archive-task.sh --yes --decision ACCEPT
```

## Utilisation de phase-runner

Après l'installation, dans une session OpenCode/Codex, dites par exemple :

> 用 $phase-runner 按现有 roadmap 开发到 Phase C。
> 你负责需求和 Phase planning，把 Phase 拆成 bounded Tasks 后交给 run-phase.sh 跑。
> 不要逐个 Task review；Phase 完成后做 integration review，然后停下等我人工测试。

Le Supervisor suit alors `skills/phase-runner/SKILL.md` : prise en charge des
exigences, planification initiale, une seule passation de toute la Phase,
traitement des arrêts checkpoint/escalade, la revue au niveau Phase, et le point
de contrôle humain. Il ne demande jamais « on continue ? » entre les Tâches et
ne révise jamais le résultat d'une Tâche.

## Choix du modèle

La V1 n'a **aucune couche de modèle qui lui soit propre**. Ni `run-worker.sh` ni
`run-phase.sh` ne passent `--model` ; le worker utilise ce que la configuration
d'OpenCode sélectionne :

- Configuration globale : `~/.config/opencode/opencode.json` -> `"model"`
- Ou le sélecteur de modèle d'OpenCode Desktop / du TUI (les sessions peuvent différer)

Il n'y a ni repli, ni routeur, ni configuration de modèle au niveau projet, ni
bascule automatique — c'est délibéré. Vérifiez les identifiants de modèle
disponibles avec `opencode models`.

## Observabilité dans OpenCode Desktop

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

## Utilisation avec Codex (application de bureau)

`phase-runner` est le skill du Supervisor, donc Codex en a besoin ; `cheap-worker`
reste dans `~/.agents/skills/` où le worker OpenCode le récupère (Codex ne le
charge jamais).

```sh
ln -sfn ~/.agents/skills/phase-runner ~/.codex/skills/phase-runner
```

Puis dans une nouvelle conversation Codex :

> 用 $phase-runner 做到 Phase C。
> 我的会话名是 `编排`（用于后台唤醒；不写就用 blocking 模式）。

### Deux modes de passation

| Mode | Commande | Comportement de Codex | Quand l'utiliser |
| --- | --- | --- | --- |
| Bloquant | `run-phase.sh` | attend dans le tour, puis fait la revue de Phase | par défaut ; toujours disponible |
| Arrière-plan + réveil | `worker-notify.sh --phase --codex-thread <id-or-name>` | rend la main immédiatement et termine le tour ; `codex queue` réveille cette session quand la boucle **s'arrête** | vous voulez quitter la machine et une session cible est connue |

Quel que soit le mode, c'est **une seule passation pour toute la Phase** : ne
lancez jamais la boucle une fois par Tâche et ne sondez jamais `status.sh` /
`check-state.sh` pendant qu'elle tourne (`--max-tasks N` est un plafond de
sécurité, pas un rythme). Une boucle en cours répond `WORKER_RUNNING` jusqu'à
son arrêt, et le notificateur réveille le Supervisor exactement une fois par
arrêt.

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
  assertion `caffeinate -i`.

## Répertoire d'exécution du projet

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

## Machine à états

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
`AWAITING_HUMAN_QA`, `WORKER_RUNNING`, `STALE_LOCK` ou `INCONSISTENT` (`exit 0` =
actionnable, `1` = arrêt). `STALE_LOCK` signifie qu'un verrou worker/phase n'a
pas de pid vivant, ce qui **ne prouve pas** que l'exécution s'est arrêtée :
vérifiez que rien ne tourne, puis `--break-lock`. `INCONSISTENT` est signalé
**avant** `STALE_LOCK`, donc un verrou périmé ne peut jamais masquer un problème
d'état.

## Quand la boucle s'arrête (règles checkpoint / escalade)

Les arrêts ne sont pas des échecs : c'est là que Codex est censé dépenser des
tokens.

- **Tâche guarded** (`risk: guarded` — architecture, API publique, schéma ou
  migration de données, sécurité, permissions, identifiants, déploiement) :
  elle s'exécute, puis la boucle s'arrête pour une revue Codex avant la Tâche
  suivante.
- **`CHECKPOINT` du worker** : le worker a besoin d'une décision (les mêmes
  sujets, une dérive du périmètre, une acceptation invérifiable, l'intention
  produit, une incertitude importante).
- **`ESCALATE` du worker / échec de la porte de preuves** : deux tentatives ont
  échoué, la Tâche est contradictoire, ou la vérification ne passe pas.
- **Infrastructure** : rapport absent/contradictoire/périmé, verrou de worker,
  verrou périmé non prouvé, sortie non nulle d'`opencode`, état incohérent.
- **Fin de Phase** (toujours) : `awaiting_phase_review`, jamais la Phase suivante.

## Tests de fumée

`tests/smoke/` crée des dépôts git jetables dans le répertoire temporaire du
système et exécute les scripts **de cet arbre source**. Il ne touche jamais de
vrais projets et n'installe rien. Voir `tests/smoke/README.md`.

```sh
tests/smoke/run-offline.sh                  # aucun appel de modèle, aucun identifiant (~380 contrôles)
tests/smoke/run-live.sh                     # tous les tests live (modèle par défaut d'OpenCode)
SMOKE_KEEP_REPOS=1 tests/smoke/run-live.sh  # conserve les dépôts générés
```

`run-offline.sh` est le contrat du projet, et la CI l'exécute sur Linux et macOS
(`.github/workflows/ci.yml`). Il a besoin d'`opencode` dans le `PATH` parce que
le doctor contrôle le vrai CLI, mais il ne fait aucun appel de modèle : chaque
worker qu'il pilote est un faux déterministe.

Les tests live utilisent le modèle par défaut configuré dans OpenCode et
réessaient les erreurs transitoires de quota du fournisseur (HTTP 429) ; sinon
ils échouent bruyamment. Ils ne passent jamais en silence.

## Reprise

L'état vit dans les fichiers :

- `.agent/RUN_STATE.json` - phase/tâche/statut/stop_reason de toute l'exécution
- `.agent/phases/<PHASE>/TASK_QUEUE.json` - le plan et l'historique par Tâche
- `.agent/current/STATE.json` - Tâche courante, baseline, id de session, dernier résultat
- `.agent/current/VERIFY.md` - le résultat de la porte de preuves de la dernière exécution

En reprise, lancez d'abord `check-state.sh` ; ensuite `run-phase.sh` continue à
partir de la Tâche `in_progress` enregistrée (il rend à nouveau `TASK.md` depuis
la file, donc un TASK.md vide ou périmé se répare tout seul). Les Tâches
terminées ne sont jamais rejouées.

## Point de contrôle humain

Quand la dernière Tâche est faite, la boucle s'arrête à
`awaiting_phase_review`. Codex fait la revue d'intégration, et seul
`review-pass` fait passer l'état à `awaiting_human_qa`. Ensuite Codex fait son
rapport, et **s'arrête** : pas de Phase suivante, pas de Tâches
supplémentaires. Après les tests humains, `qa-pass` (ou `qa-fail` pour les
défauts) enregistre le verdict. Voir
`skills/phase-runner/references/human-checkpoint.md`.

## Limites connues (V1)

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
  pris en charge nativement (voir [Support des plateformes](#support-des-plateformes)).

## Règles de développement

- Une Tâche = un changement cohérent avec une seule histoire de vérification.
- Le worker ne modifie jamais son propre TASK.md, la file, ni `RUN_STATE.json`
  (la porte de preuves fait échouer la Tâche s'il le fait).
- Codex ne révise jamais le résultat d'une Tâche et ne modifie jamais de code à
  l'intérieur de la boucle : une correction est une Tâche comme une autre.
- Une Phase se termine toujours à `awaiting_phase_review` ; la porte humaine
  n'est pas facultative.
- N'ajoutez pas à la V1 de bases de données, files d'attente, démons, tableaux de
  bord, DAG, workers parallèles ou agents récursifs.
