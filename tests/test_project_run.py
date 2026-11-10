import argparse
import errno
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch, MagicMock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts" / "twins_lab"))
import project_run


class ProjectRunTests(unittest.TestCase):
    def test_logs_stream_and_snapshot_preserve_exit_code(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            compose = root / "compose.yaml"
            compose.write_text("services: {}")
            for no_follow in (False, True):
                with self.subTest(no_follow=no_follow), \
                     patch.object(project_run.shutil, "which", return_value="podman"), \
                     patch.object(project_run.subprocess, "run", return_value=subprocess.CompletedProcess([], 7)) as run:
                    args = argparse.Namespace(engine="podman", tail=25, services=["backend"], no_follow=no_follow)
                    with self.assertRaises(SystemExit) as result:
                        project_run.trail_logs(args, root)
                    self.assertEqual(result.exception.code, 7)
                    expected = ["podman", "compose", "-f", str(compose.resolve()), "logs",
                                "--tail", "25", "--timestamps"]
                    if not no_follow:
                        expected.append("--follow")
                    run.assert_called_once_with([*expected, "backend"], cwd=root.resolve())

    def test_logs_missing_compose_does_not_run(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(project_run.subprocess, "run") as run:
            with self.assertRaisesRegex(SystemExit, "Compose introuvable"):
                project_run.trail_logs(argparse.Namespace(engine="podman"), Path(temp))
            run.assert_not_called()

    def test_repeated_run_reuses_only_this_projects_frontend(self):
        with tempfile.TemporaryDirectory() as temp:
            root = self.prepare(temp)
            socket = MagicMock()
            socket.__enter__.return_value.bind.side_effect = OSError(errno.EADDRINUSE, "busy")
            with patch.object(project_run.shutil, "which", side_effect=lambda name: name), \
                 patch.object(project_run.socket, "socket", return_value=socket), \
                 patch.object(project_run, "project_frontend_is_running", return_value=True), \
                 patch.object(project_run.subprocess, "run", side_effect=[
                     subprocess.CompletedProcess([], 0, "backend\npostgres\n"),
                     subprocess.CompletedProcess([], 0)]) as run:
                with self.assertRaises(SystemExit) as result:
                    project_run.run_project(self.args(), root, root / "generated")
                self.assertEqual(result.exception.code, 0)
                self.assertEqual(run.call_count, 2)
                self.assertFalse(any(call.args[0][0] == "node" for call in run.call_args_list))

    def test_foreign_port_listener_is_not_reused_or_stopped(self):
        with tempfile.TemporaryDirectory() as temp:
            root = self.prepare(temp)
            socket = MagicMock()
            socket.__enter__.return_value.bind.side_effect = OSError(errno.EADDRINUSE, "busy")
            with patch.object(project_run.shutil, "which", side_effect=lambda name: name), \
                 patch.object(project_run.socket, "socket", return_value=socket), \
                 patch.object(project_run, "project_frontend_is_running", return_value=False), \
                 patch.object(project_run.subprocess, "run") as run:
                with self.assertRaisesRegex(SystemExit, "--port 4201"):
                    project_run.run_project(self.args(), root, root / "generated")
                run.assert_not_called()

    def prepare(self, directory):
        root = Path(directory)
        (root / "docker-compose.yml").write_text("services: {}")
        (root / ".env").write_text("KEEP=existing\n")
        angular = root / "frontend/node_modules/@angular/cli/bin/ng.js"
        angular.parent.mkdir(parents=True)
        angular.write_text("// fixture")
        (root / "frontend/proxy.conf.json").write_text(json.dumps({"/srm/assunifier": {"target": "http://localhost:3000"}}))
        return root

    def args(self, action="up"):
        return argparse.Namespace(engine="podman", action=action, port=4200, extra=[])

    def test_run_reuses_build_preserves_env_and_proxy_and_excludes_seed(self):
        with tempfile.TemporaryDirectory() as temp:
            root = self.prepare(temp)
            def execute(command, **kwargs):
                if command[-2:] == ["config", "--services"]:
                    return subprocess.CompletedProcess(command, 0, "backend\npostgres\nseed-db\n")
                return subprocess.CompletedProcess(command, 0)
            with patch.object(project_run.shutil, "which", side_effect=lambda name: name), \
                 patch.object(project_run.socket, "socket", return_value=MagicMock()), \
                 patch("local_logs.run_angular", return_value=0) as angular, \
                 patch.object(project_run.subprocess, "run", side_effect=execute) as run:
                with self.assertRaises(SystemExit) as exit_info:
                    project_run.run_project(self.args(), root, root / "generated")
            self.assertEqual(exit_info.exception.code, 0)
            self.assertEqual((root / ".env").read_text(), "KEEP=existing\n")
            proxy = json.loads((root / "generated/proxy.project.json").read_text())
            self.assertIn("/srm/assunifier", proxy)
            self.assertEqual(proxy["/api"]["target"], "http://127.0.0.1:8001")
            commands = [call.args[0] for call in run.call_args_list]
            self.assertIn("--no-build", commands[1])
            self.assertNotIn("seed-db", commands[1])
            self.assertEqual(angular.call_args.args[0][0], "node")

    def test_failed_compose_does_not_launch_frontend(self):
        with tempfile.TemporaryDirectory() as temp:
            root = self.prepare(temp)
            with patch.object(project_run.shutil, "which", side_effect=lambda name: name), \
                 patch.object(project_run.socket, "socket", return_value=MagicMock()), \
                 patch.object(project_run.subprocess, "run", side_effect=[
                     subprocess.CompletedProcess([], 0, "backend\npostgres\n"),
                     subprocess.CalledProcessError(1, "podman")]) as run:
                with self.assertRaises(SystemExit):
                    project_run.run_project(self.args(), root, root / "generated")
                self.assertEqual(run.call_count, 2)

    def test_stop_requires_neither_frontend_nor_env_and_keeps_volumes(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "compose.yaml").write_text("services: {}")
            with patch.object(project_run.shutil, "which", return_value="podman"), \
                 patch.object(project_run.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)) as run:
                with self.assertRaises(SystemExit) as result:
                    project_run.run_project(self.args("stop"), root, root / "generated")
                self.assertEqual(result.exception.code, 0)
                self.assertEqual(run.call_args.args[0][-1], "stop")


if __name__ == "__main__":
    unittest.main()
