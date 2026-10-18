"""Commands a binding runs. No hardware required."""

import json
import os
import shlex
import signal
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from engine.actions import ActionRunner  # noqa: E402


class FakeBinding:
    def __init__(self, command):
        self.keys = None
        self.exec = command


def wait_until(predicate, timeout=10.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.05)
    return False


def zombie_children() -> list[int]:
    zombies = []
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            stat = Path(f"/proc/{entry}/stat").read_text()
        except OSError:
            continue
        fields = stat.rsplit(")", 1)[1].split()
        if fields[0] == "Z" and int(fields[1]) == os.getpid():
            zombies.append(int(entry))
    return zombies


class TestCommands(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        previous = signal.getsignal(signal.SIGCHLD)
        self.addCleanup(signal.signal, signal.SIGCHLD, previous)

    def test_command_gets_an_ordinary_environment(self):
        out = Path(self.dir.name) / "seen.json"
        script = (
            "import json, os, signal, subprocess, sys\n"
            "json.dump({'sigchld': int(signal.getsignal(signal.SIGCHLD)),"
            " 'false': subprocess.run(['false']).returncode,"
            " 'pythonpath': os.environ.get('PYTHONPATH')}, open(sys.argv[1], 'w'))"
        )
        command = shlex.join([sys.executable, "-c", script, str(out)])
        launcher_path = os.pathsep.join([str(ROOT), "/elsewhere"])
        runner = ActionRunner()
        with mock.patch.dict(os.environ, {"PYTHONPATH": launcher_path}):
            ok, _detail = runner.run(FakeBinding(command))
        self.assertTrue(ok)
        self.assertTrue(wait_until(lambda: self.collected(runner)))
        seen = json.loads(out.read_text())
        # Ignoring SIGCHLD would be inherited, and then every exit status
        # the command waits for reads as 0.
        self.assertEqual(seen["sigchld"], int(signal.SIG_DFL))
        self.assertEqual(seen["false"], 1)
        # The plugin's own entry, which the launcher adds, is not passed on.
        self.assertEqual(seen["pythonpath"], "/elsewhere")

    def test_finished_commands_are_collected(self):
        runner = ActionRunner()
        ok, _detail = runner.run(FakeBinding("true"))
        self.assertTrue(ok)
        self.assertTrue(wait_until(lambda: self.collected(runner)))

    @staticmethod
    def collected(runner) -> bool:
        runner.reap()
        return not zombie_children() and not runner._children


if __name__ == "__main__":
    unittest.main(verbosity=2)
