#Requires -Version 7.0
# CpuStabilityGovernor — frequency-cap governor for an unstable hybrid Intel CPU (i9-14900HX).
# Uses only powercfg / Windows power settings. Never touches voltage, MSRs, VBS/HVCI or firmware.
Set-StrictMode -Version 3.0

$script:Root         = $PSScriptRoot
$script:LogFile      = Join-Path $PSScriptRoot 'governor.log'
$script:StateFile    = Join-Path $PSScriptRoot 'state.json'
$script:ProfileFile  = Join-Path $PSScriptRoot 'profiles.json'
$script:BaselineFile = Join-Path $PSScriptRoot 'backup\baseline_settings.json'
$script:SchemesKey   = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes'
$script:SubProcessor = '54533251-82be-4824-96c1-47b60b740d00'
# Settings the governor owns. On this hybrid CPU the unsuffixed settings apply to efficiency class 0 (E-cores)
# and the "1" settings to efficiency class 1 (P-cores). There are no class-2 (LP-E) cores on Raptor Lake-HX.
$script:Managed = [ordered]@{
    PROCFREQMAX1     = @{ Guid = '75b0ae3f-bce0-45a7-8c89-c9611c25e101'; What = 'P-core max frequency (MHz, 0 = no cap)' }
    PROCFREQMAX      = @{ Guid = '75b0ae3f-bce0-45a7-8c89-c9611c25e100'; What = 'E-core max frequency (MHz, 0 = no cap)' }
    PROCTHROTTLEMAX1 = @{ Guid = 'bc5038f7-23e0-4960-96da-33abaf5935ed'; What = 'P-core max processor state (%; 99 = no turbo)' }
    PROCTHROTTLEMAX  = @{ Guid = 'bc5038f7-23e0-4960-96da-33abaf5935ec'; What = 'E-core max processor state (%; 99 = no turbo)' }
}
$script:KnownOverlays = @('ded574b5-45a0-4f42-8737-46345c09c238', '961cc777-2547-4f9d-8174-7d86181b8a7a', '3af9b8d9-7c97-431d-ad78-34a8bfea439f')
$script:WheaIds = 1, 17, 18, 19, 20, 46, 47

#region ---------- infrastructure ----------
function Write-GovernorLog {
    param([Parameter(Mandatory)][string]$Message,
          [ValidateSet('INFO', 'ACTION', 'TEST', 'WARN', 'ERROR')][string]$Level = 'INFO')
    $line = '{0:yyyy-MM-dd HH:mm:ss.fff} [{1,-6}] [{2}@{3} pid={4}] {5}' -f (Get-Date), $Level, $env:USERNAME, $env:COMPUTERNAME, $PID, $Message
    for ($i = 0; $i -lt 5; $i++) {   # tolerate concurrent writers (task + CLI)
        try { [IO.File]::AppendAllText($script:LogFile, $line + [Environment]::NewLine); break } catch { Start-Sleep -Milliseconds 100 }
    }
    if ($Level -in 'WARN', 'ERROR') { Write-Warning $Message } else { Write-Verbose $line }
}

