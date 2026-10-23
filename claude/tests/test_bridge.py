import importlib
import inspect
import io
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from types import SimpleNamespace
from unittest import mock

from claude import bridge as bridge_mod
from claude.bridge import DanceBridge
from claude.trigger import ANY, OneShot

SRC = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "src")


def ev(gesture, expression="neutral"):
    """Duck-typed event: the bridge only reads .gesture."""
    return SimpleNamespace(gesture=gesture, expression=expression)


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

    def test_uses_claude_oneshot(self):
        with mock.patch("claude.bridge.OneShot", wraps=bridge_mod.OneShot) as one_shot:
            self.make()
        one_shot.assert_called_once()


class OneShotTest(unittest.TestCase):
    def test_any_ignores_none(self):
        t = OneShot(ANY, cooldown_s=5.0)
        self.assertFalse(t.feed(ev("none"), 0.0))
        self.assertTrue(t.feed(ev("fist"), 1.0))

    def test_repeat_while_held(self):
        t = OneShot(ANY, cooldown_s=5.0, repeat_while_held=True)
        self.assertTrue(t.feed(ev("fist"), 0.0))
        self.assertFalse(t.feed(ev("fist"), 4.0))
        self.assertTrue(t.feed(ev("fist"), 5.0))

    def test_no_barnaby_import(self):
        with open(os.path.join(os.path.dirname(bridge_mod.__file__), "trigger.py")) as f:
            self.assertNotIn("barnaby", f.read().replace("barnaby's", ""))


def _import_barnaby_app():
    if SRC not in sys.path:
        sys.path.insert(0, SRC)
    try:
        import barnaby.app  # noqa: F401  (McKay's app pulls in cv2/numpy)
        from barnaby.reactions import PerceptionEvent  # noqa: F401
    except ImportError as e:
        return f"barnaby.app not importable ({e}); install McKay's requirements (opencv-python, numpy)"
    return None


SKIP_WIRING = _import_barnaby_app()


@unittest.skipIf(SKIP_WIRING, SKIP_WIRING or "")
class WiringTest(unittest.TestCase):
    """Importing claude.__main__ reroutes McKay's app at runtime (his files stay untouched)."""

    def setUp(self):
        import barnaby.app
        self.app = barnaby.app
        saved = (barnaby.app.on_perception, barnaby.app.on_scene_description, barnaby.app.describe_scene,
                 sys.dont_write_bytecode)

        def restore():
            (barnaby.app.on_perception, barnaby.app.on_scene_description, barnaby.app.describe_scene,
             sys.dont_write_bytecode) = saved
            sys.modules.pop("claude.__main__", None)

        self.addCleanup(restore)
        self.original = saved[0]
        env = mock.patch.dict(os.environ, {"BEAR_DANCE_BIN": os.path.join(tempfile.gettempdir(), "no-such-dance")})
        env.start()
        self.addCleanup(env.stop)
        sys.modules.pop("claude.__main__", None)
        self.launcher = importlib.import_module("claude.__main__")

    def test_on_perception_replaced_by_wrapper(self):
        from barnaby.reactions import on_perception, on_scene_description
        self.assertIs(self.original, on_perception)
        self.assertIs(self.app.on_perception, self.launcher.on_perception)
        self.assertIs(self.app.on_scene_description, self.launcher.on_scene_description)
        self.assertIsNot(self.app.on_scene_description, on_scene_description)

    def test_wrapper_calls_original_then_queues_dance(self):
        from barnaby.reactions import PerceptionEvent
        event = PerceptionEvent("fist", "happy", 0.9, 0.8, 12.0)
        order = mock.Mock()
        with mock.patch.object(self.launcher, "_original", order.original), \
                mock.patch.object(self.launcher.activities, "submit", order.submit):
            self.app.on_perception(event)
        self.assertEqual(order.mock_calls[0], mock.call.original(event))
        kind, pretext, duration = order.mock_calls[1].args
        self.assertEqual((kind, duration), ("dance", self.launcher.DANCE_S))
        self.assertIn(pretext, self.launcher.PRETEXT)

    def test_no_hand_queues_nothing(self):
        with mock.patch.object(self.launcher, "_original"), \
                mock.patch.object(self.launcher.activities, "submit") as submit:
            self.app.on_perception(ev("none"))
        submit.assert_not_called()

    def test_dance_item_runs_relay_then_yells_and_json_still_prints(self):
        from barnaby.reactions import PerceptionEvent
        from claude.activity import Item
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(self.launcher.activities, "submit"), redirect_stdout(out):
            self.app.on_perception(PerceptionEvent("open_palm", "neutral", 0.9, 0.9, 10.0))
        self.assertIn('"gesture": "open_palm"', out.getvalue())
        with mock.patch.object(self.launcher.speech, "speak") as speak, redirect_stderr(err):
            self.launcher.run(Item(1, 0, "dance", "I see you, tiny human.", 25.0))
        self.assertIn("DANCE (dry-run", err.getvalue())
        speak.assert_called_once_with("I see you, tiny human.")

    def test_gemini_line_printed_and_queued_first_class(self):
        out = io.StringIO()
        with mock.patch.object(self.launcher.activities, "submit") as submit, redirect_stdout(out):
            self.app.on_scene_description("a human in a hat")
        self.assertIn("[Barnaby sees] a human in a hat", out.getvalue())
        submit.assert_called_once_with("gemini", "a human in a hat", bucket=False)

    def test_queue_errors_never_escape(self):
        with mock.patch.object(self.launcher, "_original"), \
                mock.patch.object(self.launcher.activities, "submit", side_effect=RuntimeError("boom")), \
                redirect_stderr(io.StringIO()) as err:
            self.app.on_perception(ev("fist"))
        self.assertIn("[queue error] RuntimeError: boom", err.getvalue())

    def test_describe_scene_capped(self):
        real = mock.Mock(return_value="a human")
        with mock.patch.object(self.launcher, "_describe_scene", real), \
                mock.patch.object(self.launcher, "GEMINI_MAX", 2), redirect_stderr(io.StringIO()):
            got = [self.app.describe_scene("frame") for _ in range(4)]
        self.assertEqual(got, ["a human", "a human", "Quack quack!", "Quack quack!"])
        self.assertEqual(real.call_count, 2)

    def test_default_dance_bin_is_claude_pi_dance_sda(self):
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("BEAR_DANCE_BIN")
            sys.modules.pop("claude.__main__", None)
            importlib.import_module("claude.__main__")
            want = os.path.join(os.path.dirname(bridge_mod.__file__), "pi", "dance_sda.sh")
            self.assertEqual(os.path.realpath(os.environ["BEAR_DANCE_BIN"]), os.path.realpath(want))

    def test_gemini_args(self):
        with mock.patch.object(sys.stdin, "isatty", return_value=False):
            self.assertEqual(self.launcher.gemini_args(["--source", "0"]), (["--source", "0"], []))
            self.assertEqual(self.launcher.gemini_args(["--gemini", "--headless"]),
                             (["--headless"], ["--scene", "--scene-model", self.launcher.GEMINI_MODEL]))
            self.assertEqual(self.launcher.gemini_args(["--gemini", "--scene"]), (["--scene"], []))


if __name__ == "__main__":
    unittest.main()
