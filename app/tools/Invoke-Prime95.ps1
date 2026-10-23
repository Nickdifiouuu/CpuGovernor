# Invoke-Prime95.ps1 — run a Prime95 torture test in an isolated working directory, optionally pinned to
# specific logical CPUs, then report Prime95 errors, new WHEA events and new crash dumps. Non-elevated.
param(
  [Parameter(Mandatory)][string]$Label,
  [double]$Minutes = 10,
  [ValidateSet('SmallFFT','SmallestFFT','LargeFFT','Blend')][string]$Mode = 'SmallFFT',
  [int]$Threads = 0,                 # 0 = one per logical CPU in the affinity set
  [UInt64]$AffinityMask = 0,         # 0 = all CPUs; e.g. 0x1 = LP0, 0xF = LP0-3 (favored P-cores 0/1)
  [string]$RunRoot = (Join-Path (Split-Path $PSScriptRoot -Parent) 'data\p95')
)
$exe = (Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter prime95.exe -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
if (-not $exe) { throw 'prime95.exe not found' }
$runDir = Join-Path $RunRoot ("{0:yyyyMMdd_HHmmss}_{1}" -f (Get-Date), ($Label -replace '[^\w\-]', '_'))
New-Item -ItemType Directory -Force $runDir | Out-Null

$lpCount = [Environment]::ProcessorCount
$lps = if ($AffinityMask) { @(0..63 | Where-Object { $AffinityMask -band ([UInt64]1 -shl $_) }) } else { @(0..($lpCount - 1)) }
if ($Threads -le 0) { $Threads = $lps.Count }
$fft = @{ SmallestFFT = @(4, 21); SmallFFT = @(36, 248); LargeFFT = @(426, 8192); Blend = @(4, 8192) }[$Mode]
$mem = if ($Mode -in 'LargeFFT', 'Blend') { 4096 } else { 0 }

@"
V24OptionsConverted=1
V30OptionsConverted=1
StressTester=1
UsePrimenet=0
TortureMem=$mem
TortureTime=3
MinTortureFFT=$($fft[0])
MaxTortureFFT=$($fft[1])
TortureThreads=$Threads
TortureHyperthreading=0
EnableSetAffinity=$(if ($AffinityMask) { 0 } else { 1 })
"@ | Set-Content -Path "$runDir\prime.txt" -Encoding ascii

$start = Get-Date
$dumpsBefore = @(Get-ChildItem C:\Windows\Minidump -Filter *.dmp -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
$p = Start-Process -FilePath $exe -ArgumentList '-t', "-W$runDir" -WorkingDirectory $runDir -PassThru -WindowStyle Minimized
if ($AffinityMask) { Start-Sleep -Milliseconds 300; $p.ProcessorAffinity = [IntPtr][Int64]$AffinityMask }
"$($start.ToString('o'))`tstart`t$Label`t$Mode`tthreads=$Threads`tmask=0x$('{0:X}' -f $AffinityMask)`tpid=$($p.Id)" | Out-File "$RunRoot\runs.log" -Append

$end = $start.AddMinutes($Minutes)
while ((Get-Date) -lt $end -and -not $p.HasExited) { Start-Sleep -Seconds 2 }
$exitedEarly = $p.HasExited
if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force; Start-Sleep -Milliseconds 500 }
$stop = Get-Date

$res = if (Test-Path "$runDir\results.txt") { Get-Content "$runDir\results.txt" } else { @() }
$errLines = $res | Where-Object { $_ -match '(?i)FATAL ERROR|Hardware failure|Possible hardware errors|ERROR:|Rounding was|SUM\(INPUTS\)|illegal sumout|expected' }
$passed = @($res | Where-Object { $_ -match '(?i)passed' }).Count     # @() so a 0/1-match result still has .Count under StrictMode
$whea = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; StartTime = $start } -ErrorAction SilentlyContinue)
$newDumps = @(Get-ChildItem C:\Windows\Minidump -Filter *.dmp -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin $dumpsBefore })

$result = [pscustomobject]@{
  Label = $Label; Mode = $Mode; Threads = $Threads; AffinityMask = ('0x{0:X}' -f $AffinityMask); Start = $start; Stop = $stop
  Minutes = [math]::Round(($stop - $start).TotalMinutes, 2); Prime95ExitedEarly = $exitedEarly
  SelfTestsPassed = $passed; Prime95Errors = @($errLines).Count; WheaEvents = $whea.Count
  WheaIds = (($whea | Group-Object Id | ForEach-Object { "$($_.Name)x$($_.Count)" }) -join ' '); NewDumps = $newDumps.Count
  Verdict = $(if (@($errLines).Count -or $whea.Count -or $newDumps.Count -or $exitedEarly) { 'FAIL' } else { 'PASS' }); RunDir = $runDir
}
$result | ConvertTo-Json | Set-Content "$runDir\result.json"
"$($stop.ToString('o'))`tstop`t$Label`t$($result.Verdict)`tp95err=$($result.Prime95Errors)`twhea=$($result.WheaEvents)`tdumps=$($result.NewDumps)" | Out-File "$RunRoot\runs.log" -Append
if ($errLines) { $errLines | Set-Content "$runDir\errors.txt" }
$result