function Test-IsElevated {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-GovernorState {
    if (Test-Path $script:StateFile) { try { return Get-Content $script:StateFile -Raw | ConvertFrom-Json -AsHashtable } catch { Write-GovernorLog -Level WARN "state.json unreadable: $_" } }
    return @{}
}

function Set-GovernorState([hashtable]$State) {
    $State['UpdatedAt'] = (Get-Date).ToString('o')
    $State | ConvertTo-Json -Depth 6 | Set-Content -Path $script:StateFile -Encoding utf8
}
#endregion

#region ---------- power setting primitives ----------
function Get-CpuPowerTarget {
    <# All schemes and overlays the power service stores (listed, hidden and overlay schemes). #>
    foreach ($g in (Get-ChildItem $script:SchemesKey -ErrorAction Stop | Select-Object -ExpandProperty PSChildName)) {
        $txt = (& powercfg /qh $g SUB_PROCESSOR PROCFREQMAX1 2>&1) -join "`n"
        $name = if ($txt -match 'Power Scheme GUID: \S+\s+\((.+)\)') { $Matches[1] } else { $null }
        $overlay = $g -in $script:KnownOverlays -or "$name" -match 'Overlay'
        $hasValues = $txt -match 'Current AC Power Setting Index:\s+0x'     # templates print "UNKNOWN"
        [pscustomobject]@{
            Guid           = $g
            Name           = $(if ($name) { $name } else { 'unnamed' })
            Kind           = $(if ($overlay) { 'Overlay' } elseif ($name -and -not $hasValues) { 'Template' } else { 'Scheme' })
            # Schemes must expose the setting; overlays legitimately leave it undefined (base scheme applies).
            # Uninstalled templates (e.g. Ultimate Performance) accept writes silently but store nothing -> not addressable.
            Addressable    = [bool]$name -and ($hasValues -or $overlay)
            NeedsElevation = $overlay     # powercfg refuses overlay writes without admin
        }
    }
}

function Get-WritableCpuPowerTarget {
    <# Targets this process can write: all addressable schemes; overlays only when elevated (e.g. the SYSTEM tasks). #>
    $elev = Test-IsElevated
    Get-CpuPowerTarget | Where-Object { $_.Addressable -and ($elev -or -not $_.NeedsElevation) }
}

function Read-CpuPowerValue([string]$Guid, [string]$Alias) {
    $txt = (& powercfg /qh $Guid SUB_PROCESSOR $Alias 2>&1) -join "`n"
    [pscustomobject]@{
        AC = $(if ($txt -match 'Current AC Power Setting Index:\s+0x([0-9a-fA-F]+)') { [Convert]::ToInt64($Matches[1], 16) } else { $null })
        DC = $(if ($txt -match 'Current DC Power Setting Index:\s+0x([0-9a-fA-F]+)') { [Convert]::ToInt64($Matches[1], 16) } else { $null })
    }
}

function Write-CpuPowerValue([string]$Guid, [string]$Alias, [long]$AC, [long]$DC) {
    $o1 = & powercfg /setacvalueindex $Guid SUB_PROCESSOR $Alias $AC 2>&1
    $o2 = & powercfg /setdcvalueindex $Guid SUB_PROCESSOR $Alias $DC 2>&1
    $rb = Read-CpuPowerValue $Guid $Alias
    if ($rb.AC -ne $AC -or $rb.DC -ne $DC) {
        throw "write not verified: $Alias on $Guid -> read back AC=$($rb.AC) DC=$($rb.DC), wanted AC=$AC DC=$DC. powercfg said: $o1 $o2".Trim()
    }
}

function Remove-CpuPowerValue([string]$Guid, [string]$Alias) {
    <# Makes a setting "undefined" again on an overlay (only possible by deleting its registry values; needs admin). #>
    if (-not (Test-IsElevated)) { throw 'removing an overlay value requires elevation' }
    $key = Join-Path $script:SchemesKey "$Guid\$($script:SubProcessor)\$($script:Managed[$Alias].Guid)"
    if (Test-Path $key) { Remove-Item $key -Recurse -Force }
}

function Get-ActiveCpuPowerScheme {
    if (((& powercfg /getactivescheme) -join ' ') -match '([0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12})') { return $Matches[1] }
}

function Update-ActiveCpuPowerScheme {
    <# Re-activating the current scheme makes the power manager re-read it, so new limits apply immediately. #>
    $active = Get-ActiveCpuPowerScheme
    & powercfg /setactive $active 2>&1 | Out-Null
    return $active
}
#endregion

#region ---------- baseline / apply / reset ----------
function Save-CpuGovernorBaseline {
    <# Snapshot of the managed settings on every target, plus .pow exports of listed schemes. Taken once, before the first change. #>
    [CmdletBinding()] param([switch]$Force)
    if ((Test-Path $script:BaselineFile) -and -not $Force) { return }
    New-Item -ItemType Directory -Force (Split-Path $script:BaselineFile) | Out-Null
    $rows = foreach ($t in Get-CpuPowerTarget) {
        foreach ($k in $script:Managed.Keys) {
            $v = if ($t.Addressable) { Read-CpuPowerValue $t.Guid $k } else { [pscustomobject]@{ AC = $null; DC = $null } }
            [pscustomobject]@{ Guid = $t.Guid; Name = $t.Name; Kind = $t.Kind; Setting = $k; AC = $v.AC; DC = $v.DC }
        }
    }
    $rows | ConvertTo-Json -Depth 3 | Set-Content $script:BaselineFile -Encoding utf8
    $listed = (& powercfg /list) | Select-String '([0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12})' | ForEach-Object { $_.Matches[0].Value }
    foreach ($g in $listed) { & powercfg /export (Join-Path (Split-Path $script:BaselineFile) "scheme_$g.pow") $g 2>&1 | Out-Null }
    Write-GovernorLog -Level ACTION "Baseline snapshot saved: $($rows.Count) values -> $script:BaselineFile; exported $(@($listed).Count) listed schemes to backup\*.pow"
}

function Set-CpuFrequencyCap {
    <#
    .SYNOPSIS  Cap P-core and E-core frequency (and optionally turbo) on every scheme and overlay, AC and DC, effective immediately.
    .EXAMPLE   Set-CpuFrequencyCap -PCoreMHz 3800 -ECoreMHz 3000
    .EXAMPLE   Set-CpuFrequencyCap -PMaxStatePct 99 -EMaxStatePct 99     # turbo off on both core types
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [ValidateRange(0, 6000)][int]$PCoreMHz = 0,
        [ValidateRange(0, 6000)][int]$ECoreMHz = 0,
        [ValidateRange(1, 100)][int]$PMaxStatePct = 100,
        [ValidateRange(1, 100)][int]$EMaxStatePct = 100,
        [string]$Reason = 'manual',
        [string]$ProfileName = ''
    )
    if (-not $WhatIfPreference) { Save-CpuGovernorBaseline }
    $want = [ordered]@{ PROCFREQMAX1 = $PCoreMHz; PROCFREQMAX = $ECoreMHz; PROCTHROTTLEMAX1 = $PMaxStatePct; PROCTHROTTLEMAX = $EMaxStatePct }
    $all = @(Get-CpuPowerTarget | Where-Object Addressable)
    $targets = @(Get-WritableCpuPowerTarget)
    $skipped = @($all | Where-Object { $_.Guid -notin $targets.Guid })
    if (-not $WhatIfPreference) {
        Write-GovernorLog -Level ACTION ("Apply P={0} MHz E={1} MHz Pstate={2}% Estate={3}% on {4} schemes/overlays (AC+DC). Reason: {5}" -f $PCoreMHz, $ECoreMHz, $PMaxStatePct, $EMaxStatePct, $targets.Count, $Reason)
        if ($skipped) { Write-GovernorLog -Level INFO ("Not elevated: skipped overlay(s) {0}. They leave these settings undefined, so the base-scheme caps apply; the SYSTEM tasks write them explicitly." -f (($skipped.Name) -join ', ')) }
    }
    $failed = 0; $changed = 0
    foreach ($t in $targets) {
        foreach ($k in $want.Keys) {
            $cur = Read-CpuPowerValue $t.Guid $k
            if ($cur.AC -eq $want[$k] -and $cur.DC -eq $want[$k]) { continue }
            if (-not $PSCmdlet.ShouldProcess("$($t.Name) [$($t.Guid)]", "$k AC/DC $($cur.AC)/$($cur.DC) -> $($want[$k])")) { continue }
            try { Write-CpuPowerValue $t.Guid $k $want[$k] $want[$k]; $changed++ }
            catch { $failed++; Write-GovernorLog -Level ERROR $_.Exception.Message }
        }
    }
    if ($WhatIfPreference) { return }
    $active = Update-ActiveCpuPowerScheme
    Write-GovernorLog -Level ACTION "Wrote $changed value(s), $failed failure(s); re-activated scheme $active"
    $st = Get-GovernorState
    $st['Profile'] = $ProfileName; $st['PCoreMHz'] = $PCoreMHz; $st['ECoreMHz'] = $ECoreMHz
    $st['PMaxStatePct'] = $PMaxStatePct; $st['EMaxStatePct'] = $EMaxStatePct; $st['AppliedAt'] = (Get-Date).ToString('o'); $st['Reason'] = $Reason
    Set-GovernorState $st
    if ($failed) { throw "$failed setting write(s) failed; see governor.log" }
    [pscustomobject]@{ PCoreMHz = $PCoreMHz; ECoreMHz = $ECoreMHz; PMaxStatePct = $PMaxStatePct; EMaxStatePct = $EMaxStatePct; Targets = $targets.Count; ValuesChanged = $changed }
}

