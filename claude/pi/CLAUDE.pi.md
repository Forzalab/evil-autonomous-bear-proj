# CLAUDE.md — Pi deploy agent (Barnaby bear)

Copy to `~/tony/CLAUDE.md`. Start Claude sessions on this Pi from `~/tony` so this file loads (subagents too).

## Scope
- Project: Barnaby bear only. Everything lives in `~/tony` (BEAR_HOME): `bear/` = fork checkout, `state/` = logs + flags.
- Paths come from `bear/claude/pi/env.sh`. Never hardcode a user or home path.
- Any change outside `~/tony` (apt, BT pairing, crontab, wifi) → one line in `~/tony/FOOTPRINT.md`. Uninstall = cron line + `rm -rf ~/tony`.
- McKay's files (`src/`, `tests/`, `pyproject.toml`, `requirements.txt`) are read-only. Our code goes in `claude/` only.

## Gates (ask the human at the Pi first)
- Any GPIO / relay / wheel action: `dance_sda.sh`, `edge_test.sh`, `pulse_seq.sh`, `pin_hunt.sh`, `wheel_pin_hunt.sh`, `claude/hw/*`.
- Any `sudo` beyond `apt install`, any reboot, any crontab change.
- The relay SIG on SDA1 (BCM2) is pulled up: the relay closes at power-on, so the bear may dance once at boot.
- One test, one change at a time. A reboot under load means suspect power before code.

## Brain (shared memory) — relay only
- This Pi has NO brain token, and must never get one. The brain is private and this Pi is shared.
- The cloud session `session_01J1m2huF1hcF3fBHn34LbxK` is the relay. It writes only `projects/cocaine-bear/` in brain.
- To SAVE: `send_message` to the relay with lines starting `BRAIN:` (one fact per line: date PT, what, proof/log path).
- To READ: `send_message` to the relay with `BRAIN? <question>`. It answers from `projects/cocaine-bear/` only.
- Send a relay message:
  - after every lane PASS/FAIL,
  - when a hardware fact is found (pin, Vref, which edge dances, device path),
  - before any reboot,
  - at least every ~15 min while working.
- Never send secrets (keys, `.env`, passwords, tokens) to the relay or anywhere else.

## Report format
`LANE <name>: PASS|FAIL — <one line> — log: <path>`
