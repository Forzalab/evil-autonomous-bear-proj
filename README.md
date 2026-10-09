# Barnaby Bear

Python and OpenCV for hand gestures and facial expressions on a Pi 5.
The four model files are included in the repo. Demo videos are downloaded separately.

## Set up on Linux

Use 64-bit Raspberry Pi OS and Python 3.10-3.13.
Replace YOUR_REPO_URL with your GitHub repo URL.

```bash
sudo apt update
sudo apt install -y git python3-venv libgl1 libglib2.0-0
git clone YOUR_REPO_URL barnaby-proj
cd barnaby-proj
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install --only-binary=:all: -r requirements.txt
python -m barnaby --check
```

If you already cloned the repo, start at `cd barnaby-proj`.
The check runs all four models without a camera.

## Run

USB webcam:

```bash
python -m barnaby --source 0
```

Use `--source 1` if the camera is on a different index.
Add `--headless` when running over SSH or without a desktop.
Press Q in the preview or Ctrl+C in the terminal to stop.

Without a webcam, download and run the sample video:

```bash
python -m barnaby.demo
```

Add `--once --headless` to run it once over SSH.

## Pi CSI camera

For a Camera Module plugged into the Pi's camera connector, use this setup
instead of the USB webcam environment:

```bash
sudo apt install -y python3-picamera2 python3-opencv python3-numpy
python3 -m venv --system-site-packages .venv-camera
source .venv-camera/bin/activate
python -m pip install --no-deps -e .
python -m barnaby --check
python -m barnaby --picamera --headless
```

This requires the OS OpenCV package to be version 4.10 or newer.
Remove `--headless` to show the preview on a desktop.

## Trigger (opt-in)

`--trigger GESTURE` prints `BEAR: dance` once each time that gesture is shown.
A cooldown and a re-arm delay (the gesture must be gone for 1 s) keep a held
hand, a face change, or a flickering hand from firing it again.

```bash
python -m barnaby --trigger thumbs_up
```

`--trigger-cooldown SECONDS` sets the cooldown (default 20).
Cooldown = measure one full dance on the real bear, then set `--trigger-cooldown`.

## After PC changes

Commit and push on the PC. Then, from the repo folder on the Pi:

```bash
git pull --ff-only
source .venv/bin/activate
python -m barnaby --source 0 --headless
```

Use `.venv-camera/bin/activate` and `--picamera` for a CSI camera.
If dependencies changed, repeat the install command for your environment.

## Where to edit

- `src/barnaby/reactions.py`: add Barnaby's reactions to detected gestures/expressions.
- `src/barnaby/gestures.py`: change the gesture rules.
- `src/barnaby/vision.py`: change model inference.

The current gestures are open palm, fist, peace, pointing, middle finger, and thumbs up.
Expression labels describe facial appearance. Motion gestures such as waving
are not implemented yet.