function Reset-CpuGovernor {
    <#
    .SYNOPSIS  Undo the governor. Default: restore the exact pre-governor snapshot. -ToDefaults: no caps, 100 % max state everywhere.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([switch]$ToDefaults)
    $elev = Test-IsElevated
    if ($ToDefaults) {
        $rows = foreach ($t in Get-CpuPowerTarget | Where-Object Addressable) {
            foreach ($k in $script:Managed.Keys) { [pscustomobject]@{ Guid = $t.Guid; Name = $t.Name; Kind = $t.Kind; Setting = $k; AC = $(if ($k -like 'PROCFREQ*') { 0 } else { 100 }); DC = $(if ($k -like 'PROCFREQ*') { 0 } else { 100 }) } }
        }
    } else {
        if (-not (Test-Path $script:BaselineFile)) { throw "No baseline snapshot at $script:BaselineFile; use -ToDefaults" }
        $rows = Get-Content $script:BaselineFile -Raw | ConvertFrom-Json
    }
    if (-not $WhatIfPreference) { Write-GovernorLog -Level ACTION ("Reset requested ({0}); elevated={1}" -f $(if ($ToDefaults) { 'to defaults' } else { 'restore baseline snapshot' }), $elev) }
    $failed = 0
    $writable = @(Get-WritableCpuPowerTarget).Guid
    foreach ($r in $rows) {
        $isOverlay = $r.Guid -in $script:KnownOverlays -or $r.Kind -eq 'Overlay'
        $cur = Read-CpuPowerValue $r.Guid $r.Setting
        $undefinedBefore = ($null -eq $r.AC -and $null -eq $r.DC)
        if ($undefinedBefore -and $null -eq $cur.AC -and $null -eq $cur.DC) { continue }              # still undefined: nothing to undo
        if (-not $undefinedBefore -and $cur.AC -eq $r.AC -and $cur.DC -eq $r.DC) { continue }        # already at baseline
        if ($r.Guid -notin $writable) {
            if ($isOverlay -and -not $WhatIfPreference) { Write-GovernorLog -Level WARN "$($r.Setting) on overlay $($r.Name) is $($cur.AC)/$($cur.DC); run Reset-CpuGovernor elevated to restore it" }
            continue
        }
        if (-not $PSCmdlet.ShouldProcess("$($r.Name) [$($r.Guid)]", "$($r.Setting) $($cur.AC)/$($cur.DC) -> AC=$($r.AC) DC=$($r.DC)")) { continue }
        try {
            if ($undefinedBefore) { Remove-CpuPowerValue $r.Guid $r.Setting }    # overlay value added by the governor (elevated here)
            else { Write-CpuPowerValue $r.Guid $r.Setting $r.AC $r.DC }
        } catch { $failed++; Write-GovernorLog -Level ERROR $_.Exception.Message }
    }
    if ($WhatIfPreference) { return }
    $active = Update-ActiveCpuPowerScheme
    $st = Get-GovernorState; $st['Profile'] = $(if ($ToDefaults) { 'Reset-Defaults' } else { 'Reset-Baseline' })
    foreach ($k in 'PCoreMHz', 'ECoreMHz', 'PMaxStatePct', 'EMaxStatePct') { $st.Remove($k) }
    $st['AppliedAt'] = (Get-Date).ToString('o'); Set-GovernorState $st
    Write-GovernorLog -Level ACTION "Reset complete; $failed failure(s); re-activated $active"
    if ($failed) { throw "$failed restore write(s) failed; see governor.log" }
}
#endregion

#region ---------- telemetry & verification ----------
function Get-CpuLiveSample {
    <# One ~1 s sample of per-class frequency, utilisation, RAPL power and PPM limit state. Non-admin. #>
    param([int]$Seconds = 1)
    $paths = '\Processor Information(0,*)\Actual Frequency', '\Processor Information(0,*)\% Processor Utility',
             '\Energy Meter(RAPL_Package0_PKG)\Power', '\Energy Meter(RAPL_Package0_PP0)\Power', '\Processor Information(_Total)\% Performance Limit'
    $s = (Get-Counter -Counter $paths -SampleInterval $Seconds -MaxSamples 1 -ErrorAction SilentlyContinue).CounterSamples
    $f = @{}; $u = @{}
    foreach ($x in $s) {
        if ($x.Path -match '\(0,(\d+)\)\\actual frequency$') { $f[[int]$Matches[1]] = $x.CookedValue }
        elseif ($x.Path -match '\(0,(\d+)\)\\% processor utility$') { $u[[int]$Matches[1]] = $x.CookedValue }
    }
    $p = 0..15 | ForEach-Object { $f[$_] }; $e = 16..31 | ForEach-Object { $f[$_] }
    [pscustomobject]@{
        Time = Get-Date
        LP0MHz = [int]$f[0]; LP2MHz = [int]$f[2]
        PAvgMHz = [int]($p | Measure-Object -Average).Average; PMaxMHz = [int]($p | Measure-Object -Maximum).Maximum
        EAvgMHz = [int]($e | Measure-Object -Average).Average; EMaxMHz = [int]($e | Measure-Object -Maximum).Maximum
        PUtilPct = [math]::Round((0..15 | ForEach-Object { $u[$_] } | Measure-Object -Average).Average, 1)
        EUtilPct = [math]::Round((16..31 | ForEach-Object { $u[$_] } | Measure-Object -Average).Average, 1)
        PackageW = [math]::Round((($s | Where-Object Path -like '*rapl_package0_pkg)\power').CookedValue) / 1000, 1)
        CoresW = [math]::Round((($s | Where-Object Path -like '*rapl_package0_pp0)\power').CookedValue) / 1000, 1)
        PerfLimitPct = ($s | Where-Object Path -like '*% performance limit').CookedValue
    }
}

