# Référence

[← Retour au README](../../README.fr.md) · [English](../en/reference.md) · [简体中文](../zh-CN/reference.md)

Toutes les commandes, options et codes de sortie, plus les comportements de
sécurité, le choix du modèle et les limites connues de la V1.

## Lancer une Phase

Codex planifie la Phase (voir `skills/phase-runner/SKILL.md`), puis confie toute
la Phase à la boucle **une seule fois** :

```sh
cd /path/to/target-project

~/.agents/skills/phase-runner/scripts/run-phase.sh          # bloquant
~/.agents/skills/phase-runner/scripts/run-phase.sh --dry-run  # affiche seulement le plan

# arrière-plan + réveil de Codex uniquement quand la boucle S'ARRÊTE (revue de Phase / checkpoint / escalade)
~/.agents/skills/cheap-worker/scripts/worker-notify.sh --phase --codex-thread "orchestration"
```

| Code | Signification |
| --- | --- |
| 0 | la Phase a atteint `awaiting_phase_review` (ARRÊT : revue Codex) |
| 1 | invocation invalide, plan invalide, ou une porte d'état a refusé |
| 2 | arrêt sur un checkpoint (décision Codex requise) |
| 3 | arrêt sur une escalade (bloqué) |
| 4 | refus : la Phase est à une porte (`awaiting_phase_review` / `awaiting_human_qa`) |
| 5 | refus avant le démarrage de la boucle (worker/boucle vivant, état incohérent) ou arrêt sur un état incohérent/défaillance d'infrastructure — un **refus ne modifie jamais aucun fichier** |

Options :

| Option | Effet |
| --- | --- |
| `--root DIR` | opérer sur une autre racine de projet |
| `--max-tasks N` | plafond de sécurité du nombre de Tâches pour cette invocation |
| `--dry-run` | valider et afficher le plan, puis s'arrêter |
| `--no-check-state` | ignorer le pré-vol `check-state.sh` (usage expert) |
| `--break-lock` | la confirmation humaine explicite que rien ne tourne ; autorise la récupération des **deux** verrous périmés (le `.phase.lock` de la boucle et un `.worker.lock` périmé, transmis à `run-worker.sh`) |

### Refus et verrouillage

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
seuls les problèmes d'identité Tâche/rapport que le pré-vol peut réparer lui-même
passent par la réconciliation, et ils sont revérifiés ensuite.

### Enregistrer la revue de Phase et la QA

```sh
~/.agents/skills/phase-runner/scripts/phase-gate.sh review-pass --summary "..."
~/.agents/skills/phase-runner/scripts/phase-gate.sh review-fail --reason "..."   # ajoute des Tâches correctives, continue
~/.agents/skills/phase-runner/scripts/phase-gate.sh qa-pass --note "..."         # après confirmation humaine
~/.agents/skills/phase-runner/scripts/phase-gate.sh qa-fail --note "..."         # convertit les défauts en Tâches
```

## Lancer une seule Tâche (cheap-worker)

La boucle le pilote automatiquement ; vous pouvez aussi lancer une Tâche à la
main :

```sh
cd /path/to/target-project
~/.agents/skills/cheap-worker/scripts/doctor.sh
~/.agents/skills/cheap-worker/scripts/run-worker.sh --mode implement --title "Add retry queue"
```

`--title` est facultatif ; le titre de session devient
`cheap-worker · <task-id> · <title>`.

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
- `TASK.md` doit contenir les sections requises avec un contenu réel (les gabarits
  de liste comme `- <...>` comptent comme manquants) ; `--task-id`/`--mode`
  doivent correspondre au fichier ; un `REVIEW.md` doit porter le même
  identifiant de Tâche
- `--allow-dirty` enregistre l'état suivi/indexé/non suivi d'avant l'exécution
  dans `.agent/current/BASELINE.md`, plus `git diff HEAD --binary` dans
  `BASELINE.patch`
- opencode s'exécute toujours avec `cwd` = racine du projet, même invoqué ailleurs

### Scripts utilitaires

```sh
~/.agents/skills/cheap-worker/scripts/status.sh              # état Phase + Tâche en lecture seule
~/.agents/skills/cheap-worker/scripts/check-state.sh         # verdict de reprise
~/.agents/skills/cheap-worker/scripts/collect-result.sh --diff
~/.agents/skills/cheap-worker/scripts/archive-task.sh --yes --decision ACCEPT
```

## Choix du modèle

La V1 n'a **aucune couche de modèle qui lui soit propre**. Ni `run-worker.sh` ni
`run-phase.sh` ne passent `--model` ; le worker utilise ce que la configuration
d'OpenCode sélectionne :

- Configuration globale : `~/.config/opencode/opencode.json` -> `"model"`
- Ou le sélecteur de modèle d'OpenCode Desktop / du TUI (les sessions peuvent différer)

Il n'y a ni repli, ni routeur, ni configuration de modèle au niveau projet, ni
bascule automatique — c'est délibéré. Vérifiez les identifiants de modèle
disponibles avec `opencode models`. Pour qu'il réfléchisse davantage, réglez
l'effort du modèle dans la même configuration, par exemple :

```jsonc
{
  "providers": {
    "opencode-go": {
      "models": { "deepseek-v4.1-flash": { "settings": { "reasoningEffort": "max" } } }
    }
  }
}
```

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

> Utilise $phase-runner pour construire jusqu'à la Phase C.
> Le nom de ma session est `orchestration` (pour le réveil en arrière-plan ; omets-le pour le mode bloquant).

### Deux modes de passation

| Mode | Commande | Comportement de Codex | Quand l'utiliser |
| --- | --- | --- | --- |
| Bloquant | `run-phase.sh` | attend dans le tour, puis fait la revue de Phase | par défaut ; toujours disponible |
| Arrière-plan + réveil | `worker-notify.sh --phase --codex-thread <id-or-name>` | rend la main immédiatement et termine le tour ; `codex queue` réveille cette session quand la boucle **s'arrête** | vous voulez quitter la machine et une session cible est connue |

Quel que soit le mode, c'est **une seule passation pour toute la Phase** : ne
lancez jamais la boucle une fois par Tâche et ne sondez jamais `status.sh` /
`check-state.sh` pendant qu'elle tourne (`--max-tasks N` est un plafond de
sécurité, pas un rythme). Une boucle en cours répond `WORKER_RUNNING` jusqu'à son
arrêt, et le notificateur réveille le Supervisor exactement une fois par arrêt.

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
  assertion `caffeinate -i` (il ne peut donc pas empêcher la veille à la
  fermeture du capot).

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
  pris en charge nativement. Voir
  [Support des plateformes](../../README.fr.md#support-des-plateformes).

## Règles de développement

- Une Tâche = un changement cohérent avec une seule histoire de vérification.
- Le worker ne modifie jamais son propre TASK.md, la file, ni `RUN_STATE.json`
  (la porte de preuves fait échouer la Tâche s'il le fait).
- Codex ne révise jamais le résultat d'une Tâche et ne modifie jamais de code à
  l'intérieur de la boucle : une correction est une Tâche comme une autre.
- Une Phase se termine toujours à `awaiting_phase_review` ; la porte humaine n'est
  pas facultative.
- N'ajoutez pas à la V1 de bases de données, files d'attente, démons, tableaux de
  bord, DAG, workers parallèles ou agents récursifs.
