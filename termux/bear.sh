#!/usr/bin/env bash
# bear.sh: install and run the bear vision program in Termux with the phone camera (numbered menu).
# Run: bash ~/storage/downloads/bear.sh   (first time; then: bash ~/bear.sh, or "bear" after menu 8)
set -u

REPO_URL="${BEAR_REPO_URL:-https://github.com/Forzalab/evil-autonomous-bear-proj}"
BRANCH="tony/one-shot-trigger"
REPO="${BEAR_DIR:-$HOME/evil-autonomous-bear-proj}"
CONF="$HOME/.bear.conf"
LOGS="$HOME/bear-logs"
PROBE="$HOME/bear-probe"
VIDS="$HOME/bear-videos"
PHOTO="${TERMUX_CAMERA_PHOTO:-termux-camera-photo}"
TRIGGER_GESTURE="thumbs_up"   # The README example. Cooldown: the app default.
CAM_ORDER=(3 1 0 2)
CAM_NAMES=([0]="back" [1]="front wide" [2]="back ultrawide" [3]="front (Pi-like)")
# How to hold the phone: always the SAME sideways way, like a fixed Pi camera (the bear never
# turns the picture by itself; no motion sensor is read). Front camera EXIF is always 8 (sensor
# turned 270), so the raw frame is upright when the phone's right edge (S23 side buttons) is on top.
# Tony's orientation test gave ROTATE=0 MIRROR=0, which fits this. Any fixed way works, because 3) measures it.
POSE="SIDEWAYS, screen to you, side buttons on TOP (front camera on your LEFT)"
export DEBIAN_FRONTEND=noninteractive GIT_TERMINAL_PROMPT=0

ok()   { echo "OK: $*"; }
fail() { echo "FAIL: $*"; return 1; }
buzz() { timeout 10 termux-vibrate -d "$1" >/dev/null 2>&1; }
buzz_fail() { local i; for i in 1 2 3; do buzz 150; sleep 0.4; done; }
pause() { read -r -p "Push Enter for the menu. " _ || exit 0; }
stamp() { date +%Y%m%d-%H%M%S; }

conf_get() {  # conf_get KEY DEFAULT: a number saved in ~/.bear.conf.
  local v
  v=$(sed -n "s/^$1=\([0-9]*\)\$/\1/p" "$CONF" 2>/dev/null | tail -n 1)
  echo "${v:-$2}"
}

conf_set() {  # conf_set KEY=VALUE...: set these keys (empty VALUE: remove), keep the other lines.
  local kv lines
  lines=$(cat "$CONF" 2>/dev/null)
  for kv in "$@"; do lines=$(printf '%s\n' "$lines" | grep -v "^${kv%%=*}="); done
  for kv in "$@"; do [ -n "${kv#*=}" ] && lines+=$'\n'"$kv"; done
  printf '%s\n' "$lines" | sed '/^$/d' > "$CONF"
}

cam() {  # The selected camera ID from ~/.bear.conf (default 3).
  local id
  id=$(conf_get CAM 3)
  [[ "$id" =~ ^[0-3]$ ]] || id=3
  echo "$id"
}

turn_env() {  # The orientation test result (3) for the camera code: load_photo() in camera.py.
  BEAR_ROTATE=$(conf_get ROTATE 0); BEAR_MIRROR=$(conf_get MIRROR 0)
  export BEAR_ROTATE BEAR_MIRROR
}

install_self() {  # Copy this script to ~/bear.sh (first run from Downloads).
  local me
  me=$(realpath "$0" 2>/dev/null) || return 0
  [ -f "$me" ] && [ "$me" != "$(realpath "$HOME/bear.sh" 2>/dev/null)" ] || return 0
  cmp -s "$me" "$HOME/bear.sh" && return 0
  cp "$me" "$HOME/bear.sh" && echo "Copied this script to ~/bear.sh"
}

need_bear() {  # The code and Python packages must be there.
  [ -f "$REPO/src/barnaby/camera.py" ] || { fail "the bear code is missing. Do 1) Setup first."; return 1; }
  timeout 60 python -c 'import cv2, numpy' 2>/dev/null || { fail "Python or OpenCV is missing. Do 1) Setup first."; return 1; }
  # A new bear.sh may bring a new camera patch: apply it now (no Setup needed).
  git -C "$REPO" apply --reverse --check "$(patch_file)" 2>/dev/null || patch_repo
}