if (-not ('CpuSpin' -as [type])) {
    Add-Type -TypeDefinition @'
using System; using System.Diagnostics; using System.Threading; using System.Runtime.InteropServices;
public static class CpuSpin {
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentThread();
    [DllImport("kernel32.dll")] static extern UIntPtr SetThreadAffinityMask(IntPtr h, UIntPtr mask);
    static double sink;
    /// Busy-loop one thread pinned to a logical processor for ms milliseconds (returns immediately).
    public static Thread Start(int lp, int ms) {
        var t = new Thread(() => {
            SetThreadAffinityMask(GetCurrentThread(), new UIntPtr(1UL << lp));
            var sw = Stopwatch.StartNew(); double x = 1.0;
            while (sw.ElapsedMilliseconds < ms) { for (int i = 0; i < 100000; i++) x = x * 1.0000001 + 1e-9; }
            sink = x;
        });
        t.IsBackground = true; t.Start(); return t;
    }
}
'@
}

function Test-CpuCapApplied {
    <#
    .SYNOPSIS  Load one thread on a P-core (default LP0 = favored core) and on an E-core, measure their clocks, compare with the caps.
    #>
    [CmdletBinding()] param([int]$PLogicalProcessor = 0, [int]$ELogicalProcessor = 16, [int]$Seconds = 6, [int]$ToleranceMHz = 120)
    $st = Get-GovernorState
    $pCap = if ($st.ContainsKey('PCoreMHz')) { [int]$st['PCoreMHz'] } else { 0 }
    $eCap = if ($st.ContainsKey('ECoreMHz')) { [int]$st['ECoreMHz'] } else { 0 }
    $t1 = [CpuSpin]::Start($PLogicalProcessor, $Seconds * 1000 + 1500)
    $t2 = [CpuSpin]::Start($ELogicalProcessor, $Seconds * 1000 + 1500)
    Start-Sleep -Milliseconds 1200
    $samples = foreach ($i in 1..$Seconds) {
        $c = (Get-Counter "\Processor Information(0,$PLogicalProcessor)\Actual Frequency", "\Processor Information(0,$ELogicalProcessor)\Actual Frequency" -SampleInterval 1 -MaxSamples 1).CounterSamples
        [pscustomobject]@{ P = $c[0].CookedValue; E = $c[1].CookedValue }
    }
    $t1.Join(); $t2.Join()
    $pMax = [int]($samples.P | Measure-Object -Maximum).Maximum; $eMax = [int]($samples.E | Measure-Object -Maximum).Maximum
    $pOk = ($pCap -eq 0) -or ($pMax -le $pCap + $ToleranceMHz); $eOk = ($eCap -eq 0) -or ($eMax -le $eCap + $ToleranceMHz)
    $r = [pscustomobject]@{ PCapMHz = $pCap; PLoadedMaxMHz = $pMax; PAvgMHz = [int]($samples.P | Measure-Object -Average).Average; POk = $pOk
                            ECapMHz = $eCap; ELoadedMaxMHz = $eMax; EAvgMHz = [int]($samples.E | Measure-Object -Average).Average; EOk = $eOk }
    Write-GovernorLog -Level TEST ("Cap check: P cap {0} -> LP{1} max {2} MHz ({3}); E cap {4} -> LP{5} max {6} MHz ({7})" -f $pCap, $PLogicalProcessor, $pMax, $(if ($pOk) { 'OK' } else { 'EXCEEDED' }), $eCap, $ELogicalProcessor, $eMax, $(if ($eOk) { 'OK' } else { 'EXCEEDED' }))
    $r
}

