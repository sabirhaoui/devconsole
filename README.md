# DevConsole & Twins Lab

Interface PowerShell et moteur CLI modulaire (`lab`) conçus pour administrer, isoler et tester le monorepo **Twins Project** sous Windows.

---

## 🚀 Vision & Roadmap du Laboratoire

Le Twins Lab ambitionne de centraliser la gestion du projet au bout des doigts :

* **Isolation des composants :** Chaque module (backend et frontend) dispose d'une configuration découplée (`components/*.toml`) permettant de travailler de manière autonome sans lancer l'intégralité du monorepo.
* **Traçabilité des builds :** Génération de manifestes SCM (Git SHA, état de l'arbre de travail) par composant.
* **Validation unifiée :** Capacité d'exécuter des cycles de vie ciblés ou globaux (`test all`) combinant tests unitaires Python (`pytest`), tests d'intégration et suites de composants Angular (`Jest`).
* **Exécution Full-Stack conjointe :** Pilotage synchronisé du backend (FastAPI sandboxé) et du frontend (Angular CLI avec proxy dynamique).

---

## 🛠️ Commandes Essentielles de la CLI `lab`

Grâce au profil PowerShell configuré, la commande globale `lab` est directement accessible depuis n'importe quel répertoire du workspace.

La syntaxe est désormais `lab <projet> <action> [arguments]`. Le projet disponible est `project_twin`. Le nom du projet est obligatoire : `lab assemble build` devient `lab project_twin assemble build`. Consultez `lab --help` et `lab project_twin --help`.

### 1. `list` — Inventaire des Composants

Affiche tous les modules enregistrés ainsi que leurs côtés actifs (`backend` + `frontend`) :

```powershell
lab project_twin list

```

### 2. `scan` — Découverte Automatique

Scann les dossiers du backend (`backend/app/modules/`) et auto-détecte les contreparties frontend pour enregistrer ou mettre à jour les fichiers de configuration `.toml` :

```powershell
lab project_twin scan component

```

### 3. `build` — Construction et Traçabilité

Compile le code source d'un composant et génère un manifeste de build incluant les métadonnées Git :

```powershell
lab project_twin build studio --standalone

```

### 4. `test` — Tout tester, ou cibler un composant, le backend ou le frontend

La même commande couvre deux périmètres : `all` pour le projet complet, ou le nom d'un composant pour ses tests dédiés. Sans `--side`, elle lance le backend puis le frontend ; `--side backend` et `--side frontend` permettent de choisir un seul côté.

| Périmètre | Backend + frontend | Backend uniquement | Frontend uniquement |
| --- | --- | --- | --- |
| Projet complet | `lab project_twin test all` | `lab project_twin test all --side backend` | `lab project_twin test all --side frontend` |
| Un composant (exemple : `experimentation`) | `lab project_twin test experimentation` | `lab project_twin test experimentation --side backend` | `lab project_twin test experimentation --side frontend` |

Les anciennes commandes `lab test all` et `lab test "component"` deviennent respectivement `lab project_twin test all` et `lab project_twin test "component"`.

**Lancer toutes les suites backend et frontend du projet :**

```powershell
lab project_twin test all
```

Sans nom de composant, `lab project_twin test` lance également toutes les suites.

**Lancer les tests d'un composant enregistré :**

```powershell
lab project_twin list
lab project_twin test "experimentation"
```

Remplacez `experimentation` par un nom affiché par `list`. Les chemins des tests ciblés sont définis dans `scripts/twins_lab/components/<composant>.toml`.

`all` lance la suite backend globale (chemins `[tests].backend_paths` de `lab.toml`, sinon `testpaths` du `backend/pyproject.toml`, sinon `backend/tests`) et Jest depuis `frontend`. Un composant utilise uniquement les `test_paths` de ses sections `[backend]` et `[frontend]`, relatifs à ces deux répertoires. Un composant sans chemins backend existants ou sans tests frontend déclarés est signalé et ignoré pour le côté concerné.

**Choisir le backend ou le frontend :**

```powershell
lab project_twin test all --side backend
lab project_twin test all --side frontend
lab project_twin test "experimentation" --side backend
lab project_twin test "experimentation" --side frontend
```

`frontend` est une valeur de l'option `--side`, pas un nom de composant à passer à `test`.

**Limiter le backend aux tests unitaires :**

```powershell
lab project_twin test all --side backend --unit
lab project_twin test "experimentation" --side backend --unit
```

Le backend utilise `pytest` et le frontend utilise `Jest`. Les tests nécessitent les dépendances du projet et utilisent la racine configurée par `TWINS_ROOT` ou `[project].root` dans `lab.toml`.

### 5. `run` — Exécution Locale Isolé

Démarre un service ou un composant de manière ciblée :

* **Backend isolé (FastAPI avec rechargement à chaud) :**
```powershell
lab project_twin run experimentation backend

```


* **Frontend connecté (Angular avec proxy automatique vers le backend local) :**
```powershell
lab project_twin run experimentation frontend

```



---

## 🩺 Diagnostics et Prérequis Système

Pour vérifier l'état de l'environnement, des dépendances Python (`requirements.txt`), des packages npm, des bases natives PostgreSQL/Neo4j et des services Docker Compose, sans déclencher d'installation :

```powershell
lab project_twin install --check
```

Le contrôle distingue les prérequis du build de ceux du run. Il vérifie
explicitement PostgreSQL natif (port `5432`) et Compose (port `5433`), Neo4j
natif (Bolt `7688`) et Compose (Bolt `7687`), ainsi que les autres services
Twins. Pour installer les outils et dépendances manquants :

```powershell
lab project_twin install all
```

`lab project_twin install all` installe également PostgreSQL 15 natif, Java Temurin 17 et
Neo4j Community 5.21. Neo4j natif utilise les ports 7688/7475 pour éviter les
conflits avec Compose. L'installation ne démarre pas les bases ni les
conteneurs. Après l'installation, depuis la racine de `twins_project`, lancez
`docker compose up --build -d`, puis `npm start` depuis `frontend` pour démarrer
Angular. Utilisez `lab project_twin install --dashboard` pour générer et ouvrir directement
le tableau de bord; `lab project_twin install all --dashboard` l'ouvre après l'installation.
Exécutez `lab project_twin doctor` pour vérifier que les services sont accessibles.

La commande équivalente pour générer le dashboard manuellement reste :

```powershell
python .\scripts\twins_lab\diagnos_dashboard.py --open
```
or

```powershell
lab project_twin install all --dashboard

`lab project_twin doctor --phase build` vérifie uniquement les prérequis de compilation et
peut être lancé avant le démarrage des services.

Pour initialiser ou reconstruire la console depuis la racine de `devConsole` :

```powershell
.\Start-DevConsole.ps1

```

## Authentification machine distance

Commandes pour s'authentifier à ubuntu depuis Windows, vérifier les services et exécuter des tests unitaires sont également disponibles.

'''
lab project_twin ubuntu auth sftp.prod.assystan
'''

## Récupérer PostgreSQL et Neo4j pour le développement local

La commande `fetch-db` télécharge les deux dumps par SSH dans un nouveau dossier
`data/db-snapshots/<date UTC>/`. Elle utilise la même cible que `ubuntu auth`.

Configurer `[ubuntu.database_sync]` dans `scripts/twins_lab/lab.toml` : chemin
du projet Compose distant, noms des services et mode PostgreSQL (`native` ou
`compose`). `remote_db_name` et `remote_db_user` restent définis dans `[ubuntu]`.
Chaque cible peut surcharger ces valeurs, y compris via sa table `database_sync`.
Les noms de cible inconnus sont refusés. SSH doit être disponible, la clé accessible
et l'hôte déjà connu d'OpenSSH (`lab project_twin ubuntu auth <cible>` pour la première connexion).
PostgreSQL utilise l'authentification configurée sur le serveur, par exemple `.pgpass`.

Pour la cible `sftp.prod.assystan`, le dump utilise le PostgreSQL du conteneur
du projet Compose `project-twin` (base `pmis_twin`, utilisateur `project_twin`).
Le fichier Compose distant et son `.env` sont sélectionnés explicitement via
`remote_compose_file`, `remote_env_file` et `remote_compose_project`.
`remote_sudo = true` permet leur lecture via `sudo -n`, sans prompt.
Il n'est pas nécessaire d'installer `pg_dump` sur Ubuntu : celui du conteneur est utilisé.
Avant `--restore-project`, la commande contrôle les versions locales par rapport aux
images serveur configurées : même majeure PostgreSQL, même branche Neo4j et patch
local au moins égal au patch serveur. Un échec annule l'opération avant tout dump
et arrêt distant.

Avec un dump Neo4j déjà préparé sur le serveur (aucun arrêt déclenché) :

```powershell
lab project_twin ubuntu fetch-db sftp.prod.assystan --neo4j-dump /var/backups/twins/neo4j.dump
```

Pour créer aussi le dump Neo4j à la demande, en autorisant explicitement une
interruption du service Neo4j distant sous Docker Compose :

```powershell
lab project_twin ubuntu fetch-db sftp.prod.assystan --stop-remote-neo4j
```

Neo4j doit être initialement démarré. La commande installe un piège de redémarrage,
arrête son service, exécute `neo4j-admin database dump` dans un conteneur temporaire
avec les mêmes volumes, puis redémarre le service même si le dump échoue. Une perte
de connexion ou un arrêt brutal de la machine nécessite de vérifier le service
distant. L'utilisateur SSH doit pouvoir exécuter Docker sans prompt sudo.
Python 3 doit être présent sur le serveur : avant l'arrêt, la commande refuse le
dump si un autre conteneur actif monte le même répertoire `/data`. Cela empêche
un ancien déploiement en doublon de prendre le verrou pendant l'export.
Pour un Neo4j natif, fournir un dump préparé hors ligne via `--neo4j-dump`.

### Injecter les bases serveur dans le projet local existant

Pour récupérer les bases et remplacer celles utilisées par `lab project_twin run all` :

```powershell
lab project_twin ubuntu fetch-db sftp.prod.assystan --stop-remote-neo4j --restore-project --replace-local --engine podman
```

Cette commande utilise le projet local défini par `TWINS_ROOT` ou `[project].root`.
Les services `postgres` et `neo4j` doivent déjà être démarrés. Le client PostgreSQL
et la version Neo4j locaux doivent être compatibles avec les dumps du serveur.
La configuration distante décrite ci-dessus doit correspondre à l'installation serveur.
Pour Docker local, remplacer `--engine podman` par `--engine docker`.

Les deux dumps sont entièrement téléchargés avant l'injection. Ensuite, les services
applicatifs locaux en cours d'exécution sont arrêtés et les deux bases locales sont
sauvegardées dans `data/db-snapshots/<date>/local-before-restore/`. Neo4j local est
arrêté pour sa sauvegarde et son chargement. La base PostgreSQL applicative est
recréée, puis restaurée ; les connexions PostgreSQL restantes sont déconnectées.
Les services précédemment actifs sont redémarrés après l'opération.
En cas d'échec, les sauvegardes sont restaurées automatiquement lorsque possible.
Si cette récupération échoue, les services arrêtés restent arrêtés et le chemin
des sauvegardes est affiché pour une récupération manuelle.

**Les données et comptes applicatifs locaux sont remplacés par ceux du serveur**,
y compris les utilisateurs créés seulement en local comme `graph_maker`.
Se connecter ensuite avec un compte applicatif présent sur le serveur.
Le `.env`, les identifiants techniques PostgreSQL/Neo4j et la base Neo4j `system`
restent locaux. Ne pas relancer le build pour cette opération : il n'est pas nécessaire.
Les navigateurs ou clients externes ne doivent pas écrire directement dans les bases
pendant la restauration. La sauvegarde et le remplacement concernent les services
Compose nommés `postgres` et `neo4j` et la base Neo4j `neo4j`.

Si un dump Neo4j est déjà disponible sur le serveur, éviter l'arrêt distant :

```powershell
lab project_twin ubuntu fetch-db sftp.prod.assystan --neo4j-dump /var/backups/twins/neo4j.dump --restore-project --replace-local --engine podman
```

### Restaurer dans des bases séparées du projet

Pour restaurer dans de **nouveaux volumes Docker locaux** :

```powershell
lab project_twin ubuntu fetch-db sftp.prod.assystan --neo4j-dump /var/backups/twins/neo4j.dump --restore
```

Avant `--restore`, renseigner `postgres_image` (version majeure compatible) et
`neo4j_image` (version compatible avec le dump serveur) dans `database_sync`.
Docker Compose v2 doit être installé et démarré. Les ports locaux par défaut sont
PostgreSQL `55432`, Neo4j Bolt `57687` et HTTP `57474`, accessibles uniquement
depuis cette machine. Ils sont configurables dans la même table. Un conflit de
port fait échouer le démarrage sans remplacer les bases locales existantes.

Le dossier contient les dumps, leurs empreintes SHA-256 et, avec `--restore`,
`compose.local.json` et `backend.local.env`. Charger ce dernier dans l'environnement
du backend lancé **sur Windows** pour utiliser les nouvelles bases (les adresses
`127.0.0.1` ne conviennent pas à un backend en conteneur). La console ne modifie pas
le `.env` du projet. Les mots de passe des bases locales sont générés ; pour la
connexion à l'application, utiliser un compte présent dans le dump PostgreSQL.
Un fournisseur SSO externe, sa configuration et les secrets applicatifs ne sont
pas copiés. La base Neo4j `system` et ses comptes administrateurs ne sont pas copiés.

Les deux exports sont séquentiels, sans garantie de cohérence transactionnelle
entre PostgreSQL et Neo4j. Prévoir une période sans écritures si l'application
exige cette cohérence. Un échec conserve les dumps terminés et retourne un code
non nul ; les transferts incomplets sont supprimés. Seul `--restore-project
--replace-local` remplace les données des bases existantes ; `--restore` utilise
des volumes neufs. Le chemin `--output` doit être un **nouveau dossier**.
Les fichiers contiennent des données et identifiants sensibles et sont ignorés par Git.

## Lancer un build complet du monorepo

'''
lab project_twin assemble build
'''

## Lancer Twins Project en local après le build

```powershell
lab project_twin assemble build
lab project_twin run all
```

`lab project_twin run all` réutilise les images construites avec Podman, démarre les services
Compose du projet. `lab project_twin run` est un raccourci équivalent.
Sous Windows, si Angular tourne déjà pour ce même projet sur le port demandé,
la commande réutilise cette instance et affiche son URL. Si un autre processus
occupe ce port, elle propose `--port` pour en choisir un autre.

Le démarrage des services utilise la configuration
Compose du projet (sans relancer `seed-db`), puis lance Angular dans le terminal.
Ouvrir **http://localhost:4200** lorsque la compilation Angular est terminée.
Les requêtes `/api` sont transmises au backend sur `http://localhost:8001`.
La commande utilise `TWINS_ROOT`, ou `[project].root` dans `lab.toml`.
Elle conserve le `.env` et les volumes existants. Node et les dépendances Angular
doivent déjà être installés (`npm ci` dans `frontend` si nécessaire).
Le moteur de conteneurs doit être démarré.

```powershell
lab project_twin run all --engine docker             # si le build a été fait avec Docker
lab project_twin run all --port 4300                 # autre port pour Angular
lab project_twin run all --action status             # état des conteneurs
lab project_twin run all --action stop               # arrêter les conteneurs, conserver les données
```

`Ctrl+C` arrête Angular ; utiliser `--action stop` pour arrêter aussi les services.
Avec Docker, ajouter `--engine docker` aux commandes de statut et d'arrêt.
Ce mode utilise les bases du Compose du projet ; il ne raccorde pas automatiquement
les bases dédiées créées par `ubuntu fetch-db --restore`.
Les commandes de composants isolés (`lab project_twin run experimentation backend` ou
`lab project_twin run experimentation frontend`) restent disponibles.
