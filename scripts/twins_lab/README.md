# twins_lab

Work on one slice of twins_project without booting the whole thing.

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
