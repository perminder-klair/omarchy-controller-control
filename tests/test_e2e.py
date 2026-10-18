"""End-to-end tests: real daemon process, synthetic controller.

Run with:
    python3 -m unittest discover -s tests -v

Creating the synthetic pad needs write access to /dev/uinput (the `input`
group on a stock Omarchy install).
"""

from __future__ import annotations

import json
import os
import queue
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "tests"))

from virtual_pad import NAME, VirtualPad  # noqa: E402
from engine.devices import DeviceScanner, Gamepad  # noqa: E402

# The daemon runs under whatever interpreter is running the tests -- the engine
# is pure stdlib, so there is no separate environment to reach for.
SYSTEM_PYTHON = sys.executable

CONFIG = {
    "version": 1,
    "device": {"match": [NAME.lower()], "exclusive": False, "layout": "auto"},
    "settings": {
        "combo_window_ms": 60,
        "hold_ms": 300,
        "repeat_delay_ms": 200,
        "repeat_interval_ms": 80,
        "rescan_interval_s": 0.4,
    },
    "bindings": [
        {"combo": "A", "keys": "SUPER+RETURN", "description": "Terminal"},
        {"combo": "B", "exec": "true", "description": "Noop"},
        {"combo": "L+R", "exec": "echo shot", "description": "Screenshot"},
        {"combo": "SELECT+START", "keys": "SUPER+CTRL+L", "description": "Lock"},
        {"combo": "DPAD_UP", "keys": "VOLUMEUP", "repeat": True, "description": "Vol+"},
        {"combo": "Y", "keys": "SUPER+F", "hold": True, "description": "Hold full"},
    ],
}


class DaemonHarness:
    """Runs the real daemon as a subprocess and collects its JSON events."""

    def __init__(self, config: dict, *, extra_args=(), stdin=None):
        self.dir = tempfile.mkdtemp(prefix="cc-e2e-")
        self.config_path = Path(self.dir) / "config.json"
        self.config_path.write_text(json.dumps(config))
        self.events: queue.Queue = queue.Queue()
        self.all: list[dict] = []
        self.pid_file = Path(self.dir) / "daemon.pid"
        env = {
            **os.environ,
            "PYTHONPATH": str(ROOT),
            "PYTHONUNBUFFERED": "1",
            "CONTROLLER_CONTROL_PID_FILE": str(self.pid_file),
        }
        self.proc = subprocess.Popen(
            [
                SYSTEM_PYTHON,
                "-m",
                "engine",
                "--config",
                str(self.config_path),
                "daemon",
                "--dry-run",
                *extra_args,
            ],
            stdin=stdin,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
        )
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _read(self):
        for line in self.proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            self.all.append(event)
            self.events.put(event)

    def wait_for(self, kind: str, timeout: float = 6.0, **match) -> dict:
        deadline = time.monotonic() + timeout
        # Check anything already seen first.
        for event in list(self.all):
            if event.get("event") == kind and all(
                event.get(k) == v for k, v in match.items()
            ):
                return event
        while time.monotonic() < deadline:
            try:
                event = self.events.get(timeout=max(0.05, deadline - time.monotonic()))
            except queue.Empty:
                break
            if event.get("event") == kind and all(
                event.get(k) == v for k, v in match.items()
            ):
                return event
        raise AssertionError(
            f"timed out waiting for {kind} {match}; saw: "
            + ", ".join(sorted({e.get('event', '?') for e in self.all}))
        )

    def fires(self) -> list[dict]:
        return [e for e in self.all if e.get("event") == "fire"]

    def drain(self):
        self.all.clear()
        while not self.events.empty():
            self.events.get_nowait()

    def stop(self):
        self.proc.terminate()
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait(timeout=5)
        for stream in (self.proc.stdin, self.proc.stdout, self.proc.stderr):
            if stream is not None:
                stream.close()
        shutil.rmtree(self.dir, ignore_errors=True)