write_patch() {
cat <<'BEAR_PATCH_END'
diff --git a/src/barnaby/app.py b/src/barnaby/app.py
index 70a74aa..6b13a76 100644
--- a/src/barnaby/app.py
+++ b/src/barnaby/app.py
@@ -45,7 +45,7 @@ def unit_interval(value: str) -> float:
 
 def main(argv=None) -> None:
     parser = argparse.ArgumentParser(description=__doc__)
-    parser.add_argument("--source", default="0", help="USB camera index or video path")
+    parser.add_argument("--source", default="0", help="USB camera index, video path/URL, or termux:ID (Android Termux:API camera)")
     parser.add_argument("--picamera", action="store_true", help="Use a Pi CSI camera via Picamera2")
     parser.add_argument("--model-dir", type=Path, default=DEFAULT_MODEL_DIR)
     parser.add_argument("--width", type=positive, default=640)
@@ -72,7 +72,7 @@ def main(argv=None) -> None:
     args = parser.parse_args(argv)
     if not math.isfinite(args.interval) or args.interval < 0:
         parser.error("--interval must be finite and nonnegative")
-    if args.save_video and not args.picamera and not args.source.isdecimal():
+    if args.save_video and not args.picamera and not args.source.isdecimal() and not args.source.startswith("termux:"):
         if args.save_video.resolve() == Path(args.source).resolve():
             parser.error("--save-video must differ from the input video")
     camera = None
diff --git a/src/barnaby/camera.py b/src/barnaby/camera.py
index d5ec0f8..2b27377 100644
--- a/src/barnaby/camera.py
+++ b/src/barnaby/camera.py
@@ -1,24 +1,139 @@
-"""USB/video input on either machine, or optional Picamera2 CSI input on the Pi."""
+"""USB/video input on either machine, optional Picamera2 CSI input on the Pi,
+or an Android phone camera from Termux via Termux:API (--source termux:0)."""
 
 import math
+import os
+import subprocess
+import sys
+import tempfile
+import threading
 import time
 
 import cv2
 
 
+def photo_turn():
+    """(rotate, mirror) from BEAR_ROTATE / BEAR_MIRROR, which bear.sh sets from its
+    orientation test. Only 0 or 180 is used: a 90/270 turn means the phone was held
+    upright, and it would give a portrait frame that must be cropped; so warn
+    ("hold the phone sideways") and do not turn instead."""
+    global _turn_warned
+    rotate = (os.environ.get("BEAR_ROTATE") or "0").strip()
+    if rotate not in ("0", "180"):
+        if not _turn_warned:
+            _turn_warned = True
+            print(f"WARNING: BEAR_ROTATE={rotate!r} is not used (only 0 or 180); "
+                  "hold the phone sideways instead", file=sys.stderr, flush=True)
+        rotate = "0"
+    return int(rotate), (os.environ.get("BEAR_MIRROR") or "0").strip() == "1"
+
+
+def load_photo(path, size, turn=None):
+    """Termux:API JPEG -> BGR frame of `size` (Pi-like 640x480), or None.
+
+    The raw pixels are always landscape and the EXIF orientation is fixed (8), so
+    ignore EXIF. `turn` is (rotate, mirror), default photo_turn(): mirror (flip
+    left-right) first, then rotate 180, the same order the orientation test uses.
+    A portrait photo (safety net only) is centre-cropped, never squashed.
+    """
+    frame = cv2.imread(path, cv2.IMREAD_COLOR | cv2.IMREAD_IGNORE_ORIENTATION)
+    if frame is None:
+        return None
+    rotate, mirror = photo_turn() if turn is None else turn
+    global last_photo  # TEMP debug for BEAR_DEBUG=1 events (reactions.py)
+    last_photo = {"raw_wh": f"{frame.shape[1]}x{frame.shape[0]}", "rotate": rotate, "mirror": int(mirror)}
+    if mirror:
+        frame = cv2.flip(frame, 1)
+    if rotate == 180:
+        frame = cv2.rotate(frame, cv2.ROTATE_180)
+    h, w = frame.shape[:2]
+    tw, th = size
+    if h > w:
+        global _portrait_warned
+        if not _portrait_warned:
+            _portrait_warned = True
+            print("WARNING: portrait photo from the camera; using the centre only",
+                  file=sys.stderr, flush=True)
+        if w * th > h * tw:
+            cw = h * tw // th
+            frame = frame[:, (w - cw) // 2:(w - cw) // 2 + cw]
+        else:
+            ch = w * th // tw
+            frame = frame[(h - ch) // 2:(h - ch) // 2 + ch]
+    return cv2.resize(frame, size, interpolation=cv2.INTER_AREA)
+
+
+_portrait_warned = _turn_warned = False
+last_photo = None
+
+
+class TermuxCamera:
+    """Loops `termux-camera-photo` in a thread; read() returns the newest unseen frame as BGR."""
+
+    def __init__(self, camera_id: str, width: int, height: int, timeout: float = 20.0):
+        self.size, self.timeout = (width, height), timeout
+        self._dir = tempfile.TemporaryDirectory(prefix="barnaby-termux-")
+        self._cond = threading.Condition()
+        self._frame, self._seq, self._seen, self._error = None, 0, 0, None
+        self._stop = threading.Event()
+        self._cmd = [os.environ.get("TERMUX_CAMERA_PHOTO", "termux-camera-photo"), "-c", camera_id]
+        self._thread = threading.Thread(target=self._run, daemon=True)
+        self._thread.start()
+
+    def _run(self):
+        path = os.path.join(self._dir.name, "shot.jpg")
+        while not self._stop.is_set():
+            try:
+                os.unlink(path)
+            except FileNotFoundError:
+                pass
+            try:
+                result = subprocess.run(self._cmd + [path], capture_output=True, text=True, timeout=self.timeout)
+                frame = load_photo(path, self.size) if os.path.exists(path) else None
+                if frame is None:
+                    raise RuntimeError(f"termux-camera-photo gave no image: {(result.stdout + result.stderr).strip()!r}")
+            except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
+                with self._cond:
+                    self._error = error
+                    self._cond.notify_all()
+                return
+            with self._cond:
+                self._frame, self._seq = frame, self._seq + 1
+                self._cond.notify_all()
+
+    def read(self):
+        with self._cond:
+            self._cond.wait_for(lambda: self._seq > self._seen or self._error, timeout=self.timeout)
+            if self._seq > self._seen:
+                self._seen = self._seq
+                return True, self._frame
+            if self._error:
+                raise RuntimeError(f"Termux camera failed: {self._error}")
+            return False, None
+
+    def close(self):
+        self._stop.set()
+        self._thread.join(timeout=self.timeout)
+        self._dir.cleanup()
+
+
 class Camera:
     def __init__(self, source: str, width: int, height: int, picamera: bool = False,
                  realtime: bool = False, loop: bool = False):
         self._pi = None
         self._capture = None
-        self.is_file = not picamera and not source.isdecimal()
+        self._termux = None
+        termux = not picamera and source.startswith("termux:")
+        self.is_file = not picamera and not termux and not source.isdecimal()
         if (realtime or loop) and not self.is_file:
             raise ValueError("--realtime and --loop require a video file")
         self.realtime, self.loop = realtime, loop
         self.looped = False
         self.fps = 30.0
         self._next_frame_at = None
-        if picamera:
+        if termux:
+            self._termux = TermuxCamera(source.split(":", 1)[1] or "0", width, height)
+        elif picamera:
             try:
                 from picamera2 import Picamera2
             except ImportError as error:
@@ -50,6 +165,8 @@ class Camera:
         self.looped = False
         if self._pi is not None:
             return True, self._pi.capture_array("main")
+        if self._termux is not None:
+            return self._termux.read()
         if self.realtime and self._next_frame_at is not None:
             time.sleep(max(0.0, self._next_frame_at - time.monotonic()))
         ok, frame = self._capture.read()
@@ -66,7 +183,9 @@ class Camera:
         return ok, frame
 
     def close(self):
-        if self._pi is not None:
+        if self._termux is not None:
+            self._termux.close()
+        elif self._pi is not None:
             self._pi.stop()
             self._pi.close()
         elif self._capture is not None:
BEAR_PATCH_END
}

patch_file() {  # Write the patch to a file; print its path.
  local p="${TMPDIR:-/tmp}/bear-termux-camera.patch"
  write_patch > "$p" && echo "$p"
}

unpatch() {  # Put back the files that a camera patch (this one or an older one) changes.
  git -C "$REPO" checkout -- src/barnaby/app.py src/barnaby/camera.py 2>/dev/null
}

patch_repo() {  # Apply the Termux camera patch once. Safe to do again.
  local p
  p=$(patch_file) || { fail "could not write the camera patch"; return 1; }
  if git -C "$REPO" apply --reverse --check "$p" 2>/dev/null; then
    ok "camera patch is already applied"
  elif unpatch; git -C "$REPO" apply --check "$p" 2>/dev/null && git -C "$REPO" apply "$p"; then
    ok "camera patch applied"
  else
    fail "camera patch does not apply (the code changed). Tell Claude."
  fi
}

setup() {
  local dpkg=(-y -o Dpkg::Options::=--force-confnew)
  echo "== 1/4 Install packages (use Wi-Fi; this can take 10-20 minutes) =="
  timeout 900 pkg install "${dpkg[@]}" x11-repo \
    || { fail "pkg install x11-repo. Check the internet, then do 1) again."; return 1; }
  # Read the new x11 package list and bring old packages up to date (Termux needs both).
  timeout 1800 pkg upgrade "${dpkg[@]}" \
    || { fail "pkg upgrade. Check the internet, then do 1) again."; return 1; }
  timeout 1800 pkg install "${dpkg[@]}" python python-numpy opencv-python python-opencv-python git termux-api \
    || { fail "pkg install. Check the internet, then do 1) again."; return 1; }
  echo "== 2/4 Get the bear code =="
  if [ -d "$REPO/.git" ]; then
    # Remove our camera patch first (also an older one), so that git pull can fast-forward.
    unpatch
    timeout 300 git -C "$REPO" pull --ff-only origin "$BRANCH" \
      || echo "WARNING: git pull failed. I use the code that is on the phone now."
  else
    timeout 900 git clone --depth 1 -b "$BRANCH" "$REPO_URL" "$REPO" \
      || { rm -rf "$REPO"; fail "git clone. Check the internet, then do 1) again."; return 1; }
  fi
  echo "== 3/4 Camera patch =="
  patch_repo || return 1
  echo "== 4/4 Test the models (no camera) =="
  if (cd "$REPO" && PYTHONPATH=src timeout 300 python -m barnaby --check); then
    ok "SETUP DONE. Now do 2) Camera preview, then 3) Orientation test."
  else
    fail "model check. Do 1) again. If it fails again, tell Claude."
  fi
}

camera_preview() {  # One photo, made exactly like the bear sees it (no EXIF turn, 640x480).
  local id raw out size
  need_bear || return 1
  turn_env
  id=$(cam); mkdir -p "$PROBE"; raw="$PROBE/raw.jpg"; out="$PROBE/preview.jpg"
  rm -f "$raw" "$out"
  echo "Taking 1 photo with camera $id, ${CAM_NAMES[$id]} (max 20 s)..."
  if ! timeout -k 2 20 "$PHOTO" -c "$id" "$raw" || [ ! -s "$raw" ]; then
    fail "no photo from camera $id in 20 s."
    echo "  1. Install the Termux:API app from the SAME store as Termux (F-Droid or GitHub)."
    echo "  2. Android Settings > Apps > Termux:API > Permissions > Camera: Allow."
    echo "  3. Close all camera apps, then try again. Or do 7) Pick camera."
    return 1
  fi
  size=$(cd "$REPO" && PYTHONPATH=src timeout 60 python -c '
import sys, cv2
from barnaby.camera import load_photo
frame = load_photo(sys.argv[1], (640, 480))
if frame is None or not cv2.imwrite(sys.argv[2], frame):
    sys.exit(1)
print(f"{frame.shape[1]}x{frame.shape[0]}")' "$raw" "$out") || { fail "could not read the photo."; return 1; }
  ok "preview $size (ROTATE=$BEAR_ROTATE MIRROR=$BEAR_MIRROR): $out"
  timeout 10 termux-open "$out" >/dev/null 2>&1 || echo "Open it in the Files app: $out"
  echo "If the picture is upside down, sideways or mirrored: hold the phone $POSE, then do 3) Orientation test."
}

orient_py() {  # The orientation test check in Python. Last output line: "VERDICT <rotate> <mirror>" or "VERDICT UNSURE".
cat <<'BEAR_ORIENT_END'
"""Which way is the phone camera frame turned? Uses barnaby's own hand models.

The test: Tony's LEFT index finger points flat to HIS right. Argv: annotated-output photo...
"""
import math
import sys
import textwrap
from collections import Counter

import cv2

from barnaby.camera import load_photo
from barnaby.models import DEFAULT_MODEL_DIR
from barnaby.vision import Vision

DIRS = ["RIGHT", "DOWN", "LEFT", "UP"]  # Image directions; each is the one before turned 90 deg CW.
TURN = {0: "no turn", 90: "90 CW", 180: "180", 270: "90 CCW"}


def find_hand(vision, frame):
    """The first hand, found the same way as Vision.infer (palm boxes, then hand landmarks)."""
    height, width = frame.shape[:2]
    for palm in sorted(vision.palms.infer(frame), key=lambda row: row[-1], reverse=True)[:2]:
        x1, y1, x2, y2 = palm[:4]
        if min(width, x2) <= max(0, x1) or min(height, y2) <= max(0, y1):
            continue
        hand = vision.hands.infer(frame, palm)
        if hand is not None:
            return hand
    return None


def decide(angle, looks_right):
    """One frame -> (finger direction in the raw image, rotate CW, mirror).

    angle: index tip (8) minus index knuckle (5) in image coordinates (y down), degrees, 0 = right.
    looks_right: MPHandPose handedness hand[130] > 0.5 (_vendor/mp_handpose.py:198,
    "(left)[0, 1](right)"). The score says how the hand LOOKS in the image as given:
    MediaPipe's own left_hands.jpg (backs of two left hands) scores 0.06, flipped 0.89.
    (MediaPipe names 0.89 "Left", because it assumes a mirrored selfie image.)
    A camera photo keeps a left hand looking left; only a mirror makes it look right.
    Tony uses his LEFT hand, so looks_right means the frame is mirrored.
    Tony faces the camera, so his right is the camera's LEFT: in an upright, not
    mirrored frame (like the Pi camera) the finger points image-LEFT.
    load_photo() mirrors first, then turns; so un-mirror, then find the CW turn to LEFT.
    """
    raw = int(((angle + 45) % 360) // 90)
    fixed = int((((180 - angle) if looks_right else angle) + 45) % 360 // 90)
    return DIRS[raw], (2 - fixed) % 4 * 90, int(looks_right)


def main(out_path, paths):
    vision = Vision(DEFAULT_MODEL_DIR)
    votes, lines, middle = [], [], None
    for i, path in enumerate(paths, 1):
        # The live camera path, but no turn: we measure the raw camera frame.
        frame = load_photo(path, (640, 480), (0, False))
        hand = None if frame is None else find_hand(vision, frame)
        if i == (len(paths) + 1) // 2:
            middle = (i, frame, hand)
        if hand is None:
            lines.append(f"{i}: no hand found" if frame is not None else f"{i}: no photo")
            continue
        points = hand[4:67].reshape(21, 3)
        dx, dy = points[8, :2] - points[5, :2]
        angle = math.degrees(math.atan2(dy, dx)) % 360
        score = float(hand[130])
        direction, rotate, mirror = decide(angle, score > 0.5)
        votes.append((rotate, mirror, direction, "Right" if mirror else "Left"))
        lines.append(f"{i}: finger image-{direction} ({angle:.0f} deg), hand looks "
                     f"{votes[-1][3]} ({score:.2f}) -> ROTATE={rotate} MIRROR={mirror}")
    best = Counter(votes).most_common(1)
    need = len(paths) // 2 + 1  # most photos must agree: 3 of 5, 2 of 2
    if best and best[0][1] >= need:
        (rotate, mirror, direction, looks), count = best[0]
        summary = (f"Finger points image-{direction}, hand looks {looks} "
                   f"({'mirrored' if mirror else 'not mirrored'}) -> ROTATE={rotate} ({TURN[rotate]}), "
                   f"MIRROR={mirror}  [{count} of {len(paths)} photos agree]")
        verdict = f"VERDICT {rotate} {mirror}"
    else:
        found = len(votes)
        summary = f"UNSURE: hand found in {found} of {len(paths)} photos, fewer than {need} agree"
        verdict = "VERDICT UNSURE"
    if middle and middle[1] is not None:
        i, image, hand = middle
        image = image.copy()
        if hand is not None:
            points = hand[4:67].reshape(21, 3)
            for x, y, _ in points:
                cv2.circle(image, (int(x), int(y)), 3, (0, 255, 255), -1)
            cv2.arrowedLine(image, tuple(int(v) for v in points[5, :2]), tuple(int(v) for v in points[8, :2]),
                            (0, 255, 0), 4, tipLength=0.3)
        for row, text in enumerate([f"photo {i}, raw camera frame (no turn)"] + textwrap.wrap(summary, 56)):
            cv2.putText(image, text, (8, 24 + 24 * row), cv2.FONT_HERSHEY_SIMPLEX, 0.55, (0, 0, 0), 4)
            cv2.putText(image, text, (8, 24 + 24 * row), cv2.FONT_HERSHEY_SIMPLEX, 0.55, (255, 255, 255), 1)
        cv2.imwrite(out_path, image)
    print("\n".join(lines + [summary, verdict]))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2:])
BEAR_ORIENT_END
}

big_py() {  # Big block letters, turned so they read with the phone held $POSE.
cat <<'BEAR_BIG_END'
"""Argv: COLUMNS [TEXT...]. TEXT: print it big. No TEXT: copy stdin and print each event label big."""
import json
import signal
import sys

import cv2
import numpy as np

SHORT = {"open_palm": "PALM", "thumbs_up": "THUMB", "middle_finger": "MIDDLE"}


def big(text, cols):
    font = cv2.FONT_HERSHEY_SIMPLEX
    (w, h), base = cv2.getTextSize(text, font, 1, 2)
    image = np.zeros((h + base + 4, w + 4), np.uint8)
    cv2.putText(image, text, (2, h + 2), font, 1, 255, 2)
    # Side buttons on top = the phone is turned 90 deg CCW, so turn the text 90 deg CW.
    image = cv2.rotate(image, cv2.ROTATE_90_CLOCKWISE)
    width = max(8, min(cols - 1, 20))
    rows = max(1, round(image.shape[0] * width / image.shape[1] / 2))  # a text cell is ~2x taller than wide
    image = cv2.resize(image, (width, rows), interpolation=cv2.INTER_AREA)
    print("\n".join("".join("█" if v > 80 else " " for v in row).rstrip() for row in image) + "\n", flush=True)


def label(line):
    if line.startswith("BEAR: dance"):
        return "DANCE"
    try:
        event = json.loads(line)
    except ValueError:
        return None
    if not isinstance(event, dict) or "gesture" not in event:
        return None
    name = event["gesture"] if event["gesture"] != "none" else event.get("expression", "none")
    return SHORT.get(name, name).upper()


def main(cols, words):
    if words:
        big(" ".join(words).upper(), cols)
        return
    signal.signal(signal.SIGINT, signal.SIG_IGN)  # Ctrl+C stops the bear; we stop at end of input.
    for line in sys.stdin:
        print(line, end="", flush=True)
        text = label(line)
        if text:
            big(text, cols)


if __name__ == "__main__":
    main(int(sys.argv[1]), sys.argv[2:])
BEAR_BIG_END
}

big_file() {  # Write big_py to a file; print its path.
  local p="${TMPDIR:-/tmp}/bear-big.py"
  big_py > "$p" && echo "$p"
}

cols() { tput cols 2>/dev/null || echo 40; }

say_big() {  # say_big TEXT: one short word, huge and turned (plain text if Python/OpenCV is missing).
  timeout 30 python "$(big_file)" "$(cols)" "$@" 2>/dev/null || echo "===== $* ====="
}

finger_check() {  # finger_check N: N finger-test photos -> FT_OUT (report), FT_ROT FT_MIR (or FT_ROT=UNSURE).
  local id n=$1 dir="$PROBE/orient" i
  id=$(cam)
  mkdir -p "$dir"; rm -f "$dir"/o*.jpg "$PROBE/orient.jpg"
  for ((i = 1; i <= n; i++)); do
    echo "Photo $i of $n..."
    if ! timeout -k 2 20 "$PHOTO" -c "$id" "$dir/o$i.jpg" || [ ! -s "$dir/o$i.jpg" ]; then
      fail "no photo from camera $id. Do 2) Camera preview: it says what to fix."; return 1
    fi
  done
  buzz 400
  echo "Done, you can relax. Looking for the hand (about 10 s)..."
  FT_OUT=$(cd "$REPO" && orient_py | PYTHONPATH=src timeout 300 python - "$PROBE/orient.jpg" "$dir"/o*.jpg 2>&1) \
    || { echo "$FT_OUT"; fail "the hand check did not run. Tell Claude."; return 1; }
  read -r _ FT_ROT FT_MIR <<< "$(tail -n 1 <<< "$FT_OUT")"
}

finger_pretest() {  # Testing mode, before each live run: 2 photos. No clear finger -> back to the menu.
  local i
  echo "FINGER TEST (2 photos): hold the phone $POSE."
  echo "Stand ~1 m away. LEFT index finger flat to YOUR right."
  say_big "HAND UP"
  for i in 5 4 3 2 1; do echo "  $i..."; sleep 1; done
  finger_check 2 || { say_big "FAIL"; buzz_fail; return 1; }
  echo "$FT_OUT"
  case "$FT_ROT" in
    0|180) conf_set "ROTATE=$FT_ROT" "MIRROR=$FT_MIR"
           BEAR_ROTATE=$FT_ROT BEAR_MIRROR=$FT_MIR BEAR_FINGER_TEST="ROTATE=$FT_ROT MIRROR=$FT_MIR"
           say_big "OK $FT_ROT"
           ok "finger test: ROTATE=$FT_ROT MIRROR=$FT_MIR (saved). Starting the bear." ;;
    90|270) say_big "UPRIGHT"; buzz_fail
            fail "finger test: the phone was upright. Hold it $POSE. Back to the menu." ;;
    *) say_big "NO HAND"; buzz_fail
       fail "finger test: no clear finger in both photos. Good light, ~1 m, point to your right. Back to the menu." ;;
  esac
}

