# Install-Governor.ps1 — run ELEVATED once. Applies the default profile (elevated, so overlays are written too),
# registers the boot/logon + 5-minute health-monitor tasks (SYSTEM), exports their XML, hardens ACLs, runs a first check.
param([string]$ProfileName = '', [switch]$TasksDisabled)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$out = Join-Path $root 'data\install'
New-Item -ItemType Directory -Force $out | Out-Null
Start-Transcript -Path (Join-Path $out 'install_transcript.txt') -Force | Out-Null
try {
    Import-Module (Join-Path $root 'CpuStabilityGovernor.psd1') -Force
    if (-not $ProfileName) { $ProfileName = (Get-Content (Join-Path $root 'profiles.json') -Raw | ConvertFrom-Json).Default }
    "Applying profile $ProfileName (elevated: overlays included)"
    Set-CpuProfile -Name $ProfileName -Source 'install' | Format-List | Out-String
    Install-CpuGovernorTask -Disabled:$TasksDisabled | Format-Table -AutoSize | Out-String
    if (-not $TasksDisabled) { Start-ScheduledTask -TaskName 'CpuStabilityGovernor-HealthMonitor'; Start-Sleep -Seconds 25 }
    Get-ScheduledTask -TaskName 'CpuStabilityGovernor-*' | Get-ScheduledTaskInfo | Select-Object TaskName, LastRunTime, LastTaskResult, NextRunTime | Format-Table -AutoSize | Out-String
    $s = Get-CpuStatus -Detailed
    $s.Status | Format-List | Out-String
    $s.Targets | Format-Table -AutoSize | Out-String -Width 250
    $s | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $out 'install_status.json')
    'INSTALL OK'
} catch {
    "INSTALL FAILED: $($_.Exception.Message)"
    $_ | Out-String
} finally {
    Stop-Transcript | Out-Null
    New-Item -ItemType File (Join-Path $out 'DONE') -Force | Out-Null
}
