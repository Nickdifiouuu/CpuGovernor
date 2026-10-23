# Run-RemainingCalibration.ps1 — low P-core ladder (charts), E-core check, turbo-off, stock all-core reference.
$cal = Join-Path $PSScriptRoot 'Invoke-Calibration.ps1'
$low = foreach ($p in 2500, 2700, 2900, 3000, 3200, 3400, 3600, 3800, 4000) { @{ Label = "P$p"; PCoreMHz = $p; ECoreMHz = 0; PMaxStatePct = 100; EMaxStatePct = 100 } }
& $cal -Name 'pcore_low' -Steps $low -Tests @(@{ Kind = 'P95'; Preset = 'AllCore'; Minutes = 1.5 }, @{ Kind = 'Unwind'; LPs = @(0); Minutes = 1; Bursty = $true; Manual = $false }) | Out-Null
& $cal -Name 'ecore' -Steps @(@{ Label = 'E_uncapped_P5000'; PCoreMHz = 5000; ECoreMHz = 0; PMaxStatePct = 100; EMaxStatePct = 100 }) `
      -Tests @(@{ Kind = 'Unwind'; LPs = @(16, 20, 24, 28); Minutes = 2; Bursty = $true; Manual = $false }, @{ Kind = 'P95'; Preset = 'ECores'; Minutes = 2 }) | Out-Null
& $cal -Name 'turbooff' -Steps @(@{ Label = 'TurboOff'; PCoreMHz = 0; ECoreMHz = 0; PMaxStatePct = 99; EMaxStatePct = 99 }) `
      -Tests @(@{ Kind = 'Unwind'; LPs = @(0); Minutes = 2; Bursty = $true; Manual = $false }, @{ Kind = 'P95'; Preset = 'AllCore'; Minutes = 1.5 }) | Out-Null
& $cal -Name 'pcore_stockallcore' -Steps @(@{ Label = 'NoCap'; PCoreMHz = 0; ECoreMHz = 0; PMaxStatePct = 100; EMaxStatePct = 100 }) `
      -Tests @(@{ Kind = 'P95'; Preset = 'AllCore'; Minutes = 1.5 }) | Out-Null

$all = foreach ($n in 'pcore_low', 'ecore', 'turbooff', 'pcore_stockallcore') {
  (Get-Content (Join-Path $PSScriptRoot "..\data\calibration\$n.state.json") -Raw | ConvertFrom-Json).Results | ForEach-Object { [pscustomobject]$_ } |
    Select-Object @{ n = 'Run'; e = { $n } }, Step, Test, Verdict, Detail, CapCheckPMax, CapCheckEMax, PAvg, EAvg, PkgWAvg, TempCAvg, TempCMax
}
$all | Format-Table -AutoSize | Out-String -Width 280
