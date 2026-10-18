"""Command line interface for controller-control."""

from __future__ import annotations

import argparse
import json
import os
import select
import signal
import sys
import time
from pathlib import Path

from . import __version__
from .actions import ActionRunner
from .buttons import format_combo, parse_combo
from .config import CONFIG_PATH, PID_PATH, Binding, Config, ConfigError, editing, load
from .daemon import Daemon
from .devices import DeviceGone, Gamepad, find_pads, scan
from .keys import KeyParseError, parse_keys

# -- output helpers ----------------------------------------------------------

_COLOR = sys.stdout.isatty() and os.environ.get("NO_COLOR") is None


def _paint(text: str, code: str) -> str:
    return f"\033[{code}m{text}\033[0m" if _COLOR else text


def bold(text: str) -> str:
    return _paint(text, "1")


def dim(text: str) -> str:
    return _paint(text, "2")


def green(text: str) -> str:
    return _paint(text, "32")


def yellow(text: str) -> str:
    return _paint(text, "33")


def red(text: str) -> str:
    return _paint(text, "31")


def cyan(text: str) -> str:
    return _paint(text, "36")


def fail(message: str) -> int:
    print(f"{red('error')}: {message}", file=sys.stderr)
    return 1


# -- shared ------------------------------------------------------------------


def _load(args) -> Config:
    return load(Path(args.config) if args.config else None)


def _daemon_pid() -> int | None:
    """The running daemon's pid, from its pid file, or None.

    The pid is verified against /proc before it is used. A pid file can go
    stale and the number be recycled by an unrelated process, and signalling
    the wrong process is exactly the kind of mistake that is invisible until
    it does damage.
    """
    try:
        pid = int(PID_PATH.read_text().strip())
    except (OSError, ValueError):
        return None
    if pid <= 0:
        return None
    try:
        if os.stat(f"/proc/{pid}").st_uid != os.getuid():
            return None
        with open(f"/proc/{pid}/cmdline", "rb") as fh:
            argv = [part.decode("utf-8", "replace") for part in fh.read().split(b"\0")]
    except OSError:
        return None
    # Must genuinely be `python -m engine ... daemon`, as whole arguments --
    # not merely a command line that mentions those words somewhere.
    if "engine" not in argv or "daemon" not in argv:
        return None
    return pid


def _notify_daemon(sig: int) -> bool:
    """Signal the running daemon. Returns whether one was reached."""
    pid = _daemon_pid()
    if pid is None:
        return False
    try:
        os.kill(pid, sig)
        return True
    except OSError:
        return False


def _edit(args):
    """Load the config for a change that will be saved, locked against others."""
    return editing(Path(args.config) if args.config else None)


def _set_enabled(args, value: bool | None) -> int:
    with _edit(args) as config:
        config.enabled = (not config.enabled) if value is None else value
        config.save()
    reached = _notify_daemon(signal.SIGHUP)
    state = green("enabled") if config.enabled else yellow("disabled")
    note = (
        dim("  (applied to the running daemon)")
        if reached
        else dim("  (saved; no running daemon, applies when one starts)")
    )
    print(f"controller-control is now {state}{note}")
    return 0


def _open_one_pad(config: Config, *, exclusive: bool = False):
    pads = find_pads(config.device["match"])
    if not pads:
        return None
    return Gamepad(pads[0], config.settings, exclusive, config.aliases)


def _wait_for_pad(config: Config, timeout: float, quiet: bool = False):
    """Poll until a matching controller shows up."""
    deadline = time.monotonic() + timeout
    announced = False
    while time.monotonic() < deadline:
        pad = _open_one_pad(config)
        if pad is not None:
            return pad
        if not announced and not quiet:
            patterns = ", ".join(config.device["match"]) or "any gamepad"
            print(dim(f"waiting for a controller matching: {patterns} ..."))
            announced = True
        time.sleep(0.4)
    return None


# -- commands ----------------------------------------------------------------


def cmd_devices(args) -> int:
    devices = scan(include_all=args.all)
    if args.json:
        print(json.dumps([d.describe() for d in devices], indent=2))
        return 0
    if not devices:
        print("No input devices readable. Is your user in the 'input' group?")
        return 1
    for info in devices:
        kind = (
            green("gamepad")
            if info.is_gamepad
            else (cyan("keyboard") if info.is_keyboard else dim("other"))
        )
        print(f"{bold(info.name)}  {dim(info.path)}  [{kind}]")
        print(
            dim(
                f"    vid={info.vendor:04x} pid={info.product:04x} "
                f"bus={info.bustype:#x}"
            )
        )
        if info.is_gamepad:
            print(f"    buttons: {', '.join(info.button_tokens)}")
            if info.axis_names:
                print(f"    axes:    {', '.join(info.axis_names)}")
    return 0


