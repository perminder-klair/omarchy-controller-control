"""Translation between raw evdev codes and the button tokens used in config.

Config files talk about buttons as short uppercase tokens ("A", "L", "START",
"DPAD_UP"). This module is the single place that knows how those map onto the
codes a kernel driver actually reports.

Button naming follows the Linux/evdev convention, which is the Xbox layout:
BTN_SOUTH is "A", BTN_EAST is "B", BTN_NORTH is "X", BTN_WEST is "Y". 8BitDo
pads use the Nintendo physical layout, so the button *printed* "A" on a Zero 2
reports as BTN_EAST. That is why `learn` exists: it records whatever the pad
actually sends, so you never have to guess. Set `layout` to "nintendo" to make
the labels shown in the UI match the plastic.
"""

from __future__ import annotations

from ._codes import ABS_CODES, BTN_CODES, KEY_CODES

# --- gamepad buttons --------------------------------------------------------

# Canonical token -> evdev BTN_* code. Ordered roughly the way a pad is held.
GAMEPAD_BUTTONS: dict[str, int] = {
    "A": BTN_CODES["SOUTH"],
    "B": BTN_CODES["EAST"],
    "X": BTN_CODES["NORTH"],
    "Y": BTN_CODES["WEST"],
    "C": BTN_CODES["C"],
    "Z": BTN_CODES["Z"],
    "L": BTN_CODES["TL"],
    "R": BTN_CODES["TR"],
    "L2": BTN_CODES["TL2"],
    "R2": BTN_CODES["TR2"],
    "SELECT": BTN_CODES["SELECT"],
    "START": BTN_CODES["START"],
    "MODE": BTN_CODES["MODE"],
    # A dedicated Back input is independent of the legacy Select/Back alias.
    "BACK_BUTTON": BTN_CODES["BACK"],
    "THUMBL": BTN_CODES["THUMBL"],
    "THUMBR": BTN_CODES["THUMBR"],
    # Some drivers report the d-pad as real buttons instead of a hat axis.
    "DPAD_UP": BTN_CODES["DPAD_UP"],
    "DPAD_DOWN": BTN_CODES["DPAD_DOWN"],
    "DPAD_LEFT": BTN_CODES["DPAD_LEFT"],
    "DPAD_RIGHT": BTN_CODES["DPAD_RIGHT"],
}

CODE_TO_BUTTON: dict[int, str] = {}
for _token, _code in GAMEPAD_BUTTONS.items():
    CODE_TO_BUTTON.setdefault(_code, _token)

# Names for every other code, so decoding an event is one lookup. The first
# name listed wins, except the kernel's range markers: BTN_JOYSTICK and
# BTN_TRIGGER_HAPPY share a code with the button that opens their range, and
# that button's own name (TRIGGER, TRIGGER_HAPPY1) is the one a pad means.
_RANGE_MARKERS = frozenset({"JOYSTICK", "TRIGGER_HAPPY"})
_BTN_NAMES: dict[int, str] = {}
for _name, _code in BTN_CODES.items():
    if _code not in _BTN_NAMES or _BTN_NAMES[_code] in _RANGE_MARKERS:
        _BTN_NAMES[_code] = _name
_KEY_NAMES: dict[int, str] = {}
for _name, _code in KEY_CODES.items():
    _KEY_NAMES.setdefault(_code, f"KEY_{_name}")

# Aliases accepted in config files, so hand-written configs are forgiving.
BUTTON_ALIASES: dict[str, str] = {
    "SOUTH": "A",
    "EAST": "B",
    "NORTH": "X",
    "WEST": "Y",
    "TL": "L",
    "TR": "R",
    "TL2": "L2",
    "TR2": "R2",
    "L1": "L",
    "R1": "R",
    "LB": "L",
    "RB": "R",
    "LT": "L2",
    "RT": "R2",
    "BACK": "SELECT",
    "MINUS": "SELECT",
    "PLUS": "START",
    "HOME": "MODE",
    "GUIDE": "MODE",
    "UP": "DPAD_UP",
    "DOWN": "DPAD_DOWN",
    "LEFT": "DPAD_LEFT",
    "RIGHT": "DPAD_RIGHT",
    "DUP": "DPAD_UP",
    "DDOWN": "DPAD_DOWN",
    "DLEFT": "DPAD_LEFT",
    "DRIGHT": "DPAD_RIGHT",
    # Older builds named these after the kernel's range markers.
    "JOYSTICK": "TRIGGER",
    "TRIGGER_HAPPY": "TRIGGER_HAPPY1",
}

# Physical-label overrides for pads that use the Nintendo face layout.
NINTENDO_LABELS: dict[str, str] = {"A": "B", "B": "A", "X": "Y", "Y": "X"}

# --- hat axes ---------------------------------------------------------------

# axis code -> (token when value < 0, token when value > 0)
HAT_AXES: dict[int, tuple[str, str]] = {
    ABS_CODES["HAT0X"]: ("DPAD_LEFT", "DPAD_RIGHT"),
    ABS_CODES["HAT0Y"]: ("DPAD_UP", "DPAD_DOWN"),
}

# Analog triggers reported as axes rather than buttons.
TRIGGER_AXES: dict[int, str] = {
    ABS_CODES["Z"]: "L2",
    ABS_CODES["RZ"]: "R2",
}

# Analog sticks, exposed as four directional pseudo-buttons each.
STICK_AXES: dict[int, tuple[str, str]] = {
    ABS_CODES["X"]: ("LSTICK_LEFT", "LSTICK_RIGHT"),
    ABS_CODES["Y"]: ("LSTICK_UP", "LSTICK_DOWN"),
    ABS_CODES["RX"]: ("RSTICK_LEFT", "RSTICK_RIGHT"),
    ABS_CODES["RY"]: ("RSTICK_UP", "RSTICK_DOWN"),
}


def normalize_button(token: str) -> str:
    """Fold a user-written button token into its canonical form."""
    token = token.strip().upper().replace("-", "_").replace(" ", "_")
    return BUTTON_ALIASES.get(token, token)


def button_for_key_code(code: int) -> str:
    """Name a EV_KEY code coming off a pad or keyboard-mode device."""
    return (
        CODE_TO_BUTTON.get(code)
        or _BTN_NAMES.get(code)
        or _KEY_NAMES.get(code)
        or f"CODE_{code}"
    )


def label_overrides(layout: str) -> dict[str, str]:
    """Tokens whose label differs from their name under `layout`."""
    return dict(NINTENDO_LABELS) if layout == "nintendo" else {}


def display_label(token: str, layout: str = "auto") -> str:
    """The label to show a human, honouring Nintendo-style face buttons."""
    if layout == "nintendo":
        return NINTENDO_LABELS.get(token, token)
    return token


def parse_combo(spec: str) -> tuple[str, ...]:
    """Parse "L + R + START" into a canonical, order-independent button tuple."""
    parts = [p for p in spec.replace(",", "+").split("+") if p.strip()]
    if not parts:
        raise ValueError("empty button combo")
    return tuple(sorted({normalize_button(p) for p in parts}))


def format_combo(combo: tuple[str, ...] | list[str], layout: str = "auto") -> str:
    return " + ".join(display_label(b, layout) for b in combo)
