# Get-PowerSettingsSnapshot.ps1 — read-only dump of CPU-related power settings for every scheme and overlay (AC and DC).
param([string]$OutCsv)

$settings = [ordered]@{
  PROCFREQMAX      = 'Max processor frequency (class 0 = E-cores), MHz, 0 = unlimited'
  PROCFREQMAX1     = 'Max processor frequency (class 1 = P-cores), MHz, 0 = unlimited'
  PROCFREQMAX2     = 'Max processor frequency (class 2), MHz'
  PROCTHROTTLEMAX  = 'Max processor state (class 0), %'
  PROCTHROTTLEMAX1 = 'Max processor state (class 1), %'
  PROCTHROTTLEMIN  = 'Min processor state (class 0), %'
  PROCTHROTTLEMIN1 = 'Min processor state (class 1), %'
  PERFBOOSTMODE    = 'Processor performance boost mode'
  PERFBOOSTPOL     = 'Processor performance boost policy, %'
  PERFEPP          = 'Energy performance preference (class 0), %'
  PERFEPP1         = 'Energy performance preference (class 1), %'
  SCHEDPOLICY      = 'Heterogeneous thread scheduling policy'
  SHORTSCHEDPOLICY = 'Heterogeneous short-running thread scheduling policy'
  HETEROPOLICY     = 'Heterogeneous policy in effect'
}

# Every scheme GUID the power service knows about (listed schemes + overlays + stored-but-unlisted schemes)
$keyRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes'
$guids = Get-ChildItem $keyRoot | Select-Object -ExpandProperty PSChildName
$names = @{}
foreach ($g in $guids) {
  $hdr = (powercfg /qh $g SUB_PROCESSOR PROCFREQMAX 2>&1 | Select-Object -First 1) -join ''
  $names[$g] = if ($hdr -match '\((.+)\)') { $Matches[1] } else { '?' }
}

$rows = foreach ($g in $guids) {
  foreach ($alias in $settings.Keys) {
    $out = powercfg /qh $g SUB_PROCESSOR $alias 2>&1
    $txt = $out -join "`n"
    $ac = if ($txt -match 'Current AC Power Setting Index:\s+0x([0-9a-fA-F]+)') { [Convert]::ToInt64($Matches[1], 16) } else { $null }
    $dc = if ($txt -match 'Current DC Power Setting Index:\s+0x([0-9a-fA-F]+)') { [Convert]::ToInt64($Matches[1], 16) } else { $null }
    [pscustomobject]@{ SchemeGuid = $g; SchemeName = $names[$g]; Setting = $alias; AC = $ac; DC = $dc; Defined = ($null -ne $ac -or $null -ne $dc) }
  }
}
if ($OutCsv) { $rows | Export-Csv $OutCsv -NoTypeInformation }
$rows
