"""Starter static gestures from 21 hand landmarks; no separate gesture network."""

import numpy as np

HAND_CONNECTIONS = (
    (0, 1), (1, 2), (2, 3), (3, 4), (0, 5), (5, 6), (6, 7), (7, 8),
    (5, 9), (9, 10), (10, 11), (11, 12), (9, 13), (13, 14), (14, 15),
    (15, 16), (13, 17), (0, 17), (17, 18), (18, 19), (19, 20),
)


def _straight(points: np.ndarray, base: int, joint: int, tip: int) -> bool:
    a, b = points[base] - points[joint], points[tip] - points[joint]
    denominator = np.linalg.norm(a) * np.linalg.norm(b)
    if denominator < 1e-8:
        return False
    cosine = float(np.dot(a, b) / denominator)
    return cosine < -0.75 and np.linalg.norm(points[tip] - points[0]) > np.linalg.norm(points[joint] - points[0])


def classify_gesture(points: np.ndarray) -> str:
    """Classify screen landmarks; thumbs_up assumes the camera image is upright."""
    points = np.asarray(points, dtype=np.float32)
    if points.shape != (21, 3) or not np.isfinite(points).all():
        return "unknown"
    if np.linalg.norm(points[0] - points[9]) < 1e-8:
        return "unknown"
    fingers = [_straight(points, base, base + 1, base + 3) for base in (5, 9, 13, 17)]
    thumb = _straight(points, 1, 3, 4)
    if all(fingers):
        return "open_palm"
    if fingers == [True, True, False, False]:
        return "peace"
    if fingers == [True, False, False, False]:
        return "pointing"
    if fingers == [False, True, False, False]:
        # Thumb is ignored: people flip the bird with it tucked or sticking out.
        return "middle_finger"
    if not any(fingers):
        palm_size = float(np.linalg.norm(points[0] - points[9]))
        upward = points[2, 1] - points[4, 1]
        sideways = abs(points[2, 0] - points[4, 0])
        if thumb and upward > 0.35 * palm_size and upward > sideways:
            return "thumbs_up"
        if not thumb:
            return "fist"
    return "unknown"


class StableLabel:
    """Require consecutive observations before publishing a new label."""

    def __init__(self, observations: int = 3):
        if observations < 1:
            raise ValueError("observations must be positive")
        self.observations = observations
        self.value = "none"
        self._candidate = "none"
        self._count = 0

    def update(self, label: str) -> str:
        if label == "none":
            # Clear immediately when the subject disappears, preventing stale reactions.
            self.value = self._candidate = "none"
            self._count = 0
            return self.value
        if label != self._candidate:
            self._candidate, self._count = label, 1
        else:
            self._count += 1
        if self._count >= self.observations:
            self.value = label
        return self.value
