"""The long-running listener.

Watches for matching controllers, feeds their events through the chord
recogniser, and runs the bound actions. Emits one JSON object per line on
stdout so the Omarchy shell plugin can show live state.
"""

from __future__ import annotations

import json
import os
import select
import signal
import sys
import time

from .actions import ActionRunner
from .buttons import format_combo, label_overrides
from .combos import ComboEngine
from .config import PID_PATH, Config, ConfigError, load, stamp
from .devices import DeviceGone, DeviceScanner, Gamepad


class Daemon:
    def __init__(
        self,
        config: Config,
        *,
        dry_run: bool = False,
        emit_buttons: bool = True,
        exit_with_stdin: bool = False,
        stream=None,
    ):
        self.config = config
        self.dry_run = dry_run
        self.emit_buttons = emit_buttons
        # The shell plugin holds our stdin open. If the shell dies without
        # stopping us, the pipe closes and we leave too, instead of living on
        # beside the daemon the next shell starts and firing every press twice.
        self.exit_with_stdin = exit_with_stdin
        self.stream = stream or sys.stdout
        self.pads: dict[str, Gamepad] = {}
        # Pads holding each button. Two pads can hold the same one, and it
        # stays down until the last of them lets go.
        self._held_by: dict[str, set[str]] = {}
        self.scanner = DeviceScanner()
        self.engine = ComboEngine(config.active_bindings(), config.settings)
        self.runner = ActionRunner(dry_run=dry_run)
        self.running = False
        # Transient, signal-driven mute. Distinct from config.enabled: the
        # panel pauses firing while it records a combo, so pressing the very
        # buttons you are trying to bind cannot trigger what they are already
        # bound to. It is never persisted.
        self.paused = False
        # Signal handlers must not write to stdout, so a pause change is
        # flagged here and announced from the main loop instead. Without this
        # the UI silently disagrees with the daemon about whether it is muted.
        self._pause_announced = False
        # Self-pipe, so a signal interrupts select() instead of waiting out
        # the rescan interval. Without it a toggle can take a couple of
        # seconds to visibly take effect, which reads as a broken switch.
        self._wake_r = -1
        self._wake_w = -1
        self._reload_requested = False
        self._last_scan = 0.0
        # Hand edits to the file are picked up without needing a SIGHUP.
        self._config_stamp = stamp(config.path)

    @property
    def firing(self) -> bool:
        return self.config.enabled and not self.paused

    # -- output -------------------------------------------------------------

    def emit(self, event: str, **fields) -> None:
        payload = {"event": event, "t": round(time.time(), 3), **fields}
        try:
            self.stream.write(json.dumps(payload) + "\n")
            self.stream.flush()
        except (BrokenPipeError, ValueError):
            self.running = False

    def emit_state(self) -> None:
        self.emit(
            "state",
            connected=bool(self.pads),
            devices=[
                {"path": pad.path, "name": pad.name, "grabbed": pad.grabbed}
                for pad in self.pads.values()
            ],
            bindings=len(self.config.active_bindings()),
            exclusive=self.config.exclusive,
            enabled=self.config.enabled,
            paused=self.paused,
        )

    def emit_bindings(self) -> None:
        """The whole binding list, so the panel never has to read the file."""
        layout = self.config.layout
        self.emit(
            "bindings",
            layout=layout,
            labels=label_overrides(layout),
            bindings=[
                {**b.to_dict(), "label": b.label(layout)} for b in self.config.bindings
            ],
        )

    # -- device management --------------------------------------------------

    def rescan(self) -> None:
        self._last_scan = time.monotonic()
        patterns = self.config.device["match"]
        wanted = {info.path: info for info in self.scanner.find_pads(patterns)}

        changed = False
        for path in list(self.pads):
            if path not in wanted:
                self._drop_pad(path, "disconnected")
                changed = True

        for path, info in wanted.items():
            if path in self.pads:
                continue
            try:
                pad = Gamepad(
                    info,
                    self.config.settings,
                    self.config.exclusive,
                    self.config.aliases,
                )
            except OSError as exc:
                self.emit("error", message=f"cannot open {path}: {exc}")
                continue
            self.pads[path] = pad
            changed = True
            self.emit(
                "connected",
                path=path,
                name=pad.name,
                grabbed=pad.grabbed,
                buttons=info.button_tokens,
            )
            if self.config.exclusive and not pad.grabbed:
                self.emit(
                    "error",
                    message=f"exclusive grab refused for {pad.name}; sharing instead",
                )

        if changed:
            self.emit_state()

    def _drop_pad(self, path: str, reason: str) -> None:
        pad = self.pads.pop(path, None)
        if pad is None:
            return
        name = pad.name
        pad.close()
        # Let go of whatever only this pad was holding; another pad's buttons
        # and any chord in progress on them carry on.
        for token in [t for t, pads in self._held_by.items() if path in pads]:
            pads = self._held_by[token]
            pads.discard(path)
            if not pads:
                del self._held_by[token]
                self.engine.drop(token)
        self.emit(
            "disconnected",
            path=path,
            name=name,
            reason=reason,
            held=sorted(self.engine.held),
        )

    def _feed(self, path: str, token: str, pressed: bool, now: float):
        """One pad's button change. None when no button changed overall."""
        pads = self._held_by.get(token)
        if pressed:
            if pads:
                pads.add(path)
                return None
            self._held_by[token] = {path}
            return self.engine.press(token, now)
        if not pads or path not in pads:
            return None
        pads.discard(path)
        if pads:
            return None
        del self._held_by[token]
        return self.engine.release(token, now)

    # -- config -------------------------------------------------------------

    def request_reload(self) -> None:
        self._reload_requested = True

    def _apply_reload(self) -> None:
        self._reload_requested = False
        # Taken first, so an edit landing mid-load is noticed next time round.
        self._config_stamp = stamp(self.config.path)
        try:
            new_config = load(self.config.path)
        except ConfigError as exc:
            self.emit("error", message=f"reload failed: {exc}")
            return
        was_exclusive = self.config.exclusive
        was_match = self.config.device["match"]
        self.config = new_config
        self.engine.set_bindings(new_config.active_bindings(), new_config.settings)
        self.engine.reset()
        self._held_by.clear()
        # Re-open pads when the matching rules or grab mode changed; anything
        # else (aliases, d-pad source, thresholds) applies to them in place.
        if new_config.exclusive != was_exclusive or new_config.device["match"] != was_match:
            for path in list(self.pads):
                self._drop_pad(path, "reconfigured")
        for pad in self.pads.values():
            pad.apply(new_config.settings, new_config.aliases)
        # Announced before the warnings below: a client clears old errors on
        # "reloaded", and these belong to the config just loaded.
        self.emit(
            "reloaded",
            bindings=len(new_config.active_bindings()),
            enabled=new_config.enabled,
        )
        self.emit_bindings()
        self._warn_about_bad_actions()
        self._prepare_keyboard()
        self.rescan()

    def _prepare_keyboard(self) -> None:
        if not any(b.keys for b in self.config.active_bindings()):
            return
        try:
            self.runner.prepare()
        except OSError as exc:
            self.emit(
                "error",
                message=f"cannot create the virtual keyboard: {exc}; keys bindings will fail",
            )

    def _warn_about_bad_actions(self) -> None:
        for binding in self.config.active_bindings():
            problem = self.runner.validate(binding)
            if problem:
                self.emit(
                    "error",
                    message=f"binding {binding.label()}: {problem}",
                    combo=list(binding.combo),
                )

    # -- main loop ----------------------------------------------------------

    def _fire(self, activation) -> None:
        binding = activation.binding
        if not self.firing:
            # Still reported, so the UI can show the combo was recognised.
            self.emit(
                "suppressed",
                combo=list(binding.combo),
                label=format_combo(binding.combo, self.config.layout),
                description=binding.description,
                reason="paused" if self.paused else "disabled",
            )
            return
        ok, detail = self.runner.run(binding)
        self.emit(
            "fire",
            combo=list(binding.combo),
            label=format_combo(binding.combo, self.config.layout),
            description=binding.description,
            action=binding.action_summary(),
            reason=activation.reason,
            ok=ok,
            detail=detail,
        )

    def _pump(self, pad: Gamepad, now: float) -> None:
        try:
            events = pad.read()
        except DeviceGone:
            self._drop_pad(pad.path, "vanished")
            self.emit_state()
            return
        except OSError as exc:
            self.emit("error", message=f"read error on {pad.path}: {exc}")
            self._drop_pad(pad.path, "read-error")
            self.emit_state()
            return

        for token, pressed in events:
            activations = self._feed(pad.path, token, pressed, now)
            if activations is None:
                continue
            # Emitted after the state change, so `held` on a release no longer
            # contains the button that was just let go.
            if self.emit_buttons:
                self.emit(
                    "button",
                    button=token,
                    label=format_combo([token], self.config.layout),
                    pressed=pressed,
                    held=sorted(self.engine.held),
                )
            for activation in activations:
                self._fire(activation)

    def _write_pid_file(self) -> None:
        try:
            PID_PATH.parent.mkdir(parents=True, exist_ok=True)
            PID_PATH.write_text(f"{os.getpid()}\n")
        except OSError as exc:
            self.emit("error", message=f"cannot write {PID_PATH}: {exc}")

    def _remove_pid_file(self) -> None:
        try:
            if PID_PATH.read_text().strip() == str(os.getpid()):
                PID_PATH.unlink()
        except (OSError, ValueError):
            pass

    def run(self) -> int:
        self.running = True
        self._open_wakeup_pipe()
        self._install_signal_handlers()
        self._write_pid_file()
        try:
            self._loop()
        finally:
            # Also on a crash, so the pad is never left grabbed and the
            # virtual keyboard and pid file do not outlive us.
            self.shutdown()
        return 0

    def _loop(self) -> None:
        self.emit(
            "started",
            pid=os.getpid(),
            config=str(self.config.path),
            dry_run=self.dry_run,
            enabled=self.config.enabled,
        )
        self.emit_bindings()
        self._warn_about_bad_actions()
        self.rescan()
        # Always publish an opening snapshot. rescan() only reports when
        # something changed, so a daemon that starts with no pad attached
        # would otherwise leave a client with nothing to render.
        self.emit_state()
        self._prepare_keyboard()

        rescan_interval = self.config.setting("rescan_interval_s")

        self._pause_announced = self.paused

        while self.running:
            if self._reload_requested:
                self._apply_reload()
                rescan_interval = self.config.setting("rescan_interval_s")

            if self.paused != self._pause_announced:
                self._pause_announced = self.paused
                self.emit_state()

            now = time.monotonic()
            deadline = self.engine.next_deadline()
            timeout = rescan_interval - (now - self._last_scan)
            if deadline is not None:
                timeout = min(timeout, max(0.0, deadline - now))
            timeout = max(0.0, min(timeout, rescan_interval))

            fds = [pad.fileno() for pad in self.pads.values()]
            if self._wake_r >= 0:
                fds.append(self._wake_r)
            if self.exit_with_stdin:
                fds.append(sys.stdin.fileno())
            try:
                ready, _, _ = select.select(fds, [], [], timeout)
            except InterruptedError:
                continue
            except OSError:
                ready = []

            now = time.monotonic()
            by_fd = {pad.fileno(): pad for pad in self.pads.values()}
            for fd in ready:
                if fd == self._wake_r:
                    self._drain_wakeup()
                    continue
                if self.exit_with_stdin and fd == sys.stdin.fileno():
                    self._check_stdin()
                    continue
                pad = by_fd.get(fd)
                if pad is not None:
                    self._pump(pad, now)

            for activation in self.engine.tick(time.monotonic()):
                self._fire(activation)

            self.runner.reap()

            if time.monotonic() - self._last_scan >= rescan_interval:
                if stamp(self.config.path) != self._config_stamp:
                    self._reload_requested = True
                self.rescan()

    def _check_stdin(self) -> None:
        try:
            data = os.read(sys.stdin.fileno(), 4096)
        except OSError:
            data = b""
        if not data:
            self.running = False

    def _open_wakeup_pipe(self) -> None:
        try:
            self._wake_r, self._wake_w = os.pipe()
            os.set_blocking(self._wake_r, False)
            os.set_blocking(self._wake_w, False)
            signal.set_wakeup_fd(self._wake_w)
        except (OSError, ValueError):
            self._wake_r = self._wake_w = -1

    def _close_wakeup_pipe(self) -> None:
        try:
            signal.set_wakeup_fd(-1)
        except (OSError, ValueError):
            pass
        for fd in (self._wake_r, self._wake_w):
            if fd >= 0:
                try:
                    os.close(fd)
                except OSError:
                    pass
        self._wake_r = self._wake_w = -1

    def _drain_wakeup(self) -> None:
        if self._wake_r < 0:
            return
        try:
            while os.read(self._wake_r, 4096):
                pass
        except (BlockingIOError, OSError):
            pass

    def _install_signal_handlers(self) -> None:
        def stop(_signum, _frame):
            self.running = False

        def reload_config(_signum, _frame):
            self._reload_requested = True

        for sig in (signal.SIGINT, signal.SIGTERM):
            try:
                signal.signal(sig, stop)
            except (ValueError, OSError):
                pass
        def pause(_signum, _frame):
            self.paused = True

        def resume(_signum, _frame):
            self.paused = False

        for sig, handler in (
            (signal.SIGHUP, reload_config),
            (signal.SIGUSR1, pause),
            (signal.SIGUSR2, resume),
        ):
            try:
                signal.signal(sig, handler)
            except (ValueError, OSError):
                pass

    def shutdown(self) -> None:
        self._close_wakeup_pipe()
        self._remove_pid_file()
        for path in list(self.pads):
            pad = self.pads.pop(path)
            pad.close()
        self.runner.close()
        self.emit("stopped")