def cmd_list(args) -> int:
    config = _load(args)
    if args.json:
        print(json.dumps(config.to_dict(), indent=2))
        return 0
    bindings = config.bindings
    if not bindings:
        print("No bindings configured.")
        return 0
    header = f"{len(bindings)} binding(s)  {dim(str(config.path))}"
    if not config.enabled:
        header += "  " + yellow("[DISABLED]")
    print(bold(header))
    width = max(len(b.label(config.layout)) for b in bindings)
    for binding in bindings:
        label = binding.label(config.layout).ljust(width)
        flags = []
        if binding.repeat:
            flags.append("repeat")
        if binding.hold:
            flags.append("hold")
        if not binding.enabled:
            flags.append("disabled")
        suffix = dim(f"  [{', '.join(flags)}]") if flags else ""
        action = cyan(binding.action_summary())
        description = f"  {dim('- ' + binding.description)}" if binding.description else ""
        marker = " " if binding.enabled else dim("x")
        print(f" {marker} {green(label)}  ->  {action}{description}{suffix}")
    return 0


def cmd_monitor(args) -> int:
    config = _load(args)
    pad = _wait_for_pad(config, args.timeout)
    if pad is None:
        return fail("no matching controller found")
    print(f"{green('connected')} {bold(pad.name)} {dim(pad.path)}")
    print(dim("Press buttons to see their tokens. Ctrl-C to stop."))
    held: set[str] = set()
    try:
        while True:
            ready, _, _ = select.select([pad.fileno()], [], [], 0.5)
            if not ready:
                continue
            try:
                events = pad.read()
            except DeviceGone:
                print(yellow("controller disconnected"))
                return 0
            for token, pressed in events:
                if pressed:
                    held.add(token)
                else:
                    held.discard(token)
                label = format_combo([token], config.layout)
                arrow = green("v") if pressed else dim("^")
                current = format_combo(sorted(held), config.layout) if held else ""
                raw = dim(f"({token})") if label != token else ""
                print(f" {arrow} {bold(label):<24} {raw:<16} held: {cyan(current)}")
    except KeyboardInterrupt:
        print()
        return 0
    finally:
        pad.close()


def _capture_combo(pad, config, settle: float = 0.35):
    """Record one chord: everything held down before the user lets go."""
    held: set[str] = set()
    peak: set[str] = set()
    released_at: float | None = None
    while True:
        timeout = 0.05 if released_at else 0.5
        ready, _, _ = select.select([pad.fileno()], [], [], timeout)
        if ready:
            events = pad.read()
            for token, pressed in events:
                if pressed:
                    held.add(token)
                    peak = set(held)
                    released_at = None
                else:
                    held.discard(token)
                    if not held:
                        released_at = time.monotonic()
        if released_at and peak and time.monotonic() - released_at >= settle:
            return tuple(sorted(peak))


def cmd_learn(args) -> int:
    config = _load(args)
    pad = _wait_for_pad(config, args.timeout, quiet=args.json)
    if pad is None:
        if args.json:
            print(json.dumps({"error": "no controller"}))
        return fail("no matching controller found")
    try:
        if not args.json:
            print(f"{green('connected')} {bold(pad.name)}")
            print(bold("Press and release the button combo you want to bind..."))
        combo = _capture_combo(pad, config)
    except (KeyboardInterrupt, DeviceGone):
        return 1
    finally:
        pad.close()

    existing = config.find(combo)
    if args.json:
        print(
            json.dumps(
                {
                    "combo": " + ".join(combo),
                    "label": format_combo(combo, config.layout),
                    "buttons": list(combo),
                    "bound": existing.action_summary() if existing else None,
                }
            )
        )
        return 0

    print(f"\n  combo:  {green(bold(format_combo(combo, config.layout)))}")
    print(f"  config: {cyan(' + '.join(combo))}")
    if existing:
        print(f"  {yellow('already bound to')} {existing.action_summary()}")
    print(
        dim(
            f"\nBind it with:\n"
            f"  controller-control bind '{' + '.join(combo)}' --keys SUPER+RETURN"
        )
    )
    return 0


