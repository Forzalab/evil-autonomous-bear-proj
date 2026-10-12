# tony-tests (Pi #1 snapshot)

These are copies of `~/tony-tests` on Pi #1 (user `spauly`). They run there, not from this repo. They read McKay's checkout (`~/Desktop/barnaby/evil-autonomous-bear-proj`) and its `.venv` and never edit them.

- `boot.sh`: run by cron `@reboot /bin/bash /home/spauly/tony-tests/boot.sh`, logging to `boot.log`.
  - Steps: Bluetooth speaker in A2DP mode at max volume → wifi by name `SC_GUEST` → one-shot pin hunt if the `RUN_PIN_HUNT` flag file exists (also needs `RUN_WHEELS` for wheels) → says "Online" or "Offline".
  - `DRY=1` runs it without touching any GPIO pin.
- `pin_hunt.sh [pins...]`: announces each pin by voice, pulses it for 0.7 s, then waits. Phase 2 is the wheels, using `wheel_test` built from `~/test2.cc`. Set `NO_WHEELS=1` to skip it.
- `say.py`: speaks through McKay's Piper TTS and waits until playback has finished. Exiting earlier makes it silent.
- `dance_launch.py`: runs McKay's app with `barnaby.app.on_perception` wrapped by `bear_decider.bridge` at runtime. Each dance also speaks a canned line. Gemini is off unless you pass `--gemini` or answer y at the prompt. Run it from McKay's repo: `.venv/bin/python ~/tony-tests/dance_launch.py --source 0`.

Undo: run `crontab -e`, delete the line, then `rm ~/tony-tests/boot.sh`.
