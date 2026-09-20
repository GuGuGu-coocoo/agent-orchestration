# Tests

[← Retour au README](../../README.fr.md) · [English](../en/testing.md) · [简体中文](../zh-CN/testing.md)

Comment ce projet est vérifié, ce que les suites prouvent, et ce qu'elles ne
prouvent délibérément pas.

## La suite hors ligne

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

## La suite live

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

## Ce que les suites prouvent et ne prouvent pas

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

## CI

[`.github/workflows/ci.yml`](../../.github/workflows/ci.yml) exécute la suite hors
ligne sur `ubuntu-latest` et `macos-latest` à chaque push et chaque pull request.
Elle installe le vrai CLI OpenCode (le doctor le contrôle) et téléverse
`tests/smoke/.out` comme artefact quand un job échoue.

Les deux runners couvrent les deux générations de bash que le projet prend en
charge : bash 3.2 sur macOS et bash 5 sur Linux.

## Notes d'environnement

La suite crée des dépôts jetables et y commite des fixtures. Si le bac à sable
refuse de créer des commits (un shim `git` restreint), les contrôles qui exigent
un vrai `HEAD` sont rapportés en `SKIP` au lieu d'échouer — la ligne de résumé
affiche alors `N passed, M failed, K skipped`. Tout le reste doit passer.

Les sorties (journaux d'événements JSON du worker, journaux de la boucle, sortie
du doctor) atterrissent dans `tests/smoke/.out/` et peuvent être supprimées à
tout moment.
