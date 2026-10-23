# Does this apply to me?

CPU Governor targets one specific problem: Intel 13th/14th Gen **mobile (HX)**
processors that become unstable and crash — often under kernel-level anti-cheats
like Riot Vanguard or PUBG's Zakynthos.

## Step 1 — run the check

Right-click `Test-Applicability.ps1` → **Run with PowerShell**. It changes
nothing and prints one of three results.

It looks at:

- **CPU model** — must be an Intel 13th/14th Gen mobile HX part
  (i5/i7/i9-13xxxHX or -14xxxHX).
- **WHEA hardware errors** in the last 90 days (event IDs 17, 18, 19, 20, 47).
- **Bugchecks / blue screens** in the last 90 days (event ID 1001).

## Step 2 — read the result

| Result | Meaning | What to do |
|---|---|---|
| **No** | Not a 13th/14th Gen Intel HX CPU | Stop. The governor would only slow your machine down. |
| **Yes** | HX CPU **and** WHEA errors on record | Install and run `Calibrate.ps1`. |
| **Uncertain** | HX CPU, no WHEA errors | If you also have blue screens on record, run `Calibrate.ps1`. If no errors at all, you can skip calibration for now and only run it if crashes appear later. |

## Step 3 — calibrate (if recommended)

`Calibrate.ps1` tests your specific CPU and tells you one of three things:
your chip is **healthy** (no cap needed), **degraded** (a safe cap is applied),
or **unrecoverable** (too far gone for a cap to help — contact your manufacturer
or Intel for service). See [calibration.md](calibration.md).

## Notes

- The instability is often **silent** — crashes with nothing logged. "No WHEA
  errors" does not guarantee your chip is fine, which is why calibration exists.
- This tool was built and tested on mobile HX parts. Desktop 13th/14th Gen chips
  are affected by the same Intel issue, but the bundled profiles assume a laptop.
