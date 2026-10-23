# Install

## Requirements

- **Windows 10 (1809+) or Windows 11.**
- **PowerShell 7** — the tool's engine. Check with `pwsh -v`; install with
  `winget install Microsoft.PowerShell`. Setup stops and tells you if it's missing.
- **Administrator rights.** Setup needs them to register the optional health task
  and to lock its own files against tampering. It asks once, through the standard
  Windows UAC prompt.

## Steps

1. **Download** the repo: green **Code → Download ZIP**, then right-click the ZIP
   → **Extract All** (or `git clone`).
2. In the extracted folder, **right-click `Setup.ps1` → Run with PowerShell**.
   If scripts are blocked, see [troubleshooting.md](troubleshooting.md).
3. **Accept the UAC prompt.** Setup re-launches itself elevated (and under
   PowerShell 7 if you started it on Windows PowerShell).
4. Setup runs the applicability check, copies the files to
   `%LOCALAPPDATA%\CpuGovernor\`, and creates the shortcuts.
5. **Prompt 1 — calibration:** "Run calibration now?" Yes (recommended) tests your
   CPU and applies a safe cap if it finds instability. No applies nothing; you can
   run `Calibrate.ps1` later.
6. **Prompt 2 — health monitor:** "Install the optional background health monitor?"
   Default No installs only the frequency cap. Yes adds a scheduled task that logs
   new CPU errors and re-applies the cap at boot.
7. Open **CPU Governor** from the Start Menu.

## What Setup does

- Copies `app\` and `gui\` (plus the scripts and docs) into `%LOCALAPPDATA%\CpuGovernor\`.
- Creates **Start Menu** and **Desktop** shortcuts named **CPU Governor**.
- Never applies the bundled example caps on its own — a cap comes only from
  calibration or a profile you pick in the GUI.
- If you opt into the monitor, registers two SYSTEM scheduled tasks and makes the
  files that run elevated read-only for standard users.

## Verify it worked

- **Start Menu → CPU Governor** opens the dashboard.
- After calibration or picking a profile, the **AC / DC** line reads `[OK]`.
- `%LOCALAPPDATA%\CpuGovernor\` exists and contains `app\`, `gui\`, `Remove.ps1`.
