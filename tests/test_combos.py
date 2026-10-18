"""Unit tests for the chord recogniser. No hardware required."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from engine.combos import ComboEngine  # noqa: E402


class FakeBinding:
    def __init__(self, combo, repeat=False, hold=False):
        self.combo = tuple(sorted(combo.split("+")))
        self.repeat = repeat
        self.hold = hold
        self.description = combo

    def __repr__(self):
        return f"<{'+'.join(self.combo)}>"


SETTINGS = {
    "combo_window_ms": 50,
    "hold_ms": 400,
    "repeat_delay_ms": 300,
    "repeat_interval_ms": 100,
}


def engine(*combos, **kw):
    bindings = []
    for combo in combos:
        if isinstance(combo, tuple):
            bindings.append(FakeBinding(combo[0], **combo[1]))
        else:
            bindings.append(FakeBinding(combo))
    return ComboEngine(bindings, {**SETTINGS, **kw})


def names(activations):
    return ["+".join(a.binding.combo) for a in activations]


class TestImmediateFiring(unittest.TestCase):
    def test_unambiguous_single_button_fires_instantly(self):
        e = engine("A", "B")
        self.assertEqual(names(e.press("A", 0.0)), ["A"])

    def test_release_never_fires(self):
        e = engine("A")
        e.press("A", 0.0)
        self.assertEqual(e.release("A", 0.1), [])

    def test_unbound_button_fires_nothing(self):
        e = engine("A")
        self.assertEqual(e.press("Z", 0.0), [])


class TestAmbiguity(unittest.TestCase):
    def test_single_defers_when_superset_exists(self):
        e = engine("A", "A+B")
        # "A" alone must wait, because A+B could still arrive.
        self.assertEqual(names(e.press("A", 0.0)), [])
        self.assertEqual(names(e.tick(0.02)), [])
        self.assertEqual(names(e.tick(0.06)), ["A"])

    def test_chord_wins_over_its_own_prefix(self):
        e = engine("A", "A+B")
        e.press("A", 0.0)
        fired = e.press("B", 0.01)
        # Both buttons are down and nothing longer exists, so it fires at once.
        self.assertEqual(names(fired), ["A+B"])
        # The deferred single-button decision must have been dropped.
        self.assertEqual(names(e.tick(1.0)), [])

    def test_longest_chord_wins(self):
        e = engine("L+R", "L+R+START")
        e.press("L", 0.0)
        e.press("R", 0.01)
        fired = e.press("START", 0.02)
        self.assertEqual(names(fired), ["L+R+START"])

    def test_chord_does_not_fire_its_components(self):
        e = engine("L", "R", "L+R")
        e.press("L", 0.0)
        fired = e.press("R", 0.01)
        self.assertEqual(names(fired), ["L+R"])
        self.assertEqual(names(e.tick(1.0)), [])
        # Releasing the chord must not fire "L" or "R".
        self.assertEqual(e.release("R", 1.1), [])
        self.assertEqual(e.release("L", 1.2), [])

    def test_partial_chord_that_never_completes_falls_back(self):
        e = engine("L", "L+R")
        e.press("L", 0.0)
        self.assertEqual(names(e.tick(0.06)), ["L"])

    def test_quick_tap_of_a_chord_prefix_fires_on_release(self):
        # Let go inside the chord window: still a tap of L, not a lost press.
        e = engine("L", "L+R")
        self.assertEqual(names(e.press("L", 0.0)), [])
        self.assertEqual(names(e.release("L", 0.01)), ["L"])
        self.assertEqual(names(e.tick(0.5)), [])

    def test_quick_tap_does_not_fire_a_hold_binding(self):
        e = engine(("SELECT+START", {"hold": True}), "SELECT+START+A")
        e.press("SELECT", 0.0)
        e.press("START", 0.01)
        self.assertEqual(e.release("START", 0.02), [])
        self.assertEqual(names(e.tick(1.0)), [])

    def test_another_binding_starting_settles_the_waiting_one(self):
        e = engine("L", "L+R", "A")
        e.press("L", 0.0)
        self.assertEqual(names(e.press("A", 0.01)), ["L", "A"])

    def test_unbound_press_keeps_the_waiting_binding(self):
        e = engine("L", "L+R")
        e.press("L", 0.0)
        self.assertEqual(e.press("Z", 0.01), [])
        self.assertEqual(names(e.tick(0.06)), ["L"])


class TestIndependentButtons(unittest.TestCase):
    def test_held_button_does_not_swallow_another(self):
        e = engine("A", "L")
        self.assertEqual(names(e.press("A", 0.0)), ["A"])
        self.assertEqual(names(e.press("L", 0.3)), ["L"])

    def test_repeat_binding_fires_while_another_button_is_held(self):
        e = engine("DPAD_LEFT", ("DPAD_UP", {"repeat": True}))
        e.press("DPAD_LEFT", 0.0)
        self.assertEqual(names(e.press("DPAD_UP", 0.1)), ["DPAD_UP"])
        self.assertEqual(names(e.tick(0.4)), ["DPAD_UP"])

    def test_releasing_another_button_keeps_a_repeat_going(self):
        e = engine("A", ("DPAD_UP", {"repeat": True}))
        e.press("DPAD_UP", 0.0)
        e.press("A", 0.1)
        e.release("A", 0.15)
        self.assertEqual(names(e.tick(0.3)), ["DPAD_UP"])

    def test_drop_forgets_a_button_without_firing(self):
        e = engine("L", "L+R")
        e.press("L", 0.0)
        e.drop("L")
        self.assertEqual(e.held, set())
        self.assertEqual(names(e.tick(0.5)), [])


class TestLatching(unittest.TestCase):
    def test_held_chord_does_not_retrigger(self):
        e = engine("A")
        self.assertEqual(names(e.press("A", 0.0)), ["A"])
        for t in (0.1, 0.5, 2.0):
            self.assertEqual(names(e.tick(t)), [])

    def test_retrigger_after_release(self):
        e = engine("A")
        e.press("A", 0.0)
        e.release("A", 0.1)
        self.assertEqual(names(e.press("A", 0.2)), ["A"])

    def test_modifier_style_chord_retriggers_on_inner_button(self):
        # L is unbound on its own and acts as a shift key for L+A.
        e = engine("L+A")
        e.press("L", 0.0)
        self.assertEqual(names(e.press("A", 0.01)), ["A+L"])
        e.release("A", 0.1)  # L stays held
        self.assertEqual(names(e.press("A", 0.2)), ["A+L"])


class TestRepeat(unittest.TestCase):
    def test_repeat_fires_after_delay_then_at_interval(self):
        e = engine(("DPAD_UP", {"repeat": True}))
        self.assertEqual(names(e.press("DPAD_UP", 0.0)), ["DPAD_UP"])
        self.assertEqual(names(e.tick(0.2)), [])
        self.assertEqual(names(e.tick(0.3)), ["DPAD_UP"])
        self.assertEqual(names(e.tick(0.35)), [])
        self.assertEqual(names(e.tick(0.4)), ["DPAD_UP"])

    def test_repeat_stops_on_release(self):
        e = engine(("DPAD_UP", {"repeat": True}))
        e.press("DPAD_UP", 0.0)
        e.release("DPAD_UP", 0.1)
        self.assertEqual(names(e.tick(5.0)), [])


class TestHold(unittest.TestCase):
    def test_hold_fires_only_after_the_hold_time(self):
        e = engine(("SELECT+START", {"hold": True}))
        e.press("SELECT", 0.0)
        self.assertEqual(names(e.press("START", 0.01)), [])
        self.assertEqual(names(e.tick(0.2)), [])
        self.assertEqual(names(e.tick(0.45)), ["SELECT+START"])

    def test_hold_cancelled_by_early_release(self):
        e = engine(("SELECT+START", {"hold": True}))
        e.press("SELECT", 0.0)
        e.press("START", 0.01)
        e.release("START", 0.2)
        self.assertEqual(names(e.tick(1.0)), [])


class TestScheduling(unittest.TestCase):
    def test_next_deadline_is_none_when_idle(self):
        e = engine("A", "B")
        self.assertIsNone(e.next_deadline())

    def test_next_deadline_reports_pending_window(self):
        e = engine("A", "A+B")
        e.press("A", 1.0)
        self.assertAlmostEqual(e.next_deadline(), 1.05, places=6)

    def test_reset_clears_everything(self):
        e = engine(("A", {"repeat": True}))
        e.press("A", 0.0)
        e.reset()
        self.assertEqual(e.held, set())
        self.assertIsNone(e.next_deadline())
        self.assertEqual(names(e.tick(10.0)), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
