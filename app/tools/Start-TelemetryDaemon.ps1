# Start-TelemetryDaemon.ps1 — run ELEVATED (needed for the ASUS EC temperature). Read-only.
# Logs ~1 Hz: per-logical-CPU actual frequency, P/E utilisation, RAPL power, PPM limit flags,
# ASUS EC CPU/GPU temperature + fans, ACPI thermal zone, and (if available) HWiNFO shared-memory readings.
# Stops when <OutDir>\STOP exists or after -MaxHours.
param(
  [Parameter(Mandatory)][string]$OutDir,
  [double]$MaxHours = 12,
  [switch]$RestartHwinfo
)
$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force $OutDir | Out-Null
Remove-Item "$OutDir\STOP" -ErrorAction SilentlyContinue
$status = "$OutDir\daemon_status.txt"
"started $(Get-Date -Format o) pid $PID" | Out-File $status

if ($RestartHwinfo) {
  $h = Get-Process HWiNFO64 -ErrorAction SilentlyContinue
  if ($h) { $h | Stop-Process -Force; Start-Sleep 3 }
  Start-Process 'C:\Program Files\HWiNFO64\HWiNFO64.EXE'
  "HWiNFO restarted" | Out-File $status -Append
}

Add-Type -Path (Join-Path $PSScriptRoot '..\lib\HwinfoSharedMemory.cs')
$asus = Get-CimInstance -Namespace root\wmi -ClassName AsusAtkWmi_WMNB -ErrorAction SilentlyContinue | Select-Object -First 1
function Get-Ec([uint32]$id) {
  if (-not $asus) { return $null }
  try { $v = [uint32](Invoke-CimMethod -InputObject $asus -MethodName DSTS -Arguments @{ Device_ID = $id } -ErrorAction Stop).device_status
        if (($v -band 0xFFFF0000) -eq 0x00010000) { return [int]($v -band 0xFFFF) } } catch {}
  return $null
}

$paths = @('\Processor Information(0,*)\Actual Frequency', '\Processor Information(0,*)\% Processor Utility',
           '\Processor Information(_Total)\Performance Limit Flags', '\Processor Information(_Total)\% Performance Limit',
           '\Energy Meter(RAPL_Package0_PKG)\Power', '\Energy Meter(RAPL_Package0_PP0)\Power',
           '\Energy Meter(RAPL_Package0_PP1)\Power', '\Energy Meter(RAPL_Package0_DRAM)\Power',
           '\Thermal Zone Information(*)\High Precision Temperature')
$csv = Join-Path $OutDir ("telemetry_{0:yyyyMMdd_HHmmss}.csv" -f (Get-Date))
$hdr = @('Time','P0T0','P0T1','P1T0','P1T1','P_avg','P_max','E_avg','E_max','P_util','E_util','PkgW','CoresW','GfxW','DramW',
         'LimitFlags','PerfLimitPct','EC_CpuC','EC_GpuC','CpuFan','GpuFan','TZ_C','HW_PkgC','HW_CoreMaxC','HW_VidMax','HW_VidP0','HW_VidP1') + (0..31 | ForEach-Object { "F$_" })
($hdr -join ',') | Out-File $csv -Encoding utf8
"csv $csv" | Out-File $status -Append

$deadline = (Get-Date).AddHours($MaxHours)
$hwWarned = $false
while ((Get-Date) -lt $deadline -and -not (Test-Path "$OutDir\STOP")) {
  $s = (Get-Counter -Counter $paths -SampleInterval 1 -MaxSamples 1 -ErrorAction SilentlyContinue).CounterSamples
  if (-not $s) { continue }
  $f = @{}; $u = @{}
  foreach ($x in $s) {
    if ($x.Path -match '\((0,(\d+))\)\\actual frequency$') { $f[[int]$Matches[2]] = $x.CookedValue }
    elseif ($x.Path -match '\((0,(\d+))\)\\% processor utility$') { $u[[int]$Matches[2]] = $x.CookedValue }
  }
  $get = { param($pat) ($s | Where-Object { $_.Path -like $pat } | Select-Object -First 1).CookedValue }
  $pF = 0..15 | ForEach-Object { $f[$_] }; $eF = 16..31 | ForEach-Object { $f[$_] }
  $pU = 0..15 | ForEach-Object { $u[$_] }; $eU = 16..31 | ForEach-Object { $u[$_] }
  $tz = & $get '*thermal zone information*high precision temperature'
  # optional HWiNFO
  $hwPkg = $hwCore = $vMax = $v0 = $v1 = $null
  if ([HwinfoSharedMemory]::IsAvailable()) {
    try {
      $r = [HwinfoSharedMemory]::Read()
      $hwPkg = ($r | Where-Object { $_.Label -match '^CPU Package$' -and $_.Unit -match 'C' } | Select-Object -First 1).Value
      $hwCore = ($r | Where-Object { $_.Label -match '^Core Max$' -and $_.Unit -match 'C' } | Select-Object -First 1).Value
      $vids = $r | Where-Object { $_.Label -match 'VID' -and $_.Unit -eq 'V' }
      $vMax = ($vids | Measure-Object Value -Maximum).Maximum
      $v0 = ($vids | Where-Object { $_.Label -match '^(P-core 0|Core 0) VID' } | Select-Object -First 1).Value
      $v1 = ($vids | Where-Object { $_.Label -match '^(P-core 1|Core 1) VID' } | Select-Object -First 1).Value
    } catch {}
  } elseif (-not $hwWarned) { "HWiNFO shared memory not available at $(Get-Date -Format o)" | Out-File $status -Append; $hwWarned = $true }
  $row = @(
    (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'), $f[0], $f[1], $f[2], $f[3],
    [math]::Round(($pF | Measure-Object -Average).Average, 0), [math]::Round(($pF | Measure-Object -Maximum).Maximum, 0),
    [math]::Round(($eF | Measure-Object -Average).Average, 0), [math]::Round(($eF | Measure-Object -Maximum).Maximum, 0),
    [math]::Round(($pU | Measure-Object -Average).Average, 1), [math]::Round(($eU | Measure-Object -Average).Average, 1),
    [math]::Round((& $get '*rapl_package0_pkg)\power') / 1000, 2), [math]::Round((& $get '*rapl_package0_pp0)\power') / 1000, 2),
    [math]::Round((& $get '*rapl_package0_pp1)\power') / 1000, 2), [math]::Round((& $get '*rapl_package0_dram)\power') / 1000, 2),
    (& $get '*_total)\performance limit flags'), (& $get '*_total)\% performance limit'),
    (Get-Ec 0x00120094), (Get-Ec 0x00120097), (Get-Ec 0x00110013), (Get-Ec 0x00110014),
    $(if ($tz) { [math]::Round($tz / 10 - 273.15, 1) } else { $null }),
    $hwPkg, $hwCore, $vMax, $v0, $v1
  ) + (0..31 | ForEach-Object { [math]::Round([double]$f[$_], 0) })
  ($row -join ',') | Out-File $csv -Append -Encoding utf8
}
"stopped $(Get-Date -Format o)" | Out-File $status -Append
