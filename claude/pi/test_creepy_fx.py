"""Tests for creepy_fx (audio files only; nothing is played through the speaker).

Run from claude/pi:  $PY -m unittest test_creepy_fx
"""
import os
import random
import re
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.dont_write_bytecode = True

import creepy_fx  # noqa: E402

MIN_RMS = 0.01


def soxi_duration(path):
    return float(subprocess.run(["soxi", "-D", path], capture_output=True, text=True, check=True).stdout)


def rms_amplitude(path):
    err = subprocess.run(["sox", path, "-n", "stat"], capture_output=True, text=True).stderr
    return float(re.search(r"RMS\s+amplitude:\s+([\d.]+)", err).group(1))


class RenderAllTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rendered = creepy_fx.render_all()

    def test_at_least_twelve_effects(self):
        self.assertGreaterEqual(len(creepy_fx.NAMES), 12)
        self.assertEqual(len(set(creepy_fx.NAMES)), len(creepy_fx.NAMES))

    def test_every_effect_renders(self):
        self.assertEqual(sorted(self.rendered), sorted(creepy_fx.NAMES))
        for name, path in self.rendered.items():
            with self.subTest(name=name):
                self.assertTrue(os.path.isfile(path))

    def test_durations_in_range(self):
        for name in creepy_fx.NAMES:
            with self.subTest(name=name):
                d = soxi_duration(creepy_fx.path(name))
                self.assertTrue(0.8 <= d <= 6.0, "%s is %.2fs" % (name, d))
                self.assertAlmostEqual(creepy_fx.duration(name), d, places=2)

    def test_not_silent(self):
        for name in creepy_fx.NAMES:
            with self.subTest(name=name):
                self.assertGreater(rms_amplitude(creepy_fx.path(name)), MIN_RMS)

    def test_scary_pack(self):
        scary = creepy_fx.SCARY_NAMES
        self.assertGreaterEqual(len(scary), 8)
        self.assertTrue(set(scary) <= set(creepy_fx.NAMES))
        self.assertIn("baby_cry", scary)
        for name in scary:
            with self.subTest(name=name):
                self.assertTrue(2.0 <= creepy_fx.duration(name) <= 6.0, "%s is %.2fs" % (name, creepy_fx.duration(name)))

    def test_loudness_evened_out(self):
        levels = {n: rms_amplitude(creepy_fx.path(n)) for n in creepy_fx.NAMES}
        for name, level in levels.items():
            with self.subTest(name=name):
                self.assertTrue(0.08 <= level <= 0.5, "%s RMS %.3f" % (name, level))
        self.assertLess(max(levels.values()) / min(levels.values()), 5.0)

    def test_quiet_effects_get_compressed(self):
        """A sparse effect below QUIET_RMS goes through the compand step and comes out louder."""
        sparse = ("sparse", lambda: [creepy_fx.sox(*creepy_fx.N, "out.wav", "synth", 0.05, "sine", 900,
                                                   "fade", "q", 0, 0.05, 0.045, "pad", 0, 1.5, "reverb", 50)])
        with tempfile.TemporaryDirectory() as tmp, \
                mock.patch.object(creepy_fx, "CACHE_DIR", tmp), \
                mock.patch.dict(creepy_fx.EFFECTS, {"sparse": sparse}):
            with mock.patch.object(creepy_fx, "QUIET_RMS", 0.0):
                creepy_fx.render("sparse", force=True)
            plain = rms_amplitude(creepy_fx.path("sparse"))
            creepy_fx.render("sparse", force=True)
            levelled = rms_amplitude(creepy_fx.path("sparse"))
        self.assertGreater(levelled, plain * 1.2)

    def test_mono_22050(self):
        for name in creepy_fx.NAMES:
            with self.subTest(name=name):
                out = subprocess.run(["soxi", creepy_fx.path(name)], capture_output=True, text=True).stdout
                self.assertRegex(out, r"Channels\s+:\s+1")
                self.assertRegex(out, r"Sample Rate\s+:\s+22050")


class CacheTest(unittest.TestCase):
    """Uses a private cache dir and a cheap synth-only effect so the real cache is untouched."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        patches = [mock.patch.object(creepy_fx, "CACHE_DIR", self.tmp.name),
                   mock.patch.dict(creepy_fx.EFFECTS, {"deep_drone": creepy_fx.EFFECTS["deep_drone"]}, clear=True),
                   mock.patch.object(creepy_fx, "NAMES", ["deep_drone"])]
        for p in patches:
            p.start()
            self.addCleanup(p.stop)
        self.addCleanup(self.tmp.cleanup)

    def _stamp(self):
        st = os.stat(creepy_fx.path("deep_drone"))
        return st.st_mtime_ns, st.st_ino

    def test_second_render_reuses_cache(self):
        self.assertIn("deep_drone", creepy_fx.render_all())
        first = self._stamp()
        self.assertIn("deep_drone", creepy_fx.render_all())
        self.assertEqual(self._stamp(), first)

    def test_recipe_change_rerenders(self):
        creepy_fx.render_all()
        first = self._stamp()
        changed = ("changed", lambda: [creepy_fx.sox(*creepy_fx.N, "out.wav", "synth", 1.5, "sine", 300)])
        creepy_fx.EFFECTS["deep_drone"] = changed
        self.assertFalse(creepy_fx.is_fresh("deep_drone"))
        creepy_fx.render_all()
        self.assertNotEqual(self._stamp(), first)
        self.assertAlmostEqual(creepy_fx.duration("deep_drone"), 1.5, places=2)
        self.assertTrue(creepy_fx.is_fresh("deep_drone"))

    def test_broken_effect_is_skipped_not_raised(self):
        creepy_fx.EFFECTS["broken"] = ("broken", lambda: [creepy_fx.sox("-n", "out.wav", "no_such_effect")])
        creepy_fx.NAMES.append("broken")
        with self.assertLogs("creepy_fx", level="ERROR"):
            done = creepy_fx.render_all()
        self.assertEqual(list(done), ["deep_drone"])
        self.assertIsNone(creepy_fx.duration("broken"))


class PlayTest(unittest.TestCase):
    def test_unknown_name_returns_false(self):
        with self.assertLogs("creepy_fx", level="ERROR"):
            self.assertFalse(creepy_fx.play("no_such_effect"))

    def test_play_failure_returns_false(self):
        with mock.patch.object(creepy_fx.subprocess, "run", side_effect=OSError("no pw-play")), \
                mock.patch.object(creepy_fx, "render", return_value="/x.wav"), \
                self.assertLogs("creepy_fx", level="ERROR"):
            self.assertFalse(creepy_fx.play("heartbeat"))

    def test_play_random_respects_exclude(self):
        with mock.patch.object(creepy_fx, "play", return_value=True) as play:
            keep = creepy_fx.NAMES[0]
            for _ in range(20):
                self.assertEqual(creepy_fx.play_random(random.Random(1), exclude=creepy_fx.NAMES[1:]), keep)
            self.assertIsNone(creepy_fx.play_random(exclude=creepy_fx.NAMES))
            self.assertEqual(play.call_count, 20)


if __name__ == "__main__":
    unittest.main()