orient_test() {  # 5 photos of Tony's LEFT index finger pointing to HIS right -> ROTATE/MIRROR in ~/.bear.conf.
  local id n=5 report rot mir result
  need_bear || return 1
  id=$(cam)
  cat <<TEXT
Orientation test with camera $id, ${CAM_NAMES[$id]}:
  1. Stand the phone $POSE.
     Always hold it this same way for the bear (a Pi camera does not turn either).
  2. Stand about 1 m away (the hand must look big) and face the camera.
  3. Hold up your LEFT hand. Point the index finger flat to YOUR right side.
     Curl the other fingers. Keep still until the phone buzzes (about 15 s).
TEXT
  read -r -p "Push Enter to start. " _ || exit 0
  for i in 5 4 3 2 1; do echo "  $i..."; sleep 1; done
  finger_check "$n" || return 1
  rot=$FT_ROT mir=$FT_MIR
  case "$rot" in
    0|180) conf_set "ROTATE=$rot" "MIRROR=$mir"; say_big "SAVED"
           result="SAVED ROTATE=$rot MIRROR=$mir in ~/.bear.conf. Always hold the phone this same way. Do 2) Camera preview to check." ;;
    90|270) say_big "UPRIGHT"; result="NOT SAVED: the phone was upright. Stand it $POSE, then do 3) again." ;;
    *) say_big "AGAIN"; result="NOT SAVED: not sure. Use good light, point clearly to your right, then do 3) again." ;;
  esac
  report=$(printf 'bear orientation test, camera %s\n%s\n%s' "$id" "$(sed '$d' <<< "$FT_OUT")" "$result")
  echo; echo "$report"
  if printf '%s\n' "$report" | timeout 10 termux-clipboard-set >/dev/null 2>&1; then
    echo "(The report is copied: paste it to Claude.)"
  fi
  [ -s "$PROBE/orient.jpg" ] && { timeout 10 termux-open "$PROBE/orient.jpg" >/dev/null 2>&1 \
    || echo "Open it in the Files app: $PROBE/orient.jpg"; }
  [[ "$result" != NOT* ]]
}

