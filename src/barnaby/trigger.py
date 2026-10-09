"""One-shot gesture trigger: one bear dance per shown gesture.

Perception events arrive only when a label changes, so a held hand, a face
change, or a flickering hand would otherwise re-fire. OneShot filters that.
"""

from .reactions import PerceptionEvent

ANY = "any"  # Any detected hand (every label except "none") counts as the gesture.


class OneShot:
    """Fire once when `gesture` is shown, then stay quiet until re-armed.

    After a fire, it fires again only when `cooldown_s` has passed since that
    fire AND the gesture was absent for at least `rearm_s` before being shown
    again. Expression is ignored. The cooldown should be the length of one bear
    dance: measure it on the real bear (Fri build), then set it.
    The caller passes `now` (seconds, monotonic); this class does no I/O or timing.

    `gesture="any"` matches every hand label except "none". With
    `repeat_while_held`, a hand that stays up fires again each time the cooldown
    passes, so the caller must feed every inference, not only label changes.
    """

    def __init__(self, gesture: str, cooldown_s: float = 20.0, rearm_s: float = 1.0,
                 repeat_while_held: bool = False):
        self.gesture = gesture
        self.cooldown_s = cooldown_s
        self.rearm_s = rearm_s
        self.repeat_while_held = repeat_while_held
        self._fired_at: float | None = None
        self._absent_since: float | None = None
        self._holding = False

    def feed(self, event: PerceptionEvent, now: float) -> bool:
        """Return True when this event should start a dance."""
        shown = event.gesture != "none" if self.gesture == ANY else event.gesture == self.gesture
        if not shown:
            if self._absent_since is None:
                self._absent_since = now
            self._holding = False
            return False
        if self._holding:
            if self.repeat_while_held and self._fired_at is not None and now - self._fired_at >= self.cooldown_s:
                self._fired_at = now
                return True
            return False
        self._holding = True
        absent = 0.0 if self._absent_since is None else now - self._absent_since
        self._absent_since = None
        if self._fired_at is not None and (now - self._fired_at < self.cooldown_s or absent < self.rearm_s):
            return False
        self._fired_at = now
        return True
