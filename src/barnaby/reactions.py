"""Attach Barnaby's speech, LEDs, or servo commands here."""

from dataclasses import dataclass
import json
import os

# TEMP testing aid: bear.sh testing mode sets BEAR_DEBUG=1. Off (and removable) in prod.
DEBUG = os.environ.get("BEAR_DEBUG") == "1"


@dataclass(frozen=True)
class PerceptionEvent:
    gesture: str
    expression: str
    hand_confidence: float
    face_confidence: float
    inference_ms: float
    expression_confidence: float = 0.0  # softmax of `expression`; face_confidence is only the detector score


def on_perception(event: PerceptionEvent) -> None:
    """Called on stable label changes. Currently just prints an event."""
    # Example next step: if event.gesture == "open_palm": queue a wave animation.
    # Keep slow speech/motion work in a worker or queue so capture remains responsive.
    payload = dict(event.__dict__)
    if DEBUG:
        payload["debug"] = debug_info()
    print(json.dumps(payload), flush=True)


def debug_info() -> dict:
    """Rotation of the newest camera photo (Termux camera patch) + the finger test verdict."""
    from . import camera
    return {**(getattr(camera, "last_photo", None) or {}),
            "finger_test": os.environ.get("BEAR_FINGER_TEST", "not run")}
