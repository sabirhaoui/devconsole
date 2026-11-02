import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts" / "twins_lab"))
import database_sync as sync


class DatabaseSyncTests(unittest.TestCase):
    def test_target_inherits_settings_and_rejects_unknown(self):
        config = {"host": "host", "user": "ubuntu", "database_sync": {"postgres_mode": "native"},
                  "targets": {"prod": {"host": "prod", "database_sync": {"neo4j_service": "graph"}}}}
        selected = sync.connection(config, "prod")
        self.assertEqual(selected["host"], "prod")
        self.assertEqual(selected["database_sync"], {"postgres_mode": "native", "neo4j_service": "graph"})
        with self.assertRaises(ValueError):
            sync.connection(config, "typo")

    def test_download_is_binary_and_atomic(self):
        with tempfile.TemporaryDirectory() as tmp:
            dest = Path(tmp) / "postgres.dump"
            def run(*args, **kwargs):
                kwargs["stdout"].write(b"\x00\xff\r\nPGDMP")
            with patch.object(sync.subprocess, "run", side_effect=run):
                sync.download(["ssh"], "pg_dump", dest)
            self.assertEqual(dest.read_bytes(), b"\x00\xff\r\nPGDMP")
            dest.unlink()
            def fail(*args, **kwargs):
                kwargs["stdout"].write(b"partial")
                raise subprocess.CalledProcessError(1, "ssh")
            with patch.object(sync.subprocess, "run", side_effect=fail):
                with self.assertRaises(subprocess.CalledProcessError):
                    sync.download(["ssh"], "pg_dump", dest)
            self.assertEqual(list(Path(tmp).iterdir()), [])

    def test_restore_uses_fresh_volumes_and_no_overwrite(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            (directory / "postgres.dump").write_bytes(b"dump")
            with patch.object(sync.subprocess, "run") as run:
                sync.restore_local(directory, {"postgres_image": "postgres:15", "neo4j_image": "neo4j:5.21"}, "neo4j")
            commands = [call.args[0] for call in run.call_args_list]
            self.assertIn("load", commands[0])
            self.assertFalse(any("--overwrite-destination" in str(command) for command in commands))
            self.assertIn("--single-transaction", commands[2])
            config = json.loads((directory / "compose.local.json").read_text())
            self.assertTrue(config["name"].startswith("twins-snapshot-"))
            self.assertEqual(config["services"]["postgres"]["ports"], ["127.0.0.1:55432:5432"])

    def test_requires_explicit_neo4j_strategy_before_connecting(self):
        args = argparse.Namespace(ubuntu_target=None, neo4j_dump=None, stop_remote_neo4j=False, restore=False)
        with patch.object(sync.subprocess, "run") as run:
            with self.assertRaises(SystemExit):
                sync.fetch_databases(args, {"ubuntu": {"host": "server", "user": "ubuntu"}}, Path("."))
            run.assert_not_called()

    def test_fetch_downloads_both_and_records_checksums(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "snapshot"
            args = argparse.Namespace(ubuntu_target="prod", neo4j_dump="/backup/neo4j.dump",
                                      stop_remote_neo4j=False, restore=False, output=str(output))
            config = {"ubuntu": {"host": "default", "user": "ubuntu", "targets": {"prod": {"host": "prod"}}}}
            def run(command, **kwargs):
                self.assertEqual(command[-2], "ubuntu@prod")
                kwargs["stdout"].write(b"PGDMP" if "pg_dump" in command[-1] else b"neo4j")
            with patch.object(sync.subprocess, "run", side_effect=run) as run_mock:
                sync.fetch_databases(args, config, Path(tmp))
            self.assertEqual(run_mock.call_count, 2)
            manifest = json.loads((output / "manifest.json").read_text())
            self.assertEqual(manifest["host"], "prod")
            self.assertEqual(set(manifest["sha256"]), {"postgres.dump", "neo4j.dump"})

    def test_failed_neo4j_download_does_not_restore(self):
        with tempfile.TemporaryDirectory() as tmp:
            args = argparse.Namespace(ubuntu_target=None, neo4j_dump="/backup/neo4j.dump",
                                      stop_remote_neo4j=False, restore=True, output=str(Path(tmp) / "snapshot"))
            config = {"ubuntu": {"host": "server", "user": "ubuntu", "database_sync": {
                "postgres_image": "postgres:15", "neo4j_image": "neo4j:5.21"}}}
            def download(ssh, command, destination):
                if destination.name == "neo4j.dump":
                    raise subprocess.CalledProcessError(1, "ssh")
                destination.write_bytes(b"pg")
            with patch.object(sync, "download", side_effect=download), patch.object(sync, "restore_local") as restore:
                with self.assertRaises(SystemExit):
                    sync.fetch_databases(args, config, Path(tmp))
                restore.assert_not_called()
            self.assertTrue((Path(args.output) / "postgres.dump").exists())
            self.assertFalse((Path(args.output) / "manifest.json").exists())

    def test_remote_restart_trap_precedes_stop_and_stdout_is_dump_only(self):
        script = sync.remote_neo4j_script(["docker", "compose", "--project-directory", "/srv/my project"], "neo4j", "neo4j")
        self.assertLess(script.index("trap restart EXIT"), script.index("stop neo4j"))
        self.assertIn("stop neo4j >&2", script)
        self.assertIn("start neo4j >&2", script)
        self.assertIn("--to-stdout", script)
        self.assertIn("'/srv/my project'", script)


if __name__ == "__main__":
    unittest.main()
