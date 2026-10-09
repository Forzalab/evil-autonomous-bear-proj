#!/usr/bin/env bash
# bear.sh: install and run the bear vision program in Termux with the phone camera (numbered menu).
# Run: bash ~/storage/downloads/bear.sh   (first time; then: bash ~/bear.sh, or "bear" after menu 7)
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

cam() {  # The selected camera ID from ~/.bear.conf (default 3).
  local id
  id=$(sed -n 's/^CAM=\([0-3]\)$/\1/p' "$CONF" 2>/dev/null | tail -n 1)
  echo "${id:-3}"
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
index d5ec0f8..dfbd6cd 100644
--- a/src/barnaby/camera.py
+++ b/src/barnaby/camera.py
@@ -1,24 +1,113 @@
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
 
 
+def load_photo(path, size):
+    """Termux:API JPEG -> BGR frame of `size` (Pi-like 640x480), or None.
+
+    The raw pixels are always landscape and the EXIF orientation is fixed (8), so
+    ignore EXIF. A portrait photo (safety net only) is centre-cropped, never squashed.
+    """
+    frame = cv2.imread(path, cv2.IMREAD_COLOR | cv2.IMREAD_IGNORE_ORIENTATION)
+    if frame is None:
+        return None
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
+_portrait_warned = False
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
@@ -50,6 +139,8 @@ class Camera:
         self.looped = False
         if self._pi is not None:
             return True, self._pi.capture_array("main")
+        if self._termux is not None:
+            return self._termux.read()
         if self.realtime and self._next_frame_at is not None:
             time.sleep(max(0.0, self._next_frame_at - time.monotonic()))
         ok, frame = self._capture.read()
@@ -66,7 +157,9 @@ class Camera:
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

patch_repo() {  # Apply the Termux camera patch once. Safe to do again.
  local p="${TMPDIR:-/tmp}/bear-termux-camera.patch"
  write_patch > "$p"
  if git -C "$REPO" apply --reverse --check "$p" 2>/dev/null; then
    ok "camera patch is already applied"
  elif git -C "$REPO" apply --check "$p" 2>/dev/null && git -C "$REPO" apply "$p"; then
    ok "camera patch applied"
  else
    fail "camera patch does not apply (the code changed). Tell Claude."
  fi
}

setup() {
  local dpkg=(-y -o Dpkg::Options::=--force-confnew) p
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
    p="${TMPDIR:-/tmp}/bear-termux-camera.patch"
    write_patch > "$p"
    # Remove our patch first, so that git pull can fast-forward.
    git -C "$REPO" apply --reverse --check "$p" 2>/dev/null && git -C "$REPO" apply --reverse "$p"
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
    ok "SETUP DONE. Now do 2) Camera preview."
  else
    fail "model check. Do 1) again. If it fails again, tell Claude."
  fi
}

camera_preview() {  # One photo, made exactly like the bear sees it (no EXIF turn, 640x480).
  local id raw out size
  need_bear || return 1
  id=$(cam); mkdir -p "$PROBE"; raw="$PROBE/raw.jpg"; out="$PROBE/preview.jpg"
  rm -f "$raw" "$out"
  echo "Taking 1 photo with camera $id, ${CAM_NAMES[$id]} (max 20 s)..."
  if ! timeout -k 2 20 "$PHOTO" -c "$id" "$raw" || [ ! -s "$raw" ]; then
    fail "no photo from camera $id in 20 s."
    echo "  1. Install the Termux:API app from the SAME store as Termux (F-Droid or GitHub)."
    echo "  2. Android Settings > Apps > Termux:API > Permissions > Camera: Allow."
    echo "  3. Close all camera apps, then try again. Or do 6) Pick camera."
    return 1
  fi
  size=$(cd "$REPO" && PYTHONPATH=src timeout 60 python -c '
import sys, cv2
from barnaby.camera import load_photo
frame = load_photo(sys.argv[1], (640, 480))
if frame is None or not cv2.imwrite(sys.argv[2], frame):
    sys.exit(1)
print(f"{frame.shape[1]}x{frame.shape[0]}")' "$raw" "$out") || { fail "could not read the photo."; return 1; }
  ok "preview $size: $out"
  timeout 10 termux-open "$out" >/dev/null 2>&1 || echo "Open it in the Files app: $out"
  echo "If the picture is upside down or sideways, turn the phone the other way and try again."
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
  id=$(cam)
  echo "Hold the phone sideways. Run Camera preview first. ~1 photo per 1.5 s."
  echo "Camera $id, ${CAM_NAMES[$id]}."
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
  local i id
  for i in "${CAM_ORDER[@]}"; do echo "  $i) ${CAM_NAMES[$i]}"; done
  read -r -p "Type the camera number, then push Enter [$(cam)]: " id || exit 0
  id=${id:-$(cam)}
  [[ "$id" =~ ^[0-3]$ ]] || { fail "type 3, 1, 0 or 2"; return 1; }
  echo "CAM=$id" > "$CONF" && ok "camera $id, ${CAM_NAMES[$id]}, is saved. Do 2) Camera preview."
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
 3) Run bear LIVE
 4) Run bear LIVE + trigger
 5) Run on a recorded video
 6) Pick camera (now: $id, ${CAM_NAMES[$id]})
 7) Install shortcut "bear"
 q) Quit
MENU
  read -r -p "Type a number, then push Enter: " choice || exit 0
  case "$choice" in
    1) setup ;;
    2) camera_preview ;;
    3) run_live ;;
    4) run_live --trigger "$TRIGGER_GESTURE" ;;
    5) run_video ;;
    6) pick_camera ;;
    7) shortcut ;;
    q|Q) exit 0 ;;
    *) echo "Type 1 to 7, or q."; continue ;;
  esac
  pause
done
