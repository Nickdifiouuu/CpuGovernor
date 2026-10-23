#Requires -Version 7.0
<#
.SYNOPSIS
    Test THIS CPU at descending frequency caps and act on the result: healthy (no cap), degraded (apply a safe cap),
    or unrecoverable (no cap - needs service).
.DESCRIPTION
    Runs the stack-unwinder torture test on CPU 0 at each cap in the ladder. A level FAILS if it produces corrupted
    stack walks, a WHEA error, or a crash. Crash-safe: a crash mid-level is recorded as a FAIL; re-run to resume.
    Takes ~30-60 minutes; do not use the PC while it runs.
.PARAMETER MockOutcome
    Testing only: 'Healthy' | 'Degraded' | 'Unrecoverable'. Synthesises results, changes no system state, needs no admin.
.NOTES
    Needs administrator rights and PowerShell 7 for a real run. Run from the install folder, or pass -AppRoot.
#>
[CmdletBinding()]
param(
    [string]$AppRoot,
    [int[]]$Steps = @(5000, 4800, 4600, 4400, 4200, 4000, 3800),
    [int]$Minutes = 3,
    [switch]$Quick,
    [int]$MarginMHz = 100,
    [switch]$Yes,
    [switch]$DryRun,
    [ValidateSet('Healthy', 'Degraded', 'Unrecoverable')][string]$MockOutcome
)
$ErrorActionPreference = 'Stop'
if ($Quick) { $Minutes = 1 }
$mock = $DryRun -or $MockOutcome
if ($DryRun -and -not $MockOutcome) { $MockOutcome = 'Degraded' }

function Resolve-AppRoot([string]$Hint) {
    foreach ($c in @($Hint, (Join-Path $PSScriptRoot 'app'), (Join-Path $env:LOCALAPPDATA 'CpuGovernor\app'))) {
        if ($c -and (Test-Path (Join-Path $c 'CpuStabilityGovernor.psd1'))) { return (Resolve-Path $c).Path }
    }
    throw 'Could not find the CpuStabilityGovernor module. Pass -AppRoot <path to the app folder>.'
}
$AppRoot = Resolve-AppRoot $AppRoot
$profileFile = Join-Path $AppRoot 'profiles.json'

# ----- elevate (single UAC); a mock run changes nothing, so it needs no elevation -----
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $mock) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath), '-AppRoot', ('"{0}"' -f $AppRoot), '-Minutes', $Minutes, '-MarginMHz', $MarginMHz, '-Steps', ($Steps -join ','))
    if ($Quick) { $a += '-Quick' }; if ($Yes) { $a += '-Yes' }
    Start-Process -FilePath (Get-Process -Id $PID).Path -Verb RunAs -ArgumentList $a
    return
}

Import-Module (Join-Path $AppRoot 'CpuStabilityGovernor.psd1') -Force
$sorted = @($Steps | Sort-Object -Descending)

Write-Host ''
Write-Host '  CPU Governor - calibration' -ForegroundColor White
Write-Host '  --------------------------'
Write-Host ("  Ladder   : {0} MHz (P-core)" -f ($sorted -join ', '))
Write-Host ("  Per step : {0} min of bursty load on CPU 0" -f $Minutes)
Write-Host ''
if (-not $mock) {
    Write-Host '  Do NOT use the PC while this runs. A crash during a high step is EXPECTED on a degraded chip -' -ForegroundColor Yellow
    Write-Host '  it is recorded as a failure; run this command again afterwards to resume where it stopped.' -ForegroundColor Yellow
    if (-not $Yes) {
        $ans = Read-Host '  Start calibration now? [y/N]'
        if ($ans -notmatch '^(y|yes)$') { Write-Host '  Cancelled.'; return }
    }
}