def cmd_bind(args) -> int:
    if not args.keys and not args.exec_:
        return fail("give either --keys or --exec")
    if args.keys and args.exec_:
        return fail("--keys and --exec are mutually exclusive")

    if args.keys:
        try:
            parse_keys(args.keys)
        except KeyParseError as exc:
            return fail(str(exc))

    try:
        combo = parse_combo(args.combo)
    except ValueError as exc:
        return fail(str(exc))

    raw = {"combo": " + ".join(combo)}
    if args.keys:
        raw["keys"] = args.keys
    else:
        raw["exec"] = args.exec_
    if args.description:
        raw["description"] = args.description
    if args.repeat:
        raw["repeat"] = True
    if args.hold:
        raw["hold"] = True

    with _edit(args) as config:
        existing = config.find(combo)
        # There is no flag for it, so replacing a binding keeps it switched
        # off if it was.
        if existing is not None and not existing.enabled:
            raw["enabled"] = False
        try:
            binding = Binding(raw, len(config.bindings))
        except ConfigError as exc:
            return fail(str(exc))
        replaced = config.upsert(binding)
        config.save()
    _notify_daemon(signal.SIGHUP)
    verb = "replaced" if replaced else "added"
    print(
        f"{green(verb)} {bold(binding.label(config.layout))} -> "
        f"{cyan(binding.action_summary())}"
    )
    print(dim(f"saved to {config.path}"))
    return 0


def cmd_unbind(args) -> int:
    try:
        combo = parse_combo(args.combo)
    except ValueError as exc:
        return fail(str(exc))
    with _edit(args) as config:
        if not config.remove(combo):
            return fail(f"no binding for {format_combo(combo, config.layout)}")
        config.save()
    _notify_daemon(signal.SIGHUP)
    print(f"{green('removed')} {bold(format_combo(combo, config.layout))}")
    return 0


def cmd_test(args) -> int:
    config = _load(args)
    try:
        combo = parse_combo(args.combo)
    except ValueError as exc:
        return fail(str(exc))
    binding = config.find(combo)
    if binding is None:
        return fail(f"no binding for {format_combo(combo, config.layout)}")
    runner = ActionRunner(dry_run=args.dry_run)
    try:
        ok, detail = runner.run(binding)
    finally:
        runner.close()
    print(f"{green('ok') if ok else red('failed')}: {detail}")
    return 0 if ok else 1


def cmd_init(args) -> int:
    path = Path(args.config) if args.config else CONFIG_PATH
    if path.exists() and not args.force:
        return fail(f"{path} already exists (use --force to overwrite)")
    config = Config({}, path=path)
    config.save()
    print(f"{green('wrote')} {bold(str(path))} with {len(config.bindings)} bindings")
    return 0


def cmd_doctor(args) -> int:
    problems = 0

    def check(label: str, ok: bool, detail: str = "") -> None:
        nonlocal problems
        mark = green("ok  ") if ok else red("FAIL")
        print(f" [{mark}] {label}" + (f"  {dim(detail)}" if detail else ""))
        if not ok:
            problems += 1

    print(bold("controller-control doctor"))

    readable = [p for p in scan(include_all=True)]
    check(
        "can read /dev/input",
        bool(readable),
        f"{len(readable)} devices" if readable else "add your user to the 'input' group",
    )

    try:
        fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
        os.close(fd)
        check("can open /dev/uinput", True, "key synthesis available")
    except OSError as exc:
        check("can open /dev/uinput", False, str(exc))

    try:
        config = _load(args)
        check("config parses", True, str(config.path))
    except ConfigError as exc:
        check("config parses", False, str(exc))
        return 1

    runner = ActionRunner(dry_run=True)
    bad = [
        (b, runner.validate(b)) for b in config.active_bindings() if runner.validate(b)
    ]
    check(
        "all bindings resolve",
        not bad,
        "; ".join(f"{b.label()}: {why}" for b, why in bad),
    )

    pads = find_pads(config.device["match"])
    check(
        "controller present",
        bool(pads),
        ", ".join(p.name for p in pads) if pads else "turn the pad on / pair it",
    )

    # Not a pass/fail: a pad's capabilities do not reveal where it really
    # sends the d-pad, so this points at the way to find out rather than
    # pretending to detect it.
    source = config.dpad_source
    if source == "stick":
        hint = "  — left-stick events arrive as DPAD_*"
    else:
        hint = (
            "  — run 'controller-control monitor' and press the d-pad; if it "
            'reports LSTICK_*, set device.dpad_source to "stick"'
        )
    print(f" [{dim('info')}] d-pad source is {bold(source)}" + dim(hint))
    if config.aliases:
        remaps = ", ".join(f"{k}->{v}" for k, v in sorted(config.aliases.items()))
        print(f" [{dim('info')}] aliases: {dim(remaps)}")

    print()
    if problems:
        print(red(f"{problems} problem(s) found"))
    else:
        print(green("all good"))
    return 1 if problems else 0


