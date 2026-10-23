# Activity queue — decisions

Status: design, not built. Hard deadline Wed Oct 28.
Precedent: McKay's `src/barnaby/audio_coordinator.py` (mckay/main 07b5971). It covers audio only (one worker, Gemini first, effects ≤2, expiry, cooldown).

## Decided (Tony + group, 2026-10-23)
- One queue for movements + sounds, rebuilt from scratch.
- Ordered by time, and each item carries its duration.
- Priority: Gemini lines first.
- Everything detected is queued (hand, growl, Gemini line). Nothing is dropped.
- Delay is accepted for now.
- Sound tests are skipped for now (group directive); wheels are tested first.

## Open (to decide before building)
- Queue growth: a dance is ~20 s and can't be stopped; detections can arrive faster than that.
- Staleness: what an item queued long ago means when it finally plays.
- Overlap: which activities may run at the same time (speaker vs Try Me vs wheels vs power).
