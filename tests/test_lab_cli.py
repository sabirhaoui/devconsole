import contextlib
import io
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts" / "twins_lab"))
import lab


class LabCliTests(unittest.TestCase):
    def dispatch(self, arguments, handler):
        with patch.object(sys, "argv", ["lab", *arguments]), patch.object(lab, handler) as command:
            lab.main()
        return command.call_args.args[0]

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
