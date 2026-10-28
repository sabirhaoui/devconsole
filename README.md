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

### 1. `list` — Inventaire des Composants

Affiche tous les modules enregistrés ainsi que leurs côtés actifs (`backend` + `frontend`) :

```powershell
lab list

```

### 2. `scan` — Découverte Automatique

Scann les dossiers du backend (`backend/app/modules/`) et auto-détecte les contreparties frontend pour enregistrer ou mettre à jour les fichiers de configuration `.toml` :

```powershell
lab scan component

```

### 3. `build` — Construction et Traçabilité

Compile le code source d'un composant et génère un manifeste de build incluant les métadonnées Git :

```powershell
lab build studio --standalone

```

### 4. `test` — Validation Modulaire

Exécute les suites de tests de manière granulaire ou globale :

* **Tous les tests (isolation SQLite + frontend) :**
```powershell
lab test all

```


* **Tests unitaires purs d'un module :**
```powershell
lab test experimentation --unit

```


* **Tests frontend d'un composant :**
```powershell
lab test frontend

```



### 5. `run` — Exécution Locale Isolé

Démarre un service ou un composant de manière ciblée :

* **Backend isolé (FastAPI avec rechargement à chaud) :**
```powershell
lab run experimentation backend

```


* **Frontend connecté (Angular avec proxy automatique vers le backend local) :**
```powershell
lab run experimentation frontend

```



---

## 🩺 Diagnostics et Prérequis Système

Pour vérifier l'état de l'environnement, des dépendances Python (`requirements.txt`), des packages npm, et des services de données (PostgreSQL, Neo4j, Redis, Mailpit via Docker Compose) sans déclencher d'installation :

```powershell
lab install --check
```

Le contrôle distingue les prérequis du build de ceux du run. Il vérifie
explicitement PostgreSQL dans Docker Compose, son état de connexion et le port
`localhost:5433`, ainsi que les autres services Twins. Pour installer les
outils et dépendances manquants :

```powershell
lab install all
```

Le projet utilise PostgreSQL via Docker Compose : aucun serveur PostgreSQL
Windows séparé n'est requis. Après l'installation, depuis la racine de
`twins_project`, lancez `docker compose up --build -d`, puis `npm start` depuis
`frontend` pour démarrer Angular. Exécutez `lab doctor` pour vérifier que les
services sont accessibles ou ouvrez le tableau de bord avec :

```powershell
python .\scripts\twins_lab\diagnos_dashboard.py --open
```

`lab doctor --phase build` vérifie uniquement les prérequis de compilation et
peut être lancé avant le démarrage des services.

Pour initialiser ou reconstruire la console depuis la racine de `devConsole` :

```powershell
.\Start-DevConsole.ps1

```

Souhaitez-vous que j'affine certains aspects de ce README synthétique ou que j'ajoute des détails sur la configuration des fichiers TOML de composants ?