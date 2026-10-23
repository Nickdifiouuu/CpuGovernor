#Requires -Version 7.0
<#
.SYNOPSIS
    Creates the "CPU Governor" shortcut on the desktop. Run elevated, it also locks the GUI folder against non-admin edits.
.DESCRIPTION
    The GUI relaunches itself with admin rights, so its code must not be writable by non-admin processes: anything that
    could edit CpuGovernorGui.ps1 or Launch-Gui.cmd would get its code run elevated the next time you accept the UAC prompt.
    Elevated, this script sets the folder to Administrators/SYSTEM full control and Users read/execute (owner
    Administrators), with gui.log and data\ left user-writable. data-admin\ (used by the elevated GUI) stays admin-only.
.PARAMETER HardenOnly
    Skip the shortcut and only apply the permissions (requires elevation).
#>
[CmdletBinding()]
param([switch]$HardenOnly)
$ErrorActionPreference = 'Stop'
$gui = $PSScriptRoot
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $HardenOnly) {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $lnk = Join-Path $desktop 'CPU Governor.lnk'
    $pwsh = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    $ws = New-Object -ComObject WScript.Shell
    $s = $ws.CreateShortcut($lnk)
    $s.TargetPath = Join-Path $gui 'Launch-Gui.cmd'
    $s.WorkingDirectory = $gui
    $s.WindowStyle = 7          # minimized: the launcher's console window does not flash up
    $s.Description = 'CPU Stability Governor dashboard (status, profiles, health check)'
    if (Test-Path $pwsh) { $s.IconLocation = "$pwsh,0" }
    $s.Save()
    [Runtime.InteropServices.Marshal]::ReleaseComObject($ws) | Out-Null
    Write-Host "[OK] Shortcut created: $lnk -> $($s.TargetPath)"
}

if (-not $isAdmin) {
    Write-Host '[--] Folder permissions not changed (needs an elevated prompt). To lock the GUI code against non-admin edits run:'
    Write-Host "     pwsh -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -HardenOnly   (as administrator)"
    if ($HardenOnly) { exit 1 }
    return
}

# Same file-safe method as the governor: inheritable ACEs on folders only, then every child re-inherits (icacls /reset).
foreach ($d in 'data', 'data-admin') { New-Item -ItemType Directory -Force (Join-Path $gui $d) | Out-Null }
$log = Join-Path $gui 'gui.log'; if (-not (Test-Path $log)) { New-Item -ItemType File $log | Out-Null }
& icacls $gui /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' /C /Q | Out-Null
& icacls "$gui\*" /reset /T /C /Q | Out-Null
& icacls (Join-Path $gui 'data') /grant '*S-1-5-32-545:(OI)(CI)M' /C /Q | Out-Null
& icacls "$(Join-Path $gui 'data')\*" /reset /T /C /Q | Out-Null
& icacls $log /grant '*S-1-5-32-545:M' /C /Q | Out-Null
& icacls $gui /setowner '*S-1-5-32-544' /T /C /Q | Out-Null

# verify: code read-only for Users, data\ and gui.log writable, data-admin\ not writable
$checks = [ordered]@{
    'CpuGovernorGui.ps1 read-only for Users' = { $a = (& icacls (Join-Path $gui 'CpuGovernorGui.ps1')) -join ' '; $a -match 'BUILTIN\\Users:\(I\)\(RX\)' -and $a -notmatch 'Authenticated Users' -and $a -match 'NT AUTHORITY\\SYSTEM:\(I\)\(F\)' }
    'Launch-Gui.cmd read-only for Users'     = { $a = (& icacls (Join-Path $gui 'Launch-Gui.cmd')) -join ' '; $a -match 'BUILTIN\\Users:\(I\)\(RX\)' -and $a -notmatch 'Authenticated Users' }
    'data\ writable for Users'               = { ((& icacls (Join-Path $gui 'data')) -join ' ') -match 'BUILTIN\\Users:\(OI\)\(CI\)\(M\)' }
    'gui.log writable for Users'             = { ((& icacls $log) -join ' ') -match 'BUILTIN\\Users:\(M\)' }
    'data-admin\ read-only for Users'        = { $a = (& icacls (Join-Path $gui 'data-admin')) -join ' '; $a -match 'BUILTIN\\Users:\(I\)\(OI\)\(CI\)\(RX\)' -and $a -notmatch 'Users:\(OI\)\(CI\)\(M\)' }
}
$failed = 0
foreach ($k in $checks.Keys) { $ok = & $checks[$k]; if (-not $ok) { $failed++ }; Write-Host ('{0} {1}' -f $(if ($ok) { '[OK]  ' } else { '[FAIL]' }), $k) }
if ($failed) { throw "$failed permission check(s) failed; see icacls `"$gui`"" }
Write-Host "[OK] $gui hardened (owner Administrators)"
