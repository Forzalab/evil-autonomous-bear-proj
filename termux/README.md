# Termux phone rig

Run barnaby on an Android phone with Termux and the Termux:API app. No laptop.

- `bear.sh`: one-file menu. It installs packages, gets this branch, applies a camera patch (`--source termux:ID`), checks which way the camera frame is turned (finger test), and runs the bear live or on a recorded video.
- Testing mode (menu 9, ON by default): each LIVE run starts with a 2-photo finger test (no hand → back to the menu), prints labels in huge sideways letters, and adds `debug` (raw size, ROTATE/MIRROR, finger test) to each JSON event (`BEAR_DEBUG=1`). Turn it OFF for the real show.
- Bear talks (menu 10, online): photo → `google/gemini-3.8-flash` on OpenRouter (ZDR endpoints only) → one short bear line → `termux-tts-speak`. Asks once for the key (→ `~/.bear.key`, chmod 600); `BEAR_LLM=gemini` uses a Google key (`~/.bear-gemini.key`) instead.
  Each request is fresh: rules + a ≤120-word text memory of the last answer (reset after errors or 60 s) + one 320 px photo. Local vision still drives all motion.
- `probe.sh`: a read-only phone check. It copies a report to the clipboard.
- `PHONE-CAM-SPEC.md`: the phone cameras compared with the Pi camera.

Start: `bash termux/bear.sh` (or `bash ~/storage/downloads/bear.sh`). Live camera is about 0.65 fps, so use a recorded video for real debounce counts.
