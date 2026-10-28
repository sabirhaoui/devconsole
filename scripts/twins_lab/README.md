# twins_lab

Work on one slice of twins_project without booting the whole thing.

    lab install --check                    # verify build prerequisites and the full runtime (no changes)
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

`lab install all` uses winget to install missing Python, Node.js, Git, GNU Make
and Docker Desktop tools, creates/reuses `backend/.venv`, installs
`backend/requirements.txt`, runs `npm ci` in the frontend, and copies
`.env.example` to `.env` only when `.env` is absent. It validates the build
prerequisites after installation but does not start containers or the Angular
development server.

PostgreSQL 15 is a Docker Compose service, not a separate Windows installation.
The same applies to Neo4j 5.21, Redis 7, Mailpit, the backend, Celery workers,
Flower and Nginx. The full diagnostic lists PostgreSQL explicitly, checks that
the container accepts connections with `pg_isready`, verifies the exposed
database port, and reports the state of each required Compose service. It also
checks the Angular dev server expected on port 4200. No native `psql` install is
needed for this setup.

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
`twins-lab-prerequisites.html` in the current directory. The report separates
build prerequisites from runtime services, including PostgreSQL readiness. Use
`--open` to open it in your browser or `--output <path>` to choose another
location. A dashboard with missing required prerequisites is still generated
and returns exit code 1. The installer's `-Check` option is read-only and runs
the same full diagnostic.

Declare backend and frontend test locations with `test_paths` in their respective
TOML sections. `test all` runs the declared suites for every component; a component
name runs only that component's suites.
