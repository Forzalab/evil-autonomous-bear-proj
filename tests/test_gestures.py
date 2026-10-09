import unittest

import numpy as np

from barnaby.gestures import StableLabel, classify_gesture


def hand(extended=(True, True, True, True), thumb_up=False):
    points = np.zeros((21, 3), dtype=np.float32)
    points[0] = (0, 4, 0)
    for base, x, straight in zip((5, 9, 13, 17), (-1.5, -0.5, 0.5, 1.5), extended):
        points[base] = (x, 0, 0)
        points[base + 1] = (x, -1, 0)
        points[base + 2] = (x, -2 if straight else 0, 0)
        points[base + 3] = (x, -3 if straight else 1, 0)
    points[1] = (-2, 2, 0)
    points[2] = (-2.5, 1, 0)
    points[3] = (-2.5, 0 if thumb_up else 1, 0)
    points[4] = (-2.5, -2 if thumb_up else 2, 0)
    return points


class GesturesTest(unittest.TestCase):
    def test_starter_poses(self):
        poses = [
            (hand(), "open_palm"),
            (hand((False,) * 4), "fist"),
            (hand((True, True, False, False)), "peace"),
            (hand((True, False, False, False)), "pointing"),
            (hand((False,) * 4, thumb_up=True), "thumbs_up"),
            (hand((False, True, False, False)), "middle_finger"),
            (hand((False, True, False, False), thumb_up=True), "middle_finger"),
            (hand((False, True, False, True)), "unknown"),
        ]
        for points, expected in poses:
            with self.subTest(expected=expected):
                self.assertEqual(classify_gesture(points), expected)
                self.assertEqual(classify_gesture(points * 30 + 100), expected)

    def test_sideways_thumb_is_not_thumbs_up(self):
        points = hand((False,) * 4, thumb_up=True)
        points[:, :2] = points[:, :2] @ np.array([[0, -1], [1, 0]])
        self.assertEqual(classify_gesture(points), "unknown")

    def test_middle_finger_needs_other_fingers_curled(self):
        for extended in ((True, True, False, False), (False, True, True, False),
                         (False, True, False, True), (False, True, True, True)):
            with self.subTest(extended=extended):
                self.assertNotEqual(classify_gesture(hand(extended)), "middle_finger")

    def test_middle_finger_any_rotation(self):
        # Rule is angle based, so a bird pointed sideways or down still counts.
        points = hand((False, True, False, False))
        for angle in (90, 180, 270):
            theta = np.radians(angle)
            rot = np.array([[np.cos(theta), -np.sin(theta)], [np.sin(theta), np.cos(theta)]])
            rotated = points.copy()
            rotated[:, :2] = points[:, :2] @ rot.T
            with self.subTest(angle=angle):
                self.assertEqual(classify_gesture(rotated), "middle_finger")

    def test_bad_landmarks(self):
        for points in (np.zeros((21, 3)), np.zeros((5, 3)), np.full((21, 3), np.nan)):
            self.assertEqual(classify_gesture(points), "unknown")

    def test_label_requires_consecutive_observations(self):
        stable = StableLabel(3)
        for label in ("happy", "sad", "happy", "happy"):
            self.assertEqual(stable.update(label), "none")
        self.assertEqual(stable.update("happy"), "happy")
        self.assertEqual(stable.update("sad"), "happy")
        self.assertEqual(stable.update("none"), "none")
        self.assertEqual(stable.update("happy"), "none")


if __name__ == "__main__":
    unittest.main()
