# ==============================================================================
# Script de création de la branche 'ubuntu' et intégration dans devConsole
# ==============================================================================

$devConsoleDir = "C:\workspace\devConsole"
if (-not (Test-Path $devConsoleDir)) {
    Write-Error "Le répertoire $devConsoleDir n'existe pas."
    exit 1
}

Set-Location $devConsoleDir

# 1. Création et basculement sur la branche Git 'ubuntu'
Write-Host "[+] Création et basculement sur la branche 'ubuntu'..." -ForegroundColor Green
git checkout -b ubuntu 2>$null
if ($LASTEXITCODE -ne 0) {
    git checkout ubuntu
}

# 2. Mise à jour de lab.toml avec les configurations Ubuntu
$tomlPath = Join-Path $devConsoleDir "lab.toml"
$ubuntuTomlSnippet = @"

[ubuntu]
host = "127.0.0.1"
port = 22
user = "ubuntu"
ssh_key = "~/.ssh/id_rsa"
remote_db_name = "twins_db"
remote_db_user = "postgres"
backup_dir = "/var/backups/twins"
"@

if (Test-Path $tomlPath) {
    $content = Get-Content $tomlPath -Raw
    if ($content -notmatch "\[ubuntu\]") {
        Add-Content -Path $tomlPath -Value $ubuntuTomlSnippet
        Write-Host "[+] Fichier lab.toml mis à jour avec les variables [ubuntu]." -ForegroundColor Cyan
    }
}

# 3. Ajout/Extension des commandes 'ubuntu' dans lab.py
$labPyPath = Join-Path $devConsoleDir "lab.py"
if (Test-Path $labPyPath) {
    $labPyContent = Get-Content $labPyPath -Raw

    $ubuntuModuleCode = @'

# --------------------------------------------------------------------------- UBUNTU MANAGEMENT
def get_ubuntu_cfg(cfg: dict) -> dict:
    return cfg.get("ubuntu", {
        "host": "127.0.0.1",
        "port": 22,
        "user": "ubuntu",
        "ssh_key": "~/.ssh/id_rsa",
        "remote_db_name": "twins_db",
        "remote_db_user": "postgres",
        "backup_dir": "/var/backups/twins"
    })

def cmd_ubuntu(args, cfg, root):
    subcommand = getattr(args, "ubuntu_action", None)
    u_cfg = get_ubuntu_cfg(cfg)

    host = u_cfg.get("host")
    user = u_cfg.get("user")
    port = str(u_cfg.get("port", 22))
    key = u_cfg.get("ssh_key")
    db_name = u_cfg.get("remote_db_name", "twins_db")
    db_user = u_cfg.get("remote_db_user", "postgres")
    backup_dir = u_cfg.get("backup_dir", "/var/backups/twins")

    ssh_base = ["ssh", "-i", key, "-p", port, f"{user}@{host}"]

    if subcommand == "auth" or subcommand == "login":
        print(f"=== [UBUNTU] Connexion SSH à la VM ({user}@{host}:{port}) ===")
        sh(ssh_base, cwd=root)

    elif subcommand == "dump":
        timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        dump_file = f"{backup_dir}/dump_{db_name}_{timestamp}.sql.gz"
        print(f"=== [UBUNTU] Génération du dump en direct sur la base '{db_name}' ===")
        remote_cmd = f"mkdir -p {backup_dir} && pg_dump -U {db_user} -d {db_name} | gzip > {dump_file} && ls -lh {dump_file}"
        sh(ssh_base + [remote_cmd], cwd=root)

    elif subcommand == "backup":
        timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        archive_name = f"backup_env_{timestamp}.tar.gz"
        print(f"=== [UBUNTU] Création d'un backup global de l'environnement ===")
        remote_cmd = f"mkdir -p {backup_dir} && tar -czvf {backup_dir}/{archive_name} --exclude='*.log' /workspace/twins_project"
        sh(ssh_base + [remote_cmd], cwd=root)

    elif subcommand == "pipeline":
        action = getattr(args, "pipeline_action", "status")
        print(f"=== [UBUNTU] Gestion des Pipelines CI/CD ({action}) ===")
        if action == "run":
            remote_cmd = "cd /workspace/twins_project && git pull && docker compose restart backend frontend"
        else:
            remote_cmd = "docker compose ps && docker logs --tail 50 twins_backend"
        sh(ssh_base + [remote_cmd], cwd=root)

    elif subcommand == "history" or subcommand == "env":
        print("=== [UBUNTU] Historisation & Version des Environnements ===")
        remote_cmd = (
            "echo '--- GIT VERSION ---' && cd /workspace/twins_project && git log -1 --oneline && "
            "echo '--- DOCKER IMAGES ---' && docker images --format 'table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.CreatedAt}}' && "
            "echo '--- RECENT BACKUPS ---' && ls -lt " + backup_dir + " | head -n 10"
        )
        sh(ssh_base + [remote_cmd], cwd=root)

    else:
        print("=== [UBUNTU] Commande inconnue ou manquante. Action disponible : auth, dump, backup, pipeline, history ===")

'@

    if ($labPyContent -notmatch "cmd_ubuntu") {
        # Injection du module avant le bloc 'main()'
        $labPyContent = $labPyContent -replace "(def main\(\):)", "$ubuntuModuleCode`n`$1"
        
        # Ajout du sous-parser CLI dans main()
        $parserRegistration = @'
    # Subparser Ubuntu
    p_ubuntu = subparsers.add_parser("ubuntu", help="Gestion de la VM Ubuntu, dumps, backups, pipelines")
    ubuntu_sub = p_ubuntu.add_subparsers(dest="ubuntu_action", required=True)
    
    ubuntu_sub.add_parser("auth", help="Connexion SSH à la VM")
    ubuntu_sub.add_parser("dump", help="Générer un dump de la BDD distante")
    ubuntu_sub.add_parser("backup", help="Créer une sauvegarde complète de l'environnement")
    
    p_pipe = ubuntu_sub.add_parser("pipeline", help="Gérer ou lancer les pipelines")
    p_pipe.add_argument("pipeline_action", nargs="?", default="status", choices=["status", "run"])
    
    ubuntu_sub.add_parser("history", help="Afficher l'historique et les versions des environnements")
    ubuntu_sub.add_parser("env", help="Alias pour history")
'@
        $labPyContent = $labPyContent -replace "(elif args\.command == \"run\":\r?\n\s+cmd_run\(args, cfg, root\))", "$1`n    elif args.command == `"ubuntu`":`n        cmd_ubuntu(args, cfg, root)"
        $labPyContent = $labPyContent -replace "(args = parser\.parse_args\(\))", "$parserRegistration`n`n    $1"

        Set-Content -Path $labPyPath -Value $labPyContent -Encoding UTF8
        Write-Host "[+] Fichier lab.py enrichi avec le module 'ubuntu'." -ForegroundColor Cyan
    }
}

# 4. Commit sur la branche 'ubuntu'
Write-Host "[+] Enregistrement des modifications sur Git..." -ForegroundColor Green
git add .
git commit -m "feat(ubuntu): Ajout du sous-groupe de commandes ubuntu (SSH, dumps, backups, pipelines, historisation)"

Write-Host "`n[SUCCESS] Branche 'ubuntu' prête et commandes intégrées avec succès !" -ForegroundColor Green