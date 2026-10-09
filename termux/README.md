# Termux phone rig

Run barnaby on an Android phone with Termux and the Termux:API app. No laptop.

- `bear.sh`: one-file menu. It installs packages, gets this branch, applies a camera patch (`--source termux:ID`), and runs the bear live or on a recorded video.
- `probe.sh`: a read-only phone check. It copies a report to the clipboard.
- `PHONE-CAM-SPEC.md`: the phone cameras compared with the Pi camera.

Start: `bash termux/bear.sh` (or `bash ~/storage/downloads/bear.sh`). Live camera is about 0.65 fps, so use a recorded video for real debounce counts.
