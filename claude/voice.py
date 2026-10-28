"""Blocking speech on McKay's TTS: speak, then wait until pw-play/aplay has finished (or max_s)."""

import time


def speak_wait(speech, text: str, max_s: float = 30.0) -> None:
    """`speech` = barnaby.speech. Returns at once when TTS is off (BARNABY_TTS != 1: no worker)."""
    speech.speak(text)
    w, deadline, started = speech._worker, time.monotonic() + max_s, False
    # The worker plays in its own thread: wait for playback to start, then to finish.
    while w is not None and time.monotonic() < deadline:
        if w._playback is not None:
            started = True
        elif started or not w._thread.is_alive():
            break
        time.sleep(0.1)
