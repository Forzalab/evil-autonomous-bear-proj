import os
import re
import subprocess
import tempfile
import unittest

SCRIPT = os.path.join(os.path.dirname(__file__), "..", "pi", "edge_test.sh")

EXPECTED = {
    "tap": ["open", "close", "open"],
    "hold_release": ["open", "close", "open"],
    "hold_only": ["open", "close"],
    "blip_open": ["close", "open", "close"],
    "release_only": ["close", "open"],
    "long_hold_release": ["open", "close", "open"],
}
ORDER = list(EXPECTED)


def run(args=(), **env_over):
    tmp = tempfile.mkdtemp()
    env = dict(os.environ, DRY="1", GAP="0", SCALE="0.01", HOME=tmp,
               LOG=os.path.join(tmp, "logs", "edge_test.log"))
    env.update(env_over)
    p = subprocess.run(["bash", SCRIPT, *args], env=env, capture_output=True,
                       text=True, timeout=30)
    return p, env["LOG"]


def edges_by_test(out):
    """Map test name -> list of EDGE close/open seen between its banner and its DONE line."""
    res, cur = {}, None
    for line in out.splitlines():
        m = re.search(r"TEST \d+ of \d+: (\w+)\.", line)
        if m:
            cur = m.group(1)
            res[cur] = []
            continue
        m = re.match(r"\d\d:\d\d:\d\d\.\d{3} EDGE (close|open)$", line)
        if m and cur:
            res[cur].append(m.group(1))
        if ">>> TEST" in line and "DONE" in line:
            cur = None
    return res


class EdgeTestScript(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.proc, cls.log = run()

    def test_syntax(self):
        self.assertEqual(subprocess.run(["bash", "-n", SCRIPT]).returncode, 0)

    def test_full_run_exit_and_names(self):
        self.assertEqual(self.proc.returncode, 0, self.proc.stderr)
        for name in ORDER:
            self.assertIn(f">>> TEST {name} DONE", self.proc.stdout)

    def test_order(self):
        seen = re.findall(r"TEST \d+ of 6: (\w+)\.", self.proc.stdout)
        self.assertEqual(seen, ORDER)

    def test_edge_sequences(self):
        got = edges_by_test(self.proc.stdout)
        for name, seq in EXPECTED.items():
            self.assertEqual(got.get(name), seq, name)

    def test_dry_markers_match_edges(self):
        dry = re.findall(r"^\(dry\) (close|open)$", self.proc.stdout, re.M)
        edges = re.findall(r"EDGE (close|open)$", self.proc.stdout, re.M)
        self.assertEqual(dry, edges)
        self.assertEqual(len(edges), sum(len(v) for v in EXPECTED.values()))
        self.assertIn("(dry) rest", self.proc.stdout)

    def test_watch_banner(self):
        self.assertIn("watch: does it start at CLOSE or at RELEASE?", self.proc.stdout)

    def test_log_file_written(self):
        with open(self.log) as f:
            self.assertIn(">>> TEST long_hold_release DONE", f.read())

    def test_selected_by_name_and_number(self):
        p, _ = run(["blip_open", "t2"])
        self.assertEqual(p.returncode, 0, p.stderr)
        got = edges_by_test(p.stdout)
        self.assertEqual(list(got), ["blip_open", "hold_release"])
        self.assertEqual(got["blip_open"], ["close", "open", "close"])

    def test_unknown_test_rejected(self):
        p, _ = run(["bogus"])
        self.assertNotEqual(p.returncode, 0)
        self.assertNotIn("EDGE", p.stdout)

    def test_bad_sig_refused(self):
        for sig in ("0", "1", "28", "x"):
            p, _ = run(["tap"], SIG=sig)
            self.assertNotEqual(p.returncode, 0, sig)
            self.assertNotIn("EDGE", p.stdout)


if __name__ == "__main__":
    unittest.main()