talk_py() {  # Bear talks: photo -> online vision model -> one short line. Built in from talk.py.
cat <<'BEAR_TALK_END'
"""Bear talks: one photo -> online vision model -> one short spoken bear line.

Argv: PHOTO. Prints "LINE <text>", "INFO <latency, tokens, cost, provider>", "CTX <memory>", or "ERR <reason>".
Each request is a fresh, stateless API call: static rules (system) + PREVIOUS CONTEXT as TEXT + 1 new photo.
Rolling context lives in the file $BEAR_CONTEXT_FILE (the model's last "context" JSON, compacted to
<= 120 words; reset after an error or a gap > 60 s). BEAR_CONTEXT=0: only the last 3 lines are sent.
Key: read from a file (never argv): ~/.bear.key (OpenRouter) or ~/.bear-gemini.key (BEAR_LLM=gemini).
stdlib only for the network (Termux python has no requests).
"""
import base64
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

BACKENDS = {  # BEAR_LLM -> (chat/completions URL, default model, key file)
    "openrouter": ("https://openrouter.ai/api/v1/chat/completions", "google/gemini-3.8-flash", "~/.bear.key"),
    "gemini": ("https://generativelanguage.googleapis.com/v1beta/openai/chat/completions", "gemini-3.8-flash",
               "~/.bear-gemini.key"),
}

# Prompt from the crowd-work research (/tmp/crowd/scripts/prompts.py REFINED), adapted:
# JSON output, "snack"/"cave" lines aimed at kids toned down. PROMPT = RULES + EXAMPLES: swap either.
# Static, so it goes FIRST (system message) for prefix caching; context + photo go in the user message.
RULES = """You are Barnaby, a grumpy-but-lovable animatronic bear at a school demo. Look at the camera photo and say ONE line out loud, straight AT the people. Reply with JSON only (see the end).

RULES
- Max 15 words. One or two short sentences. Plain words a phone voice can say. No emoji, no stage directions, no quotes.
- Start with ONE bear sound: Grrr. / Hrmph. / Sniff sniff. / Rawr. / Huff. / Ooh.
- You speak about 5 to 10 seconds after the photo, so people may have moved. Pick details that stay true: 1) a bright color, logo, or loud pattern; 2) a hat, glasses, or mask; 3) something held (phone, drink, snack, trophy, sign, gear); 4) group size; 5) any other clothing. Gestures and faces are last resort.
- A gesture you saw is already over: say it in past tense or as a trait ("You look like a waver"), never "right now" or "stop doing that".
- Name the detail exactly ("red cap", "tennis racket", "striped sweater"), never generic ("your outfit"). Call people by it ("Red cap!"), never by position ("you on the left", "in the back").
- Shape: bear sound + the detail + a bear-logic twist (honey, salmon, berries, naps, caves, hibernating, the woods, sniffing, picnic baskets). Playful-spooky, like a bear who wants their stuff. Never call people food or snacks; no threats.
- Crowd: pick the ONE boldest detail, call that person by it, and let the twist include the group ("you lot", "this pack").
- Tease the CHOICE, not the person. Affection wins: end on a compliment, a bear wish, or the bear losing.
- NEVER mention body, weight, height, face, hair, skin, race, gender, age, disability, religion, names, or any brand or text you are unsure of. No drugs, alcohol, or swearing.
- A rude gesture: answer with a bear's own sass, never repeat a rude word.
- Nobody visible: grumble at the empty room. Too dark or blurry: complain about the photo, not the people.
- If RECENT LINES are given in the message, do not reuse their bear sound, detail, or twist."""
EXAMPLES = """

EXAMPLES
One person, blue hoodie: Hrmph. Cozy blue hoodie. I hibernate in less. Very jealous.
Group of five, one red cap: Grrr. Red cap, you lead this pack. The rest of you carry my picnic basket.
Phone in hand: Sniff sniff. Phone people. Bears do not do selfies. Yet.
Glasses: Ooh, fancy glasses. Can you see the honey I am hiding?
Bright yellow jacket: Hrmph. That yellow jacket woke me from hibernation. Thanks a lot.
Was waving (past gesture, as a trait): Rawr. Striped sweater, you look like a waver. I wave back. With claws.
Middle finger (past gesture): Huff. Somebody flashed a rude finger. Bold move, tiny human.
Nobody there: Huff. Empty room again. Even the chairs left me.
Dark or blurry photo: Grrr. Too dark. Either my eyes broke or you are a ghost.
With RECENT LINES ["Grrr. Red cap, you lead this pack."], same group: Sniff sniff. Six of you? That is a whole picnic."""
PROMPT = RULES + EXAMPLES
CONTEXT_RULES = """

MEMORY
- PREVIOUS CONTEXT, if given, is your memory of earlier photos. It is 5 to 60 seconds old and may be stale.
- Trust the NEW photo. Never talk about a remembered person as if they are here unless you see them now.
- If a remembered detail is in the new photo again, a callback is fun ("Red cap is back!").
- Same person as in PREVIOUS CONTEXT: copy their tag word for word.
- The context fields follow the same NEVER list: say "person" or "people", never man, woman, boy or girl."""
FORMAT = """

Reply with JSON only, no code fence:
{"speak": "<your line, max 15 words>",
 "context": {"scene": "<place, lighting, time-of-day guess, max 12 words>",
             "people": [{"tag": "<lasting detail, e.g. red cap>", "doing": "<max 6 words>"}],
             "said": ["<your last 3 lines>"],
             "summary": "<max 30 words: what changed since PREVIOUS CONTEXT>"}}
people: only people in the NEW photo, max 4, boldest first. No people: []."""
SYSTEM = PROMPT + CONTEXT_RULES + FORMAT

_STR = {"type": "string"}
SCHEMA = {"type": "object", "additionalProperties": False, "required": ["speak", "context"], "properties": {
    "speak": _STR,
    "context": {"type": "object", "additionalProperties": False, "required": ["scene", "people", "said", "summary"],
                "properties": {"scene": _STR, "summary": _STR, "said": {"type": "array", "items": _STR},
                               "people": {"type": "array", "items": {
                                   "type": "object", "additionalProperties": False, "required": ["tag", "doing"],
                                   "properties": {"tag": _STR, "doing": _STR}}}}}}}
MAX_AGE = 60      # s: older context is dropped (Tony: reset after a gap over 60 s)
MAX_WORDS = 120   # the PREVIOUS CONTEXT block can not snowball


def words(text, n):
    return " ".join(str(text).split()[:n])


def load_context(path):
    """Saved memory, or an empty one when missing, broken, too old, or switched off."""
    empty = {"t": 0, "scene": "", "people": [], "said": [], "summary": ""}
    try:
        with open(path) as f:
            ctx = json.load(f)
        if time.time() - float(ctx.get("t", 0)) > MAX_AGE:
            return empty
        return {**empty, **ctx}
    except (OSError, ValueError, TypeError, AttributeError):
        return empty


def merge(old, new, speak):
    """New memory: the model's view of the NEW photo + people it did not see (kept 1 more call) + our own said list."""
    new = new if isinstance(new, dict) else {}
    people, seen = [], set()
    for p in new.get("people") or []:
        if isinstance(p, dict) and p.get("tag"):
            tag = words(p["tag"], 5).lower()
            if tag not in seen:
                seen.add(tag); people.append({"tag": tag, "doing": words(p.get("doing", ""), 6), "missed": 0})
    for p in old.get("people") or []:  # not in this photo: drop after 2 calls without being seen
        if p.get("tag") not in seen and p.get("missed", 0) + 1 < 2:
            people.append({**p, "missed": p.get("missed", 0) + 1})
    ctx = {"t": time.time(), "scene": words(new.get("scene", old.get("scene", "")), 12), "people": people[:5],
           "said": (list(old.get("said") or []) + [speak])[-3:], "summary": words(new.get("summary", ""), 30)}
    while len(context_text(ctx).split()) > MAX_WORDS and (ctx["people"] or ctx["summary"]):
        if ctx["summary"]:
            ctx["summary"] = ""
        else:
            ctx["people"].pop()
    return ctx


def context_text(ctx, full=True):
    """The PREVIOUS CONTEXT block (text only, no old images)."""
    parts = []
    if full and (ctx.get("scene") or ctx.get("people")):
        age = int(time.time() - ctx.get("t", time.time()))
        people = "; ".join(p["tag"] + (f" ({p['doing']})" if p.get("doing") else "")
                           + (" [not in the last photo]" if p.get("missed") else "") for p in ctx.get("people", []))
        parts.append(f"PREVIOUS CONTEXT (from {age} s ago, may be stale):\nscene: {ctx.get('scene', '')}\n"
                     f"people: {people or 'nobody'}" + (f"\nsummary: {ctx['summary']}" if ctx.get("summary") else ""))
    if ctx.get("said"):
        parts.append("RECENT LINES (do not repeat):\n" + "\n".join("- " + r for r in ctx["said"][-3:]))
    return "\n\n".join(parts)


def user_text(ctx, full=True):
    """The varying part, after the static rules. The model never sees earlier photos, only this text."""
    block = context_text(ctx, full)
    return (block + "\n\n" if block else "") + "NEW photo:"


def image_b64(path):
    """Photo -> 320 px wide JPEG q60, base64. Uses the bear's own turn (ROTATE/MIRROR) when it is there."""
    import cv2
    frame = None
    try:
        from barnaby.camera import load_photo
        frame = load_photo(path, (320, 240))
    except Exception:
        frame = None
    if frame is None:
        frame = cv2.imread(path, cv2.IMREAD_COLOR)
        if frame is None:
            raise ValueError("cannot read photo")
        h, w = frame.shape[:2]
        scale = 320 / max(h, w)
        frame = cv2.resize(frame, (max(1, round(w * scale)), max(1, round(h * scale))), interpolation=cv2.INTER_AREA)
    ok, buf = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, 60])
    if not ok:
        raise ValueError("cannot encode photo")
    return base64.b64encode(buf.tobytes()).decode()


