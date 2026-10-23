<#
.SYNOPSIS
    Install CPU Governor to %LOCALAPPDATA%\CpuGovernor, register the health monitor, create shortcuts. One UAC prompt.
.DESCRIPTION
    Copies app\ and gui\ (and this script set) into the install folder, registers the SYSTEM health-monitor + boot tasks
    via the module, hardens the elevated-entry files against non-admin modification, then offers to calibrate YOUR chip.
    It does NOT apply the author's example caps automatically - calibration (or a deliberate GUI choice) sets your cap.
.PARAMETER InstallRoot   Install location (default %LOCALAPPDATA%\CpuGovernor).
.PARAMETER SkipTask      Do not register the SYSTEM scheduled tasks or harden files (use for testing on a dev box).
.PARAMETER SkipShortcuts Do not create Start Menu / Desktop shortcuts.
.PARAMETER SkipCap       Do not offer calibration.
.PARAMETER AppName       Shortcut display name (default "CPU Governor").
.PARAMETER Yes           Non-interactive: assume "no" to the calibration question, proceed without prompts.
#>
[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'CpuGovernor'),
    [string]$SourceRoot  = $PSScriptRoot,
    [string]$AppName     = 'CPU Governor',
    [int]$MonitorMinutes = 5,
    [switch]$SkipTask,
    [switch]$SkipShortcuts,
    [switch]$SkipCap,
    [switch]$Yes
)
$ErrorActionPreference = 'Stop'

