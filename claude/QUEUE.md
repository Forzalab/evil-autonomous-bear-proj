# Activity queue — decisions

Status: BUILT in `claude/activity.py` (policy `ActivityQueue` + one thread `ActivityWorker`), wired in `claude/__main__.py`. Hard deadline Wed Oct 28.
Precedent: McKay's `src/barnaby/audio_coordinator.py` (mckay/main 07b5971). It covers audio only (one worker, Gemini first, effects ≤2, expiry, cooldown).

## Decided (Tony + group, 2026-10-23)
- One queue for movements + sounds, rebuilt from scratch.
- Ordered by time, and each item carries its duration.
- Priority: Gemini lines first.
- Everything detected is queued (hand, growl, Gemini line), except a repeat of a kind that is already waiting or running (the "bucket": waves during a dance make one dance).
- Delay is accepted for now.
- Sound tests are skipped for now (group directive); wheels are tested first.

## Open (to decide before building)
- Queue growth: a dance is ~20 s and can't be stopped; detections can arrive faster than that.
- Staleness: what an item queued long ago means when it finally plays.
- Overlap: which activities may run at the same time (speaker vs Try Me vs wheels vs power).

## How it runs
- Kinds: `dance` (relay blip + PRETEXT yell, holds `DANCE_S`=25 s, > Try Me lock ~22 s), `gemini` (spoken line, priority 0, no bucket), `cmd` (argv, e.g. a wheel move; not triggered by anything yet).
- One at a time. Each item holds the bear for max(run time, duration).
- Bucket starts when the dance starts: a kid waving every 3 s from t=3 gets dances at 3, 27, 51 (test `test_tony_example_...`).
- Tune: `DANCE_S` env. Priorities: `claude/activity.py` `PRIORITY`.
