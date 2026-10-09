"""HSEmotion / EmotiEffLib AffectNet model via cv2.dnn (prototype, Barnaby).

Weights: https://github.com/sb-ai-lab/EmotiEffLib/tree/main/models/affectnet_emotions/onnx
(code Apache-2.0; weights trained on AffectNet). Input: unaligned RGB face box,
224x224, ImageNet mean/std. Output: 8 emotion logits (+ valence, arousal for *_mtl).
"""

import cv2 as cv
import numpy as np

LABELS = ["angry", "contempt", "disgust", "fearful", "happy", "neutral", "sad", "surprised"]


class HSEmotionRecog:
    def __init__(self, modelPath, backendId=0, targetId=0, size=224):
        self._model = cv.dnn.readNet(modelPath)
        self._model.setPreferableBackend(backendId)
        self._model.setPreferableTarget(targetId)
        self._size = size
        self.labels = LABELS
        self.valence_arousal = None

    def infer_proba(self, image, face):
        x, y, w, h = face[:4]
        side = max(w, h)
        cx, cy = x + w / 2, y + h / 2
        x0, y0, s = int(round(cx - side / 2)), int(round(cy - side / 2)), max(1, int(round(side)))
        padded = cv.copyMakeBorder(image, s, s, s, s, cv.BORDER_REPLICATE)
        crop = cv.cvtColor(padded[y0 + s:y0 + 2 * s, x0 + s:x0 + 2 * s], cv.COLOR_BGR2RGB)
        blob = cv.resize(crop, (self._size, self._size)).astype(np.float32) / 255
        blob = (blob - (0.485, 0.456, 0.406)) / (0.229, 0.224, 0.225)
        self._model.setInput(cv.dnn.blobFromImage(blob.astype(np.float32)))
        out = self._model.forward().ravel()
        self.valence_arousal = tuple(float(v) for v in out[8:10]) if out.size >= 10 else None
        e = np.exp(out[:8] - out[:8].max())
        return e / e.sum()
