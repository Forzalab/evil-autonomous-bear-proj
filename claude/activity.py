"""Activity queue: the bear does ONE thing at a time (dance, Gemini line, wheel move...).

Rules (Tony + group, 2026-10-23; see claude/QUEUE.md):
- Order: priority first (Gemini lines = 0, everything else = 1), then arrival time.
- Each item holds the bear for max(its run time, its duration_s).
- Bucket: a detection of a kind that is already waiting or running is dropped,
  so 10 waves during one ~22 s dance make one dance, not 10.
- Everything else is queued. Delay is accepted.
Duck-typed and barnaby-free; ActivityQueue does no I/O or timing (the caller passes `now`).
"""

import heapq
import itertools
import sys
import threading
import time
from dataclasses import dataclass, field

PRIORITY = {"gemini": 0}  # lower runs first; kinds not listed get DEFAULT_PRIORITY
DEFAULT_PRIORITY = 1


@dataclass(order=True)
class Item:
    priority: int
    seq: int
    kind: str = field(compare=False)
    payload: object = field(compare=False, default=None)
    duration_s: float = field(compare=False, default=0.0)


class ActivityQueue:
    """Policy only. The owner serializes access and supplies `now` (seconds, monotonic)."""

    def __init__(self, priority=PRIORITY):
        self.priority = priority
        self._heap: list[Item] = []
        self._seq = itertools.count()
        self.current: Item | None = None  # last started item
        self.running = False  # its run() has not returned yet
        self.busy_until = 0.0

    def busy(self, now: float) -> bool:
        return self.running or now < self.busy_until

    def submit(self, kind: str, now: float, payload=None, duration_s: float = 0.0, bucket: bool = True) -> bool:
        """Queue an activity. With `bucket`, drop it if the same kind is already waiting or running."""
        if bucket and (self.busy(now) and self.current.kind == kind
                       or any(item.kind == kind for item in self._heap)):
            return False
        heapq.heappush(self._heap, Item(self.priority.get(kind, DEFAULT_PRIORITY), next(self._seq),
                                        kind, payload, duration_s))
        return True

    def take(self, now: float) -> Item | None:
        """Start the next item when the bear is free; None while busy or empty."""
        if self.busy(now) or not self._heap:
            return None
        self.current = heapq.heappop(self._heap)
        self.running = True
        self.busy_until = now + self.current.duration_s
        return self.current

    def finish(self, now: float) -> None:
        """The run returned: the bear stays busy until its duration has also passed."""
        self.running = False
        self.busy_until = max(self.busy_until, now)

    def wait_s(self, now: float) -> float | None:
        """Seconds until take() can start something; None = nothing queued."""
        return max(0.0, self.busy_until - now) if self._heap else None

    def __len__(self):
        return len(self._heap)


class ActivityWorker:
    """One thread runs queued items in order. `run(item)` blocks until the activity ends; it may raise."""

    def __init__(self, run, queue: ActivityQueue | None = None, clock=time.monotonic, stream=None):
        self.run = run
        self.queue = queue or ActivityQueue()
        self.clock = clock
        self.stream = stream
        self._cond = threading.Condition()
        self._thread: threading.Thread | None = None

    def submit(self, kind: str, payload=None, duration_s: float = 0.0, bucket: bool = True) -> bool:
        with self._cond:
            ok = self.queue.submit(kind, self.clock(), payload, duration_s, bucket)
            if ok and self._thread is None:
                self._thread = threading.Thread(target=self._loop, name="bear-activity", daemon=True)
                self._thread.start()
            self._cond.notify()
        print(f"[queue] {kind} {'queued' if ok else 'dropped (bucket)'}, waiting {len(self.queue)}",
              file=self.stream or sys.stderr, flush=True)
        return ok

    def _loop(self):
        while True:
            with self._cond:
                item = self.queue.take(self.clock())
                while item is None:
                    self._cond.wait(self.queue.wait_s(self.clock()))
                    item = self.queue.take(self.clock())
            try:
                self.run(item)
            except Exception as e:  # one bad activity must not stop the queue
                print(f"[queue error] {item.kind}: {type(e).__name__}: {e}", file=self.stream or sys.stderr, flush=True)
            with self._cond:
                self.queue.finish(self.clock())