function Get-CpuStatus {
    <# .SYNOPSIS Governor state, caps on every scheme/overlay, live clocks/power, WHEA and crash counters. #>
    [CmdletBinding()] param([switch]$Detailed)
    $st = Get-GovernorState
    $active = Get-ActiveCpuPowerScheme
    $ov = Get-ItemProperty $script:SchemesKey -ErrorAction SilentlyContinue
    $targets = @(Get-CpuPowerTarget | Where-Object Addressable)
    $caps = foreach ($t in $targets) {
        $o = [ordered]@{ Target = $t.Name; Kind = $t.Kind; Active = ($t.Guid -eq $active) }
        foreach ($k in $script:Managed.Keys) { $v = Read-CpuPowerValue $t.Guid $k; $o[$k] = '{0}/{1}' -f $v.AC, $v.DC }
        [pscustomobject]$o
    }
    $expect = if ($st.ContainsKey('PCoreMHz')) { '{0}/{0}|{1}/{1}|{2}/{2}|{3}/{3}' -f $st['PCoreMHz'], $st['ECoreMHz'], $st['PMaxStatePct'], $st['EMaxStatePct'] } else { $null }
    # an overlay that leaves all four settings undefined inherits the base scheme's caps -> counts as consistent
    $consistent = if ($expect) { @($caps | Where-Object { $sig = '{0}|{1}|{2}|{3}' -f $_.PROCFREQMAX1, $_.PROCFREQMAX, $_.PROCTHROTTLEMAX1, $_.PROCTHROTTLEMAX
                                                        $sig -eq $expect -or ($_.Kind -eq 'Overlay' -and $sig -eq '/|/|/|/') }).Count } else { $null }
    $live = Get-CpuLiveSample
    $since = if ($st.ContainsKey('InstalledAt')) { [datetime]$st['InstalledAt'] } else { (Get-Date).AddDays(-1) }
    $whea = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; Id = $script:WheaIds; StartTime = $since } -ErrorAction SilentlyContinue)
    $dumps = @(Get-ChildItem C:\Windows\Minidump -Filter *.dmp -ErrorAction SilentlyContinue | Where-Object LastWriteTime -gt $since)
    $task = Get-ScheduledTask -TaskName 'CpuStabilityGovernor-*' -ErrorAction SilentlyContinue
    $status = [pscustomobject]@{
        Profile            = $(if ($st.ContainsKey('Profile') -and $st['Profile']) { $st['Profile'] } else { '(none)' })
        Caps               = $(if ($expect) { 'P {0} MHz | E {1} MHz | P max {2}% | E max {3}%' -f $st['PCoreMHz'], $st['ECoreMHz'], $st['PMaxStatePct'], $st['EMaxStatePct'] } else { 'not managed' })
        AppliedAt          = $(if ($st.ContainsKey('AppliedAt')) { $st['AppliedAt'] } else { $null })
        ActiveScheme       = ($targets | Where-Object Guid -eq $active | Select-Object -ExpandProperty Name)
        Overlays           = 'AC: {0} | DC: {1}' -f $ov.ActiveOverlayAcPowerScheme, $ov.ActiveOverlayDcPowerScheme
        TargetsConsistent  = $(if ($null -ne $consistent) { "$consistent/$($targets.Count)" } else { 'n/a' })
        LiveP              = 'avg {0} MHz, max {1} MHz, favored LP0 {2} / LP2 {3} MHz, util {4}%' -f $live.PAvgMHz, $live.PMaxMHz, $live.LP0MHz, $live.LP2MHz, $live.PUtilPct
        LiveE              = 'avg {0} MHz, max {1} MHz, util {2}%' -f $live.EAvgMHz, $live.EMaxMHz, $live.EUtilPct
        PackagePowerW      = $live.PackageW
        WheaSince          = '{0} event(s) since {1:yyyy-MM-dd HH:mm}' -f $whea.Count, $since
        CrashDumpsSince    = $dumps.Count
        AutoLowered        = $(if ($st.ContainsKey('AutoLowered')) { $st['AutoLowered'] } else { $false })
        ScheduledTasks     = $(if ($task) { ($task | ForEach-Object { "$($_.TaskName)=$($_.State)" }) -join ', ' } elseif (Test-Path (Join-Path $script:Root 'tasks\CpuStabilityGovernor-HealthMonitor.xml')) { 'installed (task details need an elevated prompt)' } else { 'not installed' })
    }
    if ($Detailed) { [pscustomobject]@{ Status = $status; Targets = $caps } } else { $status }
}
#endregion

#region ---------- stress wrapper ----------
function Invoke-CpuStressTest {
    <# Prime95 torture test via tools\Invoke-Prime95.ps1 with presets targeting the suspect cores. #>
    [CmdletBinding()]
    param(
        [ValidateSet('AllCore', 'Favored2T', 'Favored1T', 'NormalP1T', 'ECores')][string]$Preset = 'AllCore',
        [double]$Minutes = 10,
        [ValidateSet('SmallFFT', 'SmallestFFT', 'LargeFFT', 'Blend')][string]$Mode = 'SmallFFT',
        [string]$Label = ''
    )
    # 0xFFFF0000L: without the L suffix PowerShell parses it as a negative Int32 (-65536)
    $map = @{ AllCore = @(0, 0L); Favored2T = @(2, 0x5L); Favored1T = @(1, 0x1L); NormalP1T = @(1, 0x10L); ECores = @(16, 0xFFFF0000L) }
    $st = Get-GovernorState
    if (-not $Label) { $Label = '{0}_P{1}_E{2}' -f $Preset, $(if ($st.ContainsKey('PCoreMHz')) { $st['PCoreMHz'] } else { 'stock' }), $(if ($st.ContainsKey('ECoreMHz')) { $st['ECoreMHz'] } else { 'stock' }) }
    Write-GovernorLog -Level TEST "Stress start: $Label ($Preset, $Mode, $Minutes min)"
    $r = & (Join-Path $script:Root 'tools\Invoke-Prime95.ps1') -Label $Label -Minutes $Minutes -Mode $Mode -Threads $map[$Preset][0] -AffinityMask ([UInt64]$map[$Preset][1])
    Write-GovernorLog -Level TEST ("Stress end: {0} -> {1} (p95 errors {2}, WHEA {3} [{4}], new dumps {5})" -f $Label, $r.Verdict, $r.Prime95Errors, $r.WheaEvents, $r.WheaIds, $r.NewDumps)
    $r
}
#endregion

#region ---------- profiles ----------
function Get-ProfileConfig {
    if (-not (Test-Path $script:ProfileFile)) { throw "profiles.json not found at $script:ProfileFile" }
    Get-Content $script:ProfileFile -Raw | ConvertFrom-Json -AsHashtable
}

function Get-CpuProfile {
    <# .SYNOPSIS List the governor profiles (from profiles.json) and mark the active one. #>
    [CmdletBinding()] param()
    $cfg = Get-ProfileConfig; $st = Get-GovernorState
    foreach ($n in $cfg['StepDownOrder'] + @($cfg['Profiles'].Keys | Where-Object { $_ -notin $cfg['StepDownOrder'] })) {
        $p = $cfg['Profiles'][$n]
        [pscustomobject]@{
            Active = $(if ($st.ContainsKey('Profile') -and $st['Profile'] -eq $n) { '*' } else { '' })
            Name = $n; PCoreMHz = $p['PCoreMHz']; ECoreMHz = $p['ECoreMHz']; PMaxStatePct = $p['PMaxStatePct']; EMaxStatePct = $p['EMaxStatePct']
            Description = $p['Description']
        }
    }
}

