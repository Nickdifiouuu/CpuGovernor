# Uninstall

Two ways. Both restore your power settings, remove any scheduled task, and delete
the install. Each asks for admin rights once (UAC).

## Method 1 — from the dashboard

1. Open **CPU Governor**.
2. Click **Uninstall** (small button, bottom-left).
3. Confirm the dialog. An elevated window carries out the removal and the
   dashboard closes.

## Method 2 — Remove.ps1

Right-click **`Remove.ps1`** → **Run with PowerShell** (in the install folder
`%LOCALAPPDATA%\CpuGovernor\`, or in the downloaded repo). Confirm the prompt.

## What gets removed

- The scheduled tasks, if the health monitor was installed
  (`CpuStabilityGovernor-HealthMonitor`, `CpuStabilityGovernor-ApplyAtBoot`).
- The install folder `%LOCALAPPDATA%\CpuGovernor\`.
- The Start Menu and Desktop shortcuts.

## What gets restored

- Your **power settings** return to how they were before install. Your CPU goes
  back to full stock boost behaviour.

## Verify

- `%LOCALAPPDATA%\CpuGovernor\` is gone (it deletes a couple of seconds after the
  window closes).
- Task Scheduler shows no `CpuStabilityGovernor-*` tasks.
- `powercfg /q SCHEME_CURRENT SUB_PROCESSOR PROCFREQMAX1` shows the max frequency
  back at `0` (no cap).

## Options

- `Remove.ps1 -KeepFiles` — restore settings and remove the task but leave the files.
- `Remove.ps1 -Yes` — no prompts (for scripts).
