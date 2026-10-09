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
export DEBIAN_FRONTEND=noninteractive GIT_TERMINAL_PROMPT=0

ok()   { echo "OK: $*"; }
fail() { echo "FAIL: $*"; return 1; }
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
index d5b740a..8b9b57b 100644
--- a/src/barnaby/app.py
+++ b/src/barnaby/app.py
@@ -38,7 +38,7 @@ def overlay(frame, observation: Observation, gesture: str, expression: str):
 
 def main(argv=None) -> None:
     parser = argparse.ArgumentParser(description=__doc__)
-    parser.add_argument("--source", default="0", help="USB camera index or video path")
+    parser.add_argument("--source", default="0", help="USB camera index, video path/URL, or termux:ID (Android Termux:API camera)")
     parser.add_argument("--picamera", action="store_true", help="Use a Pi CSI camera via Picamera2")
     parser.add_argument("--model-dir", type=Path, default=DEFAULT_MODEL_DIR)
     parser.add_argument("--width", type=positive, default=640)
@@ -58,7 +58,7 @@ def main(argv=None) -> None:
     args = parser.parse_args(argv)
     if not math.isfinite(args.interval) or args.interval < 0:
         parser.error("--interval must be finite and nonnegative")
-    if args.save_video and not args.picamera and not args.source.isdecimal():
+    if args.save_video and not args.picamera and not args.source.isdecimal() and not args.source.startswith("termux:"):
         if args.save_video.resolve() == Path(args.source).resolve():
             parser.error("--save-video must differ from the input video")
     camera = None
diff --git a/src/barnaby/camera.py b/src/barnaby/camera.py
index d5ec0f8..6a19a26 100644
--- a/src/barnaby/camera.py
+++ b/src/barnaby/camera.py
@@ -1,24 +1,136 @@
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
@@ -50,6 +162,8 @@ class Camera:
         self.looped = False
         if self._pi is not None:
             return True, self._pi.capture_array("main")
+        if self._termux is not None:
+            return self._termux.read()
         if self.realtime and self._next_frame_at is not None:
             time.sleep(max(0.0, self._next_frame_at - time.monotonic()))
         ok, frame = self._capture.read()
@@ -66,7 +180,9 @@ class Camera:
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
  echo "If the picture is upside down, sideways or mirrored, do 3) Orientation test."
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
    if best and best[0][1] >= 3:
        (rotate, mirror, direction, looks), count = best[0]
        summary = (f"Finger points image-{direction}, hand looks {looks} "
                   f"({'mirrored' if mirror else 'not mirrored'}) -> ROTATE={rotate} ({TURN[rotate]}), "
                   f"MIRROR={mirror}  [{count} of {len(paths)} photos agree]")
        verdict = f"VERDICT {rotate} {mirror}"
    else:
        found = len(votes)
        summary = f"UNSURE: hand found in {found} of {len(paths)} photos, fewer than 3 agree"
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

orient_test() {  # 5 photos of Tony's LEFT index finger pointing to HIS right -> ROTATE/MIRROR in ~/.bear.conf.
  local id dir i n=5 out report verdict rot mir result
  need_bear || return 1
  id=$(cam); dir="$PROBE/orient"
  mkdir -p "$dir"; rm -f "$dir"/o*.jpg "$PROBE/orient.jpg"
  cat <<TEXT
Orientation test with camera $id, ${CAM_NAMES[$id]}:
  1. Stand the phone SIDEWAYS (long edge flat), the camera looking at you.
  2. Stand about 1 m away (the hand must look big) and face the camera.
  3. Hold up your LEFT hand. Point the index finger flat to YOUR right side.
     Curl the other fingers. Keep still until the phone buzzes (about 15 s).
TEXT
  read -r -p "Push Enter to start. " _ || exit 0
  for i in 5 4 3 2 1; do echo "  $i..."; sleep 1; done
  for ((i = 1; i <= n; i++)); do
    echo "Photo $i of $n..."
    if ! timeout -k 2 20 "$PHOTO" -c "$id" "$dir/o$i.jpg" || [ ! -s "$dir/o$i.jpg" ]; then
      fail "no photo from camera $id. Do 2) Camera preview: it says what to fix."; return 1
    fi
  done
  timeout 10 termux-vibrate -d 400 >/dev/null 2>&1
  echo "Done, you can relax. Looking for the hand (about 10 s)..."
  out=$(cd "$REPO" && orient_py | PYTHONPATH=src timeout 300 python - "$PROBE/orient.jpg" "$dir"/o*.jpg 2>&1) \
    || { echo "$out"; fail "the hand check did not run. Tell Claude."; return 1; }
  verdict=$(tail -n 1 <<< "$out")
  read -r _ rot mir <<< "$verdict"
  case "$rot" in
    0|180) conf_set "ROTATE=$rot" "MIRROR=$mir"
           result="SAVED ROTATE=$rot MIRROR=$mir in ~/.bear.conf. Do 2) Camera preview to check." ;;
    90|270) result="NOT SAVED: the phone was upright. Stand it SIDEWAYS, then do 3) again." ;;
    *) result="NOT SAVED: not sure. Use good light, point clearly to your right, then do 3) again." ;;
  esac
  report=$(printf 'bear orientation test, camera %s\n%s\n%s' "$id" "$(sed '$d' <<< "$out")" "$result")
  echo; echo "$report"
  if printf '%s\n' "$report" | timeout 10 termux-clipboard-set >/dev/null 2>&1; then
    echo "(The report is copied: paste it to Claude.)"
  fi
  [ -s "$PROBE/orient.jpg" ] && { timeout 10 termux-open "$PROBE/orient.jpg" >/dev/null 2>&1 \
    || echo "Open it in the Files app: $PROBE/orient.jpg"; }
  [[ "$result" != NOT* ]]
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
  (cd "$REPO" && PYTHONPATH=src exec python -u -m barnaby --headless "$@" "${extra[@]}") 2>&1 | tee -i "$log"
  trap - INT
  wake_off
  echo "Bear stopped. Log: $log"
}

run_live() {  # Phone camera: ~1 photo per 1.5 s, so react on each photo.
  local id
  id=$(cam); turn_env
  echo "Hold the phone sideways, like in 3) Orientation test. ~1 photo per 1.5 s."
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
    q|Q) exit 0 ;;
    *) echo "Type 1 to 8, or q."; continue ;;
  esac
  pause
done
