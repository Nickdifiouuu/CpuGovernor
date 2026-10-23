# Technical Details

## What the governor changes

For each profile it sets per-core-class limits in the Windows power scheme:

- `PROCFREQMAX`  — E-core (efficiency) maximum frequency
- `PROCFREQMAX1` — P-core (performance) maximum frequency — where the unstable boost occurs
- `PROCTHROTTLEMAX` / `PROCTHROTTLEMAX1` — E-core / P-core maximum processor state (99% = turbo off)

Intel Raptor Lake-HX has two core classes — performance and efficient — so there
is no third `PROCFREQMAX2` to set.

Windows' power-options GUI exposes only the unsuffixed settings, which on a hybrid
CPU govern the **E-cores**. The P-cores — where the unstable boost frequencies
occur — are controlled by the `1` settings, which are hidden and must be set with
`powercfg`. This is why setting "Maximum processor state" to 99% in Windows' power
options doesn't solve the problem on its own: it caps the E-cores but leaves the
P-cores free to reach their highest boost frequencies.

The governor always sets both core classes, on every power scheme and overlay,
for AC and battery, and reads each value back to confirm it. In practice the
P-core cap lands roughly 100–130 MHz below the requested value.

## Why the cap persists without a background process

Windows stores the frequency cap in the power-scheme registry. On boot, the Power
service reads the scheme and applies the cap automatically, before any third-party
drivers load. No background process or scheduled task is required for the cap to
work.

The health monitor is separate and optional: a scheduled task that reads WHEA
error logs, reports them in the GUI, re-applies your cap if another program
changes the scheme, and re-applies it at boot. The cap works with or without it.

## What the governor does not do

- Does not modify CPU voltage
- Does not install kernel drivers
- Does not modify Windows system files
- Does not disable Secure Boot, VBS, HVCI, or any security feature
- Does not connect to the internet
- Does not collect any telemetry

## Uninstall

Either method fully removes the governor and resets all power settings:

- Click the **Uninstall** button in the GUI.
- Run `Remove.ps1` from the release folder.

After removal, CPU frequency limits return to their unmodified defaults.
