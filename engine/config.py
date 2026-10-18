"""Loading, validating and saving the controller-control config."""

from __future__ import annotations

import fcntl
import json
import os
import tempfile
from contextlib import contextmanager
from pathlib import Path

from .buttons import format_combo, normalize_button, parse_combo

CONFIG_VERSION = 1

XDG_CONFIG = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")
CONFIG_DIR = XDG_CONFIG / "controller-control"
CONFIG_PATH = CONFIG_DIR / "config.json"

# Where the running daemon advertises its pid, so the CLI can signal it.
# Identifying the daemon by scanning /proc for a command line mentioning
# "engine daemon" is not safe: an ordinary shell running a command that merely
# contains those words matches too, and would then be sent SIGHUP.
_RUNTIME = Path(
    os.environ.get("XDG_RUNTIME_DIR") or f"/tmp/controller-control-{os.getuid()}"
)
# Overridable so a test run cannot stomp on the pid file of a daemon that is
# genuinely running on the same machine.
PID_PATH = Path(
    os.environ.get("CONTROLLER_CONTROL_PID_FILE") or _RUNTIME / "controller-control.pid"
)

DEFAULT_SETTINGS: dict = {
    # How long to wait for more buttons before deciding a chord is complete.
    # Only applied when a longer binding could still match, so unambiguous
    # presses stay instant.
    "combo_window_ms": 45,
    # How long a "hold" binding must be held before it fires.
    "hold_ms": 450,
    # Auto-repeat timing for bindings marked "repeat".
    "repeat_delay_ms": 400,
    "repeat_interval_ms": 110,
    # Fraction of full travel at which an analog trigger/stick counts as pressed.
    "trigger_threshold": 0.45,
    "stick_threshold": 0.65,
    # Seconds between rescans of /dev/input for hotplugged pads.
    "rescan_interval_s": 2.0,
}

# Smallest (and, for fractions, largest) value each setting accepts. A zero
# repeat interval would fire on every pass of the loop, and a zero rescan
# interval would rescan on every pass: both spin a core.
SETTING_BOUNDS: dict[str, tuple[float, float | None]] = {
    "combo_window_ms": (0, None),
    "hold_ms": (1, None),
    "repeat_delay_ms": (0, None),
    "repeat_interval_ms": (10, None),
    "trigger_threshold": (0.01, 1.0),
    "stick_threshold": (0.01, 1.0),
    "rescan_interval_s": (0.1, None),
}

# Where a pad reports its d-pad. Most controllers use the hat axis, which is
# what "hat" means and why it is the default. Some pads -- notably 8BitDo in
# D-input mode -- send the d-pad on the left stick axes instead; "stick" makes
# those arrive as DPAD_* so the same bindings work.
DPAD_SOURCES = ("hat", "stick")

DEFAULT_DEVICE: dict = {
    # Name substrings to match, case-insensitive. Empty list = any gamepad,
    # which is the default so the plugin works on first run whatever you own.
    # Narrow it (e.g. ["8bitdo"]) when you have more than one pad and only want
    # one of them driving the desktop.
    #
    # Note that an empty list also means keyboard-mode pads are ignored: a
    # keyboard-shaped device is only ever considered when you name it
    # explicitly, so this can never latch onto your actual keyboard.
    "match": [],
    # Take the pad away from every other application (games, Steam, browsers).
    "exclusive": False,
    # Face-button labelling. "auto" uses the evdev/Xbox convention, which is
    # right for most pads. "nintendo" swaps the face labels for pads whose
    # plastic follows the Nintendo layout *and* whose firmware reports
    # positionally rather than by label.
    "layout": "auto",
    # See DPAD_SOURCES above.
    "dpad_source": "hat",
    # Free-form token remapping, applied to everything the pad reports:
    #   {"L2": "L", "THUMBL": "SELECT"}
    "aliases": {},
}

# Shipped starter bindings, all built on stock Omarchy keybindings.
#
# The d-pad is bound as DPAD_*, which is where nearly every controller reports
# it. Nothing here binds an analog stick: on a pad that has one, nudging it to
# change the volume or move window focus would be a nasty surprise. Pads that
# report their d-pad on the stick instead should set device.dpad_source to
# "stick", which renames those events to DPAD_* for free.
DEFAULT_BINDINGS: list[dict] = [
    {"combo": "A", "keys": "SUPER+RETURN", "description": "Terminal"},
    {"combo": "B", "keys": "SUPER+F", "description": "Full screen"},
    {"combo": "X", "keys": "SUPER+SHIFT+RETURN", "description": "Browser"},
    {"combo": "Y", "keys": "SUPER+SHIFT+F", "description": "File manager"},
    {"combo": "START", "keys": "SUPER+SPACE", "description": "Omarchy menu"},
    {"combo": "SELECT", "keys": "SUPER+K", "description": "Keybindings"},
    {"combo": "L", "keys": "SUPER+SHIFT+TAB", "description": "Previous workspace"},
    {"combo": "R", "keys": "SUPER+TAB", "description": "Next workspace"},
    {"combo": "DPAD_LEFT", "keys": "SUPER+LEFT", "description": "Focus left window"},
    {"combo": "DPAD_RIGHT", "keys": "SUPER+RIGHT", "description": "Focus right window"},
    {"combo": "DPAD_UP", "keys": "VOLUMEUP", "repeat": True, "description": "Volume up"},
    {
        "combo": "DPAD_DOWN",
        "keys": "VOLUMEDOWN",
        "repeat": True,
        "description": "Volume down",
    },
    {
        "combo": "L + R",
        "exec": "omarchy capture screenshot fullscreen",
        "description": "Screenshot",
    },
    # Locking is on a hold so a pocket press cannot fire it.
    {
        "combo": "SELECT + START",
        "keys": "SUPER+CTRL+L",
        "hold": True,
        "description": "Lock system",
    },
]


