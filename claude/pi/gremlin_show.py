"""gremlin_show.py — short silly bear show: gremlin voice + quacks + dance + wheel wiggle.
No camera, no Gemini. Run with McKay's venv python (read-only use). DRY=1 prints steps only.
VOICE_ONLY=1 plays one gremlin line and one quack (no GPIO).
"""
import os, sys, time, signal, subprocess, tempfile, wave
from pathlib import Path

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent  # claude/pi
REPO = HERE.parents[1]
HW = REPO / "claude" / "hw"
STATE = Path(os.environ.get("BEAR_HOME", REPO.parent)) / "state"
STATE.mkdir(parents=True, exist_ok=True)
sys.path.insert(0, str(REPO / "src"))
os.environ.setdefault("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")

LOG = STATE / "gremlin_show.log"
VOICE_PATH = REPO / "voices" / "en_US-ryan-medium.onnx"
DRY = os.environ.get("DRY") == "1"
VOICE_ONLY = os.environ.get("VOICE_ONLY") == "1"

GREMLIN_FX = ["pitch", "+700", "tempo", "1.25", "tremolo", "9", "25", "echo", "0.8", "0.7", "60", "0.25"]
# Kawaii quack: high and cute but SLOW (tempo < 1), soft chorus + light reverb instead of the fast squeak.
QUACK_FX = ["pitch", "+800", "tempo", "0.8", "chorus", "0.6", "0.9", "50", "0.4", "0.25", "2", "-s", "reverb", "20"]

T0 = time.monotonic()
_voice = None


def log(msg):
    line = f"{time.strftime('%H:%M:%S')} [+{time.monotonic() - T0:5.1f}s] {msg}"
    print(line, flush=True)
    with open(LOG, "a") as f:
        f.write(line + "\n")


def voice():
    global _voice
    if _voice is None:
        from piper import PiperVoice
        _voice = PiperVoice.load(str(VOICE_PATH))
    return _voice


def speak_fx(text, fx):
    if DRY:
        return
    with tempfile.TemporaryDirectory(prefix="gremlin-") as d:
        raw, out = Path(d) / "raw.wav", Path(d) / "fx.wav"
        with wave.open(str(raw), "wb") as wf:
            voice().synthesize_wav(text, wf)
        subprocess.run(["sox", str(raw), str(out), *fx], check=True, timeout=60,
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        subprocess.run(["pw-play", str(out)], check=True, timeout=60)


def gremlin(text):
    log(f'GREMLIN: "{text}"')
    speak_fx(text, GREMLIN_FX)


def quack(text="Quack quack! Uwu!"):
    log(f'QUACK: "{text}"')
    speak_fx(text, QUACK_FX)


def demon(text):
    log(f'DEMON (say.py): "{text}"')
    if not DRY:
        subprocess.run([sys.executable, str(HERE / "say.py"), text], check=True, timeout=60)


def dance(n):
    log(f"DANCE trigger #{n} (dance_sda.sh)")
    if not DRY:
        subprocess.run([str(HERE / "dance_sda.sh")], check=True, timeout=10)


def wheels(which, steps, direction):
    log(f"WHEELS {which} {steps} {direction}")
    if not DRY:
        subprocess.run([str(HW / "wheel_test"), which, str(steps), direction], check=True, timeout=15)


def idle_pins():
    if DRY:
        log("CLEANUP (dry): would set pin 2 ip pu, 13,20,26,21 ip pd")
        return
    subprocess.run(["pinctrl", "set", "2", "ip", "pu"])
    subprocess.run(["pinctrl", "set", "13,20,26,21", "ip", "pd"])
    log("CLEANUP: pin 2 ip pu (relay normal ON), steppers 13,20,26,21 ip pd")


def on_sigint(sig, frame):
    raise KeyboardInterrupt


def show():
    gremlin("Hehehe! Barnaby's gremlin is loose!")
    dance(1)
    t_dance1 = time.monotonic()
    quack()
    gremlin("Wheee! Zoom zoom!")
    wheels("both", 140, "fwd")
    wheels("both", 140, "back")
    gremlin("Did you see my wiggle? I am very fast!")
    demon("I am the bear. The duck is not with me.")
    quack("Quack quack quack!")
    gremlin("Shhh! Don't tell the bear I'm a duck.")
    wait = 25.0 - (time.monotonic() - t_dance1)
    if wait > 0:
        log(f"WAIT {wait:.1f}s so dance #2 is >=25s after dance #1")
        if not DRY:
            time.sleep(wait)
    dance(2)
    quack()
    gremlin("Bye bye, tiny humans!")


def main():
    signal.signal(signal.SIGINT, on_sigint)
    mode = "DRY" if DRY else ("VOICE_ONLY" if VOICE_ONLY else "LIVE")
    log(f"=== gremlin_show start ({mode}) ===")
    try:
        if VOICE_ONLY:
            gremlin("Hehehe! Barnaby's gremlin is loose!")
            quack()
            return
        show()
        log("=== show complete ===")
    except KeyboardInterrupt:
        log("INTERRUPTED (Ctrl-C)")
    except Exception as e:
        log(f"ERROR: {e!r}")
        raise
    finally:
        if not VOICE_ONLY:
            idle_pins()
        log(f"=== end, total {time.monotonic() - T0:.1f}s ===")


if __name__ == "__main__":
    main()