# ----- gather per-level verdicts ------------------------------------------
if ($mock) {
    Write-Host ("  [Mock: {0}] synthesising results; no CPU stress, no system change." -f $MockOutcome) -ForegroundColor Magenta
    $results = foreach ($mhz in $sorted) {
        $v = switch ($MockOutcome) {
            'Healthy'       { 'PASS' }
            'Unrecoverable' { 'FAIL' }
            default         { if ($mhz -ge 4800) { 'FAIL' } else { 'PASS' } }   # Degraded: fault band above 4600
        }
        [pscustomobject]@{ PCoreMHz = $mhz; Verdict = $v; Detail = "mock:$MockOutcome" }
    }
} else {
    $stepDefs = foreach ($mhz in $sorted) { @{ Label = "P$mhz"; PCoreMHz = $mhz; ECoreMHz = 0; PMaxStatePct = 100; EMaxStatePct = 100 } }
    $tests = @(@{ Kind = 'Unwind'; LPs = @(0); Minutes = $Minutes; Bursty = $true; Manual = $false })
    & (Join-Path $AppRoot 'tools\Invoke-Calibration.ps1') -Name 'calibrate' -Steps $stepDefs -Tests $tests | Out-Null
    $state = Get-Content (Join-Path $AppRoot 'data\calibration\calibrate.state.json') -Raw | ConvertFrom-Json
    $results = foreach ($mhz in $sorted) {
        $rows = @($state.Results | Where-Object { $_.Step -eq "P$mhz" })
        $v = if (@($rows | Where-Object { $_.Verdict -eq 'FAIL' }).Count) { 'FAIL' }
             elseif (@($rows | Where-Object { $_.Verdict -eq 'PASS' }).Count) { 'PASS' } else { 'ERROR' }
        [pscustomobject]@{ PCoreMHz = $mhz; Verdict = $v; Detail = (@($rows | ForEach-Object { $_.Detail }) -join ' | ') }
    }
}

Write-Host ''
Write-Host '  Results (high -> low):'
foreach ($r in $results) {
    $c = switch ($r.Verdict) { 'PASS' { 'Green' } 'FAIL' { 'Red' } default { 'Yellow' } }
    Write-Host ("    {0,-6} {1}" -f $r.PCoreMHz, $r.Verdict) -ForegroundColor $c
}

# ----- classify: Healthy (A) / Degraded (B) / Unrecoverable (C) -----------
$fails  = @($results | Where-Object Verdict -eq 'FAIL')
$passes = @($results | Where-Object Verdict -eq 'PASS' | Sort-Object PCoreMHz -Descending)
$lo = ($sorted | Measure-Object -Minimum).Minimum
$hi = ($sorted | Measure-Object -Maximum).Maximum
$verdict = ''; $cap = 0

if ($fails.Count -eq 0) {
    $verdict = 'HEALTHY'
    Write-Host ''
    @(
        'Calibration complete.'
        'Result: No instability detected.'
        "Your CPU completed stress tests at every frequency from $hi MHz to $lo MHz"
        'without producing any hardware errors.'
        'This suggests your CPU is not affected by the instability issue under these'
        'test conditions.'
        'No frequency cap has been installed.'
        'If you experience crashes in games anyway (with anti-cheats like Vanguard or'
        'PUBG), the trigger may be condition-specific. You can:'
        '  1. Open the GUI and manually try the "Sustained" profile (~3.0 GHz cap).'
        '  2. If crashes stop with Sustained, your CPU has a condition-specific issue'
        '     and you should keep that profile.'
        '  3. If crashes continue, contact your laptop manufacturer.'
    ) | ForEach-Object { Write-Host "  $_" -ForegroundColor Green }
} elseif ($passes.Count -eq 0) {
    $verdict = 'UNRECOVERABLE'
    Write-Host ''
    @(
        'Calibration complete.'
        'Result: Instability detected at every tested frequency.'
        "Your CPU produced hardware errors at all frequencies from $hi MHz down to"
        "$lo MHz. Even the lowest tested frequency was unstable."
        'This means the CPU''s degradation has progressed to the point where this'
        'governor cannot stabilize it. A frequency cap will not prevent further crashes.'
        'Recommendation: Contact your laptop manufacturer or Intel for service.'
        'If you need to keep using the laptop in the meantime:'
        '  * Try the "TurboOff" profile (~2.1 GHz) from the GUI. It may reduce crash'
        '    frequency even if it doesn''t eliminate them.'
        '  * Back up your important data regularly.'
    ) | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
} else {
    $verdict = 'STABLE_AT_LEVEL'
    $y = $passes[0].PCoreMHz
    $firstFail = ($fails | Sort-Object PCoreMHz | Select-Object -First 1).PCoreMHz
    $cap = [Math]::Max($y - $MarginMHz, 1)
    Write-Host ''
    @(
        'Calibration complete.'
        "Result: Instability detected at $firstFail MHz."
        "Your CPU produced errors at $firstFail MHz but not at $y MHz."
        "Recommended cap: $cap MHz with safety margin."
        'A profile with your specific safe frequency has been applied.'
        'You can change profiles from the GUI at any time.'
    ) | ForEach-Object { Write-Host "  $_" -ForegroundColor Green }
}

