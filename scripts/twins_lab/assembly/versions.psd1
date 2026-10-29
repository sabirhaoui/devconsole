@{
    # Politique de versions du projet twins_project (plan de montée de versions).
    #   Floor   = plancher bloquant   : en dessous -> FAIL
    #   Target  = cible attendue      : en dessous -> UPGRADE (FAIL avec -Strict)
    #   Ceiling = borne haute exclue  : au-dessus  -> WARN (version pas encore validée)
    Policy = @{
        Python     = @{ Floor = '3.11'; Target = '3.14'; Ceiling = '3.15'; Note = 'Cible 3.14 minimum (version d''Ubuntu 26.04). 3.15 est sortie le 9 octobre : attendre que les librairies suivent.' }
        Node       = @{ Floor = '22.0'; Target = '26.0'; Ceiling = '27.0'; Note = 'Cible Node 26, qui passe en LTS fin octobre 2026. Angular 22 le supporte déjà.' }
        Angular    = @{ Floor = '22.0'; Target = '22.0'; Ceiling = '23.0'; Note = 'Rien à faire.' }
        PostgreSQL = @{ Floor = '15';   Target = '18';   Ceiling = '19';   Note = 'Cible 18. La montée demande un export/import ou pg_upgrade, pas juste un changement de tag.' }
        Neo4j      = @{ Floor = '5.21'; Target = '5.26'; Ceiling = '5.27'; Note = 'Cible 5.26 LTS (dernière de la branche 5, corrigée jusqu''en juin 2028). Passer à la 2026.x est un chantier à part.' }
    }

    # Images de base utilisées pour construire et livrer l'instance.
    # Pour une isolation stricte, remplacer les tags par des digests (image@sha256:...).
    Images = @{
        Python     = 'python:3.14-slim'
        Node       = 'node:26-slim'
        Nginx      = 'nginx:stable-alpine'
        PostgreSQL = 'postgres:18'
        Neo4j      = 'neo4j:5.26-community'
    }
}
