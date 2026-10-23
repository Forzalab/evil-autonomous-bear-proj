"""creepy_show.py — dance + 25 s of gremlin cackles, creepy noises and random wheel wiggles, then dance again.
Reuses gremlin_show.py helpers. Kid-safe spooky. No camera, no Gemini. DRY=1 prints only. SEED=n repeats a run.
Run: $PY claude/pi/creepy_show.py  (PY = the checkout's .venv python)
"""
import os, random, subprocess, sys, tempfile, time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gremlin_show as g  # gremlin(), quack(), demon(), dance(), wheels(), idle_pins(), log(), speak_fx()

WHISPER_FX = ["pitch", "-300", "tempo", "0.75", "tremolo", "5", "40", "reverb", "80"]
SEED = int(os.environ.get("SEED", time.time()))
rng = random.Random(SEED)


def creepy_noise():
    """Random synthesized spooky sound: low wobbling drone, rising ghost whistle, or creaky door."""
    kind = rng.choice(["drone", "ghost", "creak"])
    g.log(f"NOISE: {kind}")
    if g.DRY:
        return
    synth = {
        "drone": ["synth", "3", "sine", "48", "sine", "51", "tremolo", "3", "70", "reverb", "70", "fade", "0.4", "3", "1"],
        "ghost": ["synth", "2.5", "sine", "400-900", "tremolo", "6", "50", "reverb", "90", "fade", "0.3", "2.5", "0.8"],
        "creak": ["synth", "2", "sawtooth", "90-60", "tremolo", "18", "90", "lowpass", "900", "reverb", "40", "fade", "0.1", "2", "0.5"],
    }[kind]
    with tempfile.TemporaryDirectory(prefix="creepy-") as d:
        out = Path(d) / "noise.wav"
        subprocess.run(["sox", "-n", "-r", "22050", str(out), *synth, "vol", "0.6"], check=True, timeout=30)
        subprocess.run(["pw-play", str(out)], check=True, timeout=30)


def whisper(text):
    g.log(f'WHISPER: "{text}"')
    g.speak_fx(text, WHISPER_FX)


def random_wiggle():
    which = rng.choice(["1", "2", "both"])
    steps = rng.choice([70, 140, 210])  # ~0.5–1.5 s, wheels in the air
    g.wheels(which, steps, rng.choice(["fwd", "back"]))


def show():
    creepy_noise()
    whisper("Barnaby is waking up...")
    g.dance(1)
    t1 = time.monotonic()
    acts = [lambda: g.gremlin(rng.choice(["Hehehehe!", "Hihihi, who's there?", "Ooooh, a tiny human!"])),
            creepy_noise, random_wiggle,
            lambda: whisper(rng.choice(["I see you...", "Come closer...", "Do you like my dance?"]))]
    while time.monotonic() - t1 < 21:  # fill the ~25 s dance lockout, leave time for the last act
        rng.choice(acts)()
    wait = 25.0 - (time.monotonic() - t1)
    if wait > 0:
        g.log(f"WAIT {wait:.1f}s (25 s after dance #1)")
        if not g.DRY:
            time.sleep(wait)
    g.dance(2)
    g.gremlin("Hehehe! Again! Again!")
    g.quack("Quack quack! Bye bye, tiny humans! Uwu!")


def main():
    mode = "DRY" if g.DRY else "LIVE"
    g.log(f"=== creepy_show start ({mode}, SEED={SEED}) ===")
    try:
        show()
        g.log("=== show complete ===")
    except KeyboardInterrupt:
        g.log("INTERRUPTED (Ctrl-C)")
    finally:
        g.idle_pins()
        g.log(f"=== end, total {time.monotonic() - g.T0:.1f}s ===")


if __name__ == "__main__":
    import signal
    signal.signal(signal.SIGINT, g.on_sigint)
    main()
