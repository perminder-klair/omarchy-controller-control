"""Config validation and locked edits. No hardware required."""

import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from engine.config import Binding, Config, ConfigError, editing, load  # noqa: E402


class TestValidation(unittest.TestCase):
    def assert_rejected(self, raw, message):
        with self.assertRaises(ConfigError) as caught:
            Config(raw)
        self.assertIn(message, str(caught.exception))

    def test_setting_that_is_not_a_number(self):
        self.assert_rejected({"settings": {"hold_ms": "500ms"}}, "settings.hold_ms")

    def test_setting_left_empty(self):
        self.assert_rejected({"settings": {"stick_threshold": None}}, "settings.stick_threshold")

    def test_boolean_is_not_a_number(self):
        self.assert_rejected({"settings": {"repeat_interval_ms": True}}, "settings.repeat_interval_ms")

    def test_rescan_interval_that_would_spin(self):
        self.assert_rejected({"settings": {"rescan_interval_s": 0}}, "settings.rescan_interval_s")

    def test_threshold_beyond_full_travel(self):
        self.assert_rejected({"settings": {"trigger_threshold": 1.5}}, "settings.trigger_threshold")

    def test_device_must_be_an_object(self):
        self.assert_rejected({"device": ["8bitdo"]}, "'device'")

    def test_settings_must_be_an_object(self):
        self.assert_rejected({"settings": ["fast"]}, "'settings'")

    def test_alias_target_must_be_a_button_name(self):
        self.assert_rejected({"device": {"aliases": {"A": 1}}}, "device.aliases")

    def test_valid_numbers_are_kept(self):
        config = Config({"settings": {"hold_ms": 500, "stick_threshold": 0.5}})
        self.assertEqual(config.settings["hold_ms"], 500)
        self.assertEqual(config.settings["stick_threshold"], 0.5)

    def test_unreadable_file_is_a_config_error(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            path.write_bytes(b"\xff\xfe not text")
            with self.assertRaises(ConfigError):
                load(path)


class TestEdits(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.path = Path(self.dir.name) / "config.json"

    def cli(self, *args):
        env = {
            **os.environ,
            "PYTHONPATH": str(ROOT),
            # Never signal a daemon that is genuinely running on this machine.
            "CONTROLLER_CONTROL_PID_FILE": str(Path(self.dir.name) / "daemon.pid"),
        }
        return [sys.executable, "-m", "engine", "--config", str(self.path), *args], env

    def combos(self):
        return {b.combo for b in load(self.path).bindings}

    def test_an_edit_waits_for_the_one_in_progress(self):
        command, env = self.cli("bind", "Z", "--exec", "true")
        with editing(self.path) as config:
            proc = subprocess.Popen(command, env=env, stdout=subprocess.DEVNULL)
            self.addCleanup(proc.wait, 30)
            time.sleep(0.5)
            self.assertIsNone(proc.poll(), "bind should wait for the lock")
            config.upsert(Binding({"combo": "C", "exec": "true"}, 0))
            config.save()
        self.assertEqual(proc.wait(timeout=30), 0)
        self.assertIn(("C",), self.combos())
        self.assertIn(("Z",), self.combos())

    def test_replacing_a_disabled_binding_keeps_it_off(self):
        self.path.write_text(json.dumps(
            {"bindings": [{"combo": "A", "exec": "true", "enabled": False}]}
        ))
        command, env = self.cli("bind", "A", "--exec", "echo hi")
        subprocess.run(command, env=env, check=True, stdout=subprocess.DEVNULL)
        (binding,) = load(self.path).bindings
        self.assertEqual(binding.exec, "echo hi")
        self.assertFalse(binding.enabled)


if __name__ == "__main__":
    unittest.main(verbosity=2)
