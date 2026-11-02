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

### 4. `test` — Validation Modulaire

Exécute les suites de tests de manière granulaire ou globale :

* **Tous les tests (isolation SQLite + frontend) :**
```powershell
lab project_twin test all

```


* **Tests unitaires purs d'un module :**
```powershell
lab project_twin test experimentation --unit

```


* **Tests frontend d'un composant :**
```powershell
lab project_twin test frontend

```



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
Pour un Neo4j natif, fournir un dump préparé hors ligne via `--neo4j-dump`.

Pour restaurer immédiatement dans de **nouveaux volumes Docker locaux** :

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
non nul ; les transferts incomplets sont supprimés. La restauration n'écrase
jamais un volume existant. Le chemin `--output` doit être un **nouveau dossier**.
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
