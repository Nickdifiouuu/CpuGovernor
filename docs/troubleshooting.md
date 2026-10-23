# Troubleshooting

## Setup won't start

Windows blocks downloaded scripts by default (execution policy).

- **Easiest:** right-click `Setup.ps1` → **Run with PowerShell**. That runs it
  with a one-time bypass and changes no system setting.
- If that's greyed out or still blocked, open a terminal in the folder and run:
  ```
  powershell -ExecutionPolicy Bypass -File .\Setup.ps1
  ```
- Files from the internet can also be "marked". To clear the mark: right-click the
  file → **Properties** → tick **Unblock**, or in PowerShell:
  `Get-ChildItem -Recurse | Unblock-File`.

## "PowerShell 7 is required and was not found"

The engine needs PowerShell 7 (separate from the built-in Windows PowerShell 5.1):
```
winget install Microsoft.PowerShell
```
Then run Setup again.

## Not sure if it's working

Open **CPU Governor**:
- the **status panel** shows the active cap and `[OK]` on the AC/DC line when a
  cap is in force;
- **Copy Status to Clipboard** gives a text summary you can paste into a bug report.

## I see "NOT CALIBRATED"

You haven't run calibration yet, so no cap tuned to your CPU is in place. Run
`Calibrate.ps1`, or during Setup answer Y to the calibration prompt. See
[calibration.md](calibration.md).

## Want to change my cap

Open the dashboard and click a different profile, or re-run `Calibrate.ps1`.
Lower profiles = lower frequency = more stable but slower.

## The caps keep coming back / something changed them

That's the optional health monitor working as intended: it re-applies your profile
if another program (for example a vendor tuning app) overwrites the power settings,
and re-applies it at boot.

## Something isn't working right

Run `Remove.ps1`, then `Setup.ps1` again. A reinstall also fixes file permissions
if the module stops loading.

## Manual reset (last resort)

From an elevated PowerShell 7 prompt:
```
Import-Module "$env:LOCALAPPDATA\CpuGovernor\app\CpuStabilityGovernor.psd1"
Reset-CpuGovernor -ToDefaults          # remove all caps
Uninstall-CpuGovernorTask              # remove the scheduled tasks (if installed)
```
