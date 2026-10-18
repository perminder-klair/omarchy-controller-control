"""Device classification and event decoding. No hardware required."""

import os
import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from engine import linux_input as li  # noqa: E402
from engine._codes import ABS_CODES, BTN_CODES  # noqa: E402
from engine.buttons import button_for_key_code, parse_combo  # noqa: E402
from engine.devices import DeviceInfo, Gamepad  # noqa: E402
from engine.keys import VirtualKeyboard  # noqa: E402

PAD_BUTTONS = [
    BTN_CODES[name]
    for name in ("SOUTH", "EAST", "NORTH", "WEST", "TL", "TR", "SELECT", "START")
]
HAT = [ABS_CODES["HAT0X"], ABS_CODES["HAT0Y"]]
EVERY_KEY = range(1, li.KEY_CNT)
SETTINGS = {"trigger_threshold": 0.45, "stick_threshold": 0.65}


def device(key_codes=PAD_BUTTONS, abs_codes=HAT, abs_info=None, vendor=0, product=0):
    """A DeviceInfo as inspecting a node would build it, without the node."""
    info = DeviceInfo.__new__(DeviceInfo)
    info.path = "/dev/input/event99"
    info.name = "test device"
    info.phys = info.uniq = ""
    info.bustype = li.BUS_USB
    info.vendor = vendor
    info.product = product
    info.key_codes = sorted(key_codes)
    info.abs_codes = sorted(abs_codes)
    info.abs_info = abs_info or {a: {"value": 0, "min": -1, "max": 1} for a in abs_codes}
    return info


class TestClassification(unittest.TestCase):
    def test_plain_pad_is_a_gamepad(self):
        self.assertTrue(device().is_gamepad)

    def test_virtual_keyboard_claiming_every_key_is_not_a_gamepad(self):
        info = device(key_codes=EVERY_KEY, abs_codes=[])
        self.assertFalse(info.is_gamepad)
        self.assertTrue(info.is_keyboard)

    def test_pad_with_axes_stays_a_gamepad_whatever_keys_it_claims(self):
        self.assertTrue(device(key_codes=EVERY_KEY).is_gamepad)

    def test_own_virtual_keyboard_is_recognised(self):
        info = device(vendor=VirtualKeyboard.VENDOR, product=VirtualKeyboard.PRODUCT)
        self.assertTrue(info.is_own_keyboard)
        self.assertFalse(device().is_own_keyboard)

    def test_dedicated_back_is_listed_among_the_buttons(self):
        info = device(key_codes=PAD_BUTTONS + [BTN_CODES["BACK"]])
        self.assertIn("BACK_BUTTON", info.button_tokens)

    def test_mouse_back_button_does_not_make_a_gamepad(self):
        mouse = [BTN_CODES[n] for n in ("LEFT", "RIGHT", "MIDDLE", "SIDE", "EXTRA", "BACK")]
        info = device(key_codes=mouse, abs_codes=[])
        self.assertFalse(info.is_gamepad)
        self.assertEqual(info.button_tokens, [])


class TestNames(unittest.TestCase):
    def test_first_buttons_of_a_range_use_their_own_names(self):
        self.assertEqual(button_for_key_code(BTN_CODES["TRIGGER"]), "TRIGGER")
        self.assertEqual(button_for_key_code(BTN_CODES["TRIGGER_HAPPY1"]), "TRIGGER_HAPPY1")

    def test_names_older_builds_saved_still_resolve(self):
        self.assertEqual(parse_combo("JOYSTICK + TRIGGER_HAPPY"), ("TRIGGER", "TRIGGER_HAPPY1"))


class TestDecoding(unittest.TestCase):
    """A Gamepad reading from a pipe, so events can be written by hand."""

    def open(self, info):
        read_end, self.write_end = os.pipe()
        os.set_blocking(read_end, False)
        self.addCleanup(os.close, self.write_end)
        with mock.patch.object(li, "open_event_device", return_value=read_end):
            pad = Gamepad(info, SETTINGS)
        self.addCleanup(pad.close)
        return pad

    def feed(self, *events):
        packed = b""
        for ev_type, code, value in events:
            packed += li.pack_event(ev_type, code, value)
            if ev_type != li.EV_SYN:
                packed += li.pack_event(li.EV_SYN, li.SYN_REPORT, 0)
        os.write(self.write_end, packed)

    def test_analog_and_digital_trigger_hold_one_token(self):
        z = ABS_CODES["Z"]
        pad = self.open(device(
            key_codes=PAD_BUTTONS + [BTN_CODES["TL2"]],
            abs_codes=[z],
            abs_info={z: {"value": 0, "min": 0, "max": 255}},
        ))
        self.feed((li.EV_KEY, BTN_CODES["TL2"], 1), (li.EV_ABS, z, 255))
        self.assertEqual(pad.read(), [("L2", True)])
        # Easing the trigger off while the button is still down changes nothing.
        self.feed((li.EV_ABS, z, 0))
        self.assertEqual(pad.read(), [])
        self.feed((li.EV_KEY, BTN_CODES["TL2"], 0))
        self.assertEqual(pad.read(), [("L2", False)])

    def test_release_lost_to_dropped_events_is_recovered(self):
        pad = self.open(device())
        self.feed((li.EV_KEY, BTN_CODES["SOUTH"], 1))
        self.assertEqual(pad.read(), [("A", True)])
        # The release went in the overflow; what survives up to the next
        # report is a fragment and must be ignored.
        self.feed(
            (li.EV_SYN, li.SYN_DROPPED, 0),
            (li.EV_KEY, BTN_CODES["EAST"], 1),
            (li.EV_SYN, li.SYN_REPORT, 0),
        )
        nothing_held = bytes((li.KEY_CNT + 7) // 8)
        with mock.patch.object(li, "read_key_state", return_value=nothing_held), \
                mock.patch.object(li, "read_abs_info", return_value={"value": 0}):
            self.assertEqual(pad.read(), [("A", False)])

    def test_new_settings_apply_without_reopening(self):
        x = ABS_CODES["X"]
        pad = self.open(device(abs_codes=[x], abs_info={x: {"value": 0, "min": -100, "max": 100}}))
        pad.apply({**SETTINGS, "stick_threshold": 0.9}, {})
        self.feed((li.EV_ABS, x, 70))
        self.assertEqual(pad.read(), [])
        self.feed((li.EV_ABS, x, 95))
        self.assertEqual(pad.read(), [("LSTICK_RIGHT", True)])


if __name__ == "__main__":
    unittest.main(verbosity=2)
