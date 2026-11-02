import argparse
import json
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts" / "twins_lab"))
import production_logs as logs


class ProductionLogsTests(unittest.TestCase):
    def test_current_pid_is_running_and_invalid_pid_is_not(self):
        import os
        self.assertTrue(logs.pid_is_running(os.getpid()))
        for pid in (None, 0, -1, "123", True):
            self.assertFalse(logs.pid_is_running(pid))

    def test_stale_status_does_not_report_reused_pid_as_collector(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            logs.save(directory / "status.json", {"pid": 123, "status": "streaming"})
            with patch.object(logs, "pid_is_running", return_value=True):
                state = logs.collector_status(directory, False)
            self.assertTrue(state["pid_running"])
            self.assertFalse(state["running"])
            self.assertFalse(state["collector_verified"])
            self.assertEqual(state["status"], "stopped")
            with patch.object(logs, "pid_is_running", return_value=True):
                self.assertTrue(logs.collector_status(directory, True)["collector_verified"])

    def test_full_history_is_requested_without_cursor(self):
        command = logs.ssh_command({"host": "prod", "user": "ubuntu"}, {}, [], None, "all")
        self.assertIn("--tail all", command[-1])
        self.assertNotIn("--since", command[-1])

    def test_rotation_keeps_every_segment(self):
        import logging
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "events.jsonl"
            handler = logs.ArchiveHandler(path, maxBytes=64, backupCount=0, encoding="utf-8")
            try:
                for i in range(30):
                    handler.emit(logging.LogRecord("test", logging.INFO, "", 0,
                                                   json.dumps({"i": i, "message": "example"}), (), None))
            finally:
                handler.close()
            rows = [json.loads(line) for file in Path(temp).glob("*.jsonl")
                    for line in file.read_text(encoding="utf-8").splitlines()]
            self.assertEqual(sorted(row["i"] for row in rows), list(range(30)))

    def test_ssh_command_is_read_only_and_quotes_remote_paths(self):
        remote = {"host": "prod.example", "user": "ubuntu", "ssh_key": "~/key"}
        settings = {"remote_sudo": True, "remote_project": "/project with spaces",
                    "remote_compose_project": "twins"}
        command = logs.ssh_command(remote, settings, ["backend"], "2026-11-02T12:00:00Z", 100)
        self.assertIn("BatchMode=yes", command)
        self.assertIn("sudo -n docker compose", command[-1])
        self.assertIn("'/project with spaces'", command[-1])
        self.assertIn("logs --follow --no-color --timestamps --since", command[-1])
        self.assertTrue(command[-1].endswith(" backend"))

    def test_event_preserves_multiline_and_timestamp(self):
        event = logs.record("backend-1 | 2026-11-02T12:00:00.123456789Z error | detail\n",
                            {"host": "prod"}, "production")
        self.assertEqual(event["service"], "backend-1")
        self.assertEqual(event["message"], "error | detail")
        self.assertEqual(logs.resume_since(event["timestamp"]), "2026-11-02T11:59:55.123456+00:00")
        self.assertIsNone(logs.record("traceback line", {"host": "prod"}, None)["timestamp"])

    def test_lock_prevents_duplicate_and_releases(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            guard = logs.lock(directory)
            self.assertIsNotNone(guard)
            self.assertIsNone(logs.lock(directory))
            guard.close()
            second = logs.lock(directory)
            self.assertIsNotNone(second)
            second.close()

    def test_collector_writes_events_cursor_and_stops(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            args = argparse.Namespace(target=None, services=[], max_mb=1, backups=2, tail=100)
            cfg = {"ubuntu": {"host": "prod", "user": "ubuntu"}}
            class Process:
                returncode = 0
                def __init__(self, *a, **kw):
                    import io
                    self.stdout = io.StringIO("backend-1 | 2026-11-02T12:00:00Z hello\n")
                def poll(self):
                    return 0
                def wait(self, **kw):
                    return 0
            def stop(_):
                (directory / "stop").touch()
            with patch.object(logs.subprocess, "Popen", Process), patch.object(logs.time, "sleep", side_effect=stop):
                logs.collect(args, cfg, directory)
            event = json.loads((directory / "events.jsonl").read_text(encoding="utf-8"))
            self.assertEqual(event["message"], "hello")
            state = logs.read_state(directory)
            self.assertEqual(state["cursor"], "2026-11-02T12:00:00Z")
            self.assertEqual(state["status"], "stopped")

    def test_reconnect_uses_saved_cursor(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            logs.save(directory / "status.json", {"cursor": "2026-11-02T12:00:00Z"})
            args = argparse.Namespace(target=None, services=[], max_mb=1, backups=2, tail=100)
            def stop(_):
                (directory / "stop").touch()
            with patch.object(logs.subprocess, "Popen", side_effect=OSError("offline")) as process, \
                 patch.object(logs.time, "sleep", side_effect=stop):
                logs.collect(args, {"ubuntu": {"host": "prod", "user": "ubuntu"}}, directory)
            self.assertIn("--since 2026-11-02T11:59:55+00:00", process.call_args.args[0][-1])

