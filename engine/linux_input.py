"""Minimal pure-stdlib bindings for the Linux evdev/uinput ABI.

Only the pieces controller-control needs. No third-party dependencies, so the
plugin stays drop-in installable (Omarchy never runs install hooks for plugins).
"""

from __future__ import annotations

import ctypes
import fcntl
import glob
import os
import struct

# --- ioctl request encoding (asm-generic/ioctl.h) ---------------------------

_IOC_NONE, _IOC_WRITE, _IOC_READ = 0, 1, 2


def _ioc(direction: int, letter: str, number: int, size: int) -> int:
    return (direction << 30) | (size << 16) | (ord(letter) << 8) | number


# --- event types ------------------------------------------------------------

EV_SYN = 0x00
EV_KEY = 0x01
EV_REL = 0x02
EV_ABS = 0x03
EV_MSC = 0x04

SYN_REPORT = 0
# The kernel's buffer for this reader overflowed and events were thrown away.
SYN_DROPPED = 3

# --- button/axis codes we care about ---------------------------------------

BTN_MISC = 0x100
BTN_JOYSTICK = 0x120
BTN_GAMEPAD = 0x130
BTN_THUMBR = 0x13E
BTN_TRIGGER_HAPPY = 0x2C0
BTN_TRIGGER_HAPPY40 = 0x2E7

ABS_X = 0x00
ABS_Z = 0x02
ABS_RZ = 0x05
ABS_HAT0X = 0x10
ABS_HAT0Y = 0x11
ABS_MAX = 0x3F

KEY_MAX = 0x2FF
ABS_CNT = ABS_MAX + 1
KEY_CNT = KEY_MAX + 1

# --- evdev ioctls -----------------------------------------------------------

EVIOCGVERSION = _ioc(_IOC_READ, "E", 0x01, 4)
EVIOCGID = _ioc(_IOC_READ, "E", 0x02, 8)
EVIOCGRAB = _ioc(_IOC_WRITE, "E", 0x90, 4)


def EVIOCGNAME(length: int) -> int:
    return _ioc(_IOC_READ, "E", 0x06, length)


def EVIOCGPHYS(length: int) -> int:
    return _ioc(_IOC_READ, "E", 0x07, length)


def EVIOCGUNIQ(length: int) -> int:
    return _ioc(_IOC_READ, "E", 0x08, length)


def EVIOCGKEY(length: int) -> int:
    return _ioc(_IOC_READ, "E", 0x18, length)


def EVIOCGBIT(ev_type: int, length: int) -> int:
    return _ioc(_IOC_READ, "E", 0x20 + ev_type, length)


def EVIOCGABS(axis: int) -> int:
    return _ioc(_IOC_READ, "E", 0x40 + axis, struct.calcsize("iiiiii"))


# --- uinput ioctls ----------------------------------------------------------

_UINPUT_SETUP_FMT = "HHHH80sI"  # struct input_id + char name[80] + __u32

UI_DEV_CREATE = _ioc(_IOC_NONE, "U", 1, 0)
UI_DEV_DESTROY = _ioc(_IOC_NONE, "U", 2, 0)
UI_DEV_SETUP = _ioc(_IOC_WRITE, "U", 3, struct.calcsize(_UINPUT_SETUP_FMT))
UI_SET_EVBIT = _ioc(_IOC_WRITE, "U", 100, 4)
UI_SET_KEYBIT = _ioc(_IOC_WRITE, "U", 101, 4)
UI_SET_ABSBIT = _ioc(_IOC_WRITE, "U", 103, 4)

# struct uinput_abs_setup { __u16 code; struct input_absinfo absinfo; }
# input_absinfo is six __s32 fields; the leading __u16 is padded to 4 bytes.
_UINPUT_ABS_SETUP_FMT = "H2x6i"
UI_ABS_SETUP = _ioc(_IOC_WRITE, "U", 4, struct.calcsize(_UINPUT_ABS_SETUP_FMT))


