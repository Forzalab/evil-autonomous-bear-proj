import unittest

from barnaby.reactions import PerceptionEvent
from barnaby.trigger import ANY, OneShot

TARGET = "thumbs_up"


def ev(gesture, expression="neutral"):
    return PerceptionEvent(gesture, expression, 0.9, 0.9, 10.0)


def fires(trigger, events, step=0.2, start=0.0):
    """Feed (gesture[, expression]) events `step` seconds apart; return fire count."""
    count = 0
    for i, item in enumerate(events):
        gesture, *rest = (item,) if isinstance(item, str) else item
        count += trigger.feed(ev(gesture, *rest), start + i * step)
    return count


class OneShotTest(unittest.TestCase):
    def test_held_gesture_with_expression_changes_fires_once(self):
        events = [(TARGET, "neutral"), (TARGET, "happy"), (TARGET, "neutral")]
        self.assertEqual(fires(OneShot(TARGET), events), 1)

    def test_r11_trace_fires_once(self):
        trace = [TARGET, TARGET, "none", TARGET, TARGET, TARGET, TARGET, "none", TARGET]
        self.assertEqual(fires(OneShot(TARGET), trace), 1)

    def test_flicker_inside_cooldown_fires_once(self):
        trace = [TARGET, "none", TARGET, "none", TARGET, "none", TARGET]
        self.assertEqual(fires(OneShot(TARGET), trace, step=1.5), 1)

    def test_fires_again_after_release_and_cooldown(self):
        trigger = OneShot(TARGET, cooldown_s=20.0, rearm_s=1.0)
        self.assertEqual(fires(trigger, [TARGET, "none"], step=1.0), 1)
        self.assertEqual(fires(trigger, [TARGET], start=25.0), 1)

    def test_short_release_after_cooldown_does_not_rearm(self):
        trigger = OneShot(TARGET, cooldown_s=20.0, rearm_s=1.0)
        self.assertTrue(trigger.feed(ev(TARGET), 0.0))
        self.assertFalse(trigger.feed(ev("none"), 29.5))
        self.assertFalse(trigger.feed(ev(TARGET), 30.0))

    def test_release_long_enough_but_inside_cooldown_does_not_fire(self):
        trigger = OneShot(TARGET, cooldown_s=20.0, rearm_s=1.0)
        self.assertTrue(trigger.feed(ev(TARGET), 0.0))
        self.assertFalse(trigger.feed(ev("none"), 1.0))
        self.assertFalse(trigger.feed(ev(TARGET), 10.0))

    def test_other_gestures_never_fire(self):
        trigger = OneShot(TARGET)
        others = ["open_palm", "peace", "pointing", "middle_finger", "fist", "unknown", "none"]
        self.assertEqual(fires(trigger, others * 3), 0)

    def test_no_cooldown_or_rearm_fires_on_every_new_show(self):
        trigger = OneShot(TARGET, cooldown_s=0, rearm_s=0)
        self.assertEqual(fires(trigger, [TARGET, "none", TARGET, "none", TARGET]), 3)

    def test_no_cooldown_or_rearm_still_once_per_hold(self):
        trigger = OneShot(TARGET, cooldown_s=0, rearm_s=0)
        self.assertEqual(fires(trigger, [(TARGET, "neutral"), (TARGET, "happy")]), 1)



class AnyHandTest(unittest.TestCase):
    def any_hand(self, cooldown_s=20.0):
        return OneShot(ANY, cooldown_s, rearm_s=0.0, repeat_while_held=True)

    def test_every_hand_label_fires(self):
        for label in ("unknown", "open_palm", "middle_finger", "fist", "thumbs_up"):
            with self.subTest(label=label):
                self.assertTrue(self.any_hand().feed(ev(label), 0.0))

    def test_no_hand_never_fires(self):
        self.assertEqual(fires(self.any_hand(), ["none"] * 50, step=5.0), 0)

    def test_label_changes_while_held_fire_once_per_cooldown(self):
        trace = ["unknown", "open_palm", "middle_finger", "unknown", "fist"] * 10  # 10 s at 0.2 s
        self.assertEqual(fires(self.any_hand(), trace), 1)

    def test_held_hand_refires_every_cooldown(self):
        # Hand held for 65 s, fed every 0.5 s: fires at 0, 20, 40, 60.
        self.assertEqual(fires(self.any_hand(), ["unknown"] * 131, step=0.5), 4)

    def test_hand_back_after_cooldown_fires_without_rearm_wait(self):
        trigger = self.any_hand()
        self.assertTrue(trigger.feed(ev("open_palm"), 0.0))
        self.assertFalse(trigger.feed(ev("none"), 19.9))
        self.assertTrue(trigger.feed(ev("unknown"), 20.0))

    def test_hand_back_inside_cooldown_waits_then_fires_while_held(self):
        trigger = self.any_hand()
        self.assertTrue(trigger.feed(ev("fist"), 0.0))
        self.assertFalse(trigger.feed(ev("none"), 2.0))
        self.assertFalse(trigger.feed(ev("fist"), 5.0))
        self.assertTrue(trigger.feed(ev("fist"), 20.0))

    def test_named_gesture_keeps_release_behaviour(self):
        # Without repeat_while_held a held named gesture never re-fires, even fed every frame.
        self.assertEqual(fires(OneShot(TARGET), [TARGET] * 300, step=0.5), 1)


if __name__ == "__main__":
    unittest.main()
