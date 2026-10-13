"""bear_voices.py — funny Halloween voices + meta-aware lines for Barnaby at Clovis Community College.
Kid-safe. Reuses gremlin_show.speak_fx (Piper + sox chain + pw-play). DRY=1 prints only.
CLI: $PY bear_voices.py demo | say VOICE "text" | random
"""
import random, sys
from pathlib import Path

sys.path.insert(0, str(Path.home() / "tony-tests"))
import gremlin_show as g

# Legibility EQ added to every voice: cut rumble/mud below 150 Hz, boost speech presence at 3 kHz, tame harsh highs.
CLEAR = ["highpass", "150", "equalizer", "3000", "1.2q", "+6", "equalizer", "250", "1q", "-3", "lowpass", "7500", "gain", "-n", "-1"]

# sox effect chains for each character voice: milder pitch shifts, slower tempo, light reverb (legible first, spooky second)
VOICES = {
    "narrator": ["pitch", "-100", "tempo", "0.85", "reverb", "10"],
    "witch":    ["pitch", "+250", "tempo", "0.82", "flanger", "0", "2", "0", "40", "0.5", "sine", "25", "lin", "reverb", "15"],
    "ghost":    ["pitch", "-120", "tempo", "0.75", "tremolo", "4", "25", "reverb", "40"],
    "zombie":   ["pitch", "-300", "tempo", "0.7", "overdrive", "4", "reverb", "15"],
    "robot":    ["phaser", "0.8", "0.74", "3", "0.3", "0.5", "-t", "tempo", "0.8"],
    "chipmunk": ["pitch", "+600", "tempo", "0.95", "reverb", "10"],
    "gremlin":  ["pitch", "+500", "tempo", "0.85", "tremolo", "9", "15", "echo", "0.8", "0.7", "60", "0.15"],
    "kawaii":   ["pitch", "+650", "tempo", "0.75", "chorus", "0.6", "0.9", "50", "0.3", "0.25", "2", "-s", "reverb", "10"],
}
VOICES = {name: fx + CLEAR for name, fx in VOICES.items()}

PREAMBLE = ("We the People of the United States, in Order to form a more perfect Union, establish Justice, "
            "insure domestic Tranquility, provide for the common defence, promote the general Welfare, "
            "and secure the Blessings of Liberty to ourselves and our Posterity, do ordain and establish "
            "this Constitution for the United States of America.")

BRAINROT = [  # kid-safe Gen Alpha slang
    ("chipmunk", "Skibidi bear in Ohio! No cap!"),
    ("robot",    "Warning. Rizz levels critical. Plus one thousand aura points."),
    ("gremlin",  "Hehehe! Fanum tax! I am taking one candy from every bucket!"),
    ("kawaii",   "This dance is bussin! It's giving... spooky season! Uwu!"),
    ("zombie",   "I am so sigma... I am mewing... do not talk to me..."),
    ("witch",    "Six seven! Six seven! Okay, that one was mid."),
    ("ghost",    "Bro thinks he can escape the dance floor... delulu..."),
    ("narrator", "Born yesterday. Already chronically online. Brainrot level: maximum."),
]

# meta-aware Halloween lines (Barnaby knows where and when he is)
LINES = [
    ("witch",    "Hello, Clovis Community College! I am Barnaby. I was born yesterday!"),
    ("chipmunk", "I was born yesterday, and I already know more than your calculator!"),
    ("zombie",   "Braaaains... I mean... science! This is a STEM event, right?"),
    ("ghost",    "Ooooooh... I am the ghost of Clovis Community College... and I am only one day old..."),
    ("robot",    "System check. Born: yesterday. Location: Clovis. Mood: spooky. Wi-Fi: guest. Very scary."),
    ("witch",    "Trick or treat! I will take the treat. I am a bear. My only trick is dancing!"),
    ("kawaii",   "My creators are students! Please give them an A plus, or I will haunt their homework! Uwu!"),
    ("gremlin",  "Hehehe! They held me together with tape. Lots and lots of tape!"),
    ("zombie",   "I was born yesterday... and I am already tiiiired... is it nap time?"),
    ("robot",    "Warning. Bear is self-aware. Bear would like a pumpkin spice latte."),
    ("ghost",    "Happy Halloween, Clovis... boo... did I scare you? Give me a break, I am one day old."),
    ("chipmunk", "Yesterday I was a box of wires. Today I am a dancing bear. Tomorrow, the robotics club!"),
]


