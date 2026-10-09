"""Camera demo: python -m barnaby --source 0 (press Q to quit)."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import math
import os
from pathlib import Path
import time

import cv2

from .camera import Camera
from .gestures import HAND_CONNECTIONS, StableLabel
from .models import DEFAULT_MODEL_DIR
from .reactions import PerceptionEvent, on_perception, on_scene_description
from .scene import MODEL, describe_scene
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
    parser.add_argument("--check", action="store_true", help="Verify weights and run all models without a camera")

    # Optional cloud captioning; the local detection models continue as before.
    parser.add_argument("--scene", action="store_true", help="Describe people using Gemini 3.8 Flash")
    parser.add_argument("--scene-model", default=MODEL, help="Gemini model ID")
    parser.add_argument("--scene-interval", type=float, default=10.0,
                        help="Minimum seconds between starting Gemini requests")
    parser.add_argument("--scene-timeout", type=float, default=25.0,
                        help="Gemini request timeout in seconds")
    parser.add_argument("--scene-image-width", type=positive, default=512,
                        help="Maximum width of image submitted to Gemini")
    args = parser.parse_args(argv)

    if not math.isfinite(args.interval) or args.interval < 0:
        parser.error("--interval must be finite and nonnegative")
    if not math.isfinite(args.scene_interval) or args.scene_interval <= 0:
        parser.error("--scene-interval must be finite and positive")
    if not math.isfinite(args.scene_timeout) or args.scene_timeout <= 0:
        parser.error("--scene-timeout must be finite and positive")
    if args.scene and not args.check and not os.getenv("GEMINI_API_KEY"):
        parser.error("GEMINI_API_KEY must be set when --scene is enabled")
    if args.save_video and not args.picamera and not args.source.isdecimal():
        if args.save_video.resolve() == Path(args.source).resolve():
            parser.error("--save-video must differ from the input video")

    camera = None
    writer = None
    scene_executor = None
    scene_future = None
    next_scene_at = 0.0
    try:
        vision = Vision(args.model_dir, args.threads)
        if args.check:
            vision.check()
            print(f"All four models verified and ran on CPU (OpenCV {cv2.__version__}).")
            return

        camera = Camera(args.source, args.width, args.height, args.picamera, args.realtime, args.loop)
        if args.scene:
            scene_executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="barnaby-gemini")

        gesture_filter, expression_filter = StableLabel(args.stable_frames), StableLabel(args.stable_frames)
        previous = ("none", "none")
        count, next_inference = 0, 0.0
        observation = Observation()
        print("Barnaby vision running. Press Q in the preview or Ctrl+C to stop.")
        if args.scene:
            print(f"Gemini descriptions enabled: {args.scene_model} (every {args.scene_interval:g}s)")

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
            small = cv2.resize(
                frame,
                (max(1, round(frame.shape[1] * scale)), max(1, round(frame.shape[0] * scale))),
            )
            now = time.monotonic()

            # Offline analysis visits every frame; realtime playback uses the camera interval.
            if (camera.is_file and not args.realtime) or now >= next_inference:
                observation = vision.infer(small)
                next_inference = now + args.interval
                labels = (gesture_filter.update(observation.gesture), expression_filter.update(observation.expression))
                if labels != previous:
                    on_perception(PerceptionEvent(*labels, observation.hand_confidence,
                                                   observation.face_confidence, observation.inference_ms))
                    previous = labels

            if scene_executor is not None:
                # Consume finished Gemini responses without waiting for the network.
                if scene_future is not None and scene_future.done():
                    try:
                        description = scene_future.result()
                        on_scene_description(description)
                    except Exception as error:
                        print(f"[Barnaby Gemini error] {error}", flush=True)
                        # Back off after failed requests (e.g., rate limits).
                        next_scene_at = max(next_scene_at, time.monotonic() + 30.0)
                    finally:
                        scene_future = None

                # Sample the original camera frame so people remain visible.
                # Never queue up overlapping requests if the API is slow.
                if scene_future is None and time.monotonic() >= next_scene_at:
                    scene_future = scene_executor.submit(
                        describe_scene,
                        frame.copy(),
                        args.scene_model,
                        image_width=args.scene_image_width,
                        timeout=args.scene_timeout,
                    )
                    next_scene_at = time.monotonic() + args.scene_interval

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
        if scene_executor is not None:
            scene_executor.shutdown(wait=False, cancel_futures=True)
        if writer is not None:
            writer.release()
        if camera is not None:
            camera.close()
        if not args.headless and not args.check:
            cv2.destroyAllWindows()
