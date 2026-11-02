# Synchronisation des bases serveur vers le projet local

## Objectif

Récupérer PostgreSQL et Neo4j depuis le serveur, puis injecter leurs données dans
les bases Compose utilisées par le projet Twins local. Les comptes applicatifs,
leurs mots de passe hachés, leurs profils et leur état d'activation proviennent
alors du serveur : aucun compte de développement supplémentaire n'est nécessaire.

## Commande

```powershell
lab project_twin ubuntu fetch-db sftp.prod.assystan --stop-remote-neo4j --restore-project --replace-local --engine podman
```

Le projet local est résolu depuis `TWINS_ROOT` ou `[project].root` dans
`scripts/twins_lab/lab.toml`. Pour un moteur local Docker, utiliser `--engine docker`.

Les options ont les effets suivants :

- `--stop-remote-neo4j` autorise l'arrêt temporaire de Neo4j distant pour son dump.
- `--restore-project` cible les bases du projet local existant.
- `--replace-local` autorise le remplacement des données locales après sauvegarde.

Un dump Neo4j déjà disponible sur le serveur peut être fourni avec
`--neo4j-dump /chemin/neo4j.dump` à la place de `--stop-remote-neo4j`.
L'option historique `--restore` crée des bases Docker séparées ; elle ne peut pas
être combinée avec `--restore-project`.

## Configuration et contrôles

La configuration `[ubuntu.database_sync]` identifie explicitement le répertoire,
le fichier Compose, le nom du projet et le fichier d'environnement distants.
`remote_sudo` permet leur lecture via `sudo -n`. Aucun secret distant n'est
recopié dans la configuration suivie par Git.

PostgreSQL utilise `postgres_mode = "compose"` : `pg_dump` est exécuté dans le
conteneur serveur, sans nécessiter son installation sur l'hôte Ubuntu.
La base et l'utilisateur sont définis par `remote_db_name` et `remote_db_user`.

Avant l'injection, les versions actives locales sont contrôlées : même majeure
PostgreSQL, même branche Neo4j et patch local au moins égal à celui configuré pour
le serveur. La commande refuse les versions incompatibles ; elle ne migre pas
automatiquement les bases. Python 3 doit être disponible sur le serveur pour le
contrôle des volumes Neo4j partagés.

## Déroulement et sauvegardes

1. Télécharger les deux dumps par SSH, en mode binaire, puis calculer leurs SHA-256.
2. Arrêter les services applicatifs locaux actifs pour éviter leurs écritures.
3. Sauvegarder les bases locales avant tout remplacement.
4. Charger Neo4j hors ligne, recréer la base PostgreSQL applicative et restaurer son dump.
5. Redémarrer les services précédemment actifs.

Les fichiers sont conservés dans `data/db-snapshots/<date UTC>/`, avec les dumps
serveur, `manifest.json` et les sauvegardes locales dans `local-before-restore/`.
Ces données sensibles sont ignorées par Git. Les transferts incomplets sont
supprimés ; les dumps terminés sont conservés si une étape suivante échoue.

En cas d'échec d'injection, la commande tente de recharger les deux sauvegardes
locales. Si cette récupération échoue, les services arrêtés restent arrêtés et le
chemin des sauvegardes est indiqué pour une récupération manuelle.

Le `.env`, les comptes techniques des bases et la base Neo4j `system` restent
locaux. Les utilisateurs créés uniquement en local sont remplacés par ceux du
serveur. Les deux exports sont séquentiels et ne constituent pas un instantané
transactionnel commun ; prévoir une période sans écritures si cette cohérence est requise.

## Protection Neo4j contre les déploiements en doublon

Avant l'arrêt distant, la commande détecte les autres conteneurs actifs qui
montent le même répertoire `/data`. Elle refuse le dump en cas de partage afin
d'éviter qu'un autre déploiement prenne le verrou de la base pendant l'arrêt.
Elle n'arrête pas automatiquement ces autres conteneurs.

## Validation du 2 novembre 2026

La migration locale PostgreSQL 15 vers 18 et Neo4j 5.21 vers 5.26.32 a été réalisée
avec sauvegardes, après autorisation explicite. Les versions locales obtenues
sont PostgreSQL 18.6 et Neo4j 5.26.32.

Après l'injection, les contrôles en lecture seule ont confirmé :

- 20 utilisateurs actifs, avec des empreintes agrégées identiques des identifiants,
  mots de passe hachés, états d'activation et profils entre serveur et local ;
- 14 078 nœuds et 66 190 relations Neo4j de chaque côté ;
- un backend local répondant en HTTP 200 et une route d'authentification accessible
  via le proxy Angular, répondant en HTTP 401 en l'absence de connexion ;
- un frontend accessible sur `http://localhost:4200` et un Neo4j applicatif distant sain.

Le doublon Neo4j distant sans consommateur applicatif ni port publié a été arrêté
pour libérer le verrou du déploiement applicatif. Les données n'ont pas été supprimées.

Les 23 tests Python passent, dont les tests de transfert binaire, de sauvegarde,
de restauration, de récupération après échec et de détection de volume partagé.
Une connexion avec un mot de passe utilisateur réel n'a pas été testée : aucun
mot de passe du serveur n'a été demandé ou affiché.