# ----- locate PowerShell 7 and elevate (single UAC) -----------------------
function Find-Pwsh7 {
    foreach ($c in @((Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source, (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'))) {
        if ($c -and (Test-Path $c)) { return $c }
    }
    return $null
}
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$needsAdmin = -not $SkipTask                                  # only task registration + hardening require elevation
$needs7 = $PSVersionTable.PSVersion.Major -lt 7              # the module needs PowerShell 7
if ($needs7 -or ($needsAdmin -and -not $isAdmin)) {
    $pwsh7 = Find-Pwsh7
    if (-not $pwsh7) {
        Write-Host ''
        Write-Host '  PowerShell 7 is required and was not found.' -ForegroundColor Red
        Write-Host '  Install it, then run Setup again:' -ForegroundColor Yellow
        Write-Host '      winget install Microsoft.PowerShell'
        Write-Host ''
        Read-Host '  Press Enter to close'; return
    }
    $pass = @()
    foreach ($k in $PSBoundParameters.Keys) {
        $v = $PSBoundParameters[$k]
        if ($v -is [System.Management.Automation.SwitchParameter]) { if ($v.IsPresent) { $pass += "-$k" } }
        else { $pass += "-$k"; $pass += ('"{0}"' -f $v) }
    }
    $argl = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath)) + $pass
    if ($needsAdmin -and -not $isAdmin) { Start-Process -FilePath $pwsh7 -Verb RunAs -ArgumentList $argl }
    else { Start-Process -FilePath $pwsh7 -ArgumentList $argl }
    return
}

Write-Host ''
Write-Host '  ============================================' -ForegroundColor White
Write-Host '   CPU Governor - setup' -ForegroundColor White
Write-Host '  ============================================' -ForegroundColor White

# ----- applicability (read-only) ------------------------------------------
$applResult = 'Uncertain'; $applRec = 'RunCalibration'
$applScript = Join-Path $SourceRoot 'Test-Applicability.ps1'
if (Test-Path $applScript) {
    try {
        $appl = & $applScript -Quiet
        $applResult = [string]$appl.ApplicabilityResult
        $applRec = [string]$appl.Recommendation
        Write-Host ''
        Write-Host ("  CPU      : {0}" -f $appl.CpuName)
        Write-Host ("  Result   : {0}  ({1} WHEA / {2} bugchecks in 90 days)" -f $applResult, $appl.WheaCount90d, $appl.BugcheckCount90d) -ForegroundColor $(switch ($applResult) { 'Yes' { 'Cyan' } 'Uncertain' { 'Yellow' } default { 'Red' } })
    } catch { Write-Host "  (applicability check skipped: $($_.Exception.Message))" -ForegroundColor Yellow }
}

# ----- copy files ---------------------------------------------------------
$appSrc = Join-Path $SourceRoot 'app'; $guiSrc = Join-Path $SourceRoot 'gui'
if (-not (Test-Path (Join-Path $appSrc 'CpuStabilityGovernor.psd1'))) { throw "Source not found: $appSrc. Run Setup.ps1 from the release folder (the one containing app\ and gui\)." }
$upgrade = Test-Path (Join-Path $InstallRoot 'app\CpuStabilityGovernor.psd1')
Write-Host ''
Write-Host ("  {0} to {1}" -f $(if ($upgrade) { 'Upgrading' } else { 'Installing' }), $InstallRoot)

# stop a running health task so its files aren't locked during an upgrade copy
if ($upgrade -and -not $SkipTask) { try { Stop-ScheduledTask -TaskName 'CpuStabilityGovernor-HealthMonitor' -ErrorAction SilentlyContinue } catch {} ; Start-Sleep -Milliseconds 500 }

New-Item -ItemType Directory -Force $InstallRoot | Out-Null
foreach ($sub in 'app', 'gui') {
    $dst = Join-Path $InstallRoot $sub
    if (Test-Path $dst) { Remove-Item (Join-Path $dst '*') -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Force $dst | Out-Null
    Copy-Item (Join-Path (Join-Path $SourceRoot $sub) '*') $dst -Recurse -Force
}
foreach ($f in 'Setup.ps1', 'Remove.ps1', 'Calibrate.ps1', 'Test-Applicability.ps1', 'README.md', 'LICENSE') {
    $p = Join-Path $SourceRoot $f; if (Test-Path $p) { Copy-Item $p $InstallRoot -Force }
}
if (Test-Path (Join-Path $SourceRoot 'docs')) { Copy-Item (Join-Path $SourceRoot 'docs') (Join-Path $InstallRoot 'docs') -Recurse -Force }
Write-Host '  Files copied.' -ForegroundColor Green

Import-Module (Join-Path $InstallRoot 'app\CpuStabilityGovernor.psd1') -Force

# ----- shortcuts ----------------------------------------------------------
if (-not $SkipShortcuts) {
    $launch = Join-Path $InstallRoot 'gui\Launch-Gui.cmd'
    $pwshIco = Find-Pwsh7
    function New-Lnk($Path) {
        $ws = New-Object -ComObject WScript.Shell
        $s = $ws.CreateShortcut($Path)
        $s.TargetPath = $launch; $s.WorkingDirectory = (Join-Path $InstallRoot 'gui')
        $s.WindowStyle = 7; $s.Description = 'CPU Governor dashboard'
        if ($pwshIco) { $s.IconLocation = "$pwshIco,0" }
        $s.Save(); [Runtime.InteropServices.Marshal]::ReleaseComObject($ws) | Out-Null
    }
    $sm = Join-Path ([Environment]::GetFolderPath('Programs')) "$AppName.lnk"
    $dt = Join-Path ([Environment]::GetFolderPath('Desktop'))  "$AppName.lnk"
    New-Lnk $sm; New-Lnk $dt
    Write-Host "  Shortcuts created (Start Menu + Desktop): $AppName" -ForegroundColor Green
}

# ----- first question: calibrate now? -------------------------------------
# Never silently applies the bundled example caps - a cap comes only from calibration or a deliberate GUI choice.
$didCalibrate = $false
if ($applResult -eq 'No') {
    Write-Host ''
    Write-Host '  Your CPU is not in the affected family. The tool is installed in case you need it later,' -ForegroundColor Yellow
    Write-Host '  but no cap will be applied. You can still calibrate or pick a profile manually from the GUI.'
} elseif (-not $SkipCap) {
    Write-Host ''
    Write-Host '  Calibration tests YOUR CPU and applies a safe cap only if it finds instability'
    Write-Host '  (about 30-60 min; do not use the PC while it runs). The bundled profile values are only examples.'
    $run = if ($Yes) { 'n' } else { Read-Host '  Run calibration now? [Y/n]' }
    if ($run -notmatch '^(n|no)$') {
        & (Join-Path $InstallRoot 'Calibrate.ps1') -AppRoot (Join-Path $InstallRoot 'app') -Yes
        $didCalibrate = $true
    } else {
        Write-Host '  Skipped. No cap applied. Run Calibrate.ps1 later, or open the GUI (it will show a "not calibrated" banner).' -ForegroundColor Yellow
    }
}

# ----- second question: optional health monitor (opt-in) ------------------
if (-not $SkipTask) {
    Write-Host ''
    $mon = if ($Yes) { 'n' } else { Read-Host '  Install the optional background health monitor? It logs new CPU errors and re-applies the cap at boot. [y/N]' }
    if ($mon -match '^(y|yes)$') {
        Install-CpuGovernorTask -MonitorMinutes $MonitorMinutes | Out-Null   # registers both SYSTEM tasks + hardens app\
        # lock the files that run elevated so a non-admin program cannot swap them before the next UAC run
        foreach ($rel in @('gui\CpuGovernorGui.ps1', 'gui\Launch-Gui.cmd', 'gui\Create-Shortcut.ps1', 'Remove.ps1', 'Setup.ps1', 'Calibrate.ps1', 'Test-Applicability.ps1')) {
            $p = Join-Path $InstallRoot $rel
            if (Test-Path $p) {
                & icacls $p /inheritance:r /grant:r '*S-1-5-32-544:F' '*S-1-5-18:F' '*S-1-5-32-545:RX' /C /Q | Out-Null
                & icacls $p /setowner '*S-1-5-32-544' /C /Q | Out-Null
            }
        }
        Write-Host '  Health monitor + boot re-apply task installed (run as SYSTEM); elevated files hardened.' -ForegroundColor Green
    } else {
        Write-Host '  No background monitor installed. The frequency cap still persists across reboots on its own.' -ForegroundColor Gray
    }
}

Write-Host ''
Write-Host '  ============================================' -ForegroundColor White
Write-Host '   Setup complete.' -ForegroundColor Green
Write-Host ("   Open '{0}' from your Start Menu to control levels." -f $AppName)
if (-not $didCalibrate -and -not $SkipCap -and $applResult -ne 'No') { Write-Host '   Recommended next step: run Calibrate.ps1 to find this chip''s safe frequency.' -ForegroundColor Yellow }
Write-Host '  ============================================' -ForegroundColor White
Write-Host ''
if (-not $Yes) { Read-Host '  Press Enter to close' }
