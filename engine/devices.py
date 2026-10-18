"""Finding gamepads and decoding their events into button tokens."""

from __future__ import annotations

import errno
import os

from . import linux_input as li
from ._codes import ABS_CODES
from .buttons import (
    CODE_TO_BUTTON,
    HAT_AXES,
    STICK_AXES,
    TRIGGER_AXES,
    button_for_key_code,
)
from .keys import VirtualKeyboard

_ABS_NAMES = {code: name for name, code in ABS_CODES.items()}

# KEY_Q..KEY_P, KEY_A..KEY_L and KEY_Z..KEY_M: the letter rows of a keyboard.
_LETTER_KEYS = frozenset([*range(16, 26), *range(30, 39), *range(44, 51)])


class DeviceGone(Exception):
    """The device vanished mid-read (unplugged, or Bluetooth dropped)."""


class DeviceInfo:
    """Everything we can learn about an input device without reading from it."""

    def __init__(self, path: str, fd: int):
        self.path = path
        self.name = li.read_name(fd)
        self.phys = li.read_phys(fd)
        self.uniq = li.read_uniq(fd)
        ids = li.read_id(fd)
        self.bustype = ids["bustype"]
        self.vendor = ids["vendor"]
        self.product = ids["product"]

        key_bits = li.read_bits(fd, li.EV_KEY, li.KEY_CNT)
        abs_bits = li.read_bits(fd, li.EV_ABS, li.ABS_CNT)
        self.key_codes = [c for c in range(li.KEY_CNT) if li.bit_is_set(key_bits, c)]
        self.abs_codes = [a for a in range(li.ABS_CNT) if li.bit_is_set(abs_bits, a)]
        self.abs_info = {a: li.read_abs_info(fd, a) for a in self.abs_codes}

    @property
    def pad_buttons(self) -> list[int]:
        """Key codes in the joystick/gamepad range."""
        return [
            c
            for c in self.key_codes
            if li.BTN_JOYSTICK <= c <= li.BTN_THUMBR
            or li.BTN_TRIGGER_HAPPY <= c <= li.BTN_TRIGGER_HAPPY40
            or 0x220 <= c <= 0x223  # BTN_DPAD_*
        ]

    @property
    def is_gamepad(self) -> bool:
        if not self.pad_buttons:
            return False
        # Virtual keyboards from remote-desktop and input tools often claim
        # every key code there is, joystick buttons included. A real pad has
        # axes; a device with the letter rows and no axes is a keyboard.
        has_letters = len(_LETTER_KEYS.intersection(self.key_codes)) == len(_LETTER_KEYS)
        return bool(self.abs_codes) or not has_letters

    @property
    def is_keyboard(self) -> bool:
        # A plain keyboard exposes letter keys but no pad buttons.
        return not self.is_gamepad and any(2 <= c <= 60 for c in self.key_codes)

    @property
    def is_own_keyboard(self) -> bool:
        """The virtual keyboard this program types `keys` actions on."""
        return (self.vendor, self.product) == (VirtualKeyboard.VENDOR, VirtualKeyboard.PRODUCT)

    @property
    def button_tokens(self) -> list[str]:
        if not self.is_gamepad:
            return []
        # Pad-range buttons, plus named buttons outside that range (a
        # dedicated Back reports BTN_BACK, which sits among the mouse buttons).
        pad = set(self.pad_buttons)
        return [
            button_for_key_code(c)
            for c in self.key_codes
            if c in pad or c in CODE_TO_BUTTON
        ]

    @property
    def axis_names(self) -> list[str]:
        return [_ABS_NAMES.get(a, f"ABS_{a}") for a in self.abs_codes]

    def describe(self) -> dict:
        return {
            "path": self.path,
            "name": self.name,
            "phys": self.phys,
            "uniq": self.uniq,
            "vendor": f"{self.vendor:04x}",
            "product": f"{self.product:04x}",
            "bustype": self.bustype,
            "gamepad": self.is_gamepad,
            "keyboard": self.is_keyboard,
            "buttons": self.button_tokens,
            "axes": self.axis_names,
        }

    def matches(self, patterns: list[str]) -> bool:
        """True when the device name contains any of the (lowercase) patterns."""
        if not patterns:
            return True
        haystack = self.name.lower()
        return any(p in haystack for p in patterns)


