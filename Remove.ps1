<#
.SYNOPSIS
    Remove CPU Governor: restore power settings, remove the SYSTEM tasks, delete the install, remove shortcuts. One UAC prompt.
.PARAMETER InstallRoot  Install location (default %LOCALAPPDATA%\CpuGovernor).
.PARAMETER Confirmed    Skip the text confirmation (the GUI's Uninstall button already confirmed). UAC still applies.
.PARAMETER Yes          Non-interactive: proceed with no prompts.
.PARAMETER KeepFiles    Restore settings and remove the task but leave the installed files in place.
#>
[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'CpuGovernor'),
    [string]$AppName     = 'CPU Governor',
    [switch]$Confirmed,
    [switch]$Yes,
    [switch]$KeepFiles,
    [switch]$FilesOnly   # remove shortcuts + files only; skip power-settings restore and task removal (testing / already-clean systems)
)
$ErrorActionPreference = 'Stop'

function Find-Pwsh7 {
    foreach ($c in @((Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source, (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'))) {
        if ($c -and (Test-Path $c)) { return $c }
    }
    return $null
}
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$needsAdmin = -not $FilesOnly                                 # restoring power settings + removing SYSTEM tasks need elevation
$needs7 = ($PSVersionTable.PSVersion.Major -lt 7) -and -not $FilesOnly
if ($needs7 -or ($needsAdmin -and -not $isAdmin)) {
    $pwsh7 = Find-Pwsh7
    if (-not $pwsh7) { Write-Host '  PowerShell 7 not found. Install it (winget install Microsoft.PowerShell) and retry.' -ForegroundColor Red; Read-Host '  Press Enter'; return }
    $pass = @()
    foreach ($k in $PSBoundParameters.Keys) {
        $v = $PSBoundParameters[$k]
        if ($v -is [System.Management.Automation.SwitchParameter]) { if ($v.IsPresent) { $pass += "-$k" } }
        else { $pass += "-$k"; $pass += ('"{0}"' -f $v) }
    }
    $argl = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath)) + $pass
    if ($needsAdmin -and -not $isAdmin) { Start-Process -FilePath $pwsh7 -Verb RunAs -ArgumentList $argl } else { Start-Process -FilePath $pwsh7 -ArgumentList $argl }
    return
}

Write-Host ''
Write-Host '  CPU Governor - removal' -ForegroundColor White
Write-Host '  ----------------------'
if (-not $Confirmed -and -not $Yes) {
    Write-Host '  This stops the health monitor, removes its scheduled tasks, restores your default power settings,'
    Write-Host '  and deletes the installed files. Your CPU returns to stock behaviour.'
    $ans = Read-Host '  Remove CPU Governor now? [y/N]'
    if ($ans -notmatch '^(y|yes)$') { Write-Host '  Cancelled. Nothing was changed.'; return }
}

$appRoot = Join-Path $InstallRoot 'app'
$psd1 = Join-Path $appRoot 'CpuStabilityGovernor.psd1'
if ($FilesOnly) {
    Write-Host '  -FilesOnly: leaving power settings and scheduled tasks untouched.' -ForegroundColor Yellow
} elseif (Test-Path $psd1) {
    try {
        Import-Module $psd1 -Force
        try { Uninstall-CpuGovernorTask; Write-Host '  Scheduled tasks removed.' -ForegroundColor Green } catch { Write-Host "  Task removal: $($_.Exception.Message)" -ForegroundColor Yellow }
        try {
            if (Test-Path (Join-Path $appRoot 'backup\baseline_settings.json')) { Reset-CpuGovernor }
            else { Reset-CpuGovernor -ToDefaults }
            Write-Host '  Power settings restored (caps removed).' -ForegroundColor Green
        } catch { Write-Host "  Power restore: $($_.Exception.Message)" -ForegroundColor Yellow }
    } catch { Write-Host "  Could not load the module to clean up ($($_.Exception.Message)); removing files anyway." -ForegroundColor Yellow }
} else {
    # module gone but the tasks might still exist - remove them directly
    foreach ($t in 'CpuStabilityGovernor-HealthMonitor', 'CpuStabilityGovernor-ApplyAtBoot') {
        try { Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue } catch {}
    }
    Write-Host '  Module not found; removed any leftover scheduled tasks.' -ForegroundColor Yellow
}

# shortcuts
foreach ($lnk in @((Join-Path ([Environment]::GetFolderPath('Programs')) "$AppName.lnk"), (Join-Path ([Environment]::GetFolderPath('Desktop')) "$AppName.lnk"))) {
    if (Test-Path $lnk) { Remove-Item $lnk -Force -ErrorAction SilentlyContinue }
}
Write-Host '  Shortcuts removed.' -ForegroundColor Green

if ($KeepFiles) {
    Write-Host '  Files kept (-KeepFiles).'
} elseif (Test-Path $InstallRoot) {
    # this script lives inside $InstallRoot, so hand the final delete to a detached cmd that runs after we exit
    $cmd = 'timeout /t 2 /nobreak >nul & rmdir /s /q "{0}"' -f $InstallRoot
    Start-Process cmd.exe -ArgumentList '/c', $cmd -WindowStyle Hidden
    Write-Host ("  Installed files will be deleted: {0}" -f $InstallRoot) -ForegroundColor Green
}

Write-Host ''
Write-Host '  CPU Governor removed.' -ForegroundColor Green
Write-Host ''
if (-not $Yes -and -not $Confirmed) { Read-Host '  Press Enter to close' }