class ConfigError(Exception):
    """Raised when a config file cannot be understood."""


class Binding:
    """One combo -> action mapping."""

    __slots__ = ("combo", "keys", "exec", "description", "repeat", "hold", "enabled")

    def __init__(self, raw: dict, index: int):
        where = f"bindings[{index}]"
        if not isinstance(raw, dict):
            raise ConfigError(f"{where} must be an object")

        combo_spec = raw.get("combo")
        if not isinstance(combo_spec, str) or not combo_spec.strip():
            raise ConfigError(f"{where} is missing a 'combo'")
        try:
            self.combo = parse_combo(combo_spec)
        except ValueError as exc:
            raise ConfigError(f"{where}: {exc}") from exc

        self.keys = raw.get("keys")
        self.exec = raw.get("exec")
        if self.keys is not None and not isinstance(self.keys, str):
            raise ConfigError(f"{where}: 'keys' must be a string")
        if self.exec is not None and not isinstance(self.exec, str):
            raise ConfigError(f"{where}: 'exec' must be a string")
        if not self.keys and not self.exec:
            raise ConfigError(f"{where}: needs either 'keys' or 'exec'")

        self.description = str(raw.get("description") or "")
        self.repeat = bool(raw.get("repeat", False))
        self.hold = bool(raw.get("hold", False))
        self.enabled = bool(raw.get("enabled", True))

        if self.repeat and self.hold:
            raise ConfigError(f"{where}: 'repeat' and 'hold' are mutually exclusive")

    @property
    def key(self) -> tuple[str, ...]:
        return self.combo

    def label(self, layout: str = "auto") -> str:
        return format_combo(self.combo, layout)

    def action_summary(self) -> str:
        if self.keys:
            return f"keys {self.keys}"
        return f"exec {self.exec}"

    def to_dict(self) -> dict:
        out: dict = {"combo": " + ".join(self.combo)}
        if self.keys:
            out["keys"] = self.keys
        if self.exec:
            out["exec"] = self.exec
        if self.description:
            out["description"] = self.description
        if self.repeat:
            out["repeat"] = True
        if self.hold:
            out["hold"] = True
        if not self.enabled:
            out["enabled"] = False
        return out


class Config:
    def __init__(self, raw: dict | None = None, path: Path | None = None):
        raw = raw or {}
        self.path = path or CONFIG_PATH

        version = raw.get("version", CONFIG_VERSION)
        if version != CONFIG_VERSION:
            raise ConfigError(
                f"unsupported config version {version!r} "
                f"(this build understands {CONFIG_VERSION})"
            )

        # A master switch, so the pad can be silenced without losing bindings
        # or dropping the Bluetooth connection.
        self.enabled = bool(raw.get("enabled", True))

        raw_device = raw.get("device") or {}
        if not isinstance(raw_device, dict):
            raise ConfigError("'device' must be an object")
        raw_settings = raw.get("settings") or {}
        if not isinstance(raw_settings, dict):
            raise ConfigError("'settings' must be an object")
        self.device = {**DEFAULT_DEVICE, **raw_device}
        self.settings = {**DEFAULT_SETTINGS, **raw_settings}
        for name, (low, high) in SETTING_BOUNDS.items():
            value = self.settings[name]
            if isinstance(value, bool) or not isinstance(value, (int, float)):
                raise ConfigError(f"settings.{name} must be a number")
            if value < low or (high is not None and value > high):
                limit = f"between {low} and {high}" if high is not None else f"at least {low}"
                raise ConfigError(f"settings.{name} must be {limit}")

        match = self.device.get("match")
        if isinstance(match, str):
            match = [match]
        if match is None:
            match = []
        if not isinstance(match, list) or any(not isinstance(m, str) for m in match):
            raise ConfigError("device.match must be a string or list of strings")
        self.device["match"] = [m.lower() for m in match]

        source = self.device.get("dpad_source", "hat")
        if source not in DPAD_SOURCES:
            raise ConfigError(
                f"device.dpad_source must be one of {', '.join(DPAD_SOURCES)}"
            )

        raw_aliases = self.device.get("aliases") or {}
        if not isinstance(raw_aliases, dict):
            raise ConfigError("device.aliases must be an object")
        if any(not isinstance(v, str) for v in raw_aliases.values()):
            raise ConfigError("device.aliases values must be button names")
        aliases = {
            normalize_button(k): normalize_button(v) for k, v in raw_aliases.items()
        }
        if source == "stick":
            # A pad that puts the d-pad on the stick has no separate stick to
            # lose, so this is a straight rename rather than a trade-off.
            for direction in ("UP", "DOWN", "LEFT", "RIGHT"):
                aliases.setdefault(f"LSTICK_{direction}", f"DPAD_{direction}")
        self.device["aliases"] = aliases

        raw_bindings = raw.get("bindings")
        if raw_bindings is None:
            raw_bindings = DEFAULT_BINDINGS
        if not isinstance(raw_bindings, list):
            raise ConfigError("'bindings' must be a list")

        self.bindings: list[Binding] = []
        seen: dict[tuple[str, ...], int] = {}
        for index, item in enumerate(raw_bindings):
            binding = Binding(item, index)
            if binding.combo in seen:
                raise ConfigError(
                    f"bindings[{index}]: combo {binding.label()!r} is already "
                    f"bound at bindings[{seen[binding.combo]}]"
                )
            seen[binding.combo] = index
            self.bindings.append(binding)

    # -- accessors ----------------------------------------------------------

    @property
    def layout(self) -> str:
        return str(self.device.get("layout", "auto"))

    @property
    def aliases(self) -> dict:
        return self.device.get("aliases") or {}

    @property
    def dpad_source(self) -> str:
        return str(self.device.get("dpad_source", "hat"))

    @property
    def exclusive(self) -> bool:
        return bool(self.device.get("exclusive", False))

    def setting(self, name: str) -> float:
        return float(self.settings.get(name, DEFAULT_SETTINGS[name]))

    def active_bindings(self) -> list[Binding]:
        return [b for b in self.bindings if b.enabled]

    def find(self, combo: tuple[str, ...]) -> Binding | None:
        for binding in self.bindings:
            if binding.combo == combo:
                return binding
        return None

    def remove(self, combo: tuple[str, ...]) -> bool:
        before = len(self.bindings)
        self.bindings = [b for b in self.bindings if b.combo != combo]
        return len(self.bindings) != before

    def upsert(self, binding: Binding) -> bool:
        """Add or replace a binding. Returns True when it replaced an existing one."""
        for index, existing in enumerate(self.bindings):
            if existing.combo == binding.combo:
                self.bindings[index] = binding
                return True
        self.bindings.append(binding)
        return False

    # -- serialisation ------------------------------------------------------

    def to_dict(self) -> dict:
        return {
            "version": CONFIG_VERSION,
            "enabled": self.enabled,
            "device": self.device,
            "settings": self.settings,
            "bindings": [b.to_dict() for b in self.bindings],
        }

    def save(self, path: Path | None = None) -> Path:
        target = Path(path or self.path)
        target.parent.mkdir(parents=True, exist_ok=True)
        payload = json.dumps(self.to_dict(), indent=2) + "\n"
        # Write atomically so a crash mid-save can never truncate the config.
        handle, tmp_name = tempfile.mkstemp(
            dir=str(target.parent), prefix=".config-", suffix=".json"
        )
        try:
            with os.fdopen(handle, "w") as fh:
                fh.write(payload)
                fh.flush()
                os.fsync(fh.fileno())
            os.replace(tmp_name, target)
        except BaseException:
            try:
                os.unlink(tmp_name)
            except OSError:
                pass
            raise
        return target


def load(path: Path | None = None, *, create: bool = False) -> Config:
    target = Path(path or CONFIG_PATH)
    if not target.exists():
        config = Config({}, path=target)
        if create:
            config.save()
        return config
    try:
        raw = json.loads(target.read_text())
    except json.JSONDecodeError as exc:
        raise ConfigError(f"{target}: invalid JSON: {exc}") from exc
    except (OSError, UnicodeDecodeError) as exc:
        raise ConfigError(f"{target}: cannot read: {exc}") from exc
    if not isinstance(raw, dict):
        raise ConfigError(f"{target}: top level must be an object")
    return Config(raw, path=target)


def stamp(path: Path) -> tuple | None:
    """Identity of the file's current contents, to notice it being rewritten."""
    try:
        st = os.stat(path)
    except OSError:
        return None
    return (st.st_ino, st.st_size, st.st_mtime_ns)


@contextmanager
def editing(path: Path | None = None):
    """Load the config for a read-change-save, holding a lock throughout.

    The panel runs each edit as its own CLI process. Without the lock, two
    edits that overlap both read the old file and the second save drops the
    first edit.
    """
    target = Path(path or CONFIG_PATH)
    target.parent.mkdir(parents=True, exist_ok=True)
    with open(target.parent / f".{target.name}.lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            yield load(target)
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)
