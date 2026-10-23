# Invoke-Calibration.ps1 — crash-safe calibration ladder. For each cap step: apply caps, verify, run the test set,
# record verdict + telemetry. State is persisted before/after every test so a BSOD mid-test is recorded as a FAIL and the
# ladder resumes where it stopped (just run the same command again after the reboot).
param(
  [Parameter(Mandatory)][string]$Name,                  # calibration id, e.g. 'pcore_ladder'
  [Parameter(Mandatory)][object[]]$Steps,               # @{Label; PCoreMHz; ECoreMHz; PMaxStatePct; EMaxStatePct}
  [Parameter(Mandatory)][object[]]$Tests,               # @{Kind='P95'|'Unwind'; Preset/LPs; Minutes; Bursty}
  [switch]$StopAtFirstFail,
  [switch]$KeepLastCaps
)
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Import-Module "$root\CpuStabilityGovernor.psd1" -Force
$stateFile = "$root\data\calibration\$Name.state.json"
New-Item -ItemType Directory -Force (Split-Path $stateFile) | Out-Null
$state = if (Test-Path $stateFile) { Get-Content $stateFile -Raw | ConvertFrom-Json -AsHashtable } else { @{ Name = $Name; Results = @() } }
function Save-State { $state | ConvertTo-Json -Depth 8 | Set-Content $stateFile -Encoding utf8 }

# Crash recovery: a test left "InProgress" means the machine went down during it.
if ($state.ContainsKey('InProgress') -and $state['InProgress']) {
  $ip = $state['InProgress']; $t0 = [datetime]$ip['Start']
  $dumps = @(Get-ChildItem C:\Windows\Minidump -Filter *.dmp -ErrorAction SilentlyContinue | Where-Object LastWriteTime -gt $t0)
  $kp41 = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; StartTime = $t0 } -ErrorAction SilentlyContinue)
  $state['Results'] += @(@{ Step = $ip['Step']; Test = $ip['Test']; Start = $ip['Start']; Verdict = 'FAIL'; Why = "system went down during test (new dumps $($dumps.Count), Kernel-Power 41 x$($kp41.Count))"; Crash = $true })
  $state['InProgress'] = $null; Save-State
  Write-GovernorLog -Level WARN "Calibration ${Name}: step $($ip['Step']) / $($ip['Test']) recorded as FAIL - system crashed during the test"
}

$done = @($state['Results'] | ForEach-Object { "$($_['Step'])|$($_['Test'])" })
foreach ($s in $Steps) {
  $stepFailed = @($state['Results'] | Where-Object { $_['Step'] -eq $s.Label -and $_['Verdict'] -eq 'FAIL' }).Count -gt 0
  if ($stepFailed -and $StopAtFirstFail) { break }
  $applied = $false
  foreach ($t in $Tests) {
    $tl = if ($t.Kind -eq 'P95') { "P95-$($t.Preset)-$($t.Minutes)m" } else { "Unwind$(if ($t.Manual) {'v2'} else {'v1'})-$(($t.LPs) -join '+')-$(if ($t.Bursty) {'bursty'} else {'cont'})-$($t.Minutes)m" }
    if ("$($s.Label)|$tl" -in $done) { continue }
    if (-not $applied) {
      Set-CpuFrequencyCap -PCoreMHz $s.PCoreMHz -ECoreMHz $s.ECoreMHz -PMaxStatePct $s.PMaxStatePct -EMaxStatePct $s.EMaxStatePct -Reason "calibration $Name step $($s.Label)" -ProfileName "calib:$($s.Label)" | Out-Null
      Start-Sleep -Seconds 20                         # let clocks/temps settle between steps
      $chk = Test-CpuCapApplied
      $applied = $true
    }
    $state['InProgress'] = @{ Step = $s.Label; Test = $tl; Start = (Get-Date).ToString('o') }; Save-State
    $r = $null; $row = $null
    try {
      $r = if ($t.Kind -eq 'P95') { Invoke-CpuStressTest -Preset $t.Preset -Minutes $t.Minutes -Label "$Name-$($s.Label)-$tl" }
           else { & "$root\tools\Invoke-UnwindTorture.ps1" -Label "$Name-$($s.Label)-$tl" -Minutes $t.Minutes -LogicalProcessors $t.LPs -Bursty:([bool]$t.Bursty) -Manual:([bool]$t.Manual) }
    } catch { Write-GovernorLog -Level ERROR "Calibration ${Name}: $($s.Label)/$tl harness error: $($_.Exception.Message)" }
    if (-not $r -or -not $r.Start) {   # harness failure: record it, never reuse the previous row
      $state['Results'] += @(@{ Step = $s.Label; Test = $tl; Verdict = 'ERROR'; Detail = 'harness error - test did not run'; Start = (Get-Date).ToString('o') })
      $state['InProgress'] = $null; Save-State; continue
    }
    $m = & "$root\tools\Measure-RunTelemetry.ps1" -Start $r.Start -Stop $r.Stop
    $row = @{ Step = $s.Label; Test = $tl; PCoreMHz = $s.PCoreMHz; ECoreMHz = $s.ECoreMHz; PMaxStatePct = $s.PMaxStatePct; EMaxStatePct = $s.EMaxStatePct
              Start = $r.Start.ToString('o'); Stop = $r.Stop.ToString('o'); Verdict = $r.Verdict
              Detail = $(if ($t.Kind -eq 'P95') { "p95err=$($r.Prime95Errors) whea=$($r.WheaEvents) dumps=$($r.NewDumps)" } else { "walks=$($r.Walks) mismatch=$($r.Mismatches) crash=$($r.TestProcessCrashed) whea=$($r.WheaEvents)" })
              CapCheckPMax = $chk.PLoadedMaxMHz; CapCheckEMax = $chk.ELoadedMaxMHz
              LP0Avg = $m.LP0AvgMHz; LP0Max = $m.LP0MaxMHz; PAvg = $m.PAvgMHz; PMax = $m.PMaxMHz; EAvg = $m.EAvgMHz; EMax = $m.EMaxMHz
              PkgWAvg = $m.PkgWAvg; PkgWMax = $m.PkgWMax; TempCAvg = $m.CpuCAvg; TempCMax = $m.CpuCMax; FanAvg = $m.FanAvg; RunDir = $r.RunDir }
    $state['Results'] += @($row); $state['InProgress'] = $null; Save-State
    if ($r.Verdict -eq 'FAIL' -and $StopAtFirstFail) { break }
    Start-Sleep -Seconds 30                           # cool-down between tests
  }
  if ((@($state['Results'] | Where-Object { $_['Step'] -eq $s.Label -and $_['Verdict'] -eq 'FAIL' }).Count -gt 0) -and $StopAtFirstFail) { break }
}
if (-not $KeepLastCaps) { Reset-CpuGovernor | Out-Null; Write-GovernorLog -Level ACTION "Calibration $Name finished; caps reset to pre-governor baseline" }
$state['FinishedAt'] = (Get-Date).ToString('o'); Save-State
$state['Results'] | ForEach-Object { [pscustomobject]$_ } | Select-Object Step, Test, Verdict, Detail, LP0Avg, LP0Max, PAvg, EAvg, PkgWAvg, TempCAvg, TempCMax
