# claude/ — our code, branched off below McKay's core

Everything we add lives in this one folder. McKay's files (`src/barnaby/`, `tests/`, `pyproject.toml`,
`.gitignore`, ...) are **byte-identical to his main**. Nothing is patched on disk: `python -m claude`
imports his app and rebinds two names on `barnaby.app` at runtime, then calls his `main()`.

```
barnaby (McKay core, untouched)
  src/barnaby/app.py  main() loop ── calls on_perception(event) / submits describe_scene(...)
        │                               (looked up by name in barnaby.app at call time)
        ▼
python -m claude  (claude/__main__.py, imported before main() runs)
  ├─ wraps barnaby.app.on_perception ──► original (prints his JSON line)
  │                                   └► claude.bridge.handle(event)
  │                                        └► claude.trigger.OneShot (any hand, 25 s cooldown)
  │                                             └► spawn $BEAR_DANCE_BIN  (default claude/pi/dance_sda.sh)
  │                                                  └► relay on SDA1 → bear "Try Me" → DANCE
  │                                        └► on fire: yell a PRETEXT line via barnaby.speech.speak
  ├─ wraps barnaby.app.describe_scene ──► Gemini cap: GEMINI_MAX calls (default 5), then "Quack quack!"
  └─ adds --gemini  (strips it, passes --scene --scene-model gemini-3.5-flash-lite to his main)
```

## Layout

| path | what |
|---|---|
| `__main__.py` | launcher: the runtime reroute above (port of the Pi's `~/tony-tests/dance_launch.py`) |
| `trigger.py` | `OneShot`: one dance per shown gesture; duck-typed (event needs only `.gesture`), no barnaby import |
| `bridge.py` | `DanceBridge`: OneShot → non-blocking spawn of `BEAR_DANCE_BIN`; dry-run if missing; never raises |
| `hw/` | C++ for the Pi (`dance.cc`, `bear_auto.cc`, `run_both.cc`, `wheel_real.cc`, `sos_real.cc`, `step_pin.cc`) + [`hw/HARDWARE_LOG.md`](hw/HARDWARE_LOG.md) |
| `pi/` | Pi shell/Python scripts (boot, forever loop, SDA1 trigger, edge/pin tests, voices, shows) — see [`pi/README.md`](pi/README.md) |
| `tests/` | tests that need no Pi |

## Run

From the repo root (McKay's checkout with this folder in it), using his venv:

```
PYTHONPATH=src .venv/bin/python -m claude --source 0             # camera → hand → dance + yell
PYTHONPATH=src .venv/bin/python -m claude --gemini --source 0    # + Gemini scene talk (capped)
PYTHONPATH=src .venv/bin/python -m claude --check                # verify models, no camera
```

- Any of McKay's barnaby flags pass through (`--headless`, `--picamera`, `--scene`, ...).
- No `--gemini`: on a TTY it asks `Enable Gemini scene talk this session? [y/N]`; with no TTY (e.g. `bear_loop.sh`) Gemini stays off.
- Env: `BEAR_DANCE_BIN` (dance command; default `claude/pi/dance_sda.sh`), `GEMINI_MAX` (default 5),
  `BARNABY_TTS=1` to hear yells (McKay's speech worker), `SDA_OFF_S` (relay-off blip, default 0.3 s).
- If `BEAR_DANCE_BIN` doesn't exist the bridge prints `DANCE (dry-run: ...)` to stderr and still yells.
- On the Pi, `pi/bear_loop.sh` (started by `pi/boot.sh` from cron) runs it forever: `python -u -m claude --source 0`, restart on crash, log `~/tony-tests/bear_loop.log`.

## Stop

- Foreground: `Q` in the preview window, or Ctrl-C.
- Forever loop on the Pi: `touch ~/tony-tests/NO_BEAR; pkill -f 'python -u -m claude'`. Resume: `rm ~/tony-tests/NO_BEAR` and run `claude/pi/bear_loop.sh`.

## Test

```
python3 -m unittest discover -s claude/tests        # from the repo root
for f in claude/pi/*.sh; do bash -n "$f"; done      # shell syntax
PYTHONPATH=src python3 -m unittest discover -s tests # McKay's own tests, unchanged
```

- `test_bridge.py`: OneShot + DanceBridge (cooldown, flicker, re-arm, running child, dry-run, env binary) and
  the runtime wiring: importing `claude.__main__` replaces `barnaby.app.on_perception` with a wrapper that calls
  his original, then the bridge; bridge errors never escape; Gemini cap; `--gemini` args; default dance bin.
  The wiring tests skip with a reason if McKay's app can't be imported (needs `opencv-python`, `numpy`).
- `test_dance_cc.py`, `test_bear_auto_cc.py`: compile `hw/*.cc` with `g++` against a fake wiringPi and check the
  GPIO call sequence (skip if no `g++`).
- `test_edge_test.py`: runs `pi/edge_test.sh` with `DRY=1`.

## Hardware notes

- **Trigger:** relay SIG on **SDA1** (BCM2, physical pin 3). SDA1's on-board pull-up means relay ON at rest;
  `pi/dance_sda.sh` drives it LOW for 0.3 s (relay OFF) then releases it (ON). Danced 3/3. Short ON pulses on
  BCM17 did not (after the wiring was taped). Try Me ignores re-triggers for ~22 s, hence the 25 s cooldown.
- **Wheels (steppers, BCM):** wheel 1 **STEP 13 / DIR 26**, wheel 2 **STEP 16 / DIR 21** (verified on the Pi
  2026-10-13; `hw/bear_auto.cc`, `hw/run_both.cc`, `hw/wheel_real.cc`).
- **Vref:** set each stepper driver's current limit (Vref pot) per its datasheet *before* connecting motors;
  motors plug in only with 12 V OFF. The value used is not recorded yet; log it in `hw/HARDWARE_LOG.md`.
- **Power:** the Pi rebooted 3× while relay/wheels ran on a power bank; use a steady 5 V / 5 A supply.
- Build lines are at the top of each `hw/*.cc` (`g++ -O2 ... -lwiringPi`); binaries are git-ignored (`claude/.gitignore`).
- Full log: [`hw/HARDWARE_LOG.md`](hw/HARDWARE_LOG.md).
