# claude/pi — Pi scripts (run from this checkout)

Everything lives in ONE folder, `BEAR_HOME` (default: the folder above this checkout, e.g. `~/tony`):

```
~/tony/            BEAR_HOME. Uninstall = delete the cron line + rm -rf ~/tony
  bear/            this checkout (fork, tony/pi-tools). McKay's src/, tests/, pyproject.toml = read-only
    .venv/         own venv: pip install -r requirements.txt
    claude/hw/*    built C++ (git-ignored)
  state/           logs + flags (NO_BEAR, RUN_PIN_HUNT, RUN_WHEELS)
```

`env.sh` (sourced by every script) sets `$REPO`, `$PI`, `$HW`, `$T` (= state/), `$PY` (= .venv python) and `XDG_RUNTIME_DIR` from the current user. No user name or home path is hardcoded.

- `boot.sh`: run by cron `@reboot /bin/bash ~/tony/bear/claude/pi/boot.sh`, logging to `state/boot.log`. Its only spoken line is the greeting to Logan and Yousaf.
  - Steps: Bluetooth speaker in A2DP mode at max volume → wifi by name `SC_GUEST` → one-shot pin hunt if the `RUN_PIN_HUNT` flag file exists (also needs `RUN_WHEELS` for wheels) → starts `bear_loop.sh` (skip with `NO_BEAR`) → starts `claude rc` if online.
  - `DRY=1` runs it without touching any GPIO pin.
- `pin_hunt.sh [pins...]`: announces each pin by voice, pulses it for 0.7 s, then waits. Phase 2 is the wheels, using `claude/hw/wheel_test` (old pins; prefer `run_both`). Set `NO_WHEELS=1` to skip it.
- `say.py`: speaks through McKay's Piper TTS and waits until playback has finished. Exiting earlier makes it silent.
- `bear_loop.sh`: keeps the bear running forever (camera → hand → SDA1 dance + yell, no Gemini) and restarts it after a crash. Stop it: `touch ~/tony/state/NO_BEAR` and `pkill -f 'python -u -m claude'`.
- `dance_sda.sh`: **the trigger that works.** SIG is on SDA1 (BCM2), so the relay is ON at rest. The script switches it OFF for 0.3 s (`SDA_OFF_S`), then ON again. Danced 3/3. See `HARDWARE_LOG.md`.
- `pulse_seq.sh [COUNTxMS[@GAP] ...]`: runs announced relay pulse tests on BCM17, 25 s apart by default.
- `gremlin_show.py`: a short scripted show with a gremlin voice, kawaii quacks, 2 dances and a wheel wiggle. `DRY=1` and `VOICE_ONLY=1` are available.
- `HARDWARE_LOG.md`: wiring faults and test results.

Undo: run `crontab -e`, delete the line, then `rm -rf ~/tony`.
