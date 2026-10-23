<#
.SYNOPSIS
    Read-only check: is this an Intel 13th/14th Gen mobile (HX) CPU, and does its error history suggest the governor applies?
    Changes nothing. Runs in a few seconds. Safe on Windows PowerShell 5.1 (run it before installing PowerShell 7).
.PARAMETER Quiet
    Suppress the printed summary; only return the result object (used by Setup.ps1).
.OUTPUTS
    [pscustomobject] with: CpuName, IsTargetCpu, WheaCount90d, BugcheckCount90d, ApplicabilityResult, Recommendation, ...
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Test-Applicability.ps1
#>
[CmdletBinding()]
param([switch]$Quiet)
$ErrorActionPreference = 'Stop'
function Say($Text, $Color) { if (-not $Quiet) { if ($Color) { Write-Host $Text -ForegroundColor $Color } else { Write-Host $Text } } }

# --- CPU identity: Intel 13th/14th Gen mobile HX only ---------------------
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$name = ("" + $cpu.Name).Trim()
# e.g. i9-14900HX, i7-13700HX, i5-13450HX  (13/14 gen, HX suffix)
$isTarget = $name -match 'i[579]-1[34]\d{3}HX'
$gen = if ($name -match 'i[579]-(1[34])\d{3}HX') { [int]$Matches[1] } else { 0 }

$ucode = 'unknown'
try {
    $ur = (Get-ItemProperty 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' -ErrorAction Stop).'Update Revision'
    if ($ur -is [byte[]] -and $ur.Length -ge 4) { $ucode = '0x{0:X}' -f [BitConverter]::ToUInt32($ur, $ur.Length - 4) }
} catch {}

# --- error history (last 90 days) -----------------------------------------
$since = (Get-Date).AddDays(-90)
function Get-Events($filter) { try { return @(Get-WinEvent -FilterHashtable $filter -ErrorAction Stop) } catch { return @() } }
$whea = Get-Events @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; Id = 17, 18, 19, 20, 47; StartTime = $since }
$bug  = Get-Events @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001; StartTime = $since }
$wheaCount = $whea.Count; $bugCount = $bug.Count

# --- result + recommendation ----------------------------------------------
if (-not $isTarget) {
    $result = 'No'; $recommendation = 'Tool not applicable'
} elseif ($wheaCount -gt 0) {
    $result = 'Yes'; $recommendation = 'RunCalibration'
} elseif ($bugCount -gt 0) {
    $result = 'Uncertain'; $recommendation = 'RunCalibration'
} else {
    $result = 'Uncertain'; $recommendation = 'SkipCalibration'
}

# --- environment ----------------------------------------------------------
$ps7 = $null
foreach ($c in @((Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source, (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'))) {
    if ($c -and (Test-Path $c)) { $ps7 = $c; break }
}
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$out = [pscustomobject]@{
    CpuName             = $name
    Generation          = $gen
    Microcode           = $ucode
    IsTargetCpu         = $isTarget
    WheaCount90d        = $wheaCount
    BugcheckCount90d    = $bugCount
    ApplicabilityResult = $result          # No | Yes | Uncertain
    Recommendation      = $recommendation  # Tool not applicable | RunCalibration | SkipCalibration
    PowerShell7         = $ps7
    PowerShell7Found    = [bool]$ps7
    RunningElevated     = $isAdmin
}

if (-not $Quiet) {
    Say ''
    Say '  CPU Governor - applicability check' White
    Say '  ----------------------------------'
    Say ("  CPU             : {0}" -f $name)
    Say ("  Target family   : {0}" -f $(if ($isTarget) { "yes - Intel {0}th Gen mobile (HX)" -f $gen } else { 'NO - not a 13th/14th Gen Intel HX part' })) $(if ($isTarget) { 'Green' } else { 'Red' })
    Say ("  Microcode       : {0}" -f $ucode)
    Say ''
    Say '  Error history (last 90 days):'
    Say ("    WHEA errors (17/18/19/20/47) : {0}" -f $wheaCount) $(if ($wheaCount) { 'Yellow' } else { 'Gray' })
    Say ("    Bugchecks (BSODs, ID 1001)   : {0}" -f $bugCount) $(if ($bugCount) { 'Yellow' } else { 'Gray' })
    Say ''
    Say ("  Result          : {0}" -f $result) $(switch ($result) { 'Yes' { 'Cyan' } 'Uncertain' { 'Yellow' } default { 'Red' } })
    Say ("  Recommendation  : {0}" -f $recommendation)
    switch ($recommendation) {
        'Tool not applicable' { Say '  This CPU is not in the affected family. The governor would only slow it down - do not install.' Red }
        'RunCalibration'      { Say '  Run calibration to find your CPU''s safe frequency.' Cyan }
        'SkipCalibration'     { Say '  No errors on record. You can install and calibrate only if you later see crashes.' Gray }
    }
    Say ''
    Say ("  PowerShell 7    : {0}" -f $(if ($ps7) { "yes ($ps7)" } else { 'NOT found - winget install Microsoft.PowerShell' })) $(if ($ps7) { 'Green' } else { 'Yellow' })
    Say ("  Admin rights    : {0}" -f $(if ($isAdmin) { 'yes' } else { 'no - Setup will prompt (UAC)' }))
    Say ''
    Say '  This check changed nothing. See docs/does-this-apply-to-me.md.'
    Say ''
}
$out
