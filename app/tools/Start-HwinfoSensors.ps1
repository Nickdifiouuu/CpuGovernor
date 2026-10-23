# Start-HwinfoSensors.ps1 — run ELEVATED. Configures HWiNFO for sensors-only mode with shared memory,
# starts it, and records a read-only snapshot of the ASUS embedded-controller values.
param([Parameter(Mandatory)][string]$OutDir)
$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force $OutDir | Out-Null
$exe = 'C:\Program Files\HWiNFO64\HWiNFO64.EXE'
$ini = 'C:\Program Files\HWiNFO64\HWiNFO64.INI'

# 0. HWiNFO rewrites its INI on exit, so stop any running instance before editing settings
$running = Get-Process HWiNFO64 -ErrorAction SilentlyContinue
if ($running) { $running | Stop-Process -Force; Start-Sleep -Seconds 3; "Stopped running HWiNFO (pid $($running.Id -join ','))" | Out-File "$OutDir\hwinfo_launch.txt" }

# 1. HWiNFO settings (merge into [Settings]; everything else left unchanged)
$want = [ordered]@{ SensorsOnly = 1; SummaryOnly = 0; ShowWelcomeAndProgress = 0; AutoUpdate = 0; AutoUpdateBetaDisable = 1
                    SensorsSM = 1; MinimalizeSensors = 1; MinimalizeMainWnd = 1; SensorInterval = 1000 }
$lines = if (Test-Path $ini) { [System.Collections.Generic.List[string]](Get-Content $ini) } else { [System.Collections.Generic.List[string]]@('[Settings]') }
if (-not ($lines -contains '[Settings]')) { $lines.Insert(0, '[Settings]') }
foreach ($k in $want.Keys) {
  $idx = -1; for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match "^$k=") { $idx = $i; break } }
  if ($idx -ge 0) { $lines[$idx] = "$k=$($want[$k])" } else { $lines.Insert($lines.IndexOf('[Settings]') + 1, "$k=$($want[$k])") }
}
Set-Content -Path $ini -Value $lines -Encoding ascii
"INI written: $ini" | Out-File "$OutDir\hwinfo_launch.txt" -Append

# 2. Start HWiNFO (inherits elevation; its driver needs admin)
if (-not (Get-Process HWiNFO64 -ErrorAction SilentlyContinue)) { Start-Process $exe; "HWiNFO started $(Get-Date -Format o)" | Out-File "$OutDir\hwinfo_launch.txt" -Append }
else { "HWiNFO already running" | Out-File "$OutDir\hwinfo_launch.txt" -Append }

# 3. ASUS EC snapshot via ACPI WMI — DSTS is the read-only "get device status" method
$out = foreach ($pair in ([ordered]@{ 'ThermalPolicy (0=Balanced/Perf,1=Turbo,2=Silent)'=0x00120075; 'CPU temp C'=0x00120094; 'GPU temp C'=0x00120097
                                    'CPU fan'=0x00110013; 'GPU fan'=0x00110014; 'PL1/SPL W'=0x001200A0; 'PL2/SPPT W'=0x001200B0; 'fPPT W'=0x001200C1 }).GetEnumerator()) {
  try {
    $w = Get-CimInstance -Namespace root\wmi -ClassName AsusAtkWmi_WMNB -ErrorAction Stop | Select-Object -First 1
    $r = Invoke-CimMethod -InputObject $w -MethodName DSTS -Arguments @{ Device_ID = [uint32]$pair.Value } -ErrorAction Stop
    $v = [uint32]$r.device_status
    "{0,-50} raw=0x{1:X8} low16={2}" -f $pair.Key, $v, ($v -band 0xFFFF)
  } catch { "{0,-50} error: {1}" -f $pair.Key, $_.Exception.Message }
}
$out | Out-File "$OutDir\asus_ec_snapshot.txt"
New-Item -ItemType File "$OutDir\DONE" -Force | Out-Null
