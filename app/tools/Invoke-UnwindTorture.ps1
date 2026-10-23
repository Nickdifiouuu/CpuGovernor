# Invoke-UnwindTorture.ps1 — runs the unwinder torture test in a SEPARATE pwsh process (so a fault only kills the
# test), then reports walks, mismatches, process crash, new WHEA events and new dumps. Non-elevated.
param(
  [Parameter(Mandatory)][string]$Label,
  [double]$Minutes = 5,
  [int[]]$LogicalProcessors = @(0, 2),     # favored P-core 0 and P-core 1 (one thread each)
  [int]$Depth = 40,
  [switch]$Bursty,
  [switch]$Manual,                         # v2: explicit RtlVirtualUnwind walk through every frame (deep); default v1 uses RtlCaptureStackBackTrace
  [string]$RunRoot = (Join-Path (Split-Path $PSScriptRoot -Parent) 'data\unwind')
)
$runDir = Join-Path $RunRoot ("{0:yyyyMMdd_HHmmss}_{1}" -f (Get-Date), ($Label -replace '[^\w\-]', '_'))
New-Item -ItemType Directory -Force $runDir | Out-Null
$cs = Join-Path $PSScriptRoot '..\lib\UnwindTorture.cs'
$child = @"
`$ErrorActionPreference = 'Stop'
Add-Type -Path '$cs'
`$r = [UnwindTorture]::$(if ($Manual) { 'RunManual' } else { 'Run' })(@($($LogicalProcessors -join ',')), $([double]$Minutes * 60), $Depth, `$$([bool]$Bursty))
`$r | ConvertTo-Json | Set-Content '$runDir\workers.json'
"@
Set-Content "$runDir\child.ps1" $child
$start = Get-Date
$dumpsBefore = @(Get-ChildItem C:\Windows\Minidump -Filter *.dmp -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
"$($start.ToString('o'))`tstart`t$Label`tLPs=$($LogicalProcessors -join '+')`tbursty=$([bool]$Bursty)`tmanual=$([bool]$Manual)" | Out-File "$RunRoot\runs.log" -Append
$p = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "$runDir\child.ps1" -PassThru -WindowStyle Hidden -RedirectStandardError "$runDir\stderr.txt"
$p.WaitForExit()
$stop = Get-Date
$workers = if (Test-Path "$runDir\workers.json") { Get-Content "$runDir\workers.json" -Raw | ConvertFrom-Json } else { @() }
$whea = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; StartTime = $start } -ErrorAction SilentlyContinue)
$newDumps = @(Get-ChildItem C:\Windows\Minidump -Filter *.dmp -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin $dumpsBefore })
$crashed = ($p.ExitCode -ne 0) -or -not $workers
$mismatch = ($workers | Measure-Object Mismatches -Sum).Sum
$result = [pscustomobject]@{
  Label = $Label; LPs = ($LogicalProcessors -join '+'); Bursty = [bool]$Bursty; Manual = [bool]$Manual; Start = $start; Stop = $stop
  Minutes = [math]::Round(($stop - $start).TotalMinutes, 2); Walks = ($workers | Measure-Object Walks -Sum).Sum
  WalksPerSec = $(if ($workers) { [math]::Round(($workers | Measure-Object Walks -Sum).Sum / (($workers | Measure-Object Seconds -Maximum).Maximum), 0) } else { 0 })
  StackDepth = ($workers | Select-Object -First 1).Depth; Mismatches = [int]$mismatch
  FirstMismatch = (($workers | Where-Object { $_.FirstMismatch } | ForEach-Object { "LP$($_.Lp): $($_.FirstMismatch)" }) -join ' | ')
  TestProcessCrashed = $crashed; ExitCode = $p.ExitCode; WheaEvents = $whea.Count; NewDumps = $newDumps.Count
  Verdict = $(if ($crashed -or $mismatch -or $whea.Count -or $newDumps.Count) { 'FAIL' } else { 'PASS' }); RunDir = $runDir
}
$result | ConvertTo-Json | Set-Content "$runDir\result.json"
"$($stop.ToString('o'))`tstop`t$Label`t$($result.Verdict)`twalks=$($result.Walks)`tmismatch=$mismatch`tcrash=$crashed`twhea=$($whea.Count)" | Out-File "$RunRoot\runs.log" -Append
$result