# ----- write verdict + (for Degraded) the Calibrated profile --------------
$pj = Get-Content $profileFile -Raw | ConvertFrom-Json
Add-Member -InputObject $pj -NotePropertyName 'CalibrationVerdict' -NotePropertyValue $verdict -Force
Add-Member -InputObject $pj -NotePropertyName 'CalibrationDate' -NotePropertyValue (Get-Date).ToString('yyyy-MM-dd') -Force
# only STABLE_AT_LEVEL marks the machine calibrated and installs a cap
Add-Member -InputObject $pj -NotePropertyName 'CalibratedForThisMachine' -NotePropertyValue ($verdict -eq 'STABLE_AT_LEVEL') -Force
if ($verdict -eq 'STABLE_AT_LEVEL') {
    $calProfile = [pscustomobject]@{ PCoreMHz = $cap; ECoreMHz = 0; PMaxStatePct = 100; EMaxStatePct = 100
        Description = "Calibrated for THIS machine on $((Get-Date).ToString('yyyy-MM-dd')): safe P-core cap $cap MHz." }
    Add-Member -InputObject $pj.Profiles -NotePropertyName 'Calibrated' -NotePropertyValue $calProfile -Force
    $pj.StepDownOrder = @('Calibrated') + @($pj.StepDownOrder | Where-Object { $_ -ne 'Calibrated' })
    $pj.Default = 'Calibrated'
} else {
    # Healthy / Unrecoverable: ensure no stale calibrated cap remains and no cap is the default
    if ($pj.Profiles.PSObject.Properties.Name -contains 'Calibrated') { $pj.Profiles.PSObject.Properties.Remove('Calibrated') }
    $pj.StepDownOrder = @($pj.StepDownOrder | Where-Object { $_ -ne 'Calibrated' })
    $pj.Default = 'Productivity'
}
$pj | ConvertTo-Json -Depth 8 | Set-Content $profileFile -Encoding utf8

# ----- calibration report -------------------------------------------------
$report = Join-Path (Split-Path $AppRoot -Parent) 'calibration_result.md'
$lines = @(
    '# CPU Governor - calibration result', '',
    "- Date: $((Get-Date).ToString('yyyy-MM-dd HH:mm'))",
    "- Verdict: **$verdict**" + $(if ($verdict -eq 'STABLE_AT_LEVEL') { "  (safe cap $cap MHz)" } else { '' }) + $(if ($mock) { '  _(mock run - synthetic)_' } else { '' }),
    "- Ladder (MHz): $($sorted -join ', ')  |  per level: $Minutes min bursty on CPU 0", '',
    '| P-core cap (MHz) | Verdict |', '|---|---|'
) + @($results | ForEach-Object { "| $($_.PCoreMHz) | $($_.Verdict) |" })
Set-Content -Path $report -Value ($lines -join [Environment]::NewLine) -Encoding utf8

# ----- apply (Degraded only) ----------------------------------------------
if ($verdict -eq 'STABLE_AT_LEVEL' -and -not $mock) {
    Set-CpuProfile -Name 'Calibrated' | Out-Null
    Write-Host ("  Applied the Calibrated profile ({0} MHz)." -f $cap) -ForegroundColor Green
} elseif ($verdict -eq 'STABLE_AT_LEVEL') {
    Write-Host ("  [Mock] Would apply Calibrated = {0} MHz (profiles.json updated)." -f $cap) -ForegroundColor Magenta
}
Write-Host ("  Verdict recorded: {0}. Report: {1}" -f $verdict, $report)
Write-Host ''