class TestDaemonEndToEnd(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.harness = DaemonHarness(CONFIG)
        cls.harness.wait_for("started")
        # Daemon is up with no pad present; hotplug one in.
        cls.pad = VirtualPad()
        cls.connected = cls.harness.wait_for("connected", timeout=8.0)

    @classmethod
    def tearDownClass(cls):
        cls.pad.close()
        cls.harness.stop()

    def setUp(self):
        time.sleep(0.15)
        self.harness.drain()

    def _fired_labels(self, timeout=2.0):
        time.sleep(timeout)
        return [f["description"] for f in self.harness.fires()]

    def test_hotplug_detected_the_pad(self):
        self.assertEqual(self.connected["name"], NAME)
        self.assertIn("A", self.connected["buttons"])

    def test_single_button_fires_once(self):
        self.pad.tap("A")
        self.assertEqual(self._fired_labels(), ["Terminal"])

    def test_single_button_with_exec_action(self):
        self.pad.tap("B")
        self.assertEqual(self._fired_labels(), ["Noop"])

    def test_chord_fires_chord_not_components(self):
        self.pad.chord("L", "R")
        self.assertEqual(self._fired_labels(), ["Screenshot"])

    def test_chord_order_does_not_matter(self):
        self.pad.chord("R", "L")
        self.assertEqual(self._fired_labels(), ["Screenshot"])

    def test_second_chord(self):
        self.pad.chord("SELECT", "START")
        self.assertEqual(self._fired_labels(), ["Lock"])

    def test_unbound_button_does_nothing(self):
        self.pad.tap("X")
        self.assertEqual(self._fired_labels(), [])

    def test_dpad_hat_axis_is_decoded(self):
        self.pad.press("DPAD_UP")
        time.sleep(0.1)
        self.pad.release("DPAD_UP")
        self.assertEqual(self._fired_labels(), ["Vol+"])

    def test_dpad_repeat_while_held(self):
        self.pad.press("DPAD_UP")
        time.sleep(0.75)
        self.pad.release("DPAD_UP")
        fires = self._fired_labels(0.2)
        # initial press + repeats after the 200ms delay at 80ms intervals
        self.assertGreaterEqual(len(fires), 3)
        self.assertTrue(all(f == "Vol+" for f in fires))

    def test_hold_binding_needs_a_long_press(self):
        self.pad.tap("Y", hold=0.05)
        self.assertEqual(self._fired_labels(0.5), [])
        self.harness.drain()
        self.pad.press("Y")
        time.sleep(0.45)
        self.pad.release("Y")
        self.assertEqual(self._fired_labels(0.2), ["Hold full"])

    def test_holding_a_button_does_not_repeat_non_repeat_bindings(self):
        self.pad.press("A")
        time.sleep(0.8)
        self.pad.release("A")
        self.assertEqual(self._fired_labels(0.2), ["Terminal"])

    def test_button_events_are_reported(self):
        self.pad.tap("A")
        time.sleep(0.3)
        buttons = [e for e in self.harness.all if e.get("event") == "button"]
        self.assertTrue(any(b["button"] == "A" and b["pressed"] for b in buttons))
        self.assertTrue(any(b["button"] == "A" and not b["pressed"] for b in buttons))

    def test_dry_run_did_not_actually_type(self):
        self.pad.tap("A")
        time.sleep(0.3)
        fire = self.harness.fires()[0]
        self.assertTrue(fire["ok"])
        self.assertIn("would tap", fire["detail"])


class TestDisconnect(unittest.TestCase):
    def test_daemon_survives_the_pad_vanishing(self):
        harness = DaemonHarness(CONFIG)
        try:
            harness.wait_for("started")
            pad = VirtualPad()
            harness.wait_for("connected", timeout=8.0)
            pad.close()
            harness.wait_for("disconnected", timeout=8.0)
            # And picks it up again when it comes back.
            pad2 = VirtualPad()
            harness.wait_for("connected", timeout=8.0)
            harness.drain()
            pad2.tap("A")
            time.sleep(0.4)
            self.assertEqual([f["description"] for f in harness.fires()], ["Terminal"])
            pad2.close()
        finally:
            harness.stop()


if __name__ == "__main__":
    unittest.main(verbosity=2)


class TestHeldReporting(unittest.TestCase):
    """The panel mirrors `held`, so a release must not leave a stale button."""

    @classmethod
    def setUpClass(cls):
        cls.harness = DaemonHarness(CONFIG)
        cls.harness.wait_for("started")
        cls.pad = VirtualPad()
        cls.harness.wait_for("connected", timeout=8.0)

    @classmethod
    def tearDownClass(cls):
        cls.pad.close()
        cls.harness.stop()

    def _buttons(self):
        return [e for e in self.harness.all if e.get("event") == "button"]

    def test_release_clears_held(self):
        self.harness.drain()
        self.pad.tap("X")
        time.sleep(0.4)
        events = self._buttons()
        self.assertTrue(events, "no button events seen")
        press = next(e for e in events if e["button"] == "X" and e["pressed"])
        release = next(e for e in events if e["button"] == "X" and not e["pressed"])
        self.assertEqual(press["held"], ["X"])
        self.assertEqual(release["held"], [], "released button still reported as held")

    def test_chord_release_reports_remaining_buttons(self):
        self.harness.drain()
        self.pad.press("L")
        time.sleep(0.08)
        self.pad.press("R")
        time.sleep(0.08)
        self.pad.release("R")
        time.sleep(0.08)
        self.pad.release("L")
        time.sleep(0.4)
        events = self._buttons()
        r_release = next(e for e in events if e["button"] == "R" and not e["pressed"])
        l_release = next(e for e in events if e["button"] == "L" and not e["pressed"])
        self.assertEqual(r_release["held"], ["L"])
        self.assertEqual(l_release["held"], [])


DISABLED_CONFIG = {**CONFIG, "enabled": False}


class TestEnableDisable(unittest.TestCase):
    """The master switch, and the transient pause used while recording."""

    def test_disabled_config_suppresses_instead_of_firing(self):
        harness = DaemonHarness(DISABLED_CONFIG)
        try:
            started = harness.wait_for("started")
            self.assertFalse(started["enabled"])
            pad = VirtualPad()
            harness.wait_for("connected", timeout=8.0)
            harness.drain()
            pad.tap("A")
            suppressed = harness.wait_for("suppressed", timeout=3.0)
            self.assertEqual(suppressed["combo"], ["A"])
            self.assertEqual(suppressed["reason"], "disabled")
            self.assertEqual(harness.fires(), [], "a disabled binding still fired")
            pad.close()
        finally:
            harness.stop()

    def test_pause_and_resume_signals(self):
        harness = DaemonHarness(CONFIG)
        try:
            started = harness.wait_for("started")
            pid = started["pid"]
            pad = VirtualPad()
            harness.wait_for("connected", timeout=8.0)

            harness.drain()
            pad.tap("A")
            harness.wait_for("fire", timeout=3.0)

            os.kill(pid, signal.SIGUSR1)
            time.sleep(0.3)
            harness.drain()
            pad.tap("A")
            suppressed = harness.wait_for("suppressed", timeout=3.0)
            self.assertEqual(suppressed["reason"], "paused")
            self.assertEqual(harness.fires(), [], "paused daemon still fired")

            os.kill(pid, signal.SIGUSR2)
            time.sleep(0.3)
            harness.drain()
            pad.tap("A")
            harness.wait_for("fire", timeout=3.0)
            pad.close()
        finally:
            harness.stop()

    def test_pid_file_is_written_and_removed(self):
        harness = DaemonHarness(CONFIG)
        try:
            started = harness.wait_for("started")
            deadline = time.monotonic() + 3.0
            while time.monotonic() < deadline and not harness.pid_file.exists():
                time.sleep(0.05)
            self.assertTrue(harness.pid_file.exists(), "no pid file written")
            self.assertEqual(
                harness.pid_file.read_text().strip(), str(started["pid"])
            )
        finally:
            harness.stop()
        deadline = time.monotonic() + 3.0
        while time.monotonic() < deadline and harness.pid_file.exists():
            time.sleep(0.05)
        self.assertFalse(harness.pid_file.exists(), "pid file left behind")


class TestPauseIsObservable(unittest.TestCase):
    """A muted daemon has to say so, or the UI shows a stale switch."""

    def test_state_event_follows_pause_and_resume(self):
        harness = DaemonHarness(CONFIG)
        try:
            pid = harness.wait_for("started")["pid"]
            harness.wait_for("state", timeout=6.0)

            harness.drain()
            os.kill(pid, signal.SIGUSR1)
            paused = harness.wait_for("state", timeout=3.0)
            self.assertTrue(paused["paused"], "pause was never announced")

            harness.drain()
            os.kill(pid, signal.SIGUSR2)
            resumed = harness.wait_for("state", timeout=3.0)
            self.assertFalse(resumed["paused"], "resume was never announced")
        finally:
            harness.stop()


class TestSignalLatency(unittest.TestCase):
    """A signal must interrupt the poll, not wait out the rescan interval."""

    def test_pause_is_announced_promptly(self):
        slow = {**CONFIG, "settings": {**CONFIG["settings"], "rescan_interval_s": 5.0}}
        harness = DaemonHarness(slow)
        try:
            pid = harness.wait_for("started")["pid"]
            harness.wait_for("state", timeout=8.0)
            harness.drain()

            sent = time.monotonic()
            os.kill(pid, signal.SIGUSR1)
            state = harness.wait_for("state", timeout=4.0)
            elapsed = time.monotonic() - sent

            self.assertTrue(state["paused"])
            # Well inside the 5s rescan interval it would otherwise wait for.
            self.assertLess(elapsed, 1.5, f"took {elapsed:.2f}s to react")
        finally:
            harness.stop()


class TestDpadSource(unittest.TestCase):
    """Pads disagree about where the d-pad lives; both layouts must work."""

    BINDINGS = [
        {"combo": "DPAD_UP", "keys": "VOLUMEUP", "description": "Vol+"},
        {"combo": "LSTICK_UP", "keys": "SUPER+1", "description": "Stick up"},
    ]

    def _config(self, source):
        return {
            **CONFIG,
            "device": {**CONFIG["device"], "dpad_source": source},
            "bindings": self.BINDINGS,
        }

    def test_hat_pad_reports_dpad(self):
        harness = DaemonHarness(self._config("hat"))
        try:
            harness.wait_for("started")
            pad = VirtualPad()
            harness.wait_for("connected", timeout=8.0)
            harness.drain()
            pad.tap("DPAD_UP", hold=0.08)
            fire = harness.wait_for("fire", timeout=3.0)
            self.assertEqual(fire["description"], "Vol+")
            pad.close()
        finally:
            harness.stop()

    def test_stick_pad_is_a_stick_by_default(self):
        """Left stick must not masquerade as a d-pad unless asked."""
        harness = DaemonHarness(self._config("hat"))
        try:
            harness.wait_for("started")
            pad = VirtualPad(dpad_on_stick=True)
            harness.wait_for("connected", timeout=8.0)
            harness.drain()
            pad.tap("DPAD_UP", hold=0.08)
            fire = harness.wait_for("fire", timeout=3.0)
            self.assertEqual(
                fire["description"], "Stick up", "stick fired a d-pad binding"
            )
            pad.close()
        finally:
            harness.stop()

    def test_stick_source_renames_stick_to_dpad(self):
        harness = DaemonHarness(self._config("stick"))
        try:
            harness.wait_for("started")
            pad = VirtualPad(dpad_on_stick=True)
            harness.wait_for("connected", timeout=8.0)
            harness.drain()
            pad.tap("DPAD_UP", hold=0.08)
            fire = harness.wait_for("fire", timeout=3.0)
            self.assertEqual(fire["description"], "Vol+")
            self.assertEqual(fire["combo"], ["DPAD_UP"])
            pad.close()
        finally:
            harness.stop()


class TestAliases(unittest.TestCase):
    def test_arbitrary_token_remapping(self):
        config = {
            **CONFIG,
            "device": {**CONFIG["device"], "aliases": {"Y": "SELECT"}},
            "bindings": [{"combo": "SELECT", "keys": "SUPER+K", "description": "Keys"}],
        }
        harness = DaemonHarness(config)
        try:
            harness.wait_for("started")
            pad = VirtualPad()
            harness.wait_for("connected", timeout=8.0)
            harness.drain()
            pad.tap("Y")
            fire = harness.wait_for("fire", timeout=3.0)
            self.assertEqual(fire["combo"], ["SELECT"])
            pad.close()
        finally:
            harness.stop()


class TestDedicatedBack(unittest.TestCase):
    """Real evdev events must keep dedicated Back apart from legacy Select."""

    def setUp(self):
        config = {
            **CONFIG,
            "bindings": [
                {"combo": "BACK", "exec": "true", "description": "Select"},
                {"combo": "BACK_BUTTON", "exec": "true", "description": "Back"},
                {"combo": "BACK_BUTTON+START", "exec": "true", "description": "Back chord"},
            ],
        }
        self.harness = DaemonHarness(config)
        self.addCleanup(self.harness.stop)
        self.harness.wait_for("started")
        self.pad = VirtualPad(back_button=True)
        self.addCleanup(self.pad.close)
        self.harness.wait_for("connected", timeout=8.0)

    def test_dedicated_back_fires_without_select(self):
        # Wait out the chord window because BACK_BUTTON+START is also bound.
        self.pad.tap("BACK_BUTTON", hold=0.1)
        fire = self.harness.wait_for("fire", description="Back")
        self.assertEqual(fire["combo"], ["BACK_BUTTON"])
        release = self.harness.wait_for("button", button="BACK_BUTTON", pressed=False)
        self.assertEqual(release["held"], [])
        self.assertEqual([f["description"] for f in self.harness.fires()], ["Back"])

    def test_select_still_activates_legacy_back_binding(self):
        self.pad.tap("SELECT")
        fire = self.harness.wait_for("fire", description="Select")
        self.assertEqual(fire["combo"], ["SELECT"])
        self.harness.wait_for("button", button="SELECT", pressed=False)
        self.assertEqual([f["description"] for f in self.harness.fires()], ["Select"])

    def test_dedicated_back_chord_does_not_fire_single_binding(self):
        self.pad.chord("BACK_BUTTON", "START")
        fire = self.harness.wait_for("fire", description="Back chord")
        self.assertEqual(fire["combo"], ["BACK_BUTTON", "START"])
        self.harness.wait_for("button", button="BACK_BUTTON", pressed=False)
        self.assertEqual([f["description"] for f in self.harness.fires()], ["Back chord"])

    def test_nonexclusive_input_remains_readable_by_another_client(self):
        info = next(info for info in DeviceScanner().find_pads([NAME.lower()])
                    if info.name == NAME)
        observer = Gamepad(info, CONFIG["settings"])
        self.addCleanup(observer.close)
        self.pad.tap("BACK_BUTTON", hold=0.1)
        self.harness.wait_for("fire", description="Back")
        self.pad.tap("SELECT")
        self.harness.wait_for("fire", description="Select")
        self.assertEqual(observer.read(), [
            ("BACK_BUTTON", True), ("BACK_BUTTON", False),
            ("SELECT", True), ("SELECT", False),
        ])


class TestTwoPads(unittest.TestCase):
    """Each pad holds its own buttons; one coming or going leaves the other be."""

    SECOND = NAME + " two"

    def setUp(self):
        config = {**CONFIG, "settings": {**CONFIG["settings"], "hold_ms": 1500}}
        self.harness = DaemonHarness(config)
        self.addCleanup(self.harness.stop)
        self.harness.wait_for("started")
        self.first = VirtualPad()
        self.addCleanup(self.first.close)
        self.harness.wait_for("connected", name=NAME, timeout=8.0)
        self.second = VirtualPad(name=self.SECOND)
        self.addCleanup(self.second.close)
        self.harness.wait_for("connected", name=self.SECOND, timeout=8.0)

    def test_other_pad_leaving_does_not_cancel_a_hold(self):
        self.first.press("Y")
        time.sleep(0.1)
        self.second.close()
        self.harness.wait_for("disconnected", name=self.SECOND, timeout=3.0)
        fire = self.harness.wait_for("fire", description="Hold full", timeout=3.0)
        self.assertEqual(fire["reason"], "hold")
        self.first.release("Y")

    def test_button_stays_down_until_both_pads_let_go(self):
        self.first.press("A")
        self.harness.wait_for("button", button="A", pressed=True)
        self.harness.drain()
        self.second.press("A")
        self.second.release("A")
        time.sleep(0.3)
        self.assertEqual(
            [e for e in self.harness.all if e.get("event") == "button"], []
        )
        self.first.release("A")
        self.harness.wait_for("button", button="A", pressed=False)
        self.assertEqual([f["description"] for f in self.harness.fires()], [])


class TestConfigFollowsTheFile(unittest.TestCase):
    def test_hand_edit_is_applied_without_a_signal(self):
        harness = DaemonHarness(CONFIG)
        self.addCleanup(harness.stop)
        first = harness.wait_for("bindings")
        self.assertEqual(len(first["bindings"]), len(CONFIG["bindings"]))
        self.assertEqual(first["bindings"][0]["label"], "A")
        harness.drain()

        edited = {
            **CONFIG,
            "bindings": CONFIG["bindings"]
            + [{"combo": "X", "exec": "true", "description": "Added by hand"}],
        }
        staged = harness.config_path.with_suffix(".tmp")
        staged.write_text(json.dumps(edited))
        staged.replace(harness.config_path)

        harness.wait_for("reloaded", timeout=3.0)
        listed = harness.wait_for("bindings", timeout=3.0)
        self.assertIn("Added by hand", [b.get("description") for b in listed["bindings"]])


class TestExitWithStdin(unittest.TestCase):
    def test_daemon_leaves_when_the_shell_pipe_closes(self):
        harness = DaemonHarness(
            CONFIG, extra_args=["--exit-with-stdin"], stdin=subprocess.PIPE
        )
        self.addCleanup(harness.stop)
        harness.wait_for("started")
        harness.proc.stdin.close()
        harness.wait_for("stopped", timeout=3.0)
        self.assertEqual(harness.proc.wait(timeout=3.0), 0)


class TestDroppedEvents(unittest.TestCase):
    """A reader that falls behind loses events; no button may stay stuck down."""

    def test_release_lost_in_an_overflow_is_recovered(self):
        pad = VirtualPad()
        self.addCleanup(pad.close)
        info = next(
            info for info in DeviceScanner().find_pads([NAME.lower()])
            if info.name == NAME
        )
        reader = Gamepad(info, CONFIG["settings"])
        self.addCleanup(reader.close)

        pad.press("A")
        time.sleep(0.05)
        self.assertEqual(reader.read(), [("A", True)])

        # The release, then far more than the reader's buffer holds, all
        # before it reads again.
        pad.release("A")
        for _ in range(600):
            pad.press("DPAD_LEFT")
            pad.release("DPAD_LEFT")
        time.sleep(0.1)

        held = {"A"}
        for token, pressed in reader.read():
            if pressed:
                held.add(token)
            else:
                held.discard(token)
        self.assertEqual(held, set())
