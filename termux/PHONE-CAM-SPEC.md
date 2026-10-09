# PHONE-CAM-SPEC — Tony's phone as barnaby's Pi cam

Target pipeline: `termux-camera-photo -c ID f.jpg` → load → 640x480 → barnaby (`--width 640 --height 480`, inference downscaled to 320 wide).
Tags: **M** = MEASURED on Tony's phone, **VS** = VERIFIED-SOURCE (see Sources #), **C** = COMPUTED, **E** = ESTIMATE, **P** = PREDICTION, **U** = UNKNOWN.

## 1. Phone cameras (input: camera-info.json)

FOV = 2·atan(sensor/(2·f)) on physical sensor size [C]. Real output FOV may be a few degrees smaller (active-array crop, lens distortion correction) [E].

| ID | Facing | f mm | Sensor mm | HFOV° | VFOV° | DFOV° | JPEG termux uses | Aspect | MP |
|---|---|---|---|---|---|---|---|---|---|
| 0 | back  | 5.4 | 8.16 x 6.12 | 74.1 | 59.1 | 86.7 | 4080x3060 | 4:3 (1.3333) | 12.5 |
| 1 | front | 3.3 | 4.48 x 3.36 | 68.3 | 54.0 | 80.6 | 4000x3000 | 4:3 (1.3333) | 12.0 |
| 2 | back  | 2.2 | 5.6 x 4.2   | 103.7 | 87.3 | 115.7 | 4000x3000 | 4:3 (1.3333) | 12.0 |
| 3 | front | 3.3 | 3.799 x 2.849 | 59.9 | 46.7 | 71.5 | 3392x2544 | 4:3 (1.3333) | 8.6 |

