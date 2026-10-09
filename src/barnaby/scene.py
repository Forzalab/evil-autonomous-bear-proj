"""Get short scene descriptions from Gemini 3.8 Flash over HTTPS."""

import base64
import os

import cv2
import numpy as np

MODEL = "gemini-3.8-flash"
PROMPT = (
    "You are an anamatronic bear Describe the person or people visible in this camera image in a funny way"
    "Focus on what theyre wearing/holding and be nice but spooky as you're a scary bear"
    "This will be spoken outloud so speak at them"
)


def describe_scene(
    frame: np.ndarray,
    model: str = MODEL,
    *,
    image_width: int = 512,
    timeout: float = 25.0,
) -> str:
    """Send one BGR camera snapshot to Gemini and return a text description."""
    api_key = os.environ.get("GEMINI_API_KEY")
    if not api_key:
        raise RuntimeError("GEMINI_API_KEY is not set")
    if frame is None or frame.size == 0:
        raise ValueError("Cannot describe an empty frame")
    if image_width < 1 or timeout <= 0:
        raise ValueError("image_width and timeout must be positive")

    height, width = frame.shape[:2]
    if width > image_width:
        frame = cv2.resize(
            frame,
            (image_width, max(1, round(height * image_width / width))),
            interpolation=cv2.INTER_AREA,
        )

    ok, jpeg = cv2.imencode(
        ".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, 75]
    )
    if not ok:
        raise RuntimeError("Could not encode camera snapshot as JPEG")

    # Optional dependency: only import when Gemini captioning is enabled.
    from google import genai
    from google.genai import types

    client = genai.Client(
        api_key=api_key,
        http_options=types.HttpOptions(timeout=int(timeout * 1000)),
    )
    try:
        response = client.interactions.create(
            model=model,
            input=[
                {"type": "text", "text": PROMPT},
                {
                    "type": "image",
                    "data": base64.b64encode(jpeg.tobytes()).decode("ascii"),
                    "mime_type": "image/jpeg",
                },
            ],
            generation_config={
                "thinking_level": (
                    "minimal" if model == "gemini-3.5-flash-lite" else "low"
                )
            },
        )
        description = (response.output_text or "").strip()
        if not description:
            raise RuntimeError("Gemini returned no scene description")
        return description
    finally:
        client.close()