function Set-CpuProfile {
    <#
    .SYNOPSIS  Apply a named profile from profiles.json to every scheme/overlay (AC+DC), effective immediately.
    .EXAMPLE   Set-CpuProfile Productivity
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ArgumentCompleter({ param($c, $p, $w) (Get-Content (Join-Path (Split-Path (Get-Module CpuStabilityGovernor).Path) 'profiles.json') -Raw | ConvertFrom-Json -AsHashtable)['Profiles'].Keys | Where-Object { $_ -like "$w*" } })]
        [string]$Name,
        [string]$Source = 'manual'
    )
    $cfg = Get-ProfileConfig
    if (-not $cfg['Profiles'].ContainsKey($Name)) { throw "Unknown profile '$Name'. Known: $($cfg['Profiles'].Keys -join ', ')" }
    $p = $cfg['Profiles'][$Name]
    $r = Set-CpuFrequencyCap -PCoreMHz $p['PCoreMHz'] -ECoreMHz $p['ECoreMHz'] -PMaxStatePct $p['PMaxStatePct'] -EMaxStatePct $p['EMaxStatePct'] `
                             -Reason "profile $Name ($Source)" -ProfileName $Name -WhatIf:$WhatIfPreference
    if (-not $WhatIfPreference -and $Source -eq 'manual') { $st = Get-GovernorState; $st['AutoLowered'] = $false; Set-GovernorState $st }
    $r
}
#endregion

#region ---------- health monitor (runs every 5 min as SYSTEM) ----------
function Get-EcCpuTemperature {
    <# ASUS EC CPU temperature via read-only ACPI WMI DSTS; returns $null when not permitted (non-admin). #>
    try {
        $w = Get-CimInstance -Namespace root\wmi -ClassName AsusAtkWmi_WMNB -ErrorAction Stop | Select-Object -First 1
        $v = [uint32](Invoke-CimMethod -InputObject $w -MethodName DSTS -Arguments @{ Device_ID = [uint32]0x00120094 } -ErrorAction Stop).device_status
        if (($v -band 0xFFFF0000) -eq 0x00010000) { return [int]($v -band 0xFFFF) }
    } catch {}
    $null
}

function Invoke-CpuHealthCheck {
    <#
    .SYNOPSIS  One monitoring pass: detect new instability (processor WHEA errors, bugchecks, unexpected reboots, new dumps),
               step the cap down one level if found, re-assert caps if something changed them, and log a telemetry sample.
    #>
    [CmdletBinding()] param([switch]$NoStepDown)
    $cfg = Get-ProfileConfig; $st = Get-GovernorState
    $now = Get-Date
    $since = if ($st.ContainsKey('LastHealthCheck')) { [datetime]$st['LastHealthCheck'] } else { $now.AddMinutes(-5) }
    if (-not $st.ContainsKey('InstalledAt')) { $st['InstalledAt'] = $now.ToString('o') }

    # 1. instability evidence since the previous pass
    $whea = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; Id = $script:WheaIds; StartTime = $since } -ErrorAction SilentlyContinue |
              Where-Object { $_.Id -in 1, 18, 47 -or $_.Message -match 'Processor' })
    $bugchecks = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001; StartTime = $since } -ErrorAction SilentlyContinue)
    $unexpected = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; StartTime = $since } -ErrorAction SilentlyContinue)
    $dumps = @(Get-ChildItem C:\Windows\Minidump -Filter *.dmp -ErrorAction SilentlyContinue | Where-Object LastWriteTime -gt $since)
    $events = $whea.Count + $bugchecks.Count + $unexpected.Count + $dumps.Count

    if ($events -gt 0) {
        $detail = "WHEA(cpu)={0} bugcheck={1} unexpected-reboot={2} new-dumps={3}" -f $whea.Count, $bugchecks.Count, $unexpected.Count, $dumps.Count
        Write-GovernorLog -Level WARN "Instability detected since $($since.ToString('s')): $detail"
        $order = @($cfg['StepDownOrder']); $cur = if ($st.ContainsKey('Profile')) { [string]$st['Profile'] } else { '' }
        $i = [array]::IndexOf($order, $cur)
        $next = if ($i -lt 0) { $cfg['Default'] } elseif ($i -lt $order.Count - 1) { $order[$i + 1] } else { $null }
        if ($NoStepDown) { Write-GovernorLog -Level WARN 'Step-down suppressed (-NoStepDown)' }
        elseif ($next) {
            Set-CpuProfile -Name $next -Source "auto-stepdown: $detail" | Out-Null
            $st = Get-GovernorState; $st['AutoLowered'] = $true
            $hist = @(if ($st.ContainsKey('StepDowns')) { $st['StepDowns'] }) + @(@{ At = $now.ToString('o'); From = $cur; To = $next; Why = $detail })
            $st['StepDowns'] = $hist
            Write-GovernorLog -Level ACTION "Auto step-down $cur -> $next"
            if ($cfg['NotifyUser']) { & msg.exe * /time:60 "CPU Stability Governor: instability detected ($detail). Cap lowered: $cur -> $next." 2>$null }
            try {
                if (-not [Diagnostics.EventLog]::SourceExists('CpuStabilityGovernor')) { New-EventLog -LogName Application -Source CpuStabilityGovernor }
                Write-EventLog -LogName Application -Source CpuStabilityGovernor -EventId 1001 -EntryType Warning -Message "Instability detected ($detail). Profile lowered $cur -> $next."
            } catch {}
        } else { Write-GovernorLog -Level WARN "Already at the lowest profile ($cur); cannot step down further. Hardware service is needed." }
    }

    # 2. drift: re-assert the current profile if any target no longer matches (e.g. Armoury Crate rewrote a scheme)
    if ($st.ContainsKey('PCoreMHz')) {
        $want = @{ PROCFREQMAX1 = [long]$st['PCoreMHz']; PROCFREQMAX = [long]$st['ECoreMHz']; PROCTHROTTLEMAX1 = [long]$st['PMaxStatePct']; PROCTHROTTLEMAX = [long]$st['EMaxStatePct'] }
        $drift = foreach ($t in Get-WritableCpuPowerTarget) {
            foreach ($k in $want.Keys) { $v = Read-CpuPowerValue $t.Guid $k; if ($v.AC -ne $want[$k] -or $v.DC -ne $want[$k]) { "$($t.Name):$k=$($v.AC)/$($v.DC)" } }
        }
        if ($drift) {
            Write-GovernorLog -Level WARN "Drift detected ($(@($drift).Count) value(s): $((@($drift) | Select-Object -First 4) -join '; ')) - re-applying"
            Set-CpuFrequencyCap -PCoreMHz $want.PROCFREQMAX1 -ECoreMHz $want.PROCFREQMAX -PMaxStatePct $want.PROCTHROTTLEMAX1 -EMaxStatePct $want.PROCTHROTTLEMAX `
                                -Reason 'drift correction' -ProfileName ([string]$st['Profile']) | Out-Null
            $st = Get-GovernorState
        }
    }

    # 3. telemetry sample for the verification report
    $s = Get-CpuLiveSample -Seconds 3
    $row = [pscustomobject]@{
        Time = $now.ToString('yyyy-MM-dd HH:mm:ss'); Profile = $(if ($st.ContainsKey('Profile')) { $st['Profile'] } else { '' })
        PCap = $(if ($st.ContainsKey('PCoreMHz')) { $st['PCoreMHz'] } else { '' }); ECap = $(if ($st.ContainsKey('ECoreMHz')) { $st['ECoreMHz'] } else { '' })
        PAvgMHz = $s.PAvgMHz; PMaxMHz = $s.PMaxMHz; EAvgMHz = $s.EAvgMHz; EMaxMHz = $s.EMaxMHz; PUtil = $s.PUtilPct; EUtil = $s.EUtilPct
        PackageW = $s.PackageW; CpuTempC = Get-EcCpuTemperature; NewInstabilityEvents = $events
    }
    $dir = Join-Path $script:Root 'data\health'; New-Item -ItemType Directory -Force $dir | Out-Null
    $file = Join-Path $dir ('health_{0:yyyyMMdd}.csv' -f $now)
    $row | Export-Csv $file -Append -NoTypeInformation

    $st['LastHealthCheck'] = $now.ToString('o'); Set-GovernorState $st
    $row
}

