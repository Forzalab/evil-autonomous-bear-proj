"""Camera demo: python -m barnaby --source 0 (press Q to quit)."""

import argparse
import math
from pathlib import Path
import time

import cv2

from .camera import Camera
from .gestures import HAND_CONNECTIONS, StableLabel
from .models import DEFAULT_MODEL_DIR
from .reactions import PerceptionEvent, on_perception
from .trigger import ANY, OneShot
from .vision import Observation, Vision


def positive(value: str) -> int:
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError("must be positive")
    return number


def overlay(frame, observation: Observation, gesture: str, expression: str):
    if observation.face_box:
        x, y, w, h = observation.face_box
        cv2.rectangle(frame, (x, y), (x + w, y + h), (0, 220, 0), 2)
    if observation.hand_points is not None:
        points = observation.hand_points[:, :2].astype(int)
        for a, b in HAND_CONNECTIONS:
            cv2.line(frame, tuple(points[a]), tuple(points[b]), (255, 160, 0), 2)
        for point in points:
            cv2.circle(frame, tuple(point), 3, (0, 240, 255), -1)
    text = f"Gesture: {gesture} | Expression: {expression} | {observation.inference_ms:.0f} ms"
    cv2.putText(frame, text, (10, 25), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 240, 255), 1, cv2.LINE_AA)


def unit_interval(value: str) -> float:
    number = float(value)
    if not 0.0 <= number <= 1.0:
        raise argparse.ArgumentTypeError("must be between 0 and 1")
    return number


def main(argv=None) -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", default="0", help="USB camera index or video path")
    parser.add_argument("--picamera", action="store_true", help="Use a Pi CSI camera via Picamera2")
    parser.add_argument("--model-dir", type=Path, default=DEFAULT_MODEL_DIR)
    parser.add_argument("--width", type=positive, default=640)
    parser.add_argument("--height", type=positive, default=480)
    parser.add_argument("--inference-width", type=positive, default=320, help="Downscale inference to save CPU")
    parser.add_argument("--interval", type=float, default=0.15, help="Minimum seconds between inference starts")
    parser.add_argument("--threads", type=positive, default=2)
    parser.add_argument("--stable-frames", type=positive, default=3, help="Consecutive inference observations")
    parser.add_argument("--headless", action="store_true", help="Print events without a preview window")
    parser.add_argument("--max-frames", type=positive, help="Stop after this many captured frames")
    parser.add_argument("--realtime", action="store_true", help="Play a video at its source frame rate")
    parser.add_argument("--loop", action="store_true", help="Repeat a video until Q or Ctrl+C")
    parser.add_argument("--save-video", type=Path, help="Write an annotated MP4, including in headless mode")
    parser.add_argument("--trigger", metavar="GESTURE", help="Print 'BEAR: dance' once per shown GESTURE (off by default); "
                        "'any' = any detected hand, re-firing every cooldown while hands stay up")
    parser.add_argument("--trigger-cooldown", type=float, default=20.0, help="Seconds between triggers (one bear dance)")
    tune = parser.add_argument_group("detection tolerances (lower = more hands/faces found, more false ones)")
    tune.add_argument("--palm-threshold", type=unit_interval, default=0.65, help="Palm detector min score")
    tune.add_argument("--palm-nms", type=unit_interval, default=0.3, help="Palm box overlap (IoU) merge threshold")
    tune.add_argument("--hand-threshold", type=unit_interval, default=0.8, help="Hand landmark min confidence")
    tune.add_argument("--face-threshold", type=unit_interval, default=0.8, help="Face detector min score")
    tune.add_argument("--face-nms", type=unit_interval, default=0.3, help="Face box overlap (IoU) merge threshold")
    parser.add_argument("--check", action="store_true", help="Verify weights and run all models without a camera")
    args = parser.parse_args(argv)
    if not math.isfinite(args.interval) or args.interval < 0:
        parser.error("--interval must be finite and nonnegative")
    if args.save_video and not args.picamera and not args.source.isdecimal():
        if args.save_video.resolve() == Path(args.source).resolve():
            parser.error("--save-video must differ from the input video")
    camera = None
    writer = None
    try:
        vision = Vision(args.model_dir, args.threads, args.palm_threshold, args.palm_nms,
                        args.hand_threshold, args.face_threshold, args.face_nms)
        if args.check:
            vision.check()
            print(f"All four models verified and ran on CPU (OpenCV {cv2.__version__}).")
            return
        camera = Camera(args.source, args.width, args.height, args.picamera, args.realtime, args.loop)
        gesture_filter, expression_filter = StableLabel(args.stable_frames), StableLabel(args.stable_frames)
        previous = ("none", "none")
        trigger = None
        if args.trigger == ANY:
            trigger = OneShot(ANY, args.trigger_cooldown, rearm_s=0.0, repeat_while_held=True)
        elif args.trigger:
            trigger = OneShot(args.trigger, args.trigger_cooldown)
        count, next_inference = 0, 0.0
        observation = Observation()
        print("Barnaby vision running. Press Q in the preview or Ctrl+C to stop.")
        while True:
            ok, frame = camera.read()
            if not ok:
                if camera.is_file:
                    break
                raise RuntimeError("Camera stopped returning frames")
            if camera.looped:
                gesture_filter = StableLabel(args.stable_frames)
                expression_filter = StableLabel(args.stable_frames)
                observation, previous, next_inference = Observation(), ("none", "none"), 0.0
            scale = min(1.0, args.inference_width / frame.shape[1])
            small = cv2.resize(frame, (max(1, round(frame.shape[1] * scale)), max(1, round(frame.shape[0] * scale))))
            now = time.monotonic()
            # Offline analysis visits every frame; realtime playback uses the camera interval.
            if (camera.is_file and not args.realtime) or now >= next_inference:
                observation = vision.infer(small)
                next_inference = now + args.interval
                labels = (gesture_filter.update(observation.gesture), expression_filter.update(observation.expression))
                event = PerceptionEvent(*labels, observation.hand_confidence,
                                        observation.face_confidence, observation.inference_ms,
                                        round(observation.expression_confidence, 3))
                if labels != previous:
                    on_perception(event)
                    previous = labels
                # Fed every inference (not only on changes) so a held hand can re-fire after the cooldown.
                if trigger and trigger.feed(event, now):
                    print("BEAR: dance", flush=True)
            if not args.headless or args.save_video:
                overlay(small, observation, gesture_filter.value, expression_filter.value)
            if args.save_video:
                if writer is None:
                    args.save_video.parent.mkdir(parents=True, exist_ok=True)
                    writer = cv2.VideoWriter(str(args.save_video), cv2.VideoWriter_fourcc(*"mp4v"),
                                             camera.fps, (small.shape[1], small.shape[0]))
                    if not writer.isOpened():
                        raise RuntimeError(f"Could not create output video {args.save_video}")
                writer.write(small)
            if not args.headless:
                cv2.imshow("Barnaby Bear", small)
                if cv2.waitKey(1) & 0xFF == ord("q"):
                    break
            count += 1
            if args.max_frames and count >= args.max_frames:
                break
            if args.headless and not camera.is_file:
                time.sleep(0.005)
    except KeyboardInterrupt:
        pass
    except (OSError, ValueError, RuntimeError, cv2.error) as error:
        parser.exit(1, f"Barnaby could not start/run: {error}\n")
    finally:
        if writer is not None:
            writer.release()
        if camera is not None:
            camera.close()
        if not args.headless and not args.check:
            cv2.destroyAllWindows()
