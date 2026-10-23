# Measure-RunTelemetry.ps1 — summarise the telemetry CSV(s) for a time window (a test run). Non-elevated.
param(
  [Parameter(Mandatory)][datetime]$Start,
  [Parameter(Mandatory)][datetime]$Stop,
  [double]$SkipSeconds = 15,          # ignore ramp-up
  [string]$TelemetryDir = (Join-Path (Split-Path $PSScriptRoot -Parent) 'data\telemetry')
)
$from = $Start.AddSeconds($SkipSeconds)
$rows = foreach ($f in Get-ChildItem $TelemetryDir -Filter 'telemetry_*.csv') {
  Import-Csv $f.FullName | Where-Object { $t = [datetime]$_.Time; $t -ge $from -and $t -le $Stop }
}
if (-not $rows) { return [pscustomobject]@{ Samples = 0 } }
function Stat($name, [switch]$Max) {
  $v = @($rows | ForEach-Object { $_.$name } | Where-Object { $_ -ne '' -and $null -ne $_ } | ForEach-Object { [double]$_ })
  if (-not $v) { return $null }
  if ($Max) { [math]::Round(($v | Measure-Object -Maximum).Maximum, 1) } else { [math]::Round(($v | Measure-Object -Average).Average, 1) }
}
[pscustomobject]@{
  Samples = @($rows).Count
  LP0AvgMHz = Stat P0T0; LP0MaxMHz = Stat P0T0 -Max; LP2AvgMHz = Stat P1T0; LP2MaxMHz = Stat P1T0 -Max
  PAvgMHz = Stat P_avg; PMaxMHz = Stat P_max -Max; EAvgMHz = Stat E_avg; EMaxMHz = Stat E_max -Max
  PUtil = Stat P_util; EUtil = Stat E_util
  PkgWAvg = Stat PkgW; PkgWMax = Stat PkgW -Max; CoresWAvg = Stat CoresW
  CpuCAvg = Stat EC_CpuC; CpuCMax = Stat EC_CpuC -Max; FanAvg = Stat CpuFan
  PerfLimitPctAvg = Stat PerfLimitPct
}
