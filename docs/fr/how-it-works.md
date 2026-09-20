# Fonctionnement

[← Retour au README](../../README.fr.md) · [English](../en/how-it-works.md) · [简体中文](../zh-CN/how-it-works.md)

Ce document explique la mécanique : la boucle de Phase, la porte de preuves, la
machine à états, les fichiers sur le disque, et ce qui se passe quand quelque
chose va mal.

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

## La porte de preuves

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

## Quand la boucle s'arrête (règles checkpoint / escalade)

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
`AWAITING_HUMAN_QA`, `WORKER_RUNNING`, `STALE_LOCK` ou `INCONSISTENT`
(`exit 0` = actionnable, `1` = arrêt).

`STALE_LOCK` signifie qu'un verrou worker/phase n'a pas de pid vivant, ce qui
**ne prouve pas** que l'exécution s'est arrêtée : vérifiez que rien ne tourne,
puis passez `--break-lock`. `INCONSISTENT` est signalé **avant** `STALE_LOCK`,
donc un verrou périmé ne peut jamais masquer un problème d'état.

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

Ajoutez `.agent/` au `.gitignore` du projet cible — c'est de l'état, pas du code.

## Reprise

L'état vit dans les fichiers :

- `.agent/RUN_STATE.json` — phase/tâche/statut/stop_reason de toute l'exécution
- `.agent/phases/<PHASE>/TASK_QUEUE.json` — le plan et l'historique par Tâche
- `.agent/current/STATE.json` — Tâche courante, baseline, id de session, dernier résultat
- `.agent/current/VERIFY.md` — le résultat de la porte de preuves de la dernière exécution

En reprise, lancez d'abord `check-state.sh` ; ensuite `run-phase.sh` continue à
partir de la Tâche `in_progress` enregistrée. Il rend à nouveau `TASK.md` depuis
la file, donc un `TASK.md` vide ou périmé se répare tout seul. Les Tâches
terminées ne sont jamais rejouées.

## Point de contrôle humain

Quand la dernière Tâche est faite, la boucle s'arrête à `awaiting_phase_review`.
Codex fait la revue d'intégration, et seul `review-pass` fait passer l'état à
`awaiting_human_qa`. Ensuite Codex fait son rapport, et **s'arrête** : pas de
Phase suivante, pas de Tâches supplémentaires. Après vos tests, `qa-pass` (ou
`qa-fail` pour les défauts) enregistre le verdict.

La porte humaine n'est pas facultative et la boucle ne peut pas la contourner.
