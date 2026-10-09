#!/data/data/com.termux/files/usr/bin/bash
# probe.sh: read-only check of this phone for bear-vision (Termux, Python, OpenCV, camera, file picker). Copies a report to the clipboard.
# Run: bash ~/storage/downloads/probe.sh
set -u
D="$HOME/bear-probe"; R="$D/report.txt"
mkdir -p "$D"; : > "$R"
r() { echo "$*" >> "$R"; }
have() { command -v "$1" >/dev/null 2>&1; }
now() { date +%s.%N; }
dt() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.2f", b-a}'; }
r "PROBE_DATE=$(date '+%Y-%m-%d %H:%M:%S')"

# 1. termux-info
echo "Step 1: Termux info."
if have termux-info; then
  timeout 20 termux-info 2>/dev/null | awk '
    /^TERMUX_APK_RELEASE=|^TERMUX_VERSION=/ {print; next}
    /^Android version:|^Device manufacturer:|^Device model:/ {
      k=toupper($0); sub(/:.*/,"",k); gsub(/ /,"_",k); getline v; print k "=" v }' >> "$R"
else r "MISSING termux-info"; fi

# 2. storage
echo "Step 2: Storage."
for s in downloads dcim; do
  if [ -d "$HOME/storage/$s" ]; then r "STORAGE_${s^^}=yes"; else r "STORAGE_${s^^}=no"; fi
done

# 3. Python, numpy, OpenCV
echo "Step 3: Python and OpenCV."
PY=""; have python && PY=python
if [ -n "$PY" ]; then
  r "PYTHON=$(timeout 20 python -V 2>&1)"
  timeout 20 python - >> "$R" 2>/dev/null <<'EOF' || r "PY_CHECK=FAILED"
try:
    import numpy; print("NUMPY=" + numpy.__version__)
except Exception: print("MISSING numpy")
try:
    import cv2
except Exception:
    print("MISSING cv2"); raise SystemExit
print("CV2=" + cv2.__version__)
print("CV2_DNN_ONNX=%s" % hasattr(getattr(cv2, "dnn", None), "readNetFromONNX"))
ff = [l for l in cv2.getBuildInformation().splitlines() if l.strip().startswith("FFMPEG:")]
print("CV2_FFMPEG=" + ("YES" if ff and "YES" in ff[0] else "NO"))
EOF
else r "MISSING python"; fi

# 4. packages in the repo (no install)
echo "Step 4: Package list."
if have apt-cache; then
  r "APT=$(timeout 20 apt-cache policy opencv-python python-numpy python 2>/dev/null \
    | grep -E '^[a-z]|Candidate' | paste -sd' ' - | tr -s ' ')"
else r "MISSING apt-cache"; fi
SL="${PREFIX:-/data/data/com.termux/files/usr}/etc/apt/sources.list.d"
src=""; x11=no
for f in "$SL"/*; do [ -e "$f" ] || continue; src="$src${src:+,}${f##*/}"; case "$f" in *x11*) x11=yes;; esac; done
r "SOURCES_D=$src"; r "X11_REPO=$x11"

# 5. camera timing and image size
dims() { # prints raw=WxH exif=WxH orient=N (or SOF size without cv2)
  [ -n "$PY" ] || { echo "MISSING python"; return; }
  timeout 20 python - "$1" 2>&1 <<'EOF' | tail -1
import sys, struct
p = sys.argv[1]; b = open(p, "rb").read()
o = "?"
for bo, pat in ((">", b"\x01\x12\x00\x03\x00\x00\x00\x01"), ("<", b"\x12\x01\x03\x00\x01\x00\x00\x00")):
    i = b.find(pat, 0, 65536)
    if i >= 0: o = struct.unpack(bo + "H", b[i+8:i+10])[0]; break
try:
    import cv2
    a = cv2.imread(p, cv2.IMREAD_COLOR | cv2.IMREAD_IGNORE_ORIENTATION); e = cv2.imread(p, cv2.IMREAD_COLOR)
    print("raw=%dx%d exif=%dx%d orient=%s" % (a.shape[1], a.shape[0], e.shape[1], e.shape[0], o))
except ImportError:
    i = 2
    while i < len(b) - 9:
        m, n = b[i+1], struct.unpack(">H", b[i+2:i+4])[0]
        if m in (0xC0, 0xC1, 0xC2):
            h, w = struct.unpack(">HH", b[i+5:i+9]); print("sof=%dx%d orient=%s" % (w, h, o)); break
        i += 2 + n
    else: print("sof=NOTFOUND")
except Exception as x: print("dims=ERR " + type(x).__name__)
EOF
}
if have termux-camera-photo; then
  for id in 3 1; do
    echo
    if [ "$id" = 3 ]; then echo "Camera 3: hold the phone SIDEWAYS (landscape). Keep auto-rotate ON."
    else echo "Camera 1: hold the phone UPRIGHT (portrait)."; fi
    for c in 5 4 3 2 1; do echo "  $c"; sleep 1; done
    for i in 1 2 3; do
      f="$D/cam${id}_$i.jpg"; rm -f "$f"
      t0=$(now); timeout 20 termux-camera-photo -c "$id" "$f" >/dev/null 2>&1; rc=$?; t1=$(now)
      if [ -s "$f" ]; then sz=$(wc -c < "$f"); dm=$(dims "$f"); else sz=0; dm="nofile"; fi
      r "CAM${id}_$i=rc=$rc s=$(dt "$t0" "$t1") bytes=$sz $dm"
      echo "  Shot $i done."
    done
  done
else r "MISSING termux-camera-photo"; fi

# 6. file picker timing
echo
if have termux-storage-get; then
  P="$D/picked.bin"; rm -f "$P"
  echo "A file picker will open. Pick any small file."
  t0=$(now); timeout 20 termux-storage-get "$P" >/dev/null 2>&1; t1=$(now)
  last=-1; t2=""
  for _ in $(seq 180); do
    if [ -s "$P" ]; then
      cur=$(wc -c < "$P"); [ "$cur" = "$last" ] && { t2=$(now); break; }; last=$cur
    fi
    sleep 0.5
  done
  if [ -n "$t2" ]; then rd=$(dt "$t0" "$t2"); else rd=TIMEOUT; fi
  r "PICKER=RETURN_S=$(dt "$t0" "$t1") READY_S=$rd SIZE=$( [ -f "$P" ] && wc -c < "$P" || echo 0)"
else r "MISSING termux-storage-get"; fi

# 7. finish
echo; echo "===== REPORT ====="; cat "$R"; echo "=================="
if have termux-clipboard-set; then
  timeout 20 termux-clipboard-set < "$R" && echo "Report copied. Paste it to Claude."
else echo "MISSING termux-clipboard-set. Copy the report above by hand. File: $R"; fi
