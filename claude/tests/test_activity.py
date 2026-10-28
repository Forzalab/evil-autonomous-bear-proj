import threading
import unittest

from claude.activity import ActivityQueue, ActivityWorker


class ActivityQueueTest(unittest.TestCase):
    def test_tony_example_waves_every_3s_one_dance_per_block(self):
        q = ActivityQueue()
        accepted = []
        for t in range(3, 61, 3):  # a kid waves every 3 s for a minute
            if q.submit("dance", t, duration_s=22.0):
                accepted.append(t)
            item = q.take(t)
            if item is not None:
                q.finish(t)  # the relay blip returns at once; the 22 s hold keeps the bear busy
        self.assertEqual(accepted, [3, 27, 51])  # 3..24 busy, 25..48 busy, ...

    def test_gemini_jumps_ahead_then_arrival_order(self):
        q = ActivityQueue()
        q.submit("dance", 0.0, duration_s=0.0)
        q.submit("cmd", 0.1, ["wheels"])
        q.submit("gemini", 0.2, "hello", bucket=False)
        q.submit("gemini", 0.3, "again", bucket=False)
        order = []
        for t in (1.0, 2.0, 3.0, 4.0):
            item = q.take(t)
            order.append((item.kind, item.payload))
            q.finish(t)
        self.assertEqual(order, [("gemini", "hello"), ("gemini", "again"), ("dance", None), ("cmd", ["wheels"])])

    def test_bucket_drops_waiting_duplicate(self):
        q = ActivityQueue()
        self.assertTrue(q.submit("dance", 0.0))
        self.assertFalse(q.submit("dance", 0.5))
        self.assertEqual(len(q), 1)

    def test_one_at_a_time_and_hold_for_duration(self):
        q = ActivityQueue()
        q.submit("dance", 0.0, duration_s=22.0)
        q.submit("cmd", 0.0, ["wheels"])
        self.assertEqual(q.take(0.0).kind, "dance")
        self.assertIsNone(q.take(1.0))  # still running
        q.finish(1.0)
        self.assertIsNone(q.take(21.9))  # run returned, hold not over
        self.assertEqual(q.wait_s(21.0), 1.0)
        self.assertEqual(q.take(22.0).kind, "cmd")

    def test_long_run_outlasts_duration(self):
        q = ActivityQueue()
        q.submit("gemini", 0.0, "long line", duration_s=1.0, bucket=False)
        q.take(0.0)
        self.assertTrue(q.submit("dance", 5.0))
        self.assertIsNone(q.take(5.0))  # still speaking at 5 s
        q.finish(8.0)
        self.assertEqual(q.take(8.0).kind, "dance")

    def test_same_kind_accepted_after_hold_ends(self):
        q = ActivityQueue()
        q.submit("dance", 0.0, duration_s=22.0)
        q.take(0.0)
        q.finish(0.1)
        self.assertFalse(q.submit("dance", 21.0))
        self.assertTrue(q.submit("dance", 22.0))


class ActivityWorkerTest(unittest.TestCase):
    def test_runs_in_order_and_survives_errors(self):
        ran, done = [], threading.Event()

        def run(item):
            ran.append(item.payload)
            if item.payload == "boom":
                raise RuntimeError("boom")
            if item.payload == "last":
                done.set()

        w = ActivityWorker(run, stream=open("/dev/null", "w"))
        w.submit("gemini", "boom", bucket=False)
        w.submit("gemini", "ok", bucket=False)
        w.submit("gemini", "last", bucket=False)
        self.assertTrue(done.wait(5))
        self.assertEqual(ran, ["boom", "ok", "last"])


if __name__ == "__main__":
    unittest.main()
