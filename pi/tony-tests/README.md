# tony-tests (Pi #1 snapshot)

These are copies of `~/tony-tests` on Pi #1 (user `spauly`). They run there, not from this repo. They read McKay's checkout (`~/Desktop/barnaby/evil-autonomous-bear-proj`) and its `.venv` and never edit them.

- `boot.sh`: run by cron `@reboot /bin/bash /home/spauly/tony-tests/boot.sh`, logging to `boot.log`. Its only spoken line is the greeting to Logan and Yousaf.
  - Steps: Bluetooth speaker in A2DP mode at max volume → wifi by name `SC_GUEST` → one-shot pin hunt if the `RUN_PIN_HUNT` flag file exists (also needs `RUN_WHEELS` for wheels) → starts `bear_loop.sh` (skip with `NO_BEAR`) → starts `claude rc` if online.
  - `DRY=1` runs it without touching any GPIO pin.
- `pin_hunt.sh [pins...]`: announces each pin by voice, pulses it for 0.7 s, then waits. Phase 2 is the wheels, using `wheel_test` built from `~/test2.cc`. Set `NO_WHEELS=1` to skip it.
- `say.py`: speaks through McKay's Piper TTS and waits until playback has finished. Exiting earlier makes it silent.
- `dance_launch.py`: runs McKay's app with `barnaby.app.on_perception` wrapped by `bear_decider.bridge` at runtime. Each dance also speaks a canned line. Gemini is off unless you pass `--gemini` or answer y at the prompt. Gemini is capped at `GEMINI_MAX` calls per run (default 5), then the bear just says "Quack quack!". Run it from McKay's repo: `.venv/bin/python ~/tony-tests/dance_launch.py --source 0`. For the trigger that works, set `BEAR_DANCE_BIN=~/tony-tests/dance_sda.sh`.
- `bear_loop.sh`: keeps the bear running forever (camera → hand → SDA1 dance + yell, no Gemini) and restarts it after a crash. Stop it: `touch ~/tony-tests/NO_BEAR` and `pkill -f tony-tests/dance_launch.py`.
- `dance_sda.sh`: **the trigger that works.** SIG is on SDA1 (BCM2), so the relay is ON at rest. The script switches it OFF for 0.3 s (`SDA_OFF_S`), then ON again. Danced 3/3. See `HARDWARE_LOG.md`.
- `pulse_seq.sh [COUNTxMS[@GAP] ...]`: runs announced relay pulse tests on BCM17, 25 s apart by default.
- `gremlin_show.py`: a short scripted show with a gremlin voice, kawaii quacks, 2 dances and a wheel wiggle. `DRY=1` and `VOICE_ONLY=1` are available.
- `HARDWARE_LOG.md`: wiring faults and test results.

Undo: run `crontab -e`, delete the line, then `rm ~/tony-tests/boot.sh`.
