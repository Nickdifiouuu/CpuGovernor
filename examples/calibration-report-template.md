# Calibration report (template)

> This is a **template**, not real data. `Calibrate.ps1` writes your own
> `calibration_result.md` into the install folder when you run it. This file
> just shows what that report looks like and how to read it.

- **CPU:** [YOUR CPU MODEL]            <!-- e.g. Intel Core i9-14900HX -->
- **Date:** [DATE]                     <!-- e.g. 2026-01-15 -->
- **Verdict:** [HEALTHY | STABLE_AT_LEVEL | UNRECOVERABLE]
- **Safe cap:** [SAFE FREQUENCY] MHz   <!-- only for STABLE_AT_LEVEL -->
- **Ladder (MHz):** 5000, 4800, 4600, 4400, 4200, 4000, 3800  (per level: 3 min bursty load on CPU 0)

| P-core cap (MHz) | Verdict |
|---|---|
| 5000 | [PASS/FAIL] |
| 4800 | [PASS/FAIL] |
| 4600 | [PASS/FAIL] |
| 4400 | [PASS/FAIL] |
| 4200 | [PASS/FAIL] |
| 4000 | [PASS/FAIL] |
| 3800 | [PASS/FAIL] |

## How to read it

- **HEALTHY** — every level passed. No cap was installed. If you still crash
  under an anti-cheat, try the Sustained profile manually.
- **STABLE_AT_LEVEL** — some levels failed, some passed. The highest passing
  frequency minus a 100 MHz margin is your safe cap; it was applied as the
  `Calibrated` profile.
- **UNRECOVERABLE** — every level failed. A cap cannot stabilise this CPU;
  contact your laptop manufacturer or Intel for service. Try TurboOff meanwhile.

Re-run `Calibrate.ps1` any time (degradation shifts the safe point downward over time).
