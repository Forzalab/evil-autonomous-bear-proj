
"""Piper speech with demon voice effects, running in the background."""

import atexit
import os
from pathlib import Path
from queue import Queue, Empty, Full
import re
import shutil
import subprocess
import tempfile
from threading import Thread, Event, Lock
import wave


VOICE_PATH = (
    Path(__file__).resolve().parents[2]
    / "voices"
    / "en_US-ryan-medium.onnx"
)


def clean_for_speech(text: str) -> str:
    """Remove Gemini's nonspoken stage directions and formatting."""
    text = re.sub(r"\*[^*]*\*", " ", text)
    text = re.sub(r"(?m)^\s*[-#]+\s*", "", text)
    text = re.sub(r"\s+", " ", text.replace("`", "")).strip()
    return text


class SpeechWorker:
    """Process Gemini responses without blocking the camera."""

    def __init__(self, voice_path: Path = VOICE_PATH):
        self.voice_path = Path(voice_path)
        self._queue: Queue[str | None] = Queue(maxsize=1)
        self._stop = Event()
        self._thread = Thread(
            target=self._run,
            name="barnaby-demon-tts",
            daemon=True,
        )
        self._playback = None

    def start(self) -> None:
        if not self.voice_path.is_file():
            raise FileNotFoundError(
                f"Piper voice not found: {self.voice_path}"
            )

        for executable in ("sox", "aplay"):
            if shutil.which(executable) is None:
                raise RuntimeError(
                    f"{executable} is missing. Install sox and alsa-utils."
                )

        self._thread.start()
        atexit.register(self.stop)

    def say(self, text: str) -> None:
        """Queue the newest response, discarding old pending speech."""
        text = clean_for_speech(text)

        if not text or self._stop.is_set():
            return

        try:
            self._queue.put_nowait(text)
        except Full:
            try:
                self._queue.get_nowait()
            except Empty:
                pass

            try:
                self._queue.put_nowait(text)
            except Full:
                pass

    def _run(self) -> None:
        """Load Piper once and process incoming speech requests."""
        try:
            from piper import PiperVoice

            voice = PiperVoice.load(str(self.voice_path))
            print("[Barnaby TTS] Piper voice loaded", flush=True)

        except Exception as error:
            print(f"[Barnaby TTS] Could not load voice: {error}", flush=True)
            return

        while not self._stop.is_set():
            text = self._queue.get()

            if text is None or self._stop.is_set():
                break

            try:
                self._play(voice, text)
            except Exception as error:
                if not self._stop.is_set():
                    print(f"[Barnaby TTS] Speech error: {error}", flush=True)

    def _play(self, voice, text: str) -> None:
        """Convert text to WAV, apply demon effects, and play audio."""

        with tempfile.TemporaryDirectory(
            prefix="barnaby-tts-"
        ) as directory:

            normal_wav = Path(directory) / "piper.wav"
            demon_wav = Path(directory) / "demon.wav"

            # 1. Generate speech with Piper.
            with wave.open(str(normal_wav), "wb") as wav_file:
                voice.synthesize_wav(text, wav_file)

            if self._stop.is_set():
                return

            # 2. Apply Barnaby's demon voice effects.
            subprocess.run(
                [
                    "sox",
                    str(normal_wav),
                    str(demon_wav),
                    "pitch", "-650",
                    "tempo", "0.90",
                    "reverb", "30",
                ],
                check=True,
                timeout=60,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                text=True,
            )

            if self._stop.is_set():
                return

            # 3. Play through Raspberry Pi audio output.
            process = subprocess.Popen(
                ["aplay", "-q", str(demon_wav)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
            )

            self._playback = process

            try:
                _, errors = process.communicate(timeout=120)

                if process.returncode != 0 and not self._stop.is_set():
                    raise RuntimeError(
                        "aplay failed: "
                        + errors.decode(errors="replace").strip()
                    )

            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate()

                self._playback = None

    def stop(self) -> None:
        """Stop speech when Barnaby exits."""
        self._stop.set()

        process = self._playback
        if process is not None and process.poll() is None:
            process.terminate()

        try:
            self._queue.put_nowait(None)
        except Full:
            try:
                self._queue.get_nowait()
                self._queue.put_nowait(None)
            except (Empty, Full):
                pass

        if self._thread.is_alive():
            self._thread.join(timeout=2)


_worker: SpeechWorker | None = None
_worker_lock = Lock()


def speak(text: str) -> None:
    """Send Gemini's text to the demon voice worker."""
    global _worker

    if os.environ.get("BARNABY_TTS") != "1":
        return

    if _worker is None:
        with _worker_lock:
            if _worker is None:
                worker = SpeechWorker()
                worker.start()
                _worker = worker

    _worker.say(text)
