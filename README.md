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

Pour vérifier l'état de l'environnement, des dépendances Python (`requirements.txt`), des packages npm, des bases natives PostgreSQL/Neo4j et des services Docker Compose, sans déclencher d'installation :

```powershell
lab install --check
```

Le contrôle distingue les prérequis du build de ceux du run. Il vérifie
explicitement PostgreSQL natif (port `5432`) et Compose (port `5433`), Neo4j
natif (Bolt `7688`) et Compose (Bolt `7687`), ainsi que les autres services
Twins. Pour installer les outils et dépendances manquants :

```powershell
lab install all
```

`lab install all` installe également PostgreSQL 15 natif, Java Temurin 17 et
Neo4j Community 5.21. Neo4j natif utilise les ports 7688/7475 pour éviter les
conflits avec Compose. L'installation ne démarre pas les bases ni les
conteneurs. Après l'installation, depuis la racine de `twins_project`, lancez
`docker compose up --build -d`, puis `npm start` depuis `frontend` pour démarrer
Angular. Utilisez `lab install --dashboard` pour générer et ouvrir directement
le tableau de bord; `lab install all --dashboard` l'ouvre après l'installation.
Exécutez `lab doctor` pour vérifier que les services sont accessibles.

La commande équivalente pour générer le dashboard manuellement reste :

```powershell
python .\scripts\twins_lab\diagnos_dashboard.py --open
```
or

```powershell
lab install all --dashboard

`lab doctor --phase build` vérifie uniquement les prérequis de compilation et
peut être lancé avant le démarrage des services.

Pour initialiser ou reconstruire la console depuis la racine de `devConsole` :

```powershell
.\Start-DevConsole.ps1

```

Souhaitez-vous que j'affine certains aspects de ce README synthétique ou que j'ajoute des détails sur la configuration des fichiers TOML de composants ?