def pack_abs_setup(
    code: int,
    minimum: int,
    maximum: int,
    fuzz: int = 0,
    flat: int = 0,
    resolution: int = 0,
    value: int = 0,
) -> bytes:
    return struct.pack(
        _UINPUT_ABS_SETUP_FMT, code, value, minimum, maximum, fuzz, flat, resolution
    )

BUS_USB = 0x03
BUS_BLUETOOTH = 0x05

# --- struct input_event -----------------------------------------------------

# struct timeval is two C longs, followed by __u16 type, __u16 code, __s32 value.
_EVENT_FMT = "@llHHi"
EVENT_SIZE = struct.calcsize(_EVENT_FMT)
_event_struct = struct.Struct(_EVENT_FMT)

unpack_event = _event_struct.unpack_from


def pack_event(ev_type: int, code: int, value: int) -> bytes:
    """Pack an input_event. The kernel fills in the timestamp for uinput writes."""
    return _event_struct.pack(0, 0, ev_type, code, value)


# --- helpers ----------------------------------------------------------------


def bit_is_set(buf: bytes, bit: int) -> bool:
    index = bit // 8
    return index < len(buf) and bool(buf[index] & (1 << (bit % 8)))


def _ioctl_string(fd: int, request_for_length, length: int = 256) -> str:
    buf = ctypes.create_string_buffer(length)
    try:
        fcntl.ioctl(fd, request_for_length(length), buf)
    except OSError:
        return ""
    return buf.value.decode("utf-8", "replace")


def read_name(fd: int) -> str:
    return _ioctl_string(fd, EVIOCGNAME)


def read_phys(fd: int) -> str:
    return _ioctl_string(fd, EVIOCGPHYS, 128)


def read_uniq(fd: int) -> str:
    return _ioctl_string(fd, EVIOCGUNIQ, 128)


def read_id(fd: int) -> dict:
    buf = bytearray(8)
    try:
        fcntl.ioctl(fd, EVIOCGID, buf)
    except OSError:
        return {"bustype": 0, "vendor": 0, "product": 0, "version": 0}
    bustype, vendor, product, version = struct.unpack("HHHH", buf)
    return {
        "bustype": bustype,
        "vendor": vendor,
        "product": product,
        "version": version,
    }


def read_bits(fd: int, ev_type: int, count: int) -> bytes:
    buf = bytearray((count + 7) // 8)
    try:
        fcntl.ioctl(fd, EVIOCGBIT(ev_type, len(buf)), buf)
    except OSError:
        return b""
    return bytes(buf)


def read_key_state(fd: int) -> bytes:
    """Bitmask of the keys and buttons held down right now."""
    buf = bytearray((KEY_CNT + 7) // 8)
    try:
        fcntl.ioctl(fd, EVIOCGKEY(len(buf)), buf)
    except OSError:
        return b""
    return bytes(buf)


def read_abs_info(fd: int, axis: int) -> dict | None:
    buf = bytearray(struct.calcsize("iiiiii"))
    try:
        fcntl.ioctl(fd, EVIOCGABS(axis), buf)
    except OSError:
        return None
    value, minimum, maximum, fuzz, flat, resolution = struct.unpack("iiiiii", buf)
    return {
        "value": value,
        "min": minimum,
        "max": maximum,
        "fuzz": fuzz,
        "flat": flat,
        "resolution": resolution,
    }


def grab(fd: int, exclusive: bool) -> bool:
    """Take or release an exclusive grab on the device. Returns success."""
    try:
        fcntl.ioctl(fd, EVIOCGRAB, 1 if exclusive else 0)
        return True
    except OSError:
        return False


def event_device_paths() -> list[str]:
    paths = glob.glob("/dev/input/event*")
    paths.sort(key=lambda p: int(p.rsplit("event", 1)[-1] or 0))
    return paths


def open_event_device(path: str) -> int:
    return os.open(path, os.O_RDONLY | os.O_NONBLOCK)