function Invoke-CpuGovernorBootApply {
    <# Called by the boot/logon task: re-apply the saved profile (including any automatic step-down). #>
    $st = Get-GovernorState; $cfg = Get-ProfileConfig
    $name = if ($st.ContainsKey('Profile') -and $cfg['Profiles'].ContainsKey([string]$st['Profile'])) { [string]$st['Profile'] } else { $cfg['Default'] }
    Write-GovernorLog -Level ACTION "Boot/logon apply: profile $name"
    Set-CpuProfile -Name $name -Source 'boot task' | Out-Null
    if ($st.ContainsKey('AutoLowered') -and $st['AutoLowered']) { $st = Get-GovernorState; $st['AutoLowered'] = $true; Set-GovernorState $st }
}
#endregion

#region ---------- scheduled tasks ----------
function Install-CpuGovernorTask {
    <#
    .SYNOPSIS  Register the boot/logon apply task and the 5-minute health monitor (both run as SYSTEM). Requires elevation.
               Also exports the task XML to .\tasks and locks code files against non-admin modification (they run as SYSTEM).
    #>
    [CmdletBinding()] param([switch]$Disabled, [int]$MonitorMinutes = 5)
    if (-not (Test-IsElevated)) { throw 'Install-CpuGovernorTask must run elevated' }
    $pwsh = Join-Path $PSHOME 'pwsh.exe'
    $mod = Join-Path $script:Root 'CpuStabilityGovernor.psd1'
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 3)

    $bootAction = New-ScheduledTaskAction -Execute $pwsh -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -Command `"Import-Module '$mod'; Invoke-CpuGovernorBootApply`""
    $t1 = New-ScheduledTaskTrigger -AtStartup; $t1.Delay = 'PT30S'
    $t2 = New-ScheduledTaskTrigger -AtLogOn
    Register-ScheduledTask -TaskName 'CpuStabilityGovernor-ApplyAtBoot' -TaskPath '\' -Action $bootAction -Trigger $t1, $t2 -Principal $principal -Settings $set `
        -Description 'Re-applies the CPU frequency caps of the saved governor profile at boot and logon.' -Force | Out-Null

    $monAction = New-ScheduledTaskAction -Execute $pwsh -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -Command `"Import-Module '$mod'; Invoke-CpuHealthCheck | Out-Null`""
    $m1 = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $MonitorMinutes)
    $m2 = New-ScheduledTaskTrigger -AtStartup; $m2.Delay = 'PT2M'
    Register-ScheduledTask -TaskName 'CpuStabilityGovernor-HealthMonitor' -TaskPath '\' -Action $monAction -Trigger $m1, $m2 -Principal $principal -Settings $set `
        -Description "Every $MonitorMinutes min: checks for new CPU WHEA errors/crashes, steps the frequency cap down on instability, fixes drift, logs telemetry." -Force | Out-Null

    $xmlDir = Join-Path $script:Root 'tasks'; New-Item -ItemType Directory -Force $xmlDir | Out-Null
    foreach ($n in 'CpuStabilityGovernor-ApplyAtBoot', 'CpuStabilityGovernor-HealthMonitor') {
        Export-ScheduledTask -TaskName $n | Set-Content (Join-Path $xmlDir "$n.xml") -Encoding Unicode
        if ($Disabled) { Disable-ScheduledTask -TaskName $n | Out-Null }
    }
    Protect-CpuGovernorFiles
    $st = Get-GovernorState; if (-not $st.ContainsKey('InstalledAt')) { $st['InstalledAt'] = (Get-Date).ToString('o') }; $st['LastHealthCheck'] = (Get-Date).ToString('o'); Set-GovernorState $st
    Write-GovernorLog -Level ACTION ("Scheduled tasks installed ({0}); XML exported to {1}" -f $(if ($Disabled) { 'disabled' } else { 'enabled' }), $xmlDir)
    Get-ScheduledTask -TaskName 'CpuStabilityGovernor-*' | Select-Object TaskName, State
}

