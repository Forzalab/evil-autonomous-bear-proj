import io
import json
import unittest
from contextlib import redirect_stdout
from unittest import mock

from barnaby import reactions
from barnaby.reactions import PerceptionEvent, on_perception


class DebugTest(unittest.TestCase):
    def emit(self):
        out = io.StringIO()
        with redirect_stdout(out):
            on_perception(PerceptionEvent("fist", "happy", 0.9, 0.8, 12.0, 0.7))
        return json.loads(out.getvalue())

    def test_no_debug_by_default(self):
        with mock.patch.object(reactions, "DEBUG", False):
            self.assertNotIn("debug", self.emit())

    def test_debug_adds_finger_test(self):
        with mock.patch.object(reactions, "DEBUG", True), \
                mock.patch.dict("os.environ", {"BEAR_FINGER_TEST": "ROTATE=180 MIRROR=0"}):
            self.assertEqual(self.emit()["debug"]["finger_test"], "ROTATE=180 MIRROR=0")


if __name__ == "__main__":
    unittest.main()