def cmd_enable(args) -> int:
    return _set_enabled(args, True)


def cmd_disable(args) -> int:
    return _set_enabled(args, False)


def cmd_toggle(args) -> int:
    return _set_enabled(args, None)


def cmd_pause(args) -> int:
    reached = _notify_daemon(signal.SIGUSR2 if args.resume else signal.SIGUSR1)
    verb = "resumed" if args.resume else "paused"
    print(f"{verb} the running daemon" if reached else "no running daemon")
    return 0 if reached else 1


def cmd_daemon(args) -> int:
    try:
        config = _load(args)
    except ConfigError as exc:
        print(json.dumps({"event": "error", "message": str(exc)}), flush=True)
        return 1
    daemon = Daemon(
        config,
        dry_run=args.dry_run,
        emit_buttons=not args.no_buttons,
        exit_with_stdin=args.exit_with_stdin,
    )
    return daemon.run()


# -- argument parsing --------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="controller-control",
        description="Bind game controller button chords to desktop shortcuts.",
    )
    parser.add_argument("--version", action="version", version=__version__)
    parser.add_argument("--config", help=f"config file (default: {CONFIG_PATH})")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("devices", help="list input devices")
    p.add_argument("--all", action="store_true", help="include non-input devices")
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_devices)

    p = sub.add_parser("list", help="show configured bindings")
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_list)

    p = sub.add_parser("monitor", help="print buttons as you press them")
    p.add_argument("--timeout", type=float, default=30.0)
    p.set_defaults(func=cmd_monitor)

    p = sub.add_parser("learn", help="record one combo and print its config token")
    p.add_argument("--timeout", type=float, default=30.0)
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_learn)

    p = sub.add_parser("bind", help="bind a combo to keys or a command")
    p.add_argument("combo", help='e.g. "L + R" or "START"')
    p.add_argument("--keys", help='key combo to type, e.g. "SUPER+RETURN"')
    p.add_argument("--exec", dest="exec_", help="shell command to run")
    p.add_argument("--description", help="human readable label")
    p.add_argument("--repeat", action="store_true", help="auto-repeat while held")
    p.add_argument("--hold", action="store_true", help="only fire after a long press")
    p.set_defaults(func=cmd_bind)

    p = sub.add_parser("unbind", help="remove a binding")
    p.add_argument("combo")
    p.set_defaults(func=cmd_unbind)

    p = sub.add_parser("test", help="run the action bound to a combo")
    p.add_argument("combo")
    p.add_argument("--dry-run", action="store_true")
    p.set_defaults(func=cmd_test)

    p = sub.add_parser("init", help="write a default config file")
    p.add_argument("--force", action="store_true")
    p.set_defaults(func=cmd_init)

    p = sub.add_parser("enable", help="turn bindings back on")
    p.set_defaults(func=cmd_enable)

    p = sub.add_parser("disable", help="stop bindings firing, keeping them all")
    p.set_defaults(func=cmd_disable)

    p = sub.add_parser("toggle", help="flip between enabled and disabled")
    p.set_defaults(func=cmd_toggle)

    p = sub.add_parser("pause", help="mute firing until resumed (not persisted)")
    p.add_argument("--resume", action="store_true", help="resume instead")
    p.set_defaults(func=cmd_pause)

    p = sub.add_parser("doctor", help="check permissions and configuration")
    p.set_defaults(func=cmd_doctor)

    p = sub.add_parser("daemon", help="run the listener (used by the shell plugin)")
    p.add_argument("--dry-run", action="store_true", help="log actions, run nothing")
    p.add_argument("--no-buttons", action="store_true", help="omit per-button events")
    p.add_argument(
        "--exit-with-stdin",
        action="store_true",
        help="exit when stdin closes (the shell plugin holds it open)",
    )
    p.set_defaults(func=cmd_daemon)

    return parser


def main(argv: list[str] | None = None) -> int:
    # Stay line buffered when piped, so `monitor | tee` and friends stream.
    try:
        sys.stdout.reconfigure(line_buffering=True)
    except (AttributeError, ValueError):
        pass
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except ConfigError as exc:
        return fail(str(exc))
    except KeyboardInterrupt:
        return 130
    except BrokenPipeError:
        # Python flushes stdout again during shutdown; if the pipe is already
        # gone that second failure sets exit status 120. Redirect the fd so
        # the final flush lands somewhere harmless.
        try:
            devnull = os.open(os.devnull, os.O_WRONLY)
            os.dup2(devnull, sys.stdout.fileno())
        except OSError:
            pass
        return 0
