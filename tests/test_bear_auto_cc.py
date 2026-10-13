import os
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

from test_dance_cc import STUB_HEADER

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(ROOT, "pi", "bear_auto.cc")
PINS = (17, 13, 16, 26, 21)


def wpi_calls(stdout):
    return [line[4:] for line in stdout.splitlines() if line.startswith("WPI ")]


@unittest.skipIf(shutil.which("g++") is None, "g++ not installed")
class BearAutoCcTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp()
        with open(os.path.join(cls.tmp, "wiringPi.h"), "w") as f:
            f.write(STUB_HEADER)
        cls.exe = os.path.join(cls.tmp, "bear_auto")
        cmd = ["g++", "-O2", "-std=c++17", "-Wall", "-Wextra", "-I", cls.tmp, SOURCE, "-o", cls.exe]
        res = subprocess.run(cmd, capture_output=True, text=True)
        if res.returncode != 0:
            shutil.rmtree(cls.tmp)
            raise AssertionError(res.stderr)
        cls.warnings = res.stderr

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp)

    def assert_pins_idle_at_end(self, calls):
        tail = calls[-2 * len(PINS):]
        self.assertEqual(tail, [f"digitalWrite({p},LOW)" for p in PINS] + [f"pinMode({p},INPUT)" for p in PINS])

    def test_compiles_without_warnings(self):
        self.assertEqual(self.warnings.strip(), "")

    def test_selftest_fake_cam(self):
        res = subprocess.run([self.exe, "--selftest", "--fake-cam"], capture_output=True, text=True, timeout=30)
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        for step in ("CAMERA", "RELAY", "WHEELS"):
            self.assertIn(f">>> {step}: PASS", res.stdout)
        self.assertIn("320x240", res.stdout)
        calls = wpi_calls(res.stdout)
        i = calls.index("digitalWrite(17,HIGH)")
        self.assertEqual(calls[i:i + 3], ["digitalWrite(17,HIGH)", "delay(300)", "digitalWrite(17,LOW)"])
        # wheel 1 fwd, wheel 2 fwd (DIR1 HIGH, DIR2 LOW), then both back (DIR1 LOW, DIR2 HIGH)
        dirs = [c for c in calls[i:] if c.startswith(("digitalWrite(26,", "digitalWrite(21,"))][:6]
        self.assertEqual(dirs, ["digitalWrite(26,HIGH)", "digitalWrite(21,LOW)"] * 2
                         + ["digitalWrite(26,LOW)", "digitalWrite(21,HIGH)"])
        self.assertEqual(calls.count("digitalWrite(13,HIGH)"), 400)
        self.assertEqual(calls.count("digitalWrite(16,HIGH)"), 400)
        self.assert_pins_idle_at_end(calls)

    def test_selftest_custom_pulse(self):
        res = subprocess.run([self.exe, "--selftest", "--fake-cam", "--pulse-ms", "500"],
                             capture_output=True, text=True, timeout=30)
        self.assertIn("delay(500)", wpi_calls(res.stdout))

    def test_selftest_no_wheels_never_steps(self):
        res = subprocess.run([self.exe, "--selftest", "--fake-cam", "--no-wheels"],
                             capture_output=True, text=True, timeout=30)
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertIn(">>> WHEELS: SKIPPED", res.stdout)
        self.assertIn(">>> RELAY: PASS", res.stdout)
        calls = wpi_calls(res.stdout)
        for pin in (13, 16, 26, 21):
            self.assertNotIn(f"digitalWrite({pin},HIGH)", calls)

    def test_selftest_no_relay_never_pulses(self):
        res = subprocess.run([self.exe, "--selftest", "--fake-cam", "--no-relay"],
                             capture_output=True, text=True, timeout=30)
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertIn(">>> RELAY: SKIPPED", res.stdout)
        self.assertNotIn("digitalWrite(17,HIGH)", wpi_calls(res.stdout))

    def test_autonomous_fake_cam_fires_person(self):
        proc = subprocess.Popen([self.exe, "--fake-cam", "--cooldown", "1"],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        time.sleep(2.0)
        proc.send_signal(signal.SIGINT)
        out, err = proc.communicate(timeout=10)
        self.assertEqual(proc.returncode, 0, err)
        self.assertIn("PERSON", out)
        calls = wpi_calls(out)
        i = calls.index("digitalWrite(17,HIGH)")
        self.assertEqual(calls[i:i + 3], ["digitalWrite(17,HIGH)", "delay(300)", "digitalWrite(17,LOW)"])
        self.assertGreaterEqual(calls.count("digitalWrite(13,HIGH)"), 200)
        self.assertGreaterEqual(calls.count("digitalWrite(16,HIGH)"), 200)
        self.assert_pins_idle_at_end(calls)

    def test_no_relay_no_wheels(self):
        proc = subprocess.Popen([self.exe, "--fake-cam", "--no-relay", "--no-wheels"],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        time.sleep(1.0)
        proc.send_signal(signal.SIGINT)
        out, _ = proc.communicate(timeout=10)
        self.assertIn("PERSON", out)
        self.assertEqual(wpi_calls(out), [])


if __name__ == "__main__":
    unittest.main()
