# Hardware log (Pi #1, bear relay)

## 2026-10-12: relay → Try Me wiring shorts (intermittent dance)
- **Symptom:** the relay on BCM17 clicks on every pulse, but the bear only dances sometimes. The same 1.5 s pulse danced at 01:10:49 (Pi clock) and failed at 01:13.
- **Cause:** the relay output → bear "Try Me" wires aren't insulated properly. Bare parts short or only touch sometimes. Tony is taping them.
- **Pulse-length results so far are UNRELIABLE:**
  - Run 1: 1 / 1.2 / 1.5 / 2 s no dance; 3 s and a 2×0.3 s double tap danced.
  - Run 2: not recorded.
  - Don't change the default pulse until a rerun after the fix gives the real minimum.
- **Pi side verified OK:**
  - GPIO17 goes HIGH (~3.3 V measured).
  - Relay VCC is on the + rail, fed from 5V0. SIG is in the GPIO17 row. The bear wires are on COM + NO.
- **Earlier no-dance causes, fixed:**
  - SIG was not in the GPIO17 row (wrong breadboard row).
  - The bear was switched OFF.
