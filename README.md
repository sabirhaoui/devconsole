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

La syntaxe est `lab <projet> <action> [arguments]`. Les projets sont `project_twin`, `aras`, `aveva` et `a2-connector`. Consultez `lab --help` ou `lab <projet> --help`.

### Développer avec Aras, AVEVA et le connecteur A2

| Projet | Commandes |
| --- | --- |
| AVEVA | `lab aveva run`, `status`, `stop`, `logs` |
| Aras | `lab aras build`, `run`, `status`, `stop`, `logs`, `test` |
| Connecteur A2 | `lab a2-connector restore`, `build`, `run`, `status`, `stop`, `logs`, `test`, `lint`, `smoke` |

Copiez [lab.local.example.toml](scripts/twins_lab/lab.local.example.toml) en `scripts/twins_lab/lab.local.toml` et renseignez les lanceurs du poste. AVEVA et Aras nécessitent les points d’entrée de vos installations. Les commandes `restore`, `build`, `test` et `lint` d’A2 utilisent déjà `dotnet` et nécessitent une solution .NET dans le dépôt. Configurez `run` avec le chemin du projet de l’API et `smoke` avec le script de test des deux flux sur un environnement de développement.

Par défaut, les commandes s’exécutent dans les dossiers frères de `devConsole`. Pour changer de dossier, utilisez `--root` avant l’action, les variables `AVEVA_ROOT`, `ARAS_ROOT`, `A2_CONNECTOR_ROOT`, ou `root` dans la configuration locale, dans cet ordre de priorité.

```powershell
lab aveva doctor
lab aras build --dry-run
lab a2-connector --root C:/workspace/a2-connector test '--' --filter Category=Unit
```

`doctor` vérifie le dossier et la présence des lanceurs. `--dry-run` affiche le dossier et les arguments sans lancer le programme. Dans PowerShell, écrivez le séparateur `'--'` entre guillemets pour transmettre les arguments qui suivent au lanceur.

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

Pour consulter les logs de l’instance locale en cours :

```powershell
lab project_twin trail logs                         # 100 dernières lignes par service, puis suivi en direct
lab project_twin trail logs backend                 # filtrer sur le backend
lab project_twin trail logs --tail 500 --no-follow   # afficher puis quitter
lab project_twin trail logs --engine docker         # si l’instance utilise Docker
```

`Ctrl+C` quitte le suivi sans arrêter les services. La commande utilise le projet Compose
de `TWINS_ROOT` (ou de `lab.toml`). Les logs Angular restent dans le terminal de `run all`.

Pour collecter les logs de développement dans des fichiers exploitables :

```powershell
lab project_twin trail local start
lab project_twin trail local status
lab project_twin trail local stop
```

Le collecteur récupère l’historique disponible des conteneurs Compose et suit les nouvelles lignes.
`status` indique le PID, le curseur, les sources Compose déjà observées et les fichiers Angular.
Utiliser `--engine docker` sur les trois commandes si l’instance tourne avec Docker.
Pour cibler certains services, ajouter par exemple `--services backend postgres` au démarrage.

Dans `C:\workspace\logs\project_twins\local\podman` (ou `local\docker`),
lire `events*.jsonl` pour Compose et `angular.*.jsonl` pour la sortie du serveur Angular.
Les événements utilisent le même format que la collecte de production et portent `target: "local"`.
Au prochain `run all`, Angular écrit aussi dans ce dossier, avec une source par port.
Un Angular déjà lancé garde sa sortie dans son terminal jusqu’à son prochain démarrage.
`trail local stop` arrête le collecteur Compose. Angular écrit tant que `run all` tourne.

Pour rapatrier les logs de production en continu sur la machine locale :

```powershell
lab project_twin trail production start --target sftp.prod.assystan
lab project_twin trail production status --target sftp.prod.assystan
lab project_twin trail production stop --target sftp.prod.assystan
# Filtrage optionnel au démarrage : --services backend celery-worker
# Exécution au premier plan pour diagnostic : remplacer start par run
```

`status` vérifie le PID auprès du système (`pid_running`) et le verrou du collecteur
(`running`). `collector_verified: true` confirme les deux vérifications. Un PID peut
être réutilisé par un autre processus : son existence seule ne prouve pas la collecte.
`pid_running: null` signifie que le système n’a pas autorisé la vérification du PID.
`stop` arrête uniquement le collecteur local et conserve les fichiers déjà copiés.

Le collecteur tourne en arrière-plan indépendamment du terminal. Il utilise SSH sans
interaction et la configuration `ubuntu` / `ubuntu.targets` de `scripts/twins_lab/lab.toml`.
Les paramètres Compose proviennent de `database_sync` ; une table `production_logs`
au même niveau permet de remplacer `remote_project`, `remote_compose_project`,
`remote_compose_file`, `remote_env_file` et `remote_sudo` pour la collecte seule.
La clé SSH doit être disponible et l’hôte déjà reconnu par SSH ; `sudo`, si activé,
doit autoriser Docker sans mot de passe. Aucune installation ni modification des services distants.

Les fichiers sont dans `<workspace>/logs/project_twins/<cible>/`, soit
`C:\workspace\logs\project_twins\sftp.prod.assystan` sur cette machine.
Utiliser `--output <dossier>` pour choisir un autre dossier racine (également pour status/stop).
Au premier démarrage dans un nouveau dossier, tout l’historique encore disponible dans
Docker est récupéré (`--tail all`, défaut), puis la collecte continue en direct.
Les logs déjà supprimés par la rétention distante ne peuvent pas être récupérés.

- `events.jsonl` : un objet JSON par ligne, écrit immédiatement en UTF-8 ; rotation à 20 Mio,
  avec conservation de toutes les archives `events.<identifiant>.jsonl` par défaut.
  La source de l’autre service est l’ensemble des fichiers `events*.jsonl`, y compris
  le fichier actif qu’il peut suivre en continu. `--max-mb` ajuste la taille ;
  `--backups N` limite explicitement la rétention à N archives (0 conserve tout).
- `status.json` : PID, état, source, services et dernier horodatage reçu.
- `ssh.log` et `collector.log` : diagnostics de connexion et du processus local.

Chaque événement contient `schema_version`, `received_at` (UTC), `timestamp` (source),
`target`, `host`, `service` (préfixe Compose), `message` et `raw`. Une trace multiligne
produit plusieurs événements. Les logs peuvent contenir des données sensibles ; limiter
l’accès au dossier local aux consommateurs prévus.

Après une coupure SSH, reconnexion toutes les cinq secondes avec reprise à partir du
curseur enregistré, moins cinq secondes. Des doublons sont possibles : le consommateur
peut les rapprocher par source, service, horodatage et contenu. La reprise dépend des logs
encore disponibles dans Docker ; ce collecteur ne garantit pas une livraison exhaustive.
Arrêter le collecteur avant de changer les services filtrés (le curseur existant est réutilisé).
Il faut relancer `start` après un redémarrage Windows ; ce processus n’est pas installé
comme service Windows à démarrage automatique.

`Ctrl+C` arrête Angular ; utiliser `--action stop` pour arrêter aussi les services.
Avec Docker, ajouter `--engine docker` aux commandes de statut et d'arrêt.
Ce mode utilise les bases du Compose du projet ; il ne raccorde pas automatiquement
les bases dédiées créées par `ubuntu fetch-db --restore`.
Les commandes de composants isolés (`lab project_twin run experimentation backend` ou
`lab project_twin run experimentation frontend`) restent disponibles.