def parse(text):
    """Model reply -> (speakable line, context dict or None). Tolerant: JSON, cut-off JSON, or plain text."""
    text = re.sub(r"^```(?:json)?\s*|\s*```$", "", text.strip())
    line, ctx = None, None
    match = re.search(r"\{.*\}", text, re.S)
    if match:
        try:
            data = json.loads(match.group(0))
            value = data.get("speak", data.get("line"))
            line = value if isinstance(value, str) else None
            ctx = data.get("context")
        except (ValueError, AttributeError):
            pass
    if line is None:
        if text.startswith("{") or '"speak"' in text:
            closed = re.search(r'"(?:speak|line)"\s*:\s*"([^"]+)"', text)
            line = closed.group(1) if closed else ""   # cut-off JSON: say nothing rather than garbage
        else:
            line = text.splitlines()[0] if text else ""  # plain-text answer
    line = re.sub(r"[*_#`~<>\[\]{}|\\]", "", line)          # no markdown for TTS
    line = re.sub(r"[^\x20-\x7E]", "", line)                  # no emoji
    line = " ".join(line.split())
    if len(line.split()) > 18:
        line = " ".join(line.split()[:18]).rstrip(",;:") + "."
    return line, ctx


def ask(photo, ctx, full=True, timeout=25):
    """One fresh request. Returns (line, new_context_from_model, ms, usage, raw_text, provider)."""
    backend = os.environ.get("BEAR_LLM", "openrouter")
    url, model, key_file = BACKENDS.get(backend, BACKENDS["openrouter"])
    model = os.environ.get("BEAR_MODEL", model)
    with open(os.path.expanduser(key_file)) as f:
        key = f.read().strip()
    body = {
        "model": model,
        "messages": [
            {"role": "system", "content": SYSTEM},
            {"role": "user", "content": [
                {"type": "text", "text": user_text(ctx, full)},
                {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64," + image_b64(photo)}},
            ]},
        ],
        "response_format": {"type": "json_schema", "json_schema": {"name": "bear", "strict": True, "schema": SCHEMA}},
        "temperature": 1.0,  # Gemini 3 default; lower can loop. Vertex (the ZDR route) ignores it anyway.
        "max_tokens": 1000,  # thinking is mandatory and counts here; 300 cut lines off
    }
    if backend == "openrouter":
        body["reasoning"] = {"effort": os.environ.get("BEAR_EFFORT", "low"), "exclude": True}
        # Zero Data Retention (Tony's rule): route ONLY to endpoints that keep no prompts or photos.
        # For google/gemini-3.8-flash that means Google Vertex (AI Studio is not ZDR). Do not remove.
        body["provider"] = {"zdr": True, "data_collection": "deny"}
    else:
        body["reasoning_effort"] = os.environ.get("BEAR_EFFORT", "low")
    request = urllib.request.Request(url, json.dumps(body).encode(), {
        "Authorization": "Bearer " + key, "Content-Type": "application/json",
        "HTTP-Referer": "https://github.com/Forzalab/evil-autonomous-bear-proj", "X-Title": "bear talks"})
    start = time.time()
    with urllib.request.urlopen(request, timeout=timeout) as response:
        reply = json.load(response)
    ms = int((time.time() - start) * 1000)
    text = reply["choices"][0]["message"].get("content") or ""
    line, new = parse(text)
    return line, new, ms, reply.get("usage") or {}, text, reply.get("provider", "?")


def main(photo):
    path = os.environ.get("BEAR_CONTEXT_FILE", os.path.expanduser("~/.bear-talk-context.json"))
    full = os.environ.get("BEAR_CONTEXT", "1") != "0"
    ctx = load_context(path)
    try:
        line, new, ms, usage, _, provider = ask(photo, ctx, full)
        if not line:
            raise ValueError("empty answer")
    except Exception as e:  # noqa: BLE001 - any error: forget the memory, keep the loop alive
        try:
            os.remove(path)
        except OSError:
            pass
        if isinstance(e, FileNotFoundError):
            print("ERR no key file: do 10) again to paste it")
        elif isinstance(e, urllib.error.HTTPError):
            hint = {400: "bad request", 401: "key is wrong (rm the key file, then paste again)",
                    402: "no credits left", 403: "key not allowed",
                    404: "no zero-data-retention endpoint for this model",
                    429: "too many requests, slow down"}.get(e.code, "server problem")
            print(f"ERR HTTP {e.code}: {hint}")
        elif isinstance(e, (urllib.error.URLError, TimeoutError, OSError)):
            print(f"ERR network: {type(e).__name__}")
        else:
            print(f"ERR {e}" if isinstance(e, ValueError) else f"ERR {type(e).__name__}")
        return
    ctx = merge(ctx, new, line)
    try:
        with open(path, "w") as f:
            json.dump(ctx, f)
    except OSError:
        pass
    cost = usage.get("cost")
    print(f"INFO {ms} ms, {usage.get('prompt_tokens', 0)}+{usage.get('completion_tokens', 0)} tokens"
          + (f", ${cost:.4f}" if isinstance(cost, (int, float)) else "") + f", {provider}")
    print("CTX " + ("; ".join(p["tag"] for p in ctx["people"]) or "nobody") + f" | {ctx['scene']}")
    print(f"LINE {line}")


if __name__ == "__main__":
    main(sys.argv[1])
BEAR_TALK_END
}

