import inspect
import io
import json
import os
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest import mock

from barnaby.reactions import PerceptionEvent, on_perception
from bear_decider import bridge as bridge_mod
from bear_decider.bridge import DanceBridge


def ev(gesture, expression="neutral"):
    return PerceptionEvent(gesture, expression, 0.9, 0.9, 10.0)


class FakeProc:
    def __init__(self, running=False):
        self.running = running

    def poll(self):
        return None if self.running else 0


class FakeSpawn:
    """Records argv lists; returns FakeProc objects (finished unless `running`)."""

    def __init__(self, running=False, error=None):
        self.calls = []
        self.running = running
        self.error = error

    def __call__(self, argv):
        if self.error is not None:
            raise self.error
        self.calls.append(list(argv))
        return FakeProc(self.running)


class Clock:
    def __init__(self):
        self.t = 0.0

    def __call__(self):
        return self.t


class DanceBridgeTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.NamedTemporaryFile(delete=False)
        tmp.close()
        self.binary = tmp.name
        self.addCleanup(os.unlink, self.binary)
        self.clock = Clock()
        self.spawn = FakeSpawn()

    def make(self, **kw):
        kw.setdefault("binary", self.binary)
        kw.setdefault("spawn", self.spawn)
        kw.setdefault("clock", self.clock)
        return DanceBridge(**kw)

    def at(self, b, t, gesture):
        self.clock.t = t
        with redirect_stdout(io.StringIO()):
            return b.handle(ev(gesture))

    def test_first_hand_fires_once(self):
        b = self.make()
        self.assertTrue(self.at(b, 0.0, "open_palm"))
        self.assertFalse(self.at(b, 0.5, "open_palm"))
        self.assertEqual(self.spawn.calls, [[self.binary]])

    def test_none_never_fires(self):
        b = self.make()
        for i in range(10):
            self.assertFalse(self.at(b, i * 5.0, "none"))
        self.assertEqual(self.spawn.calls, [])

    def test_flicker_inside_cooldown_no_second_fire(self):
        b = self.make()
        self.assertTrue(self.at(b, 0.0, "open_palm"))
        self.assertFalse(self.at(b, 1.0, "fist"))
        self.assertFalse(self.at(b, 2.0, "open_palm"))
        self.assertFalse(self.at(b, 3.0, "none"))
        self.assertFalse(self.at(b, 10.0, "open_palm"))
        self.assertEqual(len(self.spawn.calls), 1)

    def test_fires_again_after_cooldown_and_absence(self):
        b = self.make()
        self.assertTrue(self.at(b, 0.0, "open_palm"))
        self.assertFalse(self.at(b, 1.0, "none"))
        self.assertTrue(self.at(b, 30.0, "fist"))
        self.assertEqual(len(self.spawn.calls), 2)

    def test_specific_gesture_ignores_others(self):
        b = self.make(gesture="thumbs_up")
        for i, g in enumerate(["open_palm", "fist", "peace", "none", "pointing"]):
            self.assertFalse(self.at(b, i * 30.0, g))
        self.assertEqual(self.spawn.calls, [])
        self.assertTrue(self.at(b, 200.0, "thumbs_up"))
        self.assertEqual(len(self.spawn.calls), 1)

    def test_previous_child_still_running_skips(self):
        self.spawn = FakeSpawn(running=True)
        b = self.make()
        self.assertTrue(self.at(b, 0.0, "open_palm"))
        self.assertFalse(self.at(b, 1.0, "none"))
        self.assertFalse(self.at(b, 30.0, "open_palm"))
        self.assertEqual(len(self.spawn.calls), 1)

    def test_finished_child_does_not_block(self):
        b = self.make()  # FakeProc.poll() returns 0 -> finished
        self.assertTrue(self.at(b, 0.0, "open_palm"))
        self.assertFalse(self.at(b, 1.0, "none"))
        self.assertTrue(self.at(b, 30.0, "open_palm"))

    def test_missing_binary_dry_run(self):
        missing = os.path.join(tempfile.gettempdir(), "no-such-dir-xyz", "dance")
        b = self.make(binary=missing)
        out = io.StringIO()
        with redirect_stdout(out):
            result = b.handle(ev("open_palm"))
        self.assertFalse(result)
        self.assertIn("DANCE (dry-run", out.getvalue())
        self.assertEqual(self.spawn.calls, [])

    def test_spawn_oserror_dry_run(self):
        b = self.make(spawn=FakeSpawn(error=OSError("exec format error")))
        out = io.StringIO()
        with redirect_stdout(out):
            result = b.handle(ev("open_palm"))
        self.assertFalse(result)
        self.assertIn("DANCE (dry-run", out.getvalue())

    def test_binary_from_env(self):
        with mock.patch.dict(os.environ, {"BEAR_DANCE_BIN": self.binary}):
            b = DanceBridge(spawn=self.spawn, clock=self.clock)
        self.assertTrue(self.at(b, 0.0, "open_palm"))
        self.assertEqual(self.spawn.calls, [[self.binary]])

    def test_default_cooldown_is_25_and_longer_than_try_me_lock(self):
        default = inspect.signature(DanceBridge).parameters["cooldown_s"].default
        self.assertEqual(default, 25.0)
        self.assertGreater(default, 22.0)
        b = self.make()
        self.assertTrue(self.at(b, 0.0, "open_palm"))
        self.assertFalse(self.at(b, 1.0, "none"))
        self.assertFalse(self.at(b, 23.0, "open_palm"))  # inside 25 s
        self.assertFalse(self.at(b, 24.0, "none"))
        self.assertTrue(self.at(b, 26.0, "open_palm"))

    def test_uses_barnaby_oneshot(self):
        with mock.patch("bear_decider.bridge.OneShot", wraps=bridge_mod.OneShot) as one_shot:
            self.make()
        one_shot.assert_called_once()


class HookTest(unittest.TestCase):
    def test_on_perception_calls_bridge_once_and_json_unchanged(self):
        event = PerceptionEvent("fist", "happy", 0.9, 0.8, 12.0, 0.7)
        out = io.StringIO()
        with mock.patch("bear_decider.bridge.handle") as handle, redirect_stdout(out):
            on_perception(event)
        handle.assert_called_once_with(event)
        payload = json.loads(out.getvalue().splitlines()[0])
        self.assertEqual(payload["gesture"], "fist")
        self.assertEqual(payload["expression"], "happy")
        self.assertEqual(payload["hand_confidence"], 0.9)
        self.assertEqual(payload["face_confidence"], 0.8)
        self.assertEqual(payload["inference_ms"], 12.0)
        self.assertEqual(payload["expression_confidence"], 0.7)


if __name__ == "__main__":
    unittest.main()
