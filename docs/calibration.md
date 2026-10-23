# Calibration

The bundled profile values are examples. Calibration tests **your** CPU and acts
on what it finds. Run it from Setup (answer Y to "Run calibration now?") or later
with `Calibrate.ps1`.

## What it does

It applies a descending ladder of P-core caps — 5000, 4800, 4600, 4400, 4200,
4000, 3800 MHz — and, at each level, runs a stack-unwinder torture test on CPU 0.
A level fails if it produces corrupted results, a WHEA error, or a crash.

- Takes **30–60 minutes**. Don't use the PC while it runs — results depend on
  light, bursty load reaching top boost clocks.
- **A crash during a high level is expected** on a degraded chip. It's recorded
  as a failure; just run `Calibrate.ps1` again to resume where it stopped.
- Re-runnable any time (degradation shifts the safe point downward over time).

## The three outcomes

**Healthy — no errors at any frequency.**
Your CPU completed every level cleanly. No cap is installed. If you still crash
under an anti-cheat, the trigger may be condition-specific: open the GUI and try
the **Sustained** profile; if crashes stop, keep it.

**Degraded — errors at some frequencies but not others.**
The highest frequency that passed, minus a 100 MHz safety margin, becomes your
cap. It's saved as a **Calibrated** profile and applied automatically. You can
switch profiles from the GUI any time.

**Unrecoverable — errors at every frequency, down to 3800 MHz.**
Even the lowest tested frequency was unstable, so a cap can't stabilize this CPU.
Contact your laptop manufacturer or Intel for service. To keep using the laptop
meanwhile, try the **TurboOff** profile (it may reduce crashes) and back up your
data regularly.

## The report

Each run writes `calibration_result.md` into the install folder with the verdict
and the pass/fail table. Open it any time from the GUI's **Open calibration
result** button. See [examples/calibration-report-template.md](../examples/calibration-report-template.md)
for the format.
