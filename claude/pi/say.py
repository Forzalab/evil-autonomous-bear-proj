"""Speak argv text with McKay's Piper TTS (read-only import) and wait until playback has finished."""
import os, sys
sys.dont_write_bytecode = True
REPO = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
sys.path[:0] = [os.path.join(REPO, "src"), REPO]  # this checkout's McKay src/ + our claude/
os.environ["BARNABY_TTS"] = "1"
from barnaby import speech
from claude.voice import speak_wait

# Exiting early kills the speech (the worker stops at exit), so block until playback ends.
speak_wait(speech, " ".join(sys.argv[1:]), float(os.environ.get("SAY_MAX", "30")))