def say(voice, text):
    g.log(f'VOICE[{voice}]: "{text}"')
    try:
        g.speak_fx(text, VOICES[voice])
        return True
    except Exception as e:  # never crash a show over one line
        g.log(f"voice error ({voice}): {e!r}")
        return False


def _render(text, fx, out):
    """Piper → sox fx → out.wav (22050 Hz mono)."""
    import subprocess, wave
    raw = str(out) + ".raw.wav"
    with wave.open(raw, "wb") as wf:
        g.voice().synthesize_wav(text, wf)
    subprocess.run(["sox", raw, "-r", "22050", "-c", "1", str(out), *fx], check=True, timeout=60,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def _stutter(word, rng):
    """'skibidi' → 'ski- ski- skibidi' (only for words long enough to read clearly)."""
    if len(word) < 4 or not word[0].isalpha():
        return word
    part = word[: rng.choice([2, 3])]
    return f"{part}- " * rng.choice([1, 2, 3]) + word


def glitch_say(text, rng=random):
    """Say a line as if the bear is glitching: chunks in random voices, stuttered words, static bursts, a reversed blip."""
    import subprocess, tempfile
    words = text.split()
    n = max(2, min(4, len(words) // 3))
    cuts = sorted(rng.sample(range(1, len(words)), min(n - 1, len(words) - 1)))
    chunks = [" ".join(words[a:b]) for a, b in zip([0] + cuts, cuts + [len(words)])]
    g.log(f'GLITCH: "{text}" → {len(chunks)} chunks')
    if g.DRY:
        return True
    try:
        with tempfile.TemporaryDirectory(prefix="glitch-") as d:
            parts = []
            for i, chunk in enumerate(chunks):
                chunk = " ".join(_stutter(w, rng) if rng.random() < 0.3 else w for w in chunk.split())
                voice = rng.choice(list(VOICES))
                out = f"{d}/{i:02d}.wav"
                _render(chunk, VOICES[voice], out)
                if rng.random() < 0.25:  # play this chunk backwards then forwards, like a skipping tape
                    subprocess.run(["sox", out, f"{d}/{i:02d}r.wav", "reverse", "trim", "0", "0.25"], check=True)
                    parts.append(f"{d}/{i:02d}r.wav")
                parts.append(out)
                g.log(f"  chunk {i + 1} [{voice}]: {chunk}")
                if rng.random() < 0.5:  # static burst between chunks
                    bz = f"{d}/{i:02d}bz.wav"
                    subprocess.run(["sox", "-n", "-r", "22050", "-c", "1", bz, "synth", str(rng.choice([0.08, 0.15, 0.25])),
                                    "whitenoise", "bandpass", "2500", "1q", "vol", "0.35"], check=True)
                    parts.append(bz)
            mix = f"{d}/glitch.wav"
            subprocess.run(["sox", *parts, mix, "gain", "-n", "-1"], check=True, timeout=60)
            subprocess.run(["pw-play", mix], check=True, timeout=120)
        return True
    except Exception as e:  # never crash a show over one line
        g.log(f"glitch error: {e!r}")
        return False


def say_random(rng=random):
    voice, text = rng.choice(LINES)
    return say(voice, text)


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "demo"
    if cmd == "say":
        say(sys.argv[2], " ".join(sys.argv[3:]))
    elif cmd == "random":
        say_random()
    elif cmd == "constitution":
        say("narrator", PREAMBLE)
    elif cmd == "glitch":
        for voice, text in random.sample(BRAINROT + LINES, 8):
            glitch_say(text)
    elif cmd == "brainrot":
        for voice, text in random.sample(BRAINROT, len(BRAINROT)):
            say(voice, text)
    else:  # demo: one line per voice
        seen = set()
        for voice, text in LINES:
            if voice not in seen:
                seen.add(voice)
                say(voice, text)
