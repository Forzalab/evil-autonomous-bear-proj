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

## 2026-10-13 01:27–01:29 — post-tape rerun: relay clicks, NO dance at any width
| width | try 1 |
|---|---|
| 0.3 s | click, no dance |
| 1.5 s | click, no dance |
| 3.0 s | click, no dance |
- No width reached 3/3. After taping, the relay output no longer triggers the bear: the trigger circuit is likely open (a taped joint broken or insulated where it must touch) or not on COM + NO.
- Next: short the two bear wires together by hand (bear ON) to test the bear side; meter-check COM–NO continuity while the Pi holds pin 17 high.

## 2026-10-13 01:48 — SIG moved from GPIO17 to SDA1 (BCM2, physical pin 3)
- Observation (Tony): physically plugging SIG into SDA1, or into any pin/rail with voltage, makes the bear dance right away ("kickstart").
- Why: SDA1 has a permanent 1.8 kΩ pull-up to 3.3 V on the Pi board, so it idles HIGH. SIG on SDA1 = relay ON at rest. The plug-in moment = relay closes = bear triggers.
- Scripted GPIO17 pulses (0.3–3 s): relay clicks, no dance (post-tape runs). Hand plug-in to voltage: dance. Open question: steady close vs. pulse.
- Pi rebooted twice during pulse runs (01:17, 01:47; power bank shut off). Possible brownout or power-bank cutoff; watch power.
- Test on SDA1 is inverted: drive BCM2 LOW = relay OFF, release to input (pull-up) = relay ON (like a plug-in).
- RESULT 01:50–01:51 (SIG on SDA1): Tony reports "works!": the bear danced on the SDA tests (relay OFF 5 s → back ON and held ON).
- Takeaway: the bear triggers when the relay closes AND STAYS closed. Short closes (0.3–3 s on GPIO17, post-tape) did not trigger it. Untested with the bear ON and working wiring: a long hold (≥5–10 s) on GPIO17. The 10 s holds at 01:07 had the bear switched OFF.
- RESULT 01:52–01:53 (SIG on SDA1): relay OFF only 0.3 s → back ON and held: 3/3 DANCED ("all works").
- CONCLUSION: the trigger that works is "relay normally CLOSED (held), brief OPEN of 0.3 s, then CLOSED again". Short ON pulses from a normally-OPEN relay (0.3–3 s) did not work after taping.

## 2026-10-13 01:57–02:05 — full chain, wheels, reboots
- Full chain (camera + Gemini flash-lite + dance bridge via dance_sda.sh, no wheels, 120 s): 4 dances fired with pretext yells, 12 Gemini lines spoken, 21 hand events, no errors. Some Gemini lines were too dark for kids (McKay's prompt in scene.py).
- dance_launch.py now caps Gemini at GEMINI_MAX=5 calls per run, then answers "Quack quack!".
- Wheels: wheel_test 1 and 2, 700 steps fwd each, 5.0 s each, exit 0, pins idle afterwards.
- Pi rebooted a THIRD time (02:02, during the gremlin show). All 3 reboots happened while relay/wheels were in use → likely power-bank brownout/cutoff. Use a steadier 5 V/5 A supply.
- Boot is now silent (no voice cues) and starts `claude rc` when online.
