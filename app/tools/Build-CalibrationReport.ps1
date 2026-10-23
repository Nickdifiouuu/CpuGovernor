# Build-CalibrationReport.ps1 — aggregate calibration state files into tables + chart data, render SVG charts.
param(
  [string[]]$Calibrations = @('pcore_low', 'pcore_high', 'pcore_threshold', 'pcore_stockallcore', 'ecore', 'turbooff'),
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)
$rows = foreach ($c in $Calibrations) {
  $f = "$Root\data\calibration\$c.state.json"
  if (Test-Path $f) { (Get-Content $f -Raw | ConvertFrom-Json).Results | ForEach-Object { $_ | Add-Member -NotePropertyName Calibration -NotePropertyValue $c -PassThru } }
}
$rows | Export-Csv "$Root\data\calibration\all_results.csv" -NoTypeInformation

# one record per P-core step (numeric cap; 0 = no cap -> plotted at 5600)
$steps = $rows | Where-Object { $_.Calibration -like 'pcore_*' } | Group-Object Step | ForEach-Object {
  $g = $_.Group; $cap = [int]$g[0].PCoreMHz
  $u1 = @($g | Where-Object Test -like 'Unwindv1-*'); $u2 = @($g | Where-Object Test -like 'Unwindv2-*'); $p = @($g | Where-Object Test -like 'P95-AllCore*')
  $walks = ($u1 | ForEach-Object { if ($_.Detail -match 'walks=(\d+)') { [double]$Matches[1] } } | Measure-Object -Sum).Sum
  $errs = ($u1 | ForEach-Object { if ($_.Detail -match 'mismatch=(\d+)') { [double]$Matches[1] } } | Measure-Object -Sum).Sum
  [pscustomobject]@{
    Step = $_.Name; CapMHz = $cap; X = $(if ($cap -eq 0) { 5800 } else { $cap }); Label = $(if ($cap -eq 0) { 'no cap' } else { "$cap" })
    Verdict = $(if (@($g | Where-Object Verdict -eq 'FAIL').Count) { 'FAIL' } else { 'PASS' })
    UnwindWalks = $walks; UnwindErrors = $errs; ErrPer100M = $(if ($walks) { [math]::Round($errs / $walks * 1e8, 1) } else { $null })
    V2Result = ($u2 | ForEach-Object { if ($_.Detail -match 'crash=True') { 'process crashed' } elseif ($_.Verdict -eq 'FAIL') { 'errors' } else { 'pass' } }) -join ','
    SingleThreadMaxMHz = [int]($g[0].CapCheckPMax); LightLoadLP0AvgMHz = $(if ($u1) { [int]$u1[0].LP0Avg } else { $null })
    AllCorePAvgMHz = $(if ($p) { [int]$p[0].PAvg } else { $null }); AllCoreEAvgMHz = $(if ($p) { [int]$p[0].EAvg } else { $null })
    AllCorePkgW = $(if ($p) { [double]$p[0].PkgWAvg } else { $null }); AllCoreTempC = $(if ($p) { [double]$p[0].TempCAvg } else { $null }); AllCoreTempMaxC = $(if ($p) { [double]$p[0].TempCMax } else { $null })
    LightPkgW = $(if ($u1) { [double]$u1[0].PkgWAvg } else { $null }); LightTempC = $(if ($u1) { [double]$u1[0].TempCAvg } else { $null })
    P95 = ($p | ForEach-Object { $_.Verdict }) -join ','
  }
} | Sort-Object X
$steps | Export-Csv "$Root\data\calibration\steps_summary.csv" -NoTypeInformation

$stock = $steps | Where-Object CapMHz -eq 0 | Select-Object -First 1
$xt = @(@(2500, '2500'), @(3000, '3000'), @(3500, '3500'), @(4000, '4000'), @(4500, '4500'), @(5000, '5000'), @(5500, '5500'), @(5800, 'no cap'))
$pt = { param($prop, $unit) @($steps | Where-Object { $null -ne $_.$prop -and $_.$prop -ne 0 } | ForEach-Object { , @($_.X, [double]$_.$prop, ("{0} {1} at cap {2}" -f $_.$prop, $unit, $_.Label)) }) }
$charts = @(
  @{ type = 'bar'; width = 900; file = 'lp0_errors_vs_cap.svg'; title = 'Silent errors on LP0 vs P-core frequency cap'
     subtitle = 'Unwinder torture test (bursty), errors per 100 million stack walks - 0 means none observed'
     ylabel = 'errors / 100 M walks'; xlabel = 'P-core cap (MHz)'
     bars = @($steps | Where-Object { $null -ne $_.ErrPer100M } | ForEach-Object { , @($_.Label, [double]$_.ErrPer100M, ("{0:N0} errors in {1:N0} walks" -f $_.UnwindErrors, $_.UnwindWalks)) }) }
  @{ type = 'line'; file = 'clocks_vs_cap.svg'; title = 'Clock speed reached under load vs P-core cap'; subtitle = 'MHz; single-thread = favored core LP0 spin test, all-core = Prime95 Small FFT (32 threads)'
     ylabel = 'MHz'; xlabel = 'P-core cap (MHz)'; unit = ' MHz'; xticks = $xt; ymin = 0; ymax = 6000
     series = @(@{ name = 'Single-thread peak (LP0)'; short = '1T'; slot = 1; points = & $pt 'SingleThreadMaxMHz' 'MHz' },
                @{ name = 'All-core, P-core average'; short = 'P all-core'; slot = 2; points = & $pt 'AllCorePAvgMHz' 'MHz' },
                @{ name = 'All-core, E-core average'; short = 'E all-core'; slot = 3; points = & $pt 'AllCoreEAvgMHz' 'MHz' }) }
  @{ type = 'line'; file = 'power_vs_cap.svg'; title = 'CPU package power vs P-core cap'; subtitle = 'Watts (RAPL package), average over each test'
     ylabel = 'W'; xlabel = 'P-core cap (MHz)'; unit = ' W'; xticks = $xt; ymin = 0
     series = @(@{ name = 'All-core Prime95'; short = 'all-core'; slot = 1; points = & $pt 'AllCorePkgW' 'W' },
                @{ name = 'Light bursty load (LP0 test)'; short = 'light'; slot = 2; points = & $pt 'LightPkgW' 'W' }) }
  @{ type = 'line'; file = 'temp_vs_cap.svg'; title = 'CPU temperature vs P-core cap'; subtitle = 'deg C, ASUS embedded-controller CPU sensor, average over each test'
     ylabel = 'deg C'; xlabel = 'P-core cap (MHz)'; unit = ' C'; xticks = $xt; ymin = 40; ymax = 100
     series = @(@{ name = 'All-core Prime95'; short = 'all-core'; slot = 1; points = & $pt 'AllCoreTempC' 'C' },
                @{ name = 'Light bursty load (LP0 test)'; short = 'light'; slot = 2; points = & $pt 'LightTempC' 'C' }) }
)
@{ charts = $charts } | ConvertTo-Json -Depth 10 | Set-Content "$Root\data\calibration\chart_data.json" -Encoding utf8
python "$Root\tools\make_charts.py" "$Root\data\calibration\chart_data.json" "$Root\charts"
$steps | Format-Table Label, Verdict, UnwindErrors, UnwindWalks, ErrPer100M, V2Result, SingleThreadMaxMHz, AllCorePAvgMHz, AllCoreEAvgMHz, AllCorePkgW, AllCoreTempC, LightTempC -AutoSize | Out-String -Width 250