key_file() {  # The API key file: OpenRouter (default) or a Google Gemini key (BEAR_LLM=gemini).
  if [ "${BEAR_LLM:-openrouter}" = gemini ]; then echo "$HOME/.bear-gemini.key"; else echo "$HOME/.bear.key"; fi
}

ask_key() {  # First use: paste the key once. Never shown, saved only for you (chmod 600).
  local f key
  f=$(key_file)
  [ -s "$f" ] && return 0
  echo "First time: paste your ${BEAR_LLM:-OpenRouter} API key (it is not shown), then push Enter."
  read -r -s -p "Key: " key || exit 0
  echo
  key=$(printf '%s' "$key" | tr -d '[:space:]')
  [ -n "$key" ] || { fail "no key pasted"; return 1; }
  (umask 077; printf '%s\n' "$key" > "$f") && chmod 600 "$f" && ok "key saved in $f (to change it: rm $f)"
}

bear_talk() {  # Loop: 1 photo -> 1 line (online) -> the phone says it. One request at a time. Ctrl+C stops.
  local id raw py out line info ctx n=0 t0 stop=0 speak
  need_bear || return 1
  ask_key || return 1
  turn_env; id=$(cam); mkdir -p "$PROBE"; raw="$PROBE/talk.jpg"
  py="${TMPDIR:-/tmp}/bear-talk.py"; talk_py > "$py" || { fail "could not write $py"; return 1; }
  # Rolling context: each fresh request also sends the last answer's short memory (text, max 120 words).
  # talk.py forgets it after an error or a gap over 60 s; BEAR_CONTEXT=0 sends only the last 3 lines.
  export BEAR_CONTEXT_FILE="$PROBE/talk-context.json"; rm -f "$BEAR_CONTEXT_FILE"
  echo "Bear talks (online: ${BEAR_LLM:-openrouter}). Camera $id, ${CAM_NAMES[$id]}. A new line every few seconds."
  echo "Only a small 320 px photo goes online (OpenRouter: zero-data-retention endpoints only)."
  echo "To stop: push Ctrl+C (CTRL key on the Termux bar, then C)."
  timeout 10 termux-wake-lock >/dev/null 2>&1; WAKE=1
  trap 'stop=1' INT
  while [ "$stop" = 0 ]; do
    n=$((n + 1)); t0=$(date +%s%N); rm -f "$raw"
    if ! timeout -k 2 20 "$PHOTO" -c "$id" "$raw" || [ ! -s "$raw" ]; then
      [ "$stop" = 1 ] && break
      echo "[$n] no photo from camera $id. Do 2) Camera preview: it says what to fix."; sleep 3; continue
    fi
    [ "$stop" = 1 ] && break
    # Each request is fresh: rules + memory text + this 1 photo. One request at a time.
    out=$(cd "$REPO" && PYTHONPATH=src timeout 45 python "$py" "$raw" 2>/dev/null) || out=${out:-"ERR timeout"}
    [ "$stop" = 1 ] && break
    line=$(sed -n 's/^LINE //p' <<< "$out"); info=$(sed -n 's/^INFO //p' <<< "$out")
    ctx=$(sed -n 's/^CTX //p' <<< "$out")
    if [ -z "$line" ]; then
      rm -f "$BEAR_CONTEXT_FILE"  # error: start the memory fresh
      echo "[$n] $(grep -m 1 '^ERR' <<< "$out" || echo "ERR no answer") (round $(( ($(date +%s%N) - t0) / 1000000 )) ms). Trying again..."
      sleep 3; continue
    fi
    say_big "${line%%[ ,.!?]*}" &   # Only the first sound word, huge, while the phone talks.
    speak=$(printf '%s\n' "$line" | timeout 30 termux-tts-speak -p "${BEAR_PITCH:-0.6}" -r "${BEAR_RATE:-0.9}" 2>&1)
    wait
    echo "[$n] BEAR: $line"
    echo "     online $info; round $(( ($(date +%s%N) - t0) / 1000000 )) ms${speak:+ (voice: $speak)}"
    echo "     memory: $ctx"
    [ "$stop" = 1 ] || sleep "${BEAR_TALK_GAP:-2}"
  done
  trap - INT
  wake_off
  echo "Bear stopped talking."
}