- "JPEG termux uses" = largest JPEG size by area [VS #2: `Collections.max(sizes, bySize)` on `getOutputSizes(JPEG)`]; confirmed for ID 3 (3392x2544) and ID 1 (4000x3000) [M].
- All four are 4:3 sensor-native → landscape JPEG downsizes to 640x480 with no squash [C].
- ID 3 = same pixel pitch as ID 1 (1.12 µm; 3392/4000 = 3.799/4.48 = 0.848) → likely a center crop of the same front sensor [C/E].
- ID 0 reports `logical_multi_camera` → may switch physical lens internally [E].

## 2. Pi cameras (which one barnaby uses: **U** — README says "CSI cam via Picamera2", no model)

| Pi cam | Sensor | Native aspect | HFOV° | VFOV° | Effective at 640x480 (H x V) | Best phone match |
|---|---|---|---|---|---|---|
| Camera Module v2 (IMX219) | 3.68x2.76 mm, 3280x2464 | 4:3 [VS #1] | 62.2 [VS #1] | 48.8 [VS #1] | 62.2 x 48.8 (no crop) [C] | **ID 3** (59.9x46.7, Δ -2.3/-2.1) |
| Camera Module 3 std (IMX708) | 6.45x3.63 mm, 4608x2592 | 16:9 [VS #1] | 66 [VS #1] | 41 [VS #1] | ~54 x 41 (4:3 center crop) [C/E] | **ID 3** (59.9x46.7) |
| Camera Module 3 Wide (IMX708) | same, f 2.75 | 16:9 [VS #1] | 102 [VS #1] | 67 [VS #1] | ~83 x 67 (4:3 center crop) [C/E] | **ID 0** (74.1x59.1); ID 2 is too wide (104x87) |

- Effective-at-640x480 assumes libcamera crops 16:9 → 4:3 to keep aspect (no squash) [E]. Crop HFOV = 2·atan((3.63·4/3)/(2f)) [C].

## 3. Pick

| Role | ID | Faces | Why |
|---|---|---|---|
| **DEFAULT** | **3** | front (Tony sees himself / screen side) | Closest FOV to CM v2 and CM3-std@4:3 (Δ ≤ 6°), 4:3 → 640x480 clean, smallest JPEG (8.6 MP) = fastest shot/decode. |
| **FALLBACK** | **1** | front | Same sensor, full width; +6° HFOV vs CM v2. Use if ID 3 fails to open / returns black. Both IDs worked on the probe (rc=0) [M]. |
| alt (bear-POV, CM3 Wide) | 0 | back (faces away from Tony) | Only if the bear's cam is a CM3 Wide or the phone is mounted looking at the room. |

## 4. Measured on Tony's phone

Samsung Galaxy S23 SM-S911B, Android 15, Termux 0.119.0-beta.1. All **M**.

| Item | ID 3 | ID 1 |
|---|---|---|
| `termux-camera-photo` rc | 0 | 0 |
| Time per shot | 1.51–1.81 s (first shot slowest) | same range |
| Throughput | ~0.65 fps | ~0.65 fps |
| Raw JPEG pixels | 3392x2544 landscape | 4000x3000 landscape |
| EXIF Orientation | 8 on every shot (phone held sideways) | 8 on every shot (phone upright) |

| Other | Value |
|---|---|
| Pixel orientation vs pose | pixels always landscape, never rotated by termux-api/HAL; EXIF 8 does not follow device pose (= sensor orientation) |
| `termux-storage-get` | returns in 0.27 s, file ready after ~2.9–4.0 s (117 KB) → **async**, poll for the file |
| Python | 3.14.6 present; numpy / cv2 **not installed**; x11-repo **not enabled** |

## 5. Orientation / mirror rules

| Rule | Detail | Tag |
|---|---|---|
| Decode | `cv2.imread(path, cv2.IMREAD_COLOR \| cv2.IMREAD_IGNORE_ORIENTATION)` → raw 4:3 landscape → `INTER_AREA` resize to 640x480 (Pi-like, no squash) | M / VS #4 |
| Do NOT apply EXIF | plain `IMREAD_COLOR` applies EXIF 8 → every frame becomes portrait 2544x3392 → wrong (squash or 90° rotated scene) | M / VS #4 |
| EXIF 8 meaning | "Rotate 270 CW" (= stored image must be rotated 90° CCW to display upright) | VS #6 |
| Upright sideways direction | raw pixels = upright-portrait view rotated 90° CW → raw is upright when the phone is turned **90° CCW from portrait** (as Tony sees the screen): top edge / front camera on Tony's **left**, side buttons (right edge on S23) pointing **up** | **P** (derived from EXIF 8 + front cam unmirrored; confirm with preview) |
| Other sideways direction | camera on Tony's right → upside-down frames → turn the phone the other way | P |
| Front-cam mirroring | Camera2 still JPEGs are not mirrored (preview mirroring is app-side); termux-api adds no flip | E / VS #2 |
| Mirror sensitivity | `classify_gesture` uses finger extension + thumb **y** only; no left/right logic → mirror does not matter | VS (repo gestures.py) |
| Upright sensitivity | `thumbs_up` needs thumb tip above thumb base in image y; 90°/180°-rotated frames kill thumbs_up and degrade YuNet | VS (repo gestures.py) |

**Rule for Tony:** hold/mount the phone **sideways**. One sideways direction gives an upright scene, the other upside-down. Predicted upright: camera on the left, side buttons up [P]. Check with the deploy script's **"Camera preview"** item; if upside-down, turn the phone the other way.

**Deploy script:** decode with `IMREAD_IGNORE_ORIENTATION`; if aspect ≠ 4:3, center-crop first; resize to 640x480 `INTER_AREA`; no `--flip` needed.

## 6. Known gaps vs Pi

| Gap | Phone/termux | Pi (Picamera2) | Tag |
|---|---|---|---|
| Frame rate | **~0.65 fps** (1.5–1.8 s per still) | 30 fps video, 640x480 directly | M / VS #1 |
| Per-shot cost | open camera + 500 ms preview (AE/AF settle) + capture + close, every shot | ~33 ms | VS #2 / M |
| AE/AF/AWB | reset each shot; only 500 ms to converge → exposure/focus can flicker | continuous | VS #2 / E |
| Gesture hold time | `--stable-frames 1` → hold ~1.5–3 s; default `--stable-frames 3` → ~4.5–6 s | 3 frames ≈ 0.1 s | C (from M) / VS (repo app.py) |
| Honest timing | stills can't reproduce Pi debounce; record 30 fps video and feed it via `--realtime` for Pi-like timing and true debounce counts | — | C |
| Capture size | 8.6–12 MP JPEG decode each shot on phone CPU | 640x480 RGB888 | M / VS (repo camera.py) |
| File handoff | `termux-storage-get` is async (file lands ~3–4 s later) | — | M |
| Motion blur / AF hunting | possible on hand motion | — | E |
| Concurrency | one `termux-camera-photo` at a time; camera busy if another app holds it | — | E |

## Sources

1. Raspberry Pi camera docs (hardware specifications table) — https://www.raspberrypi.com/documentation/accessories/camera.html
2. termux-api `CameraPhotoAPI.java` (largest JPEG, 500 ms preview, JPEG_ORIENTATION calc, no mirror) — https://github.com/termux/termux-api/blob/master/app/src/main/java/com/termux/api/apis/CameraPhotoAPI.java
3. Android `CaptureRequest.JPEG_ORIENTATION` ("may either encode this value into the JPEG EXIF header, or rotate the image data") — https://developer.android.com/reference/android/hardware/camera2/CaptureRequest#JPEG_ORIENTATION
4. OpenCV ImreadModes (`IMREAD_IGNORE_ORIENTATION`: "do not rotate the image according to EXIF's orientation flag"; `IMREAD_UNCHANGED` ignores EXIF) — https://docs.opencv.org/4.x/d8/d6a/group__imgcodecs__flags.html
5. Repo (read-only): `/home/user/forzalab/evil-autonomous-bear-proj/src/barnaby/{camera.py,app.py,gestures.py}`
6. EXIF Orientation values (8 = "Rotate 270 CW") — https://exiftool.org/TagNames/EXIF.html
