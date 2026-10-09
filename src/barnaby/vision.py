"""OpenCV CPU inference, kept independent from the camera and robot hardware."""

from dataclasses import dataclass
import os
from pathlib import Path
import time

import cv2
import numpy as np

from ._vendor.facial_fer_model import FacialExpressionRecog
from ._vendor.hsemotion_onnx import HSEmotionRecog
from ._vendor.mp_handpose import MPHandPose
from ._vendor.mp_palmdet import MPPalmDet
from .gestures import classify_gesture
from .models import model_paths


@dataclass
class Observation:
    gesture: str = "none"
    expression: str = "none"
    hand_confidence: float = 0.0
    face_confidence: float = 0.0  # YuNet face *detection* score, NOT the expression probability
    expression_confidence: float = 0.0  # softmax probability of the reported expression
    expression_margin: float = 0.0  # top-1 minus top-2 probability
    hand_points: np.ndarray | None = None
    face_box: tuple[int, int, int, int] | None = None
    inference_ms: float = 0.0


# Closed-set classifiers must pick a class even for faces they were never trained on
# (tongue out, half-turned head, upside-down frame). Below these, report "unsure".
UNSURE_MIN_PROB = float(os.environ.get("BARNABY_FER_MIN_PROB", "0.6"))
UNSURE_MIN_MARGIN = float(os.environ.get("BARNABY_FER_MIN_MARGIN", "0.3"))
CUR_LABELS = ["angry", "disgust", "fearful", "happy", "neutral", "sad", "surprised"]


class Vision:
    def __init__(self, model_dir: Path, threads: int = 2, palm_threshold: float = 0.65, palm_nms: float = 0.3,
                 hand_threshold: float = 0.8, face_threshold: float = 0.8, face_nms: float = 0.3):
        """Thresholds are detector scores in [0, 1]; lower finds more (and more false) hands/faces."""
        version = tuple(int(part) for part in cv2.__version__.split(".")[:2])
        if version < (4, 10):
            raise RuntimeError(f"OpenCV >=4.10 is required; found {cv2.__version__}")
        cv2.setNumThreads(threads)
        paths = model_paths(model_dir)
        backend, target = cv2.dnn.DNN_BACKEND_OPENCV, cv2.dnn.DNN_TARGET_CPU
        self.palms = MPPalmDet(str(paths["palm"]), nmsThreshold=palm_nms, scoreThreshold=palm_threshold, backendId=backend, targetId=target)
        self.hands = MPHandPose(str(paths["hand"]), confThreshold=hand_threshold, backendId=backend, targetId=target)
        self.faces = cv2.FaceDetectorYN.create(str(paths["face"]), "", (320, 240), face_threshold, face_nms, 5000,
                                                backend, target)
        self.expressions = FacialExpressionRecog(str(paths["expression"]), backendId=backend, targetId=target)
        # Prototype: BARNABY_FER=hsemotion uses EmotiEffLib enet_b0_8_va_mtl.onnx from model_dir.
        self.hsemotion = None
        if os.environ.get("BARNABY_FER", "").lower() == "hsemotion":
            self.hsemotion = HSEmotionRecog(str(model_dir / "enet_b0_8_va_mtl.onnx"), backend, target)

    def infer(self, frame: np.ndarray) -> Observation:
        """Process one BGR image. Limit the starter to one face and one hand."""
        started = time.perf_counter()
        result = Observation()
        height, width = frame.shape[:2]
        self.faces.setInputSize((width, height))
        _, faces = self.faces.detect(frame)
        if faces is not None and len(faces):
            # Prefer the largest face; this is not identity tracking.
            face = max(faces, key=lambda row: row[2] * row[3])
            if self.hsemotion is not None:
                probs, labels = self.hsemotion.infer_proba(frame, face), self.hsemotion.labels
            else:
                probs, labels = self.expressions.infer_proba(frame, face[:-1]), CUR_LABELS
            order = np.argsort(probs)[::-1]
            result.expression_confidence = float(probs[order[0]])
            result.expression_margin = float(probs[order[0]] - probs[order[1]])
            unsure = result.expression_confidence < UNSURE_MIN_PROB or result.expression_margin < UNSURE_MIN_MARGIN
            result.expression = "unsure" if unsure else labels[order[0]]
            result.face_confidence = float(face[-1])  # Detection confidence, not emotion confidence.
            result.face_box = tuple(int(value) for value in face[:4])
        palms = self.palms.infer(frame)
        for palm in sorted(palms, key=lambda row: row[-1], reverse=True)[:2]:
            # Reject off-frame/degenerate boxes before the upstream hand crop.
            x1, y1, x2, y2 = palm[:4]
            if min(width, x2) <= max(0, x1) or min(height, y2) <= max(0, y1):
                continue
            hand = self.hands.infer(frame, palm)
            if hand is not None:
                result.hand_points = hand[4:67].reshape(21, 3)
                result.hand_confidence = float(hand[-1])
                result.gesture = classify_gesture(result.hand_points)
                break
        result.inference_ms = (time.perf_counter() - started) * 1000
        return result

    def check(self) -> None:
        """Exercise all four networks without needing a camera."""
        frame = np.zeros((240, 320, 3), dtype=np.uint8)
        self.infer(frame)
        # Blank images have no detections; explicitly run the two crop networks.
        palm = np.array([100, 60, 180, 140, 140, 135, 110, 100, 125, 85,
                         140, 80, 155, 85, 170, 100, 145, 120, 0.9], dtype=np.float32)
        self.hands.infer(frame, palm)
        label = self.expressions.infer(np.zeros((112, 112, 3), dtype=np.uint8))
        if not 0 <= int(label[0]) < 7:
            raise RuntimeError("Unexpected expression model output")
