"""Attach Barnaby's speech, LEDs, or servo commands here."""

from dataclasses import dataclass
import json


@dataclass(frozen=True)
class PerceptionEvent:
    gesture: str
    expression: str
    hand_confidence: float
    face_confidence: float
    inference_ms: float


def on_perception(event: PerceptionEvent) -> None:
    """Called on stable label changes. Currently just prints an event."""
    # Example next step: if event.gesture == "open_palm": queue a wave animation.
    # Keep slow speech/motion work in a worker or queue so capture remains responsive.
    print(json.dumps(event.__dict__), flush=True)


def on_scene_description(description: str) -> None:
    """Receive descriptions of people from Gemini."""
    print(f"[Barnaby sees] {description}", flush=True)
    # Later: queue speech or a Barnaby reaction here.
