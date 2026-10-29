# twins_lab

Work on one slice of twins_project without booting the whole thing.

    lab install --check                    # verify build prerequisites and the full runtime (no changes)
    lab install --dashboard                # generate and open the HTML diagnostic dashboard
    lab install all --dashboard            # install prerequisites, then open the dashboard
    lab install all                        # install tools and project dependencies
    lab doctor --phase build               # check build prerequisites only
    lab doctor                              # check build prerequisites and running services
    python diagnos_dashboard.py --open     # generate and open the HTML diagnostic dashboard

    .\lab.ps1 doctor                          # toolchain + repo path
    .\lab.ps1 list
    .\lab.ps1 inspect experimentation         # what it imports from / who imports it
    .\lab.ps1 up experimentation              # only the docker services it needs
    .\lab.ps1 test experimentation --unit     # backend unit + frontend jest, no DB
    .\lab.ps1 test experimentation --side backend -- -k run_rewind -x
    .\lab.ps1 run experimentation backend     # FastAPI with ONLY this router (+ /__lab/routes)
    .\lab.ps1 run experimentation frontend    # ng serve proxied to the lab API

Add a component = copy components/experimentation.toml, change paths.
The lab never edits the main repo: it only reads it and launches processes in it.

`lab install all` uses winget to install missing Python, Node.js, Git, GNU Make,
Docker Desktop, PostgreSQL 15, Temurin JDK 17, and the DevConsole CLI tools
(PowerShell 7, GitHub CLI, jq, uv, Maven, Gradle, Helm, kind, Minikube, GitLab
Runner, Terraform, CMake, .NET SDK, Go, and Rust/Cargo). It uses pip/pipx for
pip, Poetry, and the WSL-based Ansible installation, and npm for pnpm, Yarn,
TypeScript, and Angular CLI. It downloads Neo4j Community
5.21.0 from the official distribution site and verifies its SHA-256 checksum.
PostgreSQL's installer is interactive so its service account and password can
be configured locally. Neo4j is extracted under `%LOCALAPPDATA%\Programs\Neo4j`
and configured on Bolt port 7688 / HTTP port 7475 to avoid collisions with
Docker Compose. The script creates/reuses `backend/.venv`, installs
`backend/requirements.txt`, runs `npm ci` in the frontend, and copies
`.env.example` to `.env` only when `.env` is absent. It validates the build
prerequisites after installation but does not start databases, containers, or
the Angular development server. On first start, Neo4j asks you to replace its
initial `neo4j` password. Before connecting a local backend to native databases,
set `POSTGRES_PASSWORD`, `NEO4J_PASSWORD`, and `NEO4J_URI=bolt://localhost:7688`
in `.env` to match the local database setup. If WSL/Ubuntu is newly installed
for Ansible, restart Windows if requested, launch Ubuntu once to create its
Linux user, then rerun `lab install all`; the installer adds a Windows `ansible`
command that delegates to Ubuntu WSL.

To install the Podman CLI as an optional tool, run the installer with
`-InstallPodman`. This does not replace Docker Desktop for the current
Docker Compose runtime.

PostgreSQL 15 and Neo4j 5.21 are available both as native Windows installations
and as Docker Compose services. Redis 7, Mailpit, the backend, Celery workers,
Flower and Nginx remain Compose services. The full diagnostic checks native
PostgreSQL/Neo4j versions and their ports (5432/7688), as well as Compose
PostgreSQL readiness, exposed ports, and required running services. It also
checks the Angular dev server expected on port 4200.

After `lab install all` succeeds, review local secrets in `.env`, start Docker
Desktop, and run these commands from the Twins project root:

    docker compose up --build -d

Then start Angular from a second PowerShell terminal:

    cd frontend
    npm start

Run `lab doctor` after startup to check the complete build-and-run environment.
`lab doctor --phase build` reports only toolchain, project files, and dependency
installation status, so it can be used before starting Docker services.

`python diagnos_dashboard.py` runs the same checks as `lab doctor` and writes
`twins-lab-prerequisites.html` in the current directory. Use
`lab install --dashboard` (also accepts `--dahsboard`) to create and open it;
`lab install all --dashboard` opens it after installing. The report separates
build prerequisites from runtime services, including native database checks
and Compose PostgreSQL readiness. Use `--output <path>` with the Python script
to choose another location. A dashboard with missing required prerequisites is
still generated and returns exit code 1.

Declare backend and frontend test locations with `test_paths` in their respective
TOML sections. `test all` runs the declared suites for every component; a component
name runs only that component's suites.
