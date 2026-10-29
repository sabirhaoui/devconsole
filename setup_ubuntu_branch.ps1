# ==============================================================================
# Script d'intégration de la branche 'ubuntu' et publication sur le dépôt distant
# ==============================================================================

$devConsoleDir = "C:\workspace\devConsole"
if (-not (Test-Path $devConsoleDir)) {
    Write-Error "Le répertoire $devConsoleDir n'existe pas."
    exit 1
}

Set-Location $devConsoleDir

# 1. Création et basculement sur la branche Git 'ubuntu'
Write-Host "[+] Création et basculement sur la branche Git 'ubuntu'..." -ForegroundColor Green
git checkout -b ubuntu 2>$null
if ($LASTEXITCODE -ne 0) {
    git checkout ubuntu
}

# 2. Mise à jour de lab.toml avec les configurations par défaut de la VM
$tomlPath = Join-Path $devConsoleDir "lab.toml"
$ubuntuTomlSnippet = @"

[ubuntu]
host = "192.168.1.50"
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
        Write-Host "[+] Fichier lab.toml enrichi avec la section [ubuntu]." -ForegroundColor Cyan
    }
}

# 3. Ajout de la logique 'ubuntu' dans lab.py
$labPyPath = Join-Path $devConsoleDir "lab.py"
if (Test-Path $labPyPath) {
    $labPyContent = Get-Content $labPyPath -Raw

    # Injection du module de gestion Ubuntu si absent
    if ($labPyContent -notmatch "def cmd_ubuntu") {
        $ubuntuModuleCode = @'


# --------------------------------------------------------------------------- UBUNTU MANAGEMENT
def get_ubuntu_cfg(cfg: dict) -> dict:
    return cfg.get("ubuntu", {
        "host": "192.168.1.50",
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

    ssh_base = ["ssh", "-i", os.path.expanduser(key), "-p", port, f"{user}@{host}"]

    if subcommand in ("auth", "login"):
        print(f"=== [UBUNTU] Connexion SSH à la VM ({user}@{host}:{port}) ===")
        sh(ssh_base, cwd=root)

    elif subcommand == "dump":
        timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        dump_file = f"{backup_dir}/dump_{db_name}_{timestamp}.sql.gz"
        print(f"=== [UBUNTU] Génération du dump direct de la base '{db_name}' ===")
        remote_cmd = f"mkdir -p {backup_dir} && pg_dump -U {db_user} -d {db_name} | gzip > {dump_file} && ls -lh {dump_file}"
        sh(ssh_base + [remote_cmd], cwd=root)

    elif subcommand == "backup":
        timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        archive_name = f"backup_env_{timestamp}.tar.gz"
        print(f"=== [UBUNTU] Création d'un backup global de l'espace de travail ===")
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

    elif subcommand in ("history", "env"):
        print("=== [UBUNTU] Historisation & Versions des Environnements ===")
        remote_cmd = (
            "echo '--- GIT VERSION ---' && cd /workspace/twins_project && git log -1 --oneline && "
            "echo '--- DOCKER IMAGES ---' && docker images --format 'table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.CreatedAt}}' && "
            "echo '--- RECENT BACKUPS ---' && ls -lt " + backup_dir + " | head -n 10"
        )
        sh(ssh_base + [remote_cmd], cwd=root)

    else:
        print("=== [UBUNTU] Actions disponibles : auth, dump, backup, pipeline, history ===")

'@
        $labPyContent = $labPyContent -replace "def main\(\):", "$ubuntuModuleCode`n`ndef main():"
    }

    # Injection du sous-parser si absent
    if ($labPyContent -notmatch 'subparsers\.add_parser\("ubuntu"') {
        $parserBlock = @"
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

    args = parser.parse_args()
"@
        $labPyContent = $labPyContent -replace "args = parser\.parse_args\(\)", $parserBlock
    }

    # Injection du routage si absent
    if ($labPyContent -notmatch 'elif args\.command == "ubuntu":') {
        $routingBlock = @"
    elif args.command == "run":
        cmd_run(args, cfg, root)
    elif args.command == "ubuntu":
        cmd_ubuntu(args, cfg, root)
"@
        $labPyContent = $labPyContent -replace "elif args\.command == \"run\":\r?\n\s+cmd_run\(args, cfg, root\)", $routingBlock
    }

    Set-Content -Path $labPyPath -Value $labPyContent -Encoding UTF8
    Write-Host "[+] Fichier lab.py mis à jour avec les commandes ubuntu." -ForegroundColor Cyan
}

# 4. Commit et Publication sur le dépôt distant (origin)
Write-Host "[+] Validation des changements dans Git..." -ForegroundColor Green
git add .
git commit -m "feat(ubuntu): intégration native des commandes de gestion de la VM (SSH, dumps, backups, pipelines, versions)"

Write-Host "[+] Publication de la branche 'ubuntu' sur le dépôt distant (origin)..." -ForegroundColor Green
git push -u origin ubuntu

Write-Host "`n[SUCCESS] La branche 'ubuntu' a été créée, commitée et publiée avec succès !" -ForegroundColor Green