class DeviceScanner:
    """Inspects input devices, remembering what it has already seen.

    Opening a /dev/input/event* node is surprisingly expensive -- on a typical
    desktop it blocks for ~20ms in the kernel, so re-inspecting every node just
    to notice a hotplug costs a quarter of a second and stalls the daemon's
    timers. Listing the nodes, by contrast, is a sub-millisecond glob. So this
    caches the inspection per device node and only pays the open() cost for
    nodes it has not seen before.

    The cache key includes the node's identity, mtime and ctime, so a node
    that is destroyed and recreated is re-inspected rather than served from
    cache. ctime matters for hotplug: a new node appears root-only and udev
    grants access a moment later, which changes only the ctime. Without it a
    scan in that moment would remember the node as unreadable for good.
    """

    def __init__(self) -> None:
        self._cache: dict[str, tuple[tuple, DeviceInfo | None]] = {}

    @staticmethod
    def _stamp(path: str) -> tuple | None:
        try:
            st = os.stat(path)
        except OSError:
            return None
        return (st.st_ino, st.st_rdev, st.st_mtime_ns, st.st_ctime_ns)

    def inspect(self, path: str) -> DeviceInfo | None:
        stamp = self._stamp(path)
        if stamp is None:
            self._cache.pop(path, None)
            return None
        cached = self._cache.get(path)
        if cached is not None and cached[0] == stamp:
            return cached[1]

        info: DeviceInfo | None = None
        try:
            fd = li.open_event_device(path)
        except OSError:
            fd = -1
        if fd >= 0:
            try:
                info = DeviceInfo(path, fd)
            except OSError:
                info = None
            finally:
                os.close(fd)
        self._cache[path] = (stamp, info)
        return info

    def scan(self, include_all: bool = False) -> list[DeviceInfo]:
        paths = li.event_device_paths()
        live = set(paths)
        for stale in [p for p in self._cache if p not in live]:
            del self._cache[stale]

        out = []
        for path in paths:
            info = self.inspect(path)
            if info is None:
                continue
            if include_all or info.is_gamepad or info.is_keyboard:
                out.append(info)
        return out

    def find_pads(
        self, patterns: list[str], allow_keyboard: bool = True
    ) -> list[DeviceInfo]:
        """Devices that both look like a controller and match the name filter.

        `allow_keyboard` covers 8BitDo pads switched into keyboard mode, which
        present as an ordinary HID keyboard rather than a gamepad.
        """
        devices = []
        for info in self.scan():
            # Never our own output: grabbing it would swallow every key we type.
            if info.is_own_keyboard or not info.matches(patterns):
                continue
            if info.is_gamepad or (allow_keyboard and patterns and info.is_keyboard):
                devices.append(info)
        return devices


def scan(include_all: bool = False) -> list[DeviceInfo]:
    """One-shot inspection of every readable /dev/input/event* node."""
    return DeviceScanner().scan(include_all=include_all)


def find_pads(patterns: list[str], allow_keyboard: bool = True) -> list[DeviceInfo]:
    """One-shot search for controllers matching `patterns`."""
    return DeviceScanner().find_pads(patterns, allow_keyboard=allow_keyboard)


class Gamepad:
    """An open controller, decoding raw events into button tokens."""

    def __init__(
        self,
        info: DeviceInfo,
        settings: dict,
        exclusive: bool = False,
        aliases: dict | None = None,
    ):
        self.info = info
        self.path = info.path
        self.name = info.name
        # Which inputs hold each token, as (event type, code). Two inputs can
        # produce one token -- an analog trigger and its digital button, or a
        # hat and a stick aliased onto the d-pad -- and the token stays held
        # until both let go.
        self._holders: dict[str, set[tuple[int, int]]] = {}
        self.apply(settings, aliases)
        self.fd = li.open_event_device(info.path)
        self.grabbed = li.grab(self.fd, True) if exclusive else False
        # Axis tokens currently considered "pressed", keyed by axis code.
        self._axis_state: dict[int, set[str]] = {}
        # Key codes reported down, to compare against the real state after
        # the kernel drops events.
        self._keys_down: set[int] = set()
        self._resyncing = False

    def apply(self, settings: dict, aliases: dict | None = None) -> None:
        """Take new settings and aliases without reopening the device."""
        # Applied to every token before anything else sees it, so bindings,
        # capture and the UI all speak the same names.
        self.aliases = dict(aliases or {})
        self.trigger_threshold = float(settings.get("trigger_threshold", 0.45))
        self.stick_threshold = float(settings.get("stick_threshold", 0.65))
        # Tokens may now be named differently; the daemon starts over too.
        self._holders.clear()

    def fileno(self) -> int:
        return self.fd

    def close(self) -> None:
        if self.fd < 0:
            return
        if self.grabbed:
            li.grab(self.fd, False)
        try:
            os.close(self.fd)
        finally:
            self.fd = -1

    # -- decoding -----------------------------------------------------------

    def _hat_tokens(self, code: int, value: int) -> set[str]:
        negative, positive = HAT_AXES[code]
        if value < 0:
            return {negative}
        if value > 0:
            return {positive}
        return set()

    def _trigger_tokens(self, code: int, value: int) -> set[str]:
        info = self.info.abs_info.get(code) or {}
        low, high = info.get("min", 0), info.get("max", 255)
        span = high - low
        fraction = (value - low) / span if span else 0.0
        return {TRIGGER_AXES[code]} if fraction >= self.trigger_threshold else set()

    def _stick_tokens(self, code: int, value: int) -> set[str]:
        info = self.info.abs_info.get(code) or {}
        low, high = info.get("min", -32768), info.get("max", 32767)
        centre = (low + high) / 2.0
        span = (high - low) / 2.0
        fraction = (value - centre) / span if span else 0.0
        negative, positive = STICK_AXES[code]
        if fraction <= -self.stick_threshold:
            return {negative}
        if fraction >= self.stick_threshold:
            return {positive}
        return set()

    def _decode_abs(self, code: int, value: int) -> list[tuple[tuple, str, bool]]:
        if code in HAT_AXES:
            active = self._hat_tokens(code, value)
        elif code in TRIGGER_AXES:
            active = self._trigger_tokens(code, value)
        elif code in STICK_AXES:
            active = self._stick_tokens(code, value)
        else:
            return []

        previous = self._axis_state.get(code, set())
        if active == previous:
            return []
        self._axis_state[code] = active
        source = (li.EV_ABS, code)
        events = [(source, token, False) for token in sorted(previous - active)]
        events += [(source, token, True) for token in sorted(active - previous)]
        return events

    def _decode_key(self, code: int, pressed: bool) -> list[tuple[tuple, str, bool]]:
        if pressed:
            self._keys_down.add(code)
        else:
            self._keys_down.discard(code)
        return [((li.EV_KEY, code), button_for_key_code(code), pressed)]

    def _resync(self) -> list[tuple[tuple, str, bool]]:
        """Bring our idea of what is held in line with the device's real state."""
        changes: list[tuple[tuple, str, bool]] = []
        state = li.read_key_state(self.fd)
        if state:
            down = {c for c in self.info.key_codes if li.bit_is_set(state, c)}
            for code in sorted(self._keys_down - down):
                changes.extend(self._decode_key(code, False))
            for code in sorted(down - self._keys_down):
                changes.extend(self._decode_key(code, True))
        for code in self.info.abs_codes:
            if code in HAT_AXES or code in TRIGGER_AXES or code in STICK_AXES:
                info = li.read_abs_info(self.fd, code)
                if info is not None:
                    changes.extend(self._decode_abs(code, info["value"]))
        return changes

    def _track(self, source: tuple, token: str, pressed: bool) -> bool:
        """Record one input changing. True when it changes whether `token` is held."""
        holders = self._holders.get(token)
        if pressed:
            if holders:
                holders.add(source)
                return False
            self._holders[token] = {source}
            return True
        if not holders or source not in holders:
            return False
        holders.discard(source)
        if holders:
            return False
        del self._holders[token]
        return True

    # -- reading ------------------------------------------------------------

    def read(self) -> list[tuple[str, bool]]:
        """Drain pending events. Returns (button_token, pressed) pairs."""
        changes: list[tuple[tuple, str, bool]] = []
        while True:
            try:
                data = os.read(self.fd, li.EVENT_SIZE * 64)
            except BlockingIOError:
                break
            except OSError as exc:
                if exc.errno in (errno.ENODEV, errno.EBADF):
                    raise DeviceGone(self.path) from exc
                if exc.errno == errno.EAGAIN:
                    break
                raise
            if not data:
                raise DeviceGone(self.path)

            for offset in range(0, len(data) - li.EVENT_SIZE + 1, li.EVENT_SIZE):
                _sec, _usec, ev_type, code, value = li.unpack_event(data, offset)
                if ev_type == li.EV_SYN:
                    if code == li.SYN_DROPPED:
                        # Our buffer overflowed and events were lost, perhaps
                        # a release. Skip to the next report, then read the
                        # real state, so no button is left stuck down.
                        self._resyncing = True
                    elif code == li.SYN_REPORT and self._resyncing:
                        self._resyncing = False
                        changes.extend(self._resync())
                    continue
                if self._resyncing:
                    continue
                if ev_type == li.EV_KEY:
                    if value == 2:  # kernel autorepeat; our own repeat handles it
                        continue
                    changes.extend(self._decode_key(code, value == 1))
                elif ev_type == li.EV_ABS:
                    changes.extend(self._decode_abs(code, value))

            if len(data) < li.EVENT_SIZE * 64:
                break

        events: list[tuple[str, bool]] = []
        for source, token, pressed in changes:
            token = self.aliases.get(token, token)
            if self._track(source, token, pressed):
                events.append((token, pressed))
        return events