function Protect-CpuGovernorFiles {
    <# Code that runs as SYSTEM must not be writable by non-admins (else it is a privilege-escalation path).
       Root folder gets inheritable Administrators/SYSTEM full + Users read-execute; every child re-inherits (icacls /reset);
       data/log/state/document locations additionally grant Users modify. Owner = Administrators (owner rights could rewrite the DACL).
       Inheritance flags (OI)(CI) are only ever applied to folders: on files they fail and would leave an empty DACL. #>
    if (-not (Test-IsElevated)) { throw 'requires elevation' }
    $root = $script:Root
    & icacls $root /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' /C /Q | Out-Null
    & icacls "$root\*" /reset /T /C /Q | Out-Null
    foreach ($w in 'data', 'logs', 'backup', 'charts') {
        $p = Join-Path $root $w; New-Item -ItemType Directory -Force $p | Out-Null
        & icacls $p /grant '*S-1-5-32-545:(OI)(CI)M' /C /Q | Out-Null
        & icacls "$p\*" /reset /T /C /Q | Out-Null
    }
    foreach ($f in 'governor.log', 'state.json', 'calibration_report.md', 'README.md', 'investigation_log.md') {
        $p = Join-Path $root $f; if (-not (Test-Path $p)) { New-Item -ItemType File $p | Out-Null }; & icacls $p /grant '*S-1-5-32-545:M' /C /Q | Out-Null }
    & icacls $root /setowner '*S-1-5-32-544' /T /C /Q | Out-Null
    $probe = (& icacls (Join-Path $root 'CpuStabilityGovernor.psm1')) -join ' '
    if ($probe -notmatch 'BUILTIN\\Users:\(I\)\(RX\)' -or $probe -notmatch 'NT AUTHORITY\\SYSTEM:\(I\)\(F\)') { throw "ACL verification failed: $probe" }
    Write-GovernorLog -Level ACTION 'Hardened ACLs (verified): code + profiles.json read-only for Users, owner Administrators; data, logs, backup, charts, state/log and documents user-writable'
}
function Uninstall-CpuGovernorTask {
    [CmdletBinding()] param()
    if (-not (Test-IsElevated)) { throw 'Uninstall-CpuGovernorTask must run elevated' }
    foreach ($n in 'CpuStabilityGovernor-ApplyAtBoot', 'CpuStabilityGovernor-HealthMonitor') { Unregister-ScheduledTask -TaskName $n -Confirm:$false -ErrorAction SilentlyContinue }
    Write-GovernorLog -Level ACTION 'Scheduled tasks removed'
}
#endregion

#region ---------- verification report ----------
function Get-CpuGovernorReport {
    <# .SYNOPSIS Summary for a period (default: since the governor was installed): crashes, WHEA, frequencies, power, step-downs. #>
    [CmdletBinding()] param([double]$Hours = 0)
    $st = Get-GovernorState
    $since = if ($Hours -gt 0) { (Get-Date).AddHours(-$Hours) } elseif ($st.ContainsKey('InstalledAt')) { [datetime]$st['InstalledAt'] } else { (Get-Date).AddHours(-24) }
    $whea = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; StartTime = $since } -ErrorAction SilentlyContinue)
    $bug = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001; StartTime = $since } -ErrorAction SilentlyContinue)
    $kp41 = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; StartTime = $since } -ErrorAction SilentlyContinue)
    $rows = @(Get-ChildItem (Join-Path $script:Root 'data\health') -Filter 'health_*.csv' -ErrorAction SilentlyContinue | ForEach-Object { Import-Csv $_.FullName } | Where-Object { [datetime]$_.Time -ge $since })
    $busy = @($rows | Where-Object { [double]$_.PUtil -ge 10 })
    $avg = { param($set, $col) if ($set) { [math]::Round((@($set | ForEach-Object { [double]$_.$col }) | Measure-Object -Average).Average, 0) } else { $null } }
    [pscustomobject]@{
        Since = $since; HoursCovered = [math]::Round(((Get-Date) - $since).TotalHours, 1); HealthSamples = $rows.Count
        Bugchecks = $bug.Count; UnexpectedReboots = $kp41.Count
        WheaTotal = $whea.Count; WheaByType = (($whea | Group-Object Id | ForEach-Object { "id$($_.Name) x$($_.Count)" }) -join ', ')
        StepDowns = $(if ($st.ContainsKey('StepDowns')) { @($st['StepDowns']).Count } else { 0 }); CurrentProfile = $(if ($st.ContainsKey('Profile')) { $st['Profile'] } else { '' })
        PAvgMHz_all = & $avg $rows 'PAvgMHz'; PAvgMHz_busy = & $avg $busy 'PAvgMHz'; PMaxMHz_busy = & $avg $busy 'PMaxMHz'
        EAvgMHz_all = & $avg $rows 'EAvgMHz'; PackageW_avg = & $avg $rows 'PackageW'
        CpuTempC_avg = & $avg @($rows | Where-Object CpuTempC) 'CpuTempC'
        CpuTempC_max = $(if ($rows | Where-Object CpuTempC) { (@($rows | Where-Object CpuTempC | ForEach-Object { [double]$_.CpuTempC }) | Measure-Object -Maximum).Maximum } else { $null })
    }
}
#endregion

Export-ModuleMember -Function Write-GovernorLog, Get-CpuPowerTarget, Save-CpuGovernorBaseline, Set-CpuFrequencyCap, Reset-CpuGovernor,
    Get-CpuLiveSample, Test-CpuCapApplied, Get-CpuStatus, Invoke-CpuStressTest, Get-GovernorState,
    Get-CpuProfile, Set-CpuProfile, Invoke-CpuHealthCheck, Invoke-CpuGovernorBootApply,
    Install-CpuGovernorTask, Uninstall-CpuGovernorTask, Protect-CpuGovernorFiles, Get-CpuGovernorReport
