[English](README.md) | [简体中文](README.zh-CN.md) | **Français**

# agent-orchestration

[![CI](https://github.com/GuGuGu-coocoo/agent-orchestration/actions/workflows/ci.yml/badge.svg)](https://github.com/GuGuGu-coocoo/agent-orchestration/actions/workflows/ci.yml)

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

## Points forts

**La vérification est une porte, pas une déclaration.** Après chaque Tâche, la
boucle rejoue les commandes de vérification de la Tâche elle-même, vérifie que le
diff est resté dans les fichiers autorisés, et confirme que ses propres fichiers
de plan n'ont pas été touchés. Un worker qui dit « DONE » ne suffit jamais — voir
[la porte de preuves](docs/fr/how-it-works.md#la-porte-de-preuves).

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

## Les deux skills

| Skill | Rôle | Scripts |
| --- | --- | --- |
| **`cheap-worker`** | Exécute exactement une Tâche dans sa propre session OpenCode et écrit un `RESULT.md` ou un `ESCALATION.md`. Utilisé par la boucle, ou seul. | `run-worker.sh`, `worker-notify.sh`, `doctor.sh`, `status.sh`, `check-state.sh`, `collect-result.sh`, `archive-task.sh` |
| **`phase-runner`** | La boucle (`run-phase.sh`) qui enchaîne les Tâches derrière la porte de preuves, plus le playbook Codex pour superviser une Phase et l'enregistreur de portes Phase/QA (`phase-gate.sh`). | `run-phase.sh`, `phase-gate.sh` |

## Démarrage rapide

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

## Prérequis

| Dépendance | Nécessaire pour | Remarques |
| --- | --- | --- |
| [OpenCode](https://opencode.ai) v2 (`opencode`) | exécuter les Tâches : une session par Tâche | dans le `PATH`, authentifié |
| `git` | baselines, diffs, contrôle de portée | chaque projet cible est un dépôt |
| `jq` | tous les fichiers d'état | obligatoire, sans repli |
| `bash` | tous les scripts | bash 3.2+ |
| `python3` | commandes de vérification des projets Python | facultatif |
| l'application de bureau Codex | passation en arrière-plan + réveil | facultatif ; le mode bloquant s'en passe |

### Support des plateformes

| Plateforme | État |
| --- | --- |
| macOS | développé et testé ici |
| Linux | couvert par la CI (`ubuntu-latest`) |
| Windows | non pris en charge nativement — utilisez WSL (non testé). Git Bash natif n'est pas pris en charge. |

## Documentation

| Document | Contenu |
| --- | --- |
| [Fonctionnement](docs/fr/how-it-works.md) | Architecture, la porte de preuves, la machine à états, `.agent/`, les arrêts, la reprise, le point de contrôle humain |
| [Référence](docs/fr/reference.md) | Toutes les commandes et options, tous les codes de sortie, les comportements de sécurité, le choix du modèle, l'observabilité Desktop, l'intégration Codex, les limites connues |
| [Tests](docs/fr/testing.md) | Les suites hors ligne et live, ce qu'elles prouvent et ne prouvent pas, la CI |

Autres langues : [English](README.md) · [简体中文](README.zh-CN.md)

## Licence

[MIT](LICENSE)
