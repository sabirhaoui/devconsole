import contextlib
import io
import os
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts" / "twins_lab"))
import lab


class LabCliTests(unittest.TestCase):
    def dispatch(self, arguments, handler):
        with patch.object(sys, "argv", ["lab", *arguments]), patch.object(lab, handler) as command:
            lab.main()
        return command.call_args.args[0]

    def run_aveva_log(self, local_appdata, *arguments):
        stdout, stderr = io.StringIO(), io.StringIO()
        with patch.dict(os.environ, {"LOCALAPPDATA": local_appdata}), \
             patch.object(sys, "argv", ["lab", "aveva", "log", *arguments]), \
             contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            with self.assertRaises(SystemExit) as result:
                lab.main()
        return result.exception.code, stdout.getvalue(), stderr.getvalue()

    def test_aveva_log_reads_latest_lines(self):
        with TemporaryDirectory() as directory:
            path = Path(directory) / "Aveva" / "AVEVA Unified Engineering_init.log"
            path.parent.mkdir()
            lines = [f"Initialisation {number}" for number in range(81)]
            lines += ["custom_evars.bat:12 Unsupported command exit", "custom_evars.bat:13 Invalid syntax"]
            path.write_text("\n".join(lines) + "\n", encoding="utf-8-sig")
            for options, count in (([], 80), (["--lines", "2"], 2)):
                with self.subTest(options=options):
                    code, stdout, stderr = self.run_aveva_log(directory, *options)
                    header, modified, *output = stdout.splitlines()
                    self.assertEqual((code, stderr), (0, ""))
                    self.assertIn(str(path.resolve()), header)
                    self.assertRegex(modified, r"^Dernière modification : \d{4}-\d{2}-\d{2}")
                    self.assertEqual(output, lines[-count:])

    def test_aveva_log_missing_file(self):
        with TemporaryDirectory() as directory:
            code, stdout, stderr = self.run_aveva_log(directory)
        self.assertEqual((code, stdout), (1, ""))
        self.assertIn("journal introuvable", stderr)
        self.assertIn("AVEVA Unified Engineering_init.log", stderr)

    def test_aveva_log_follows_appended_lines(self):
        with TemporaryDirectory() as directory:
            path = Path(directory) / "Aveva" / "AVEVA Unified Engineering_init.log"
            path.parent.mkdir()
            path.write_text("Ancien diagnostic\n", encoding="utf-8")

            def append_line(_interval):
                if pause.call_count > 1:
                    raise KeyboardInterrupt
                with path.open("a", encoding="utf-8") as journal:
                    journal.write("Invalid syntax\n")

            with patch("workspace_projects.sleep", side_effect=append_line) as pause:
                code, stdout, stderr = self.run_aveva_log(directory, "--lines", "0", "--follow")
        self.assertEqual((code, stderr), (130, ""))
        self.assertEqual(stdout.splitlines()[2:], ["Invalid syntax"])

    def test_assemble_build(self):
        args = self.dispatch(["project_twin", "assemble", "build"], "cmd_assemble")
        self.assertEqual(args.project, "project_twin")
        self.assertEqual(args.extra, ["build"])

    def test_assemble_forwarded_arguments(self):
        args = self.dispatch(["project_twin", "assemble", "--", "-UpTo", "build"], "cmd_assemble")
        self.assertEqual(args.extra, ["-UpTo", "build"])

    def test_run_options(self):
        args = self.dispatch(["project_twin", "run", "all", "--engine", "docker", "--port", "4300"], "cmd_run")
        self.assertEqual((args.component, args.engine, args.port), ("all", "docker", 4300))

    def test_trail_logs_defaults(self):
        args = self.dispatch(["project_twin", "trail", "logs"], "cmd_trail")
        self.assertEqual((args.engine, args.tail, args.services, args.no_follow),
                         ("podman", 100, [], False))

    def test_production_collector_options(self):
        args = self.dispatch(["project_twin", "trail", "production", "start", "--target",
                              "sftp.prod.assystan", "--services", "backend", "celery-worker"], "cmd_trail")
        self.assertEqual(args.production_action, "start")
        self.assertEqual(args.services, ["backend", "celery-worker"])
        self.assertEqual(args.target, "sftp.prod.assystan")
        self.assertEqual(args.tail, "all")
        self.assertEqual(args.backups, 0)
        self.assertIsNone(args.output)

    def test_trail_logs_options(self):
        args = self.dispatch(["project_twin", "trail", "logs", "backend", "--engine", "docker",
                              "--tail", "25", "--no-follow"], "cmd_trail")
        self.assertEqual((args.services, args.engine, args.tail, args.no_follow),
                         (["backend"], "docker", 25, True))

    def test_trail_negative_tail_rejected(self):
        with patch.object(sys, "argv", ["lab", "project_twin", "trail", "logs", "--tail", "-1"]), \
             contextlib.redirect_stderr(io.StringIO()), patch.object(lab, "cmd_trail") as command:
            with self.assertRaises(SystemExit) as result:
                lab.main()
            self.assertEqual(result.exception.code, 2)
            command.assert_not_called()

    def test_component_named_assemble_is_not_an_action(self):
        args = self.dispatch(["project_twin", "test", "assemble", "--unit"], "cmd_test")
        self.assertEqual(args.component, "assemble")
        self.assertTrue(args.unit)

    def test_missing_or_unknown_project_rejected(self):
        for argv in (["list"], ["unknown", "list"], []):
            with self.subTest(argv=argv), patch.object(sys, "argv", ["lab", *argv]), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as result:
                    lab.main()
                self.assertEqual(result.exception.code, 2)
