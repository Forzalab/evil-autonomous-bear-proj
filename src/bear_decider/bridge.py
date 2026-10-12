"""Perception -> dance bridge: a shown hand runs the pi/dance relay pulse once."""

import os
import subprocess
import sys
import time

from barnaby.trigger import ANY, OneShot


class DanceBridge:
    """Spawn `binary` (non-blocking) when OneShot fires. Never raises.

    cooldown_s 25 > the Try Me lock (~22 s, unmeasured), so a fire never lands inside it.
    Dry-run notes go to `stream` (None = stdout).
    """

    def __init__(self, gesture: str = ANY, cooldown_s: float = 25.0, binary: str | None = None,
                 spawn=subprocess.Popen, clock=time.monotonic, stream=None):
        self.trigger = OneShot(gesture, cooldown_s)
        self.binary = binary or os.environ.get("BEAR_DANCE_BIN", "pi/dance")
        self.spawn = spawn
        self.clock = clock
        self.stream = stream
        self._proc = None

    def handle(self, event) -> bool:
        """Return True when a dance was started."""
        if not self.trigger.feed(event, self.clock()):
            return False
        if self._proc is not None and self._proc.poll() is None:
            return False  # previous dance still running
        if not os.path.isfile(self.binary):
            print(f"DANCE (dry-run: {self.binary} not found)", file=self.stream, flush=True)
            return False
        try:
            self._proc = self.spawn([self.binary])
        except OSError as e:
            print(f"DANCE (dry-run: {e})", file=self.stream, flush=True)
            return False
        return True


_bridge: DanceBridge | None = None


def handle(event) -> bool:
    """Feed the shared bridge, built on first use. Notes go to stderr: stdout is one JSON line per event."""
    global _bridge
    if _bridge is None:
        _bridge = DanceBridge(stream=sys.stderr)
    return _bridge.handle(event)
