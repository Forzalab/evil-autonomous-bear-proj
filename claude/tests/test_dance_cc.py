import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # claude/
SOURCE = os.path.join(ROOT, "hw", "dance.cc")

# Fake wiringPi: every call logs one "WPI ..." line to stdout; no hardware, no sleep.
STUB_HEADER = r"""
#pragma once
#include <cstdio>
#ifndef STUB_SETUP_RET
#define STUB_SETUP_RET 0
#endif
#define INPUT 0
#define OUTPUT 1
#define LOW 0
#define HIGH 1
inline int wiringPiSetupGpio() { std::printf("WPI setup\n"); std::fflush(stdout); return STUB_SETUP_RET; }
inline void pinMode(int pin, int mode) {
    std::printf("WPI pinMode(%d,%s)\n", pin, mode == OUTPUT ? "OUTPUT" : mode == INPUT ? "INPUT" : "?");
    std::fflush(stdout);
}
inline void digitalWrite(int pin, int val) {
    std::printf("WPI digitalWrite(%d,%s)\n", pin, val == HIGH ? "HIGH" : val == LOW ? "LOW" : "?");
    std::fflush(stdout);
}
inline void delay(unsigned int ms) { std::printf("WPI delay(%u)\n", ms); std::fflush(stdout); }
inline void delayMicroseconds(unsigned int us) { std::printf("WPI delayMicroseconds(%u)\n", us); std::fflush(stdout); }
"""


def expected(ms):
    return ["setup", "pinMode(17,OUTPUT)", "digitalWrite(17,HIGH)", f"delay({ms})",
            "digitalWrite(17,LOW)", "pinMode(17,INPUT)"]


@unittest.skipIf(shutil.which("g++") is None, "g++ not installed")
class DanceCcTest(unittest.TestCase):
    def setUp(self):
        self.assertTrue(os.path.isfile(SOURCE), f"missing {SOURCE}")
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp)
        with open(os.path.join(self.tmp, "wiringPi.h"), "w") as f:
            f.write(STUB_HEADER)

    def build(self, setup_ret=0):
        exe = os.path.join(self.tmp, f"dance_{setup_ret}".replace("-", "m"))
        cmd = ["g++", "-O2", "-I", self.tmp, f"-DSTUB_SETUP_RET={setup_ret}", SOURCE, "-o", exe]
        res = subprocess.run(cmd, capture_output=True, text=True)
        self.assertEqual(res.returncode, 0, res.stderr)
        return exe

    def run_exe(self, exe, *args):
        res = subprocess.run([exe, *args], capture_output=True, text=True, timeout=10)
        calls = [line[4:] for line in res.stdout.splitlines() if line.startswith("WPI ")]
        return res, calls

    def test_default_pulse_300ms(self):
        res, calls = self.run_exe(self.build())
        self.assertEqual(calls, expected(300))
        self.assertEqual(res.returncode, 0, res.stderr)

    def test_argv_ms_overrides_default(self):
        res, calls = self.run_exe(self.build(), "500")
        self.assertEqual(calls, expected(500))
        self.assertEqual(res.returncode, 0, res.stderr)

    def test_setup_failure_exits_1(self):
        res, calls = self.run_exe(self.build(setup_ret=-1))
        self.assertEqual(res.returncode, 1)
        self.assertNotIn("digitalWrite(17,HIGH)", calls)
        self.assertTrue(res.stderr.strip())


if __name__ == "__main__":
    unittest.main()