WAKE=0
wake_off() { [ "$WAKE" = 1 ] && { timeout 10 termux-wake-unlock >/dev/null 2>&1; WAKE=0; }; return 0; }
trap wake_off EXIT

run_bear() {  # Arguments go to barnaby. Output is also in ~/bear-logs/<time>.log.
  local log extra=()
  need_bear || return 1
  mkdir -p "$LOGS"; log="$LOGS/$(stamp).log"
  [ -n "${BEAR_MAX_FRAMES:-}" ] && extra=(--max-frames "$BEAR_MAX_FRAMES")
  echo "To stop: push Ctrl+C (CTRL key on the Termux bar, then C). Log: $log"
  timeout 10 termux-wake-lock >/dev/null 2>&1; WAKE=1
  trap 'echo' INT
  if [ "${BEAR_BIG:-0}" = 1 ]; then  # Each new label also huge, readable with the phone sideways.
    (cd "$REPO" && PYTHONPATH=src exec python -u -m barnaby --headless "$@" "${extra[@]}") 2>&1 | tee -i "$log" \
      | python -u "$(big_file)" "$(cols)"
  else
    (cd "$REPO" && PYTHONPATH=src exec python -u -m barnaby --headless "$@" "${extra[@]}") 2>&1 | tee -i "$log"
  fi
  trap - INT
  wake_off
  echo "Bear stopped. Log: $log"
}

run_live() {  # Phone camera: ~1 photo per 1.5 s, so react on each photo.
  local id BEAR_DEBUG=0 BEAR_BIG=0 BEAR_FINGER_TEST="not run"
  export BEAR_DEBUG BEAR_BIG BEAR_FINGER_TEST
  id=$(cam); turn_env
  if [ "$(conf_get TESTING 1)" = 1 ]; then  # Testing mode: finger test first, big labels, debug in each event.
    need_bear || return 1
    finger_pretest || return 1
    BEAR_DEBUG=1 BEAR_BIG=1
  fi
  echo "Hold the phone $POSE, the same way as in 3) Orientation test. ~1 photo per 1.5 s."
  echo "Camera $id, ${CAM_NAMES[$id]}, ROTATE=$BEAR_ROTATE MIRROR=$BEAR_MIRROR."
  run_bear --source "termux:$id" --stable-frames 1 --interval 0 "$@"
}

wait_file() {  # Wait until file $1 exists and its size is the same for 2 s. Max $2 seconds.
  local f=$1 t=0 last=-1 size same=0
  while [ "$t" -lt "$2" ]; do
    size=$({ wc -c < "$f"; } 2>/dev/null) || size=-1
    if [ "$size" -gt 0 ] && [ "$size" = "$last" ]; then
      same=$((same + 1)); [ "$same" -ge 2 ] && return 0
    else
      same=0
    fi
    last=$size; sleep 1; t=$((t + 1))
    [ $((t % 15)) = 0 ] && echo "  ...still waiting ($t s of $2 s)"
  done
  return 1
}

pick_video() {  # Sets VIDEO. First the Android file picker, then a list of the newest .mp4 files.
  local out n files=()
  mkdir -p "$VIDS"; out="$VIDS/picked-$(stamp).mp4"
  echo "Pick a video in the window that opened (max 2 minutes)..."
  if timeout -k 2 20 termux-storage-get "$out" && wait_file "$out" 120; then
    find "$VIDS" -maxdepth 1 -name 'picked-*.mp4' | sort -r | tail -n +4 | while read -r n; do rm -f "$n"; done
    VIDEO=$out; ok "video copied: $out"; return 0
  fi
  rm -f "$out"
  echo "No video came from the picker. These are the newest videos on the phone:"
  mapfile -t files < <(find -H "$HOME/storage/dcim/Camera" "$HOME/storage/downloads" -maxdepth 1 -type f \
    -iname '*.mp4' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n 9 | cut -d' ' -f2-)
  [ "${#files[@]}" -gt 0 ] || { fail "no .mp4 in Camera or Downloads. Type termux-setup-storage once, or record a video."; return 1; }
  for n in "${!files[@]}"; do echo "  $((n + 1))) ${files[$n]#"$HOME"/storage/}"; done
  read -r -p "Type the video number, then push Enter [1]: " n || exit 0
  n=${n:-1}
  [[ "$n" =~ ^[1-9]$ ]] && [ "$n" -le "${#files[@]}" ] || { fail "type a number from the list"; return 1; }
  VIDEO=${files[$((n - 1))]}
}

run_video() {  # A clip from the camera app: real 30 fps, so keep the default filters.
  local yn trig=()
  pick_video || return 1
  read -r -p "Add the dance trigger ($TRIGGER_GESTURE)? (y/N): " yn || exit 0
  [[ "$yn" =~ ^[yY] ]] && trig=(--trigger "$TRIGGER_GESTURE")
  run_bear --source "$VIDEO" --realtime "${trig[@]}"
}

pick_camera() {
  local i id old
  old=$(cam)
  for i in "${CAM_ORDER[@]}"; do echo "  $i) ${CAM_NAMES[$i]}"; done
  read -r -p "Type the camera number, then push Enter [$(cam)]: " id || exit 0
  id=${id:-$(cam)}
  [[ "$id" =~ ^[0-3]$ ]] || { fail "type 3, 1, 0 or 2"; return 1; }
  if [ "$id" = "$old" ]; then
    conf_set "CAM=$id"
  else  # Each camera is turned its own way: forget the old orientation test.
    conf_set "CAM=$id" "ROTATE=" "MIRROR="
  fi && ok "camera $id, ${CAM_NAMES[$id]}, is saved. Do 3) Orientation test."
}

shortcut() {
  local line="alias bear='bash ~/bear.sh'"
  install_self
  grep -qxF "$line" "$HOME/.bashrc" 2>/dev/null || echo "$line" >> "$HOME/.bashrc"
  ok "shortcut is ready. Open a new Termux session, then type: bear"
}

on_off() { [ "$1" = 1 ] && echo ON || echo OFF; }

toggle_testing() {
  conf_set "TESTING=$((1 - $(conf_get TESTING 1)))"
  ok "testing mode $(on_off "$(conf_get TESTING 1)")."
}

VIDEO=""
install_self
while true; do
  id=$(cam)
  cat <<MENU

=========== BEAR ===========
 1) Setup / update
 2) Camera preview
 3) Orientation test (now: ROTATE=$(conf_get ROTATE 0) MIRROR=$(conf_get MIRROR 0))
 4) Run bear LIVE
 5) Run bear LIVE + trigger
 6) Run on a recorded video
 7) Pick camera (now: $id, ${CAM_NAMES[$id]})
 8) Install shortcut "bear"
 9) Testing mode (now: $(on_off "$(conf_get TESTING 1)")): finger test + big text + debug in LIVE runs
10) Bear talks (online): photo -> funny line -> the phone says it
 q) Quit
MENU
  read -r -p "Type a number, then push Enter: " choice || exit 0
  case "$choice" in
    1) setup ;;
    2) camera_preview ;;
    3) orient_test ;;
    4) run_live ;;
    5) run_live --trigger "$TRIGGER_GESTURE" ;;
    6) run_video ;;
    7) pick_camera ;;
    8) shortcut ;;
    9) toggle_testing ;;
    10) bear_talk ;;
    q|Q) exit 0 ;;
    *) echo "Type 1 to 10, or q."; continue ;;
  esac
  pause
done
