"""Dedicated evdev Back must coexist with legacy Select/Back configurations."""

import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from engine._codes import BTN_CODES  # noqa: E402
from engine.buttons import button_for_key_code, parse_combo  # noqa: E402
from engine.combos import ComboEngine  # noqa: E402
from engine.config import Config, load  # noqa: E402


class TestDedicatedBackButton(unittest.TestCase):
    def test_evdev_back_and_select_are_distinct(self):
        self.assertEqual(button_for_key_code(BTN_CODES["BACK"]), "BACK_BUTTON")
        self.assertEqual(button_for_key_code(BTN_CODES["SELECT"]), "SELECT")

    def test_legacy_back_alias_still_means_select(self):
        self.assertEqual(parse_combo("BACK"), ("SELECT",))
        self.assertEqual(parse_combo("BACK_BUTTON"), ("BACK_BUTTON",))

    def test_chord_keeps_both_buttons(self):
        self.assertEqual(parse_combo("BACK_BUTTON+SELECT"), ("BACK_BUTTON", "SELECT"))

    def test_separate_bindings_activate_independently(self):
        bindings = [SimpleNamespace(combo=parse_combo(token), repeat=False, hold=False)
                    for token in ["BACK_BUTTON", "SELECT"]]
        engine = ComboEngine(bindings, dict(combo_window_ms=50, hold_ms=400,
                            repeat_delay_ms=300, repeat_interval_ms=100))
        back = button_for_key_code(BTN_CODES["BACK"])
        select = button_for_key_code(BTN_CODES["SELECT"])
        self.assertEqual([a.binding.combo for a in engine.press(back, 0)], [("BACK_BUTTON",)])
        engine.release(back, 0.1)
        self.assertEqual([a.binding.combo for a in engine.press(select, 0.2)], [("SELECT",)])

    def test_legacy_and_dedicated_bindings_survive_save_and_reload(self):
        config = Config({"bindings": [
            {"combo": "BACK", "exec": "true"},
            {"combo": "BACK_BUTTON", "exec": "true"},
        ]})
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            config.save(path)
            restored = load(path)
        self.assertEqual([b.combo for b in restored.bindings],
                         [("SELECT",), ("BACK_BUTTON",)])

    def test_device_aliases_keep_dedicated_and_legacy_names_distinct(self):
        config = Config({"device": {"aliases": {
            "back-button": "BACK", "A": "back_button",
        }}, "bindings": []})
        self.assertEqual(config.aliases,
                         {"BACK_BUTTON": "SELECT", "A": "BACK_BUTTON"})


if __name__ == "__main__":
    unittest.main()
