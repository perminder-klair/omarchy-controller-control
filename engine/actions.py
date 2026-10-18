"""Running the action attached to a binding."""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

from .keys import KeyParseError, VirtualKeyboard, parse_keys

# The launcher puts the plugin directory on PYTHONPATH so `-m engine` resolves.
# Commands a binding runs must not inherit that.
_PLUGIN_ROOT = str(Path(__file__).resolve().parents[1])


def _child_env() -> dict[str, str]:
    env = dict(os.environ)
    paths = [
        p for p in env.get("PYTHONPATH", "").split(os.pathsep) if p and p != _PLUGIN_ROOT
    ]
    if paths:
        env["PYTHONPATH"] = os.pathsep.join(paths)
    else:
        env.pop("PYTHONPATH", None)
    return env


class ActionRunner:
    def __init__(self, dry_run: bool = False, keyboard: VirtualKeyboard | None = None):
        self.dry_run = dry_run
        self.keyboard = keyboard or VirtualKeyboard()
        self._key_cache: dict[str, list[int]] = {}
        # Commands still running, so their exit can be collected. Ignoring
        # SIGCHLD instead would be inherited by every command a binding runs,
        # and a program that waits on its own children then reads every exit
        # status as 0.
        self._children: list[subprocess.Popen] = []

    def close(self) -> None:
        self.keyboard.close()

    def prepare(self) -> None:
        """Create the virtual keyboard now, before any binding needs it.

        Opening it waits for the compositor to bind the new device. Done
        lazily, that wait landed on the first keys binding, inside the
        daemon's event loop, while the pad kept sending events.
        """
        if not self.dry_run:
            self.keyboard.open()

    def reap(self) -> None:
        """Collect commands that have exited, so none linger as zombies."""
        self._children = [child for child in self._children if child.poll() is None]

    def codes_for(self, spec: str) -> list[int]:
        cached = self._key_cache.get(spec)
        if cached is None:
            cached = parse_keys(spec)
            self._key_cache[spec] = cached
        return cached

    def validate(self, binding) -> str | None:
        """Return an error message if the binding's action cannot run."""
        if binding.keys:
            try:
                self.codes_for(binding.keys)
            except KeyParseError as exc:
                return str(exc)
        return None

    def run(self, binding) -> tuple[bool, str]:
        """Execute a binding. Returns (ok, detail)."""
        if binding.keys:
            try:
                codes = self.codes_for(binding.keys)
            except KeyParseError as exc:
                return False, str(exc)
            if self.dry_run:
                return True, f"would tap {binding.keys}"
            try:
                self.keyboard.tap(codes)
            except OSError as exc:
                return False, f"uinput write failed: {exc}"
            return True, f"tapped {binding.keys}"

        command = binding.exec
        if self.dry_run:
            return True, f"would run {command}"
        self.reap()
        try:
            child = subprocess.Popen(
                ["/bin/sh", "-c", command],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
                env=_child_env(),
            )
        except OSError as exc:
            return False, f"spawn failed: {exc}"
        self._children.append(child)
        return True, f"ran {command}"
