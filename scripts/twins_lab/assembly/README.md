# assembly - chaîne d'assemblage de la solution twins_project

Là où `lab build|test|run` travaillent un composant isolé, `lab assemble` construit la **solution complète**,
inventorie ses dépendances, vérifie qu'elles compilent, et livre une **instance exécutable** (images Docker + compose).

    lab assemble -- -UpTo scan                 # prébuild : outils du poste + versions déclarées dans le dépôt
    lab assemble -- -UpTo compile -SkipTests   # + installation isolée, inventaire, compilation (sans Docker)
    lab assemble                               # chaîne complète jusqu'au livrable et au test de fumée
    lab assemble -- -Strict                    # les UPGRADE et WARN deviennent bloquants (code de sortie 2)

Sans lab : `.\twins-assemble.ps1 -TwinsRoot C:\workspace\twins_project [-UpTo ...]`. Codes de sortie : 0 ok, 1 FAIL, 2 avertissements sous `-Strict`.

## Les étapes (chaque étape est une porte : un FAIL arrête la chaîne)

| Étape | Ce qu'elle fait | Porte franchie si |
|---|---|---|
| scan | Outils effectifs (python, node, npm, docker, git) et versions **déclarées** (requirements, pyproject, .nvmrc, package.json, images de compose et Dockerfile) comparées à `versions.psd1` | aucun FAIL |
| resolve | `git worktree` jetable du commit, venv neuf, `pip install`, `pip check`, `npm ci`, `npm ls`, inventaire, dépendances en retard, `EBADENGINE` | installation et arbres cohérents |
| compile | `compileall` + import de `app.main`, `npm run build` (Angular) | tout compile, `index.html` produit |
| test | pytest (suite complète) et jest dans le worktree | tests verts (`-AllowTestFailures` pour une période de transition) |
| package | Build des images dans des conteneurs propres, puis **inventaire effectif de l'image** livrée et écart avec le venv du build | images construites, `pip check` OK dans l'image |
| deliver | Dossier `delivery/` immuable + `manifest.json` + test de fumée sur une instance éphémère | versions effectives conformes, HTTP 200 |

Statuts : `OK`, `INFO`, `UPGRADE` (sous la cible, au-dessus du plancher), `WARN` (borne haute dépassée, tag flottant, dépendance non épinglée...), `FAIL`.

## Politique de versions (`versions.psd1`)

| Composant | Plancher | Cible | Borne haute (exclue) |
|---|---|---|---|
| Python | 3.11 | 3.14 | 3.15 (attendre que les librairies suivent) |
| Node | 22 | 26 (LTS fin octobre 2026) | 27 |
| Angular | 22 | 22 | 23 |
| PostgreSQL | 15 | 18 | 19 |
| Neo4j | 5.21 | 5.26 LTS | 5.27 (la 2026.x est un chantier à part) |

Le plancher est ce qui marche aujourd'hui, la cible est le plan de montée. Quand une montée est terminée, on remonte le plancher.

## Identité : build immuable, run éphémère

* **Build** = `<date du commit>-<sha7>` (ex. `20261029-d15b91e`). Dérivé du commit, jamais de l'heure : un même commit donne la même identité, un build existant n'est refait qu'avec `-Rebuild`.
* **Run** = `run-<horodatage>` choisi par `run-instance.ps1` : projet compose, réseau, volumes, mots de passe et port propres à chaque run.

Arborescence produite (hors dépôt, par défaut `C:\workspace\twins_builds`) :

    <build>\reports\   manifest.json  inventory.json  backend-host-freeze.txt
    <build>\logs\      un journal complet par étape
    <build>\delivery\  docker-compose.yml  run-instance.ps1  build.json  manifest.json  [images.tar]

`manifest.json` : commit, branche, empreintes SHA256 des lockfiles et de la politique, versions détectées, constats, identifiants des images.

## Recommandations pour des environnements iso

Déjà appliqué par la chaîne : build depuis un **commit** (pas depuis le dossier de travail), venv et `node_modules` neufs par build,
images construites dans des conteneurs, un run = ses propres réseau/volumes/secrets/port, bases non publiées, aucun `.env` dans les images.

À mettre en place, par ordre d'effet :

1. **Lockfile Python portable avec hashes.** `requirements.txt` n'épingle pas tout : le build de l'image peut différer du venv du poste (la chaîne signale l'écart).
   `uv pip compile requirements.in --universal --generate-hashes -o requirements.lock`, puis `pip install --require-hashes -r requirements.lock` dans le Dockerfile.
   Ne pas utiliser `pip freeze` de Windows comme lock : il contient des paquets propres à Windows (pywin32...).
2. **Images de base par digest.** Remplacer les tags de `versions.psd1` par `image@sha256:...` (`docker buildx imagetools inspect <tag>`), et laisser un bot (Renovate/Dependabot) proposer les montées.
   Un tag comme `postgres:18` ou `node:26-slim` bouge à chaque correctif.
3. **Un seul endroit pour les versions.** Aligner `.python-version`, `.nvmrc`, `requires-python`, `engines.node` + `engine-strict=true` dans `.npmrc` sur `versions.psd1` ; le scan vérifie déjà leur cohérence.
4. **Le build de référence est celui du conteneur.** Le poste Windows sert à développer et à scanner ; la livraison se fait par la même chaîne dans un runner CI à image de build fixe (GitLab runner Docker + `pwsh`).
5. **Pas d'état implicite.** Ni `~/.npmrc`, `pip.conf`, ni variables héritées du shell : en CI, environnement minimal (`PIP_CONFIG_FILE=/dev/null`, `NPM_CONFIG_USERCONFIG` vers un fichier du dépôt).
   Caches partagés seulement s'ils sont indexés par le hash du lockfile (`RUN --mount=type=cache` de BuildKit), jamais un dossier commun modifiable.
6. **Reproductibilité.** `SOURCE_DATE_EPOCH` = date du commit, `PYTHONHASHSEED=0`, pas de `latest`, pas de `--pull` implicite en cours de build.
7. **Fins de ligne.** Les Dockerfile/yml/conf doivent rester en LF (le `.gitattributes` de ce dossier le force ; la chaîne les renormalise aussi à la copie). Un CRLF casse les `RUN ... \`.
8. **Windows.** `git config core.longpaths true` et `LongPathsEnabled=1` (node_modules), `OutRoot` court (ex. `C:\workspace\twins_builds`) et hors OneDrive.
9. **Séparer build et run.** Rien de secret à la construction ; les secrets sont générés au run (`.runs\<run>.env`) ou fournis par le gestionnaire de secrets de la CI.
10. **Données.** Jamais de volume partagé entre runs. Pour PostgreSQL 15 -> 18 : `pg_upgrade` ou export/import, répété sur une copie avant la bascule. Pour Neo4j 5.21 -> 5.26 : `neo4j-admin database dump` avant, puis test sur volume neuf.
    Avec les images PostgreSQL 18, le volume se monte sur `/var/lib/postgresql` (déjà fait dans le compose).

## Limites connues

* Les noms de variables d'environnement du backend dans `docker-compose.yml` (`DATABASE_URL`, `NEO4J_*`) sont à aligner sur `backend/app/modules/shared/config.py` (repérés `VERIFY`).
* Pas de worker Celery ni de broker dans le compose : à ajouter dès que le broker est identifié.
* `install_needed.ps1` et `lab doctor` codent encore PostgreSQL 15, Neo4j 5.21, Python >= 3.11 et Node 22 : ils devraient lire `versions.psd1`.
