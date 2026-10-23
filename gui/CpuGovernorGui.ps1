#Requires -Version 7.0
<#
.SYNOPSIS
    Dashboard for the CpuStabilityGovernor module: status, recent activity, profile switching, health check, CPU0 fault test.
.DESCRIPTION
    A separate consumer of the governor's public commands. It reads state and status, and changes nothing except the
    profile (Set-CpuProfile) and Reset to Defaults (Reset-CpuGovernor -ToDefaults), both behind explicit user actions.
    It never writes into C:\Tools\CpuStabilityGovernor itself; its own log and data live next to this script.
    Relaunches itself elevated via UAC; if elevation is declined it runs read-only (monitoring only).
.PARAMETER NoElevate
    Do not request UAC. Without admin rights the GUI is read-only.
.PARAMETER SelfTest
    Build the window, refresh everything once, save a screenshot and the displayed values, then close. Clicks nothing.
#>
[CmdletBinding()]
param(
    [switch]$NoElevate,
    [switch]$SelfTest,
    [switch]$Mock,              # self-test only: blank live event/date fields so a screenshot carries no personal data
    [string]$SelfTestOut = ''
)
Set-StrictMode -Version 3.0

# ------------------------------------------------------------------ paths & constants
$script:GovRoot      = if ($env:CPUGOV_APPROOT) { $env:CPUGOV_APPROOT } else { (Join-Path (Split-Path $PSScriptRoot -Parent) 'app') }
$script:GovModule    = Join-Path $script:GovRoot 'CpuStabilityGovernor.psd1'
$script:GovLog       = Join-Path $script:GovRoot 'governor.log'
$script:GovProfiles  = Join-Path $script:GovRoot 'profiles.json'
$script:ReportPath   = Join-Path (Split-Path $script:GovRoot -Parent) 'calibration_result.md'  # written by Calibrate.ps1
$script:FaultTool    = Join-Path $script:GovRoot 'tools\Invoke-UnwindTorture.ps1'
$script:MonitorTask  = 'CpuStabilityGovernor-HealthMonitor'
$script:ProfileOrder = @('LowLoad', 'Productivity', 'Sustained', 'TurboOff')
$script:GuiLog       = Join-Path $PSScriptRoot 'gui.log'
$script:Pwsh         = (Get-Process -Id $PID).Path
$script:IsAdmin      = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
# data\ is user-writable. data-admin\ is admin-only once Create-Shortcut.ps1 has hardened the folder: an elevated GUI keeps
# the files that its elevated child processes execute or trust there, so a non-admin process cannot swap them.
$script:WorkDir      = Join-Path $PSScriptRoot $(if ($script:IsAdmin) { 'data-admin' } else { 'data' })
$script:StatusFile   = Join-Path $script:WorkDir 'status_check.json'
$script:TestRunRoot  = Join-Path $script:WorkDir 'cpu0-tests'

function Write-GuiLog {
    param([string]$Message, [ValidateSet('INFO', 'ACTION', 'WARN', 'ERROR')][string]$Level = 'INFO')
    $line = '{0:yyyy-MM-dd HH:mm:ss.fff} [{1,-6}] [pid={2} admin={3}] {4}' -f (Get-Date), $Level, $PID, $script:IsAdmin, $Message
    for ($i = 0; $i -lt 5; $i++) {
        try { [IO.File]::AppendAllText($script:GuiLog, $line + [Environment]::NewLine); return } catch { Start-Sleep -Milliseconds 80 }
    }
}

# ------------------------------------------------------------------ elevation (self-relaunch)
$script:ElevationNote = ''
if (-not $script:IsAdmin -and -not $NoElevate) {
    $fwd = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', ('"{0}"' -f $PSCommandPath))
    if ($SelfTest) { $fwd += '-SelfTest' }
    if ($SelfTestOut) { $fwd += @('-SelfTestOut', ('"{0}"' -f $SelfTestOut)) }
    try {
        Start-Process -FilePath $script:Pwsh -Verb RunAs -WindowStyle Hidden -ArgumentList $fwd -ErrorAction Stop | Out-Null
        Write-GuiLog 'Started without admin rights; relaunched elevated via UAC'
        exit 0
    } catch {
        $script:ElevationNote = 'the UAC prompt was declined'
        Write-GuiLog "UAC elevation declined or failed ($($_.Exception.Message)); running read-only" 'WARN'
    }
}
if ($script:IsAdmin) {
    # an elevated process should not auto-load modules from the user-writable profile folders
    $userRoots = @($env:USERPROFILE, $env:OneDrive) | Where-Object { $_ }
    $env:PSModulePath = (($env:PSModulePath -split ';') | Where-Object { $p = $_; $p -and -not ($userRoots | Where-Object { $p -like "$_*" }) }) -join ';'
}
New-Item -ItemType Directory -Force $script:WorkDir | Out-Null
Write-GuiLog ('GUI starting (elevated={0}, selftest={1}, apartment={2}, pwsh {3})' -f $script:IsAdmin, [bool]$SelfTest, [Threading.Thread]::CurrentThread.GetApartmentState(), $PSVersionTable.PSVersion)

# ------------------------------------------------------------------ WinForms setup
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
try { [void][System.Windows.Forms.Application]::SetHighDpiMode([System.Windows.Forms.HighDpiMode]::PerMonitorV2) } catch {}
[System.Windows.Forms.Application]::EnableVisualStyles()
if (-not ('GuiNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class GuiNative {
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)] static extern int SetWindowTheme(IntPtr hwnd, string app, string idList);
    public static void DarkTitleBar(IntPtr hwnd) { int on = 1; DwmSetWindowAttribute(hwnd, 20, ref on, 4); }
    public static void DarkScrollBars(IntPtr hwnd) { SetWindowTheme(hwnd, "DarkMode_Explorer", null); }
}
'@
}

function New-Rgb([int]$R, [int]$G, [int]$B) { [System.Drawing.Color]::FromArgb($R, $G, $B) }
$script:Col = @{
    Bg = New-Rgb 30 30 30; Panel = New-Rgb 37 37 38; Edge = New-Rgb 63 63 70; Text = New-Rgb 230 230 230; Muted = New-Rgb 155 155 155
    Btn = New-Rgb 51 51 55; BtnHover = New-Rgb 62 62 66; BtnDown = New-Rgb 45 45 48; Blue = New-Rgb 14 99 156; BlueEdge = New-Rgb 28 151 234
    Green = New-Rgb 78 201 120; Red = New-Rgb 241 76 76; Amber = New-Rgb 224 179 65; BannerBg = New-Rgb 110 28 28; NoteBg = New-Rgb 82 66 20; GreenBg = New-Rgb 22 80 44
    LogBg = New-Rgb 22 22 22; DangerEdge = New-Rgb 150 50 50; WarnEdge = New-Rgb 150 115 35; Disabled = New-Rgb 120 120 120
}
$script:Fnt = @{
    Base    = New-Object System.Drawing.Font('Segoe UI', 9)
    Bold    = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    Value   = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
    Profile = New-Object System.Drawing.Font('Segoe UI', 16, [System.Drawing.FontStyle]::Bold)
    Warn    = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    Mono    = New-Object System.Drawing.Font('Consolas', 9)
}
$script:EdgePen = New-Object System.Drawing.Pen($script:Col.Edge)
$script:Tips = New-Object System.Windows.Forms.ToolTip
$script:Tips.AutoPopDelay = 20000
$script:Ui = @{}

function New-Pad([int]$L, [int]$T, [int]$R, [int]$B) { New-Object System.Windows.Forms.Padding($L, $T, $R, $B) }
function New-ColStyle([string]$Type, [float]$Value = 0) { New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::$Type, $Value) }
function New-RowStyle([string]$Type, [float]$Value = 0) { New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::$Type, $Value) }

function New-Lbl([string]$Text = '', $Font = $script:Fnt.Base, $Color = $script:Col.Text) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text; $l.Font = $Font; $l.ForeColor = $Color; $l.AutoSize = $true
    $l.BackColor = [System.Drawing.Color]::Transparent; $l.Margin = New-Pad 0 2 0 2
    $l
}

function New-Btn([string]$Text, [scriptblock]$OnClick, [int]$Height = 32) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text; $b.Font = $script:Fnt.Base; $b.ForeColor = $script:Col.Text; $b.BackColor = $script:Col.Btn
    $b.FlatStyle = 'Flat'; $b.UseVisualStyleBackColor = $false
    $b.FlatAppearance.BorderColor = $script:Col.Edge; $b.FlatAppearance.BorderSize = 1
    $b.FlatAppearance.MouseOverBackColor = $script:Col.BtnHover; $b.FlatAppearance.MouseDownBackColor = $script:Col.BtnDown
    $b.Height = $Height; $b.AutoSize = $true; $b.AutoSizeMode = 'GrowOnly'
    $b.Padding = New-Pad 10 1 10 1; $b.Margin = New-Pad 0 0 8 6; $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    if ($OnClick) { $b.Add_Click($OnClick) }
    $b
}

function New-Grid([int]$Cols, [int]$Rows) {
    $t = New-Object System.Windows.Forms.TableLayoutPanel
    $t.ColumnCount = $Cols; $t.RowCount = $Rows; $t.BackColor = [System.Drawing.Color]::Transparent
    $t.Margin = New-Pad 0 0 0 0; $t.Padding = New-Pad 0 0 0 0
    $t
}

function New-Section([string]$Title, $Body, [switch]$Fill) {
    # Bordered dark card: header label + body. -Fill: the card stretches with the window; otherwise it sizes to its content.
    $card = New-Grid 1 2
    $card.BackColor = $script:Col.Panel; $card.Padding = New-Pad 12 8 12 8; $card.Margin = New-Pad 0 0 0 10
    [void]$card.ColumnStyles.Add((New-ColStyle Percent 100))
    [void]$card.RowStyles.Add((New-RowStyle AutoSize))
    [void]$card.RowStyles.Add($(if ($Fill) { New-RowStyle Percent 100 } else { New-RowStyle AutoSize }))
    $hdr = New-Lbl $Title $script:Fnt.Bold $script:Col.Muted; $hdr.Margin = New-Pad 0 0 0 6
    $card.Controls.Add($hdr, 0, 0)
    $Body.Dock = 'Fill'
    $card.Controls.Add($Body, 0, 1)
    $card.Dock = 'Fill'
    if (-not $Fill) { $card.AutoSize = $true; $card.AutoSizeMode = 'GrowAndShrink' }
    $card.Add_Paint({ param($s, $e) $e.Graphics.DrawRectangle($script:EdgePen, 0, 0, $s.Width - 1, $s.Height - 1) })
    $card
}

function Format-GHz([object]$Mhz) {
    if ($null -eq $Mhz -or "$Mhz" -eq '') { return 'n/a' }
    $v = [double]$Mhz; if ($v -le 0) { return 'no cap' }
    '{0:0.00} GHz' -f ($v / 1000)
}

function Format-Age([datetime]$When) {
    $s = ((Get-Date) - $When).TotalSeconds
    if ($s -lt 90) { return "$([int][Math]::Max(0, $s)) s ago" }
    if ($s -lt 5400) { return "$([int]($s / 60)) min ago" }
    if ($s -lt 172800) { return ('{0:0.#} h ago' -f ($s / 3600)) }
    '{0:0} days ago' -f ($s / 86400)
}

# ------------------------------------------------------------------ module import & static info
$script:ModuleError = $null
$script:Commands = @()
$script:Profiles = @()
try {
    Import-Module $script:GovModule -Force -ErrorAction Stop
    $script:Commands = @((Get-Command -Module CpuStabilityGovernor).Name)
    $script:Profiles = @(Get-CpuProfile)
    # show a button for every switchable profile that exists, preferring this chip's own Calibrated profile first
    # (Stock is reference-only, never a button). Falls back to the author profiles if the list can't be built.
    $pref = @('Calibrated', 'LowLoad', 'Productivity', 'Sustained', 'TurboOff')
    $present = @($script:Profiles.Name)
    $ordered = @($pref | Where-Object { $present -contains $_ }) + @($present | Where-Object { $_ -notin $pref -and $_ -ne 'Stock' })
    if ($ordered.Count) { $script:ProfileOrder = $ordered }
    Write-GuiLog "Module imported: $($script:Commands.Count) commands"
} catch {
    $script:ModuleError = "Could not import the governor module: $($_.Exception.Message)"
    Write-GuiLog $script:ModuleError 'ERROR'
}

# requested MHz -> measured single-thread peak, from the calibration note in profiles.json (read-only; display only)
# and whether these caps were calibrated for THIS machine (false = bundled author's-chip example, see _WARNING in profiles.json)
$script:Measured = @{}
$script:Calibrated = $true
$script:CalVerdict = ''        # '', 'HEALTHY', 'STABLE_AT_LEVEL' or 'UNRECOVERABLE' (written by Calibrate.ps1)
try {
    $pj = Get-Content -LiteralPath $script:GovProfiles -Raw | ConvertFrom-Json
    $note = [string]$pj.Note
    foreach ($m in [regex]::Matches($note, '(\d{4})\s*->\s*(\d{4})')) { $script:Measured[[int]$m.Groups[1].Value] = [int]$m.Groups[2].Value }
    $names = $pj.PSObject.Properties.Name
    if ($names -contains 'CalibratedForThisMachine') { $script:Calibrated = [bool]$pj.CalibratedForThisMachine }
    if ($names -contains 'CalibrationVerdict') { $script:CalVerdict = [string]$pj.CalibrationVerdict }
} catch {}

$script:Machine = try {
    $cs = Get-CimInstance Win32_ComputerSystem; $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1; $bios = Get-CimInstance Win32_BIOS
    $nt = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $ucode = try { $ur = [byte[]][Microsoft.Win32.Registry]::GetValue('HKEY_LOCAL_MACHINE\HARDWARE\DESCRIPTION\System\CentralProcessor\0', 'Update Revision', $null); '0x{0:X}' -f [BitConverter]::ToUInt32($ur, [Math]::Max(0, $ur.Length - 4)) } catch { 'n/a' }
    '{0} {1} | {2} | microcode {3} | BIOS {4} | Windows {5} ({6}.{7})' -f $cs.Manufacturer, $cs.Model, $cpu.Name.Trim(), $ucode, $bios.SMBIOSBIOSVersion, $nt.DisplayVersion, $nt.CurrentBuild, $nt.UBR
} catch { 'machine info unavailable' }

# ------------------------------------------------------------------ form & layout
$form = New-Object System.Windows.Forms.Form
$form.SuspendLayout()
$form.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)
$form.AutoScaleMode = 'Dpi'
$form.Text = 'CPU Stability Governor' + $(if ($script:IsAdmin) { '' } else { '  (read-only)' })
$form.Size = New-Object System.Drawing.Size(940, 740)            # clamped to the monitor's working area on Shown
$form.MinimumSize = New-Object System.Drawing.Size(820, 600)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $script:Col.Bg; $form.ForeColor = $script:Col.Text; $form.Font = $script:Fnt.Base
$form.KeyPreview = $true
try { $form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($script:Pwsh) } catch {}
$form.Add_HandleCreated({ try { [GuiNative]::DarkTitleBar($form.Handle) } catch {} })

$root = New-Grid 1 6
$root.Dock = 'Fill'; $root.Padding = New-Pad 12 10 12 6; $root.BackColor = $script:Col.Bg
[void]$root.ColumnStyles.Add((New-ColStyle Percent 100))
foreach ($i in 0..5) { [void]$root.RowStyles.Add($(if ($i -eq 3) { New-RowStyle Percent 100 } else { New-RowStyle AutoSize })) }
$form.Controls.Add($root)

# labels whose text can be long wrap at their cell width (see Update-WrapWidths)
$script:Ui.WrapLabels = @()

# rows 0-1: error banner (red) and read-only notice (amber); hidden when empty
function New-BannerLabel($Back) {
    $l = New-Lbl '' $script:Fnt.Bold ([System.Drawing.Color]::White)
    $l.Dock = 'Fill'; $l.BackColor = $Back; $l.TextAlign = 'MiddleLeft'
    $l.Padding = New-Pad 10 4 10 4; $l.Margin = New-Pad 0 0 0 8; $l.Visible = $false
    $script:Ui.WrapLabels += $l
    $l
}
$script:Ui.Banner = New-BannerLabel $script:Col.BannerBg
$script:Ui.Banner.Cursor = [System.Windows.Forms.Cursors]::Hand
$script:Ui.Banner.Add_Click({ if ($script:Ui.Banner.Tag) { [void][System.Windows.Forms.MessageBox]::Show([string]$script:Ui.Banner.Tag, 'CPU Governor - errors', 'OK', 'Error') } })
$root.Controls.Add($script:Ui.Banner, 0, 0)
$script:Ui.Note = New-BannerLabel $script:Col.NoteBg
# calibration-state banner: amber (not calibrated), green (healthy / calibrated), red (unrecoverable)
$notices = @(); $noteBg = $script:Col.NoteBg
switch ($script:CalVerdict) {
    'HEALTHY'         { $notices += 'CPU appears healthy - no cap installed. Use the profile buttons to apply one manually if needed.'; $noteBg = $script:Col.GreenBg }
    'STABLE_AT_LEVEL' { $notices += 'Calibrated - safe frequency identified. Your Calibrated profile is applied.'; $noteBg = $script:Col.GreenBg }
    'UNRECOVERABLE'   { $notices += 'Calibration failed - this CPU is too degraded to stabilise. Contact your laptop manufacturer or Intel for service.'; $noteBg = $script:Col.BannerBg }
    default           { if (-not $script:Calibrated) { $notices += 'NOT CALIBRATED - run Calibrate.ps1 to find your safe frequency.' } }
}
if (-not $script:IsAdmin) {
    $notices += 'Read-only mode' + $(if ($script:ElevationNote) { " ($($script:ElevationNote))" } else { '' }) +
        ': profile switching, reset and the health check need administrator rights. Restart the GUI and accept the UAC prompt.'
}
if ($notices.Count) { $script:Ui.Note.BackColor = $noteBg; $script:Ui.Note.Text = ($notices -join '   |   '); $script:Ui.Note.Visible = $true }
$root.Controls.Add($script:Ui.Note, 0, 1)

# row 2: status panel
$sg = New-Grid 5 3
foreach ($w in 25, 16, 16, 27, 16) { [void]$sg.ColumnStyles.Add((New-ColStyle Percent $w)) }
foreach ($i in 0..2) { [void]$sg.RowStyles.Add((New-RowStyle AutoSize)) }
$sg.AutoSize = $true; $sg.AutoSizeMode = 'GrowAndShrink'
$cells = @(@('PROFILE', 'Profile'), @('P-CORE CAP', 'PCap'), @('E-CORE CAP', 'ECap'), @('AC / DC OVERLAYS', 'Ovl'), @('UPTIME', 'Up'))
for ($c = 0; $c -lt $cells.Count; $c++) {
    $cap = New-Lbl $cells[$c][0] $script:Fnt.Bold $script:Col.Muted
    $val = New-Lbl '...' $(if ($c -eq 0) { $script:Fnt.Profile } else { $script:Fnt.Value })
    $sub = New-Lbl '' $script:Fnt.Base $script:Col.Muted
    $cap.Margin = New-Pad 0 0 10 0; $val.Margin = New-Pad 0 2 10 0; $sub.Margin = New-Pad 0 0 10 0
    $sg.Controls.Add($cap, $c, 0); $sg.Controls.Add($val, $c, 1); $sg.Controls.Add($sub, $c, 2)
    $script:Ui["$($cells[$c][1])Val"] = $val; $script:Ui["$($cells[$c][1])Sub"] = $sub
    $script:Ui.WrapLabels += $val, $sub
}
$root.Controls.Add((New-Section 'STATUS   (refreshes every 30 s, F5 = now)' $sg), 0, 2)

# row 3: recent activity (left) + profile switcher (right)
$mid = New-Grid 2 1
$mid.Dock = 'Fill'
[void]$mid.ColumnStyles.Add((New-ColStyle Percent 62))
[void]$mid.ColumnStyles.Add((New-ColStyle Percent 38))
[void]$mid.RowStyles.Add((New-RowStyle Percent 100))

$act = New-Grid 1 3
[void]$act.ColumnStyles.Add((New-ColStyle Percent 100))
[void]$act.RowStyles.Add((New-RowStyle AutoSize))
[void]$act.RowStyles.Add((New-RowStyle Percent 100))
[void]$act.RowStyles.Add((New-RowStyle AutoSize))
$logHdr = New-Lbl 'governor.log - last 10 lines' $script:Fnt.Base $script:Col.Muted; $logHdr.Margin = New-Pad 0 0 0 2
$act.Controls.Add($logHdr, 0, 0)
$script:Ui.Log = New-Object System.Windows.Forms.TextBox
$script:Ui.Log.Multiline = $true; $script:Ui.Log.ReadOnly = $true; $script:Ui.Log.WordWrap = $false; $script:Ui.Log.ScrollBars = 'Both'
$script:Ui.Log.Font = $script:Fnt.Mono; $script:Ui.Log.BackColor = $script:Col.LogBg; $script:Ui.Log.ForeColor = $script:Col.Text
$script:Ui.Log.BorderStyle = 'FixedSingle'; $script:Ui.Log.Dock = 'Fill'; $script:Ui.Log.Margin = New-Pad 0 0 0 8; $script:Ui.Log.TabStop = $false
$script:Ui.Log.Add_HandleCreated({ param($s, $e) try { [GuiNative]::DarkScrollBars($s.Handle) } catch {} })
$act.Controls.Add($script:Ui.Log, 0, 1)
$stats = New-Grid 2 4
[void]$stats.ColumnStyles.Add((New-ColStyle AutoSize))
[void]$stats.ColumnStyles.Add((New-ColStyle Percent 100))
$stats.AutoSize = $true; $stats.AutoSizeMode = 'GrowAndShrink'; $stats.Dock = 'Fill'
$rowsDef = @(@('WHEA errors (24 h)', 'Whea'), @('BSODs (24 h)', 'Bsod'), @('Last health monitor run', 'Mon'), @('Since governor install', 'Since'))
for ($r = 0; $r -lt $rowsDef.Count; $r++) {
    [void]$stats.RowStyles.Add((New-RowStyle AutoSize))
    $k = New-Lbl $rowsDef[$r][0] $script:Fnt.Base $script:Col.Muted; $k.Margin = New-Pad 0 2 12 2
    $v = New-Lbl '...' $script:Fnt.Bold; $v.Margin = New-Pad 0 2 0 2
    $stats.Controls.Add($k, 0, $r); $stats.Controls.Add($v, 1, $r); $script:Ui["$($rowsDef[$r][1])Val"] = $v; $script:Ui["$($rowsDef[$r][1])Key"] = $k
    $script:Ui.WrapLabels += $v
}
$act.Controls.Add($stats, 0, 2)
$mid.Controls.Add((New-Section 'RECENT ACTIVITY' $act -Fill), 0, 0)

$prof = New-Grid 1 7
[void]$prof.ColumnStyles.Add((New-ColStyle Percent 100))
$script:Ui.ProfileButtons = [ordered]@{}
for ($i = 0; $i -lt $script:ProfileOrder.Count; $i++) {
    $name = $script:ProfileOrder[$i]
    [void]$prof.RowStyles.Add((New-RowStyle AutoSize))
    $p = $script:Profiles | Where-Object Name -eq $name | Select-Object -First 1
    $capText = if (-not $p) { 'profile not found' }
               elseif ($p.PMaxStatePct -lt 100) { "turbo off (max state $($p.PMaxStatePct)%)" }
               else { 'P {0}   |   E {1}' -f (Format-GHz $p.PCoreMHz), (Format-GHz $p.ECoreMHz) }
    $emphasize = ($name -eq 'TurboOff' -and $script:CalVerdict -eq 'UNRECOVERABLE')
    if ($emphasize) { $capText += '   (for degraded CPUs)' }
    $b = New-Btn "$name`n$capText" { param($s, $e) Invoke-ProfileSwitch ([string]$s.Tag) } 40
    $b.Tag = $name; $b.Dock = 'Fill'; $b.AutoSize = $false; $b.TextAlign = 'MiddleLeft'; $b.Margin = New-Pad 0 0 0 4; $b.Font = $script:Fnt.Bold
    if ($emphasize) { $b.FlatAppearance.BorderColor = $script:Col.Red; $b.FlatAppearance.BorderSize = 2; $script:Tips.SetToolTip($b, 'Recommended for severely degraded CPUs - may reduce crashes even if it cannot eliminate them.') }
    elseif ($p) { $script:Tips.SetToolTip($b, [string]$p.Description) }
    $prof.Controls.Add($b, 0, $i); $script:Ui.ProfileButtons[$name] = $b
}
# health check and reset side by side
[void]$prof.RowStyles.Add((New-RowStyle AutoSize))
$pair = New-Grid 2 1
$pair.Dock = 'Fill'; $pair.AutoSize = $true; $pair.AutoSizeMode = 'GrowAndShrink'; $pair.Margin = New-Pad 0 4 0 0
[void]$pair.ColumnStyles.Add((New-ColStyle Percent 55))
[void]$pair.ColumnStyles.Add((New-ColStyle Percent 45))
[void]$pair.RowStyles.Add((New-RowStyle AutoSize))
$script:Ui.HealthBtn = New-Btn 'Run Health Check Now' { Invoke-HealthCheckNow }
$script:Ui.HealthBtn.Dock = 'Fill'; $script:Ui.HealthBtn.AutoSize = $false; $script:Ui.HealthBtn.Margin = New-Pad 0 0 6 4
$script:Ui.ResetBtn = New-Btn 'Reset to Defaults' { Invoke-ResetDefaults }
$script:Ui.ResetBtn.Dock = 'Fill'; $script:Ui.ResetBtn.AutoSize = $false; $script:Ui.ResetBtn.Margin = New-Pad 0 0 0 4
$script:Ui.ResetBtn.FlatAppearance.BorderColor = $script:Col.DangerEdge
$script:Tips.SetToolTip($script:Ui.ResetBtn, 'Removes all frequency caps (stock clocks). Asks for confirmation first.')
$pair.Controls.Add($script:Ui.HealthBtn, 0, 0); $pair.Controls.Add($script:Ui.ResetBtn, 1, 0)
$prof.Controls.Add($pair, 0, 4)
[void]$prof.RowStyles.Add((New-RowStyle AutoSize))
$script:Ui.ProfStatus = New-Lbl '' $script:Fnt.Base $script:Col.Amber
$script:Ui.WrapLabels += $script:Ui.ProfStatus
if (-not $script:IsAdmin) { $script:Ui.ProfStatus.Text = 'Read-only mode: these need administrator rights.' } else { $script:Ui.ProfStatus.Visible = $false }
$prof.Controls.Add($script:Ui.ProfStatus, 0, 5)
# description of the active profile; takes whatever height is left
[void]$prof.RowStyles.Add((New-RowStyle Percent 100))
$script:Ui.ProfDesc = New-Lbl '' $script:Fnt.Base $script:Col.Muted
$script:Ui.ProfDesc.AutoSize = $false; $script:Ui.ProfDesc.AutoEllipsis = $true; $script:Ui.ProfDesc.Dock = 'Fill'; $script:Ui.ProfDesc.Margin = New-Pad 0 4 0 0
$prof.Controls.Add($script:Ui.ProfDesc, 0, 6)
$profCard = New-Section 'PROFILE SWITCHER' $prof -Fill
$profCard.Margin = New-Pad 12 0 0 12
$mid.Controls.Add($profCard, 1, 0)
$root.Controls.Add($mid, 0, 3)

# row 4: actions
$acts = New-Grid 1 2
[void]$acts.ColumnStyles.Add((New-ColStyle Percent 100))
[void]$acts.RowStyles.Add((New-RowStyle AutoSize))
[void]$acts.RowStyles.Add((New-RowStyle AutoSize))
$acts.AutoSize = $true; $acts.AutoSizeMode = 'GrowAndShrink'
$flow = New-Object System.Windows.Forms.FlowLayoutPanel
$flow.AutoSize = $true; $flow.AutoSizeMode = 'GrowAndShrink'; $flow.WrapContents = $true; $flow.Dock = 'Fill'; $flow.Margin = New-Pad 0 0 0 0
$flow.BackColor = [System.Drawing.Color]::Transparent
$flow.Controls.Add((New-Btn 'Open calibration result' { Invoke-OpenReport }))
$flow.Controls.Add((New-Btn 'Open governor.log' { Invoke-OpenLog }))
$script:Ui.TestBtn = New-Btn 'Run CPU0 Fault Test' { Invoke-FaultTest }
$script:Ui.TestBtn.FlatAppearance.BorderColor = $script:Col.WarnEdge
$flow.Controls.Add($script:Ui.TestBtn)
$flow.Controls.Add((New-Btn 'Copy Status to Clipboard' { Invoke-CopyStatus }))
$acts.Controls.Add($flow, 0, 0)
$script:Ui.Warn = New-Lbl ('WARNING: Run CPU0 Fault Test is the diagnostic from the calibration - 60 s of bursty load on CPU 0, the defective core. ' +
    'It FAILS on this CPU at stock clocks and should PASS on a capped profile. It MAY CRASH THE SYSTEM: save your work first.') $script:Fnt.Warn $script:Col.Amber
$script:Ui.Warn.Margin = New-Pad 0 2 0 2
$script:Ui.WrapLabels += $script:Ui.Warn
$acts.Controls.Add($script:Ui.Warn, 0, 1)
$root.Controls.Add((New-Section 'ACTIONS' $acts), 0, 4)

# row 5: footer
$foot = New-Grid 3 1
$foot.Dock = 'Fill'; $foot.AutoSize = $true; $foot.AutoSizeMode = 'GrowAndShrink'
[void]$foot.ColumnStyles.Add((New-ColStyle AutoSize))
[void]$foot.ColumnStyles.Add((New-ColStyle Percent 100))
[void]$foot.ColumnStyles.Add((New-ColStyle AutoSize))
# small, muted "Uninstall" in the bottom-left corner, deliberately far from the profile controls
$script:Ui.UninstallBtn = New-Object System.Windows.Forms.Button
$script:Ui.UninstallBtn.Text = 'Uninstall'; $script:Ui.UninstallBtn.Font = $script:Fnt.Base
$script:Ui.UninstallBtn.ForeColor = $script:Col.Muted; $script:Ui.UninstallBtn.BackColor = $script:Col.Panel
$script:Ui.UninstallBtn.FlatStyle = 'Flat'; $script:Ui.UninstallBtn.FlatAppearance.BorderColor = $script:Col.Edge; $script:Ui.UninstallBtn.FlatAppearance.BorderSize = 1
$script:Ui.UninstallBtn.AutoSize = $true; $script:Ui.UninstallBtn.Height = 24; $script:Ui.UninstallBtn.Padding = New-Pad 8 1 8 1
$script:Ui.UninstallBtn.Margin = New-Pad 0 2 14 2; $script:Ui.UninstallBtn.Cursor = [System.Windows.Forms.Cursors]::Hand
$script:Ui.UninstallBtn.Add_Click({ Invoke-Uninstall })
$script:Tips.SetToolTip($script:Ui.UninstallBtn, 'Remove CPU Governor and restore default power settings (runs Remove.ps1).')
$foot.Controls.Add($script:Ui.UninstallBtn, 0, 0)
$script:Ui.Msg = New-Lbl 'Starting...' $script:Fnt.Base $script:Col.Muted
$script:Ui.Msg.AutoEllipsis = $true
$foot.Controls.Add($script:Ui.Msg, 1, 0)
$right = New-Object System.Windows.Forms.FlowLayoutPanel
$right.AutoSize = $true; $right.AutoSizeMode = 'GrowAndShrink'; $right.FlowDirection = 'RightToLeft'; $right.WrapContents = $false
$right.Margin = New-Pad 0 0 0 0; $right.BackColor = [System.Drawing.Color]::Transparent
$script:Ui.Updated = New-Lbl 'Last updated: --:--:--' $script:Fnt.Base $script:Col.Muted
$script:Ui.MonAge = New-Lbl 'SYSTEM monitor: ?' $script:Fnt.Base $script:Col.Muted; $script:Ui.MonAge.Margin = New-Pad 0 2 16 2
$script:Ui.Dot = New-Object System.Windows.Forms.Panel
$script:Ui.Dot.Size = New-Object System.Drawing.Size(12, 12); $script:Ui.Dot.Margin = New-Pad 0 4 6 0; $script:Ui.Dot.BackColor = [System.Drawing.Color]::Transparent
$script:Ui.Dot.Tag = $script:Col.Muted
$script:Ui.Dot.Add_Paint({ param($s, $e)
    $e.Graphics.SmoothingMode = 'AntiAlias'
    $br = New-Object System.Drawing.SolidBrush([System.Drawing.Color]$s.Tag)
    $e.Graphics.FillEllipse($br, 0, 0, $s.Width - 1, $s.Height - 1); $br.Dispose() })
$right.Controls.Add($script:Ui.Updated); $right.Controls.Add($script:Ui.MonAge); $right.Controls.Add($script:Ui.Dot)
$foot.Controls.Add($right, 2, 0)
$root.Controls.Add($foot, 0, 5)

$form.ResumeLayout($false)
$form.PerformLayout()

# wrapping labels get their cell's width as MaximumSize (recomputed when the window is resized)
function Update-WrapWidths {
    foreach ($l in $script:Ui.WrapLabels) {
        $w = $l.Parent.ClientSize.Width
        if ($l.Parent -is [System.Windows.Forms.TableLayoutPanel]) {
            $pos = $l.Parent.GetPositionFromControl($l)
            $widths = $l.Parent.GetColumnWidths()
            if ($pos.Column -ge 0 -and $pos.Column -lt $widths.Count) { $w = $widths[$pos.Column] }
        }
        $w -= $l.Margin.Horizontal
        if ($w -lt 80) { continue }     # layout not settled yet (early resize events); keep the previous width
        if ($l.MaximumSize.Width -ne $w) { $l.MaximumSize = New-Object System.Drawing.Size($w, 0) }
    }
}
$form.Add_Resize({ Update-WrapWidths })

# ------------------------------------------------------------------ state & helpers
$script:State = @{}
$script:Errors = [ordered]@{}   # source -> message; the banner lists every current error
$script:Tick = 0
$script:StatusProc = $null
$script:TestProc = $null; $script:TestLabel = ''
$script:HealthStarted = $null
$script:Snapshot = [ordered]@{}
$script:Busy = $false

function Set-Err([string]$Source, [string]$Message) {
    if ($Message) {
        if (-not $script:Errors.Contains($Source) -or $script:Errors[$Source] -ne $Message) { Write-GuiLog "$Source failed: $Message" 'ERROR' }
        $script:Errors[$Source] = $Message
    } elseif ($script:Errors.Contains($Source)) { $script:Errors.Remove($Source) }
    $all = @($script:Errors.Keys | ForEach-Object { "[FAIL] ${_}: $($script:Errors[$_])" })
    if ($script:ModuleError) { $all = @("[FAIL] $($script:ModuleError)") + $all }
    $script:Ui.Banner.Visible = $all.Count -gt 0
    $script:Ui.Banner.Text = ($all -join '    ') + $(if ($all.Count) { '    (click for details)' } else { '' })
    $script:Ui.Banner.Tag = ($all -join [Environment]::NewLine)
}

function Set-Msg([string]$Text, $Color = $script:Col.Muted) { $script:Ui.Msg.Text = $Text; $script:Ui.Msg.ForeColor = $Color }

function Get-StateValue([string]$Key) { if ($script:State.ContainsKey($Key)) { $script:State[$Key] } else { $null } }

function Show-LogTail {
    # caret at the start of the last line: scrolls to the newest entry without scrolling sideways
    $t = $script:Ui.Log
    $t.SelectionStart = [Math]::Max(0, $t.Text.LastIndexOf("`n") + 1); $t.SelectionLength = 0; $t.ScrollToCaret()
}

function Set-FormFit {
    # keep the window inside the working area of the monitor it opened on (1080p at 150 % leaves only 672 px of height)
    $wa = [System.Windows.Forms.Screen]::FromControl($form).WorkingArea
    $w = [Math]::Min($form.Width, $wa.Width); $h = [Math]::Min($form.Height, $wa.Height)
    if ($w -lt $form.Width -or $h -lt $form.Height) {
        $form.MinimumSize = New-Object System.Drawing.Size([Math]::Min($form.MinimumSize.Width, $w), [Math]::Min($form.MinimumSize.Height, $h))
        $form.Size = New-Object System.Drawing.Size($w, $h)
    }
    $x = $wa.X + [Math]::Max(0, [int](($wa.Width - $form.Width) / 2)); $y = $wa.Y + [Math]::Max(0, [int](($wa.Height - $form.Height) / 2))
    $form.Location = New-Object System.Drawing.Point($x, $y)
}

function Update-Buttons {
    $cur = [string](Get-StateValue 'Profile')
    $canAct = $script:IsAdmin -and -not $script:ModuleError -and -not $script:Busy
    foreach ($n in $script:Ui.ProfileButtons.Keys) {
        $b = $script:Ui.ProfileButtons[$n]
        if ($n -eq $cur) { $b.BackColor = $script:Col.Blue; $b.FlatAppearance.BorderColor = $script:Col.BlueEdge; $b.FlatAppearance.MouseOverBackColor = $script:Col.Blue }
        else { $b.BackColor = $script:Col.Btn; $b.FlatAppearance.BorderColor = $script:Col.Edge; $b.FlatAppearance.MouseOverBackColor = $script:Col.BtnHover }
        $b.Enabled = $canAct
    }
    $script:Ui.ResetBtn.Enabled = $canAct
    $script:Ui.HealthBtn.Enabled = $script:IsAdmin -and -not $script:HealthStarted
    $script:Ui.TestBtn.Enabled = -not $script:TestProc -and -not $script:Busy
    if (-not $script:IsAdmin) {
        foreach ($c in @($script:Ui.ResetBtn, $script:Ui.HealthBtn) + @($script:Ui.ProfileButtons.Values)) {
            $script:Tips.SetToolTip($c, 'Needs administrator rights - restart the GUI and accept the UAC prompt.')
        }
    }
}

# ------------------------------------------------------------------ fast refresh (UI thread, every 30 s, ~0.2 s)
function Update-FastStatus {
    # 1. governor state: profile and caps
    try {
        if ($script:ModuleError) { throw 'module not loaded' }
        $script:State = Get-GovernorState
        $prof = [string](Get-StateValue 'Profile'); if (-not $prof) { $prof = '(none)' }
        $script:Ui.ProfileVal.Text = $prof
        $applied = if (Get-StateValue 'AppliedAt') { 'applied {0:yyyy-MM-dd HH:mm}' -f ([datetime](Get-StateValue 'AppliedAt')) } else { '' }
        $why = ([string](Get-StateValue 'Reason')) -replace '^profile \S+ \((.+)\)$', '$1'
        if (Get-StateValue 'AutoLowered') {
            $script:Ui.ProfileSub.Text = "AUTO-LOWERED by the health monitor after instability ($applied)"; $script:Ui.ProfileSub.ForeColor = $script:Col.Amber
        } elseif ($prof -like 'Reset-*') {
            $script:Ui.ProfileSub.Text = "all caps removed - stock clocks ($applied)"; $script:Ui.ProfileSub.ForeColor = $script:Col.Amber
        } else {
            $script:Ui.ProfileSub.Text = $applied + $(if ($why) { " ($why)" } else { '' }); $script:Ui.ProfileSub.ForeColor = $script:Col.Muted
        }
        if ($script:State.ContainsKey('PCoreMHz')) {
            $pc = [int](Get-StateValue 'PCoreMHz'); $ec = [int](Get-StateValue 'ECoreMHz')
            $pm = [int](Get-StateValue 'PMaxStatePct'); $em = [int](Get-StateValue 'EMaxStatePct')
            $script:Ui.PCapVal.Text = if ($pc -gt 0) { Format-GHz $pc } elseif ($pm -lt 100) { 'turbo off' } else { 'no cap' }
            $script:Ui.ECapVal.Text = if ($ec -gt 0) { Format-GHz $ec } elseif ($em -lt 100) { 'turbo off' } else { 'no cap' }
            $script:Ui.PCapSub.Text = if ($pm -lt 100) { "max state $pm%" }
                                      elseif ($pc -gt 0 -and $script:Measured.ContainsKey($pc)) { 'peak ~{0:0.00} GHz' -f ($script:Measured[$pc] / 1000) }
                                      elseif ($pc -gt 0) { 'requested cap' } else { 'stock, up to 5.6 GHz' }
            $script:Ui.ECapSub.Text = if ($em -lt 100) { "max state $em%" } elseif ($ec -gt 0) { 'requested cap' } else { 'stock, ~4.1 GHz' }
            $script:Tips.SetToolTip($script:Ui.PCapVal, 'Requested P-core cap (PROCFREQMAX1). The measured single-thread peak lands 100-130 MHz lower.')
        } else {
            $script:Ui.PCapVal.Text = 'no cap'; $script:Ui.ECapVal.Text = 'no cap'
            $script:Ui.PCapSub.Text = 'governor caps not applied'; $script:Ui.ECapSub.Text = 'governor caps not applied'
        }
        $p = $script:Profiles | Where-Object Name -eq $prof | Select-Object -First 1
        $script:Ui.ProfDesc.Text = if ($p) { [string]$p.Description } else { '' }
        Set-Err 'state' $null
    } catch { Set-Err 'state' $_.Exception.Message }

    # 2. uptime (GetTickCount64: time since the kernel started, including sleep)
    try {
        $up = [TimeSpan]::FromMilliseconds([Environment]::TickCount64)
        $script:Ui.UpVal.Text = if ($up.TotalDays -ge 1) { '{0} d {1} h {2} min' -f $up.Days, $up.Hours, $up.Minutes } else { '{0} h {1} min' -f [int][Math]::Floor($up.TotalHours), $up.Minutes }
        $script:Ui.UpSub.Text = 'since {0:MM-dd HH:mm}' -f ((Get-Date) - $up)
        $script:Snapshot['Uptime'] = "$($script:Ui.UpVal.Text) ($($script:Ui.UpSub.Text))"
    } catch { Set-Err 'uptime' $_.Exception.Message }

    # 3. governor.log tail (the user@host pid column is dropped to save width). A missing log is normal before the first
    #    cap is applied - treat it as "nothing yet", not an error.
    try {
        if (-not (Test-Path -LiteralPath $script:GovLog)) {
            $text = '(no governor.log yet - apply a profile or run calibration to start logging)'
        } else {
            $lines = @(Get-Content -LiteralPath $script:GovLog -Tail 10 -ErrorAction Stop) | ForEach-Object { $_ -replace '^\d{4}-(\d\d-\d\d \d\d:\d\d:\d\d)\.\d+ (\[[A-Z ]+\]) \[[^\]]*\] ', '$1 $2 ' }
            $text = ($lines -join "`r`n")
        }
        if ($script:Ui.Log.Text -ne $text) { $script:Ui.Log.Text = $text; Show-LogTail }
        Set-Err 'governor.log' $null
    } catch { Set-Err 'governor.log' $_.Exception.Message }

    # 4. WHEA errors and BSODs in the last 24 h. Same event sources as Get-CpuGovernorReport, queried directly because the
    #    report also parses every health CSV, which becomes too slow for a 30-second refresh on the UI thread.
    try {
        $since = (Get-Date).AddHours(-24)
        $defs = @(
            @{ Key = 'Whea'; Filter = @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger' } },
            @{ Key = 'Bsod'; Filter = @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001 } }
        )
        foreach ($d in $defs) {
            $f24 = $d.Filter.Clone(); $f24['StartTime'] = $since
            $ev = @(Get-WinEvent -FilterHashtable $f24 -MaxEvents 1000 -ErrorAction SilentlyContinue)
            $last = if ($ev.Count) { $ev[0] } else { Get-WinEvent -FilterHashtable $d.Filter -MaxEvents 1 -ErrorAction SilentlyContinue }
            $detail = if (-not $last) { 'none on record' }
                      elseif ($d.Key -eq 'Whea') { 'last: {0:yyyy-MM-dd HH:mm}, event {1} ({2})' -f $last.TimeCreated, $last.Id, (Format-Age $last.TimeCreated) }
                      else {
                          $code = if ($last.Message -match 'bugcheck was: (0x[0-9a-fA-F]+)') { ', 0x{0:X}' -f [Convert]::ToInt64($Matches[1], 16) } else { '' }
                          'last: {0:yyyy-MM-dd HH:mm}{1} ({2})' -f $last.TimeCreated, $code, (Format-Age $last.TimeCreated)
                      }
            $lbl = $script:Ui["$($d.Key)Val"]
            $lbl.Text = '{0}{1}     {2}' -f $ev.Count, $(if ($ev.Count -ge 1000) { '+' } else { '' }), $detail
            $lbl.ForeColor = if ($ev.Count -gt 0) { $script:Col.Red } else { $script:Col.Green }
            $script:Snapshot["$($d.Key)24"] = $lbl.Text
        }
        Set-Err 'event log' $null
    } catch { Set-Err 'event log' $_.Exception.Message }

    # 5. health monitor: last completed pass (state.json, written by the SYSTEM task); the task's result when elevated
    try {
        $lastPass = if (Get-StateValue 'LastHealthCheck') { [datetime](Get-StateValue 'LastHealthCheck') } else { $null }
        $taskOk = $true; $extra = ''
        if ($script:IsAdmin) {
            $ti = Get-ScheduledTaskInfo -TaskName $script:MonitorTask -ErrorAction Stop
            $taskOk = $ti.LastTaskResult -in 0, 0x41301   # 0x41301 = running now
            $extra = '   task result 0x{0:X}' -f $ti.LastTaskResult
            if ($ti.NextRunTime) { $extra += ', next run {0:HH:mm:ss}' -f $ti.NextRunTime }
        }
        $fresh = $lastPass -and ((Get-Date) - $lastPass).TotalMinutes -le 10 -and $taskOk
        $script:Ui.MonVal.Text = if ($lastPass) { '{0:yyyy-MM-dd HH:mm:ss} ({1}){2}' -f $lastPass, (Format-Age $lastPass), $extra } else { "never$extra" }
        $script:Ui.MonVal.ForeColor = if ($fresh) { $script:Col.Green } else { $script:Col.Red }
        $script:Ui.Dot.Tag = if ($fresh) { $script:Col.Green } else { $script:Col.Red }; $script:Ui.Dot.Invalidate()
        $script:Ui.MonAge.Text = if ($lastPass) { "SYSTEM monitor: $(Format-Age $lastPass)" } else { 'SYSTEM monitor: never' }
        $script:Tips.SetToolTip($script:Ui.Dot, $(if ($fresh) { 'The SYSTEM health monitor completed a pass in the last 10 minutes.' } else { 'No completed health-monitor pass in the last 10 minutes.' }))
        $script:Snapshot['Monitor'] = $script:Ui.MonVal.Text
        Set-Err 'monitor' $null
    } catch { Set-Err 'monitor' $_.Exception.Message }

    $script:Ui.Updated.Text = 'Last updated: ' + (Get-Date).ToString('HH:mm:ss')
    Update-Buttons
}

# ------------------------------------------------------------------ slow check (child process, polled by the timer)
# Get-CpuStatus -Detailed takes ~4.5 s (32 powercfg reads plus a 1 s clock sample), so it runs in a separate pwsh process
# every 2 minutes, after every change, and on F5. The UI thread only reads its JSON result.
function Start-StatusCheck([switch]$Force) {
    if ($script:ModuleError) { return }
    if ($script:StatusProc -and -not $script:StatusProc.HasExited) {
        if (-not $Force) { return }
        try { $script:StatusProc.Kill($true) } catch {}
    }
    Remove-Item -LiteralPath $script:StatusFile -ErrorAction SilentlyContinue
    $cmd = @"
`$out = '$($script:StatusFile)'
try {
    Import-Module '$($script:GovModule)' -Force -ErrorAction Stop
    `$d = Get-CpuStatus -Detailed
    `$map = @(Get-CpuPowerTarget | Select-Object Guid, Name, Kind, Addressable)
    `$rep = Get-CpuGovernorReport
    [pscustomobject]@{ Ok = `$true; At = (Get-Date).ToString('o'); Error = ''; Status = `$d.Status; Targets = @(`$d.Targets); Map = `$map; Report = `$rep } |
        ConvertTo-Json -Depth 6 | Set-Content -LiteralPath `$out -Encoding utf8
} catch {
    [pscustomobject]@{ Ok = `$false; At = (Get-Date).ToString('o'); Error = `$_.Exception.Message } | ConvertTo-Json | Set-Content -LiteralPath `$out -Encoding utf8
}
"@
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    $script:StatusProc = Start-Process -FilePath $script:Pwsh -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $enc) -WindowStyle Hidden -PassThru
    if ($script:Ui.OvlVal.Text -eq '...') { $script:Ui.OvlVal.Text = 'checking...'; $script:Ui.OvlVal.ForeColor = $script:Col.Muted }
    if ($script:Ui.SinceVal.Text -eq '...') { $script:Ui.SinceVal.Text = 'checking...'; $script:Ui.SinceVal.ForeColor = $script:Col.Muted }
}

function Complete-StatusCheck {
    $script:StatusProc = $null
    try {
        if (-not (Test-Path -LiteralPath $script:StatusFile)) { throw 'the status check produced no result' }
        $j = Get-Content -LiteralPath $script:StatusFile -Raw | ConvertFrom-Json
        if (-not $j.Ok) { throw $j.Error }
        $at = [datetime]$j.At

        # since-install summary (Get-CpuGovernorReport)
        $all = $j.Report
        $script:Ui.SinceKey.Text = 'Since install ({0:MM-dd HH:mm})' -f ([datetime]$all.Since)
        $script:Ui.SinceVal.Text = '{0} BSODs, {1} unexpected reboots, {2} WHEA, {3} step-downs' -f $all.Bugchecks, $all.UnexpectedReboots, $all.WheaTotal, $all.StepDowns
        $script:Tips.SetToolTip($script:Ui.SinceVal, ('Get-CpuGovernorReport since {0:yyyy-MM-dd HH:mm}: {1} health samples, busy P-core average {2} MHz, package average {3} W' -f ([datetime]$all.Since), $all.HealthSamples, $all.PAvgMHz_busy, $all.PackageW_avg))
        $anyBad = ([int]$all.Bugchecks + [int]$all.UnexpectedReboots + [int]$all.WheaTotal + [int]$all.StepDowns) -gt 0
        $script:Ui.SinceVal.ForeColor = if ($anyBad) { $script:Col.Red } else { $script:Col.Green }
        $script:Snapshot['SinceInstall'] = '{0} (since {1:yyyy-MM-dd HH:mm})' -f $script:Ui.SinceVal.Text, ([datetime]$all.Since)

        # AC/DC: the effective value on each side is the active overlay's value if it defines one, else the base scheme's
        $st = Get-GovernorState
        if (-not $st.ContainsKey('PCoreMHz')) {
            $script:Ui.OvlVal.Text = 'no caps to verify'; $script:Ui.OvlVal.ForeColor = $script:Col.Amber
            $script:Ui.OvlSub.Text = 'governor caps are not applied (stock)'
            $script:Snapshot['Overlays'] = 'no caps applied'
            Set-Err 'overlay check' $null; return
        }
        $want = [ordered]@{ PROCFREQMAX1 = "$($st['PCoreMHz'])"; PROCFREQMAX = "$($st['ECoreMHz'])"; PROCTHROTTLEMAX1 = "$($st['PMaxStatePct'])"; PROCTHROTTLEMAX = "$($st['EMaxStatePct'])" }
        $none = '00000000-0000-0000-0000-000000000000'
        $ovs = [string]$j.Status.Overlays
        $acG = if ($ovs -match 'AC:\s*([0-9a-fA-F-]{36})') { $Matches[1] } else { $none }
        $dcG = if ($ovs -match 'DC:\s*([0-9a-fA-F-]{36})') { $Matches[1] } else { $none }
        $base = @($j.Targets | Where-Object Active) | Select-Object -First 1
        if (-not $base) { throw 'the active power scheme is not in the status output' }
        $res = foreach ($side in @(@('AC', 0, $acG), @('DC', 1, $dcG))) {
            $bad = @(); $via = [string]$base.Target; $ovRow = $null; $pVal = ''
            if ($side[2] -ne $none) {
                $ovName = @($j.Map | Where-Object Guid -eq $side[2] | Select-Object -ExpandProperty Name) | Select-Object -First 1
                $ovRow = if ($ovName) { $j.Targets | Where-Object Target -eq $ovName | Select-Object -First 1 } else { $null }
                if (-not $ovRow) { $bad += "active overlay $($side[2]) cannot be read, so its caps are unverified" }
            }
            foreach ($k in $want.Keys) {
                $v = (([string]$base.$k) -split '/')[$side[1]]
                if ($ovRow) { $ov = (([string]$ovRow.$k) -split '/')[$side[1]]; if ($ov -ne '') { $v = $ov; $via = [string]$ovRow.Target } }
                if ($k -eq 'PROCFREQMAX1') { $pVal = $v }
                if ($v -ne $want[$k]) { $bad += "$k=$(if ($v -eq '') { 'undefined' } else { $v }) (want $($want[$k]))" }
            }
            [pscustomobject]@{ Side = $side[0]; Ok = ($bad.Count -eq 0); Via = $via; P = $pVal; Bad = ($bad -join ', ') }
        }
        # every overlay must carry the cap (or leave all four settings undefined and inherit it), so changing the Windows
        # power mode cannot lift it
        $ovRows = @($j.Targets | Where-Object Kind -eq 'Overlay')
        $ovOk = 0
        foreach ($row in $ovRows) {
            $vals = foreach ($k in $want.Keys) { foreach ($v in (([string]$row.$k) -split '/')) { [pscustomobject]@{ Want = $want[$k]; Got = $v } } }
            $allUndefined = @($vals | Where-Object Got -ne '').Count -eq 0
            $allMatch = @($vals | Where-Object { $_.Got -ne $_.Want }).Count -eq 0
            if ($allMatch -or $allUndefined) { $ovOk++ }
        }
        $failed = @($res | Where-Object { -not $_.Ok })
        $allOk = $failed.Count -eq 0 -and $ovOk -eq $ovRows.Count
        $script:Ui.OvlVal.Text = if ($allOk) { '[OK] AC and DC carry the cap' }
                                 elseif ($failed.Count) { '[FAIL] ' + (($failed | ForEach-Object { $_.Side }) -join ' and ') + ' not capped as expected' }
                                 else { "[FAIL] only $ovOk of $($ovRows.Count) overlays carry the cap" }
        $script:Ui.OvlVal.ForeColor = if ($allOk) { $script:Col.Green } else { $script:Col.Red }
        $script:Ui.OvlSub.Text = '{0} schemes + overlays match, {1:HH:mm}' -f $j.Status.TargetsConsistent, $at
        $tip = (@($res | ForEach-Object { '{0}: P-core cap {1} via {2}{3}' -f $_.Side, (Format-GHz $_.P), $_.Via, $(if ($_.Bad) { " - $($_.Bad)" } else { '' }) }) +
                "Overlays carrying the cap: $ovOk of $($ovRows.Count). Checked with Get-CpuStatus -Detailed at $($at.ToString('HH:mm:ss')).") -join [Environment]::NewLine
        $script:Tips.SetToolTip($script:Ui.OvlVal, $tip); $script:Tips.SetToolTip($script:Ui.OvlSub, $tip)
        $script:Snapshot['Overlays'] = '{0} - AC via {1}, DC via {2}; overlays {3}/{4}; {5}' -f $script:Ui.OvlVal.Text, $res[0].Via, $res[1].Via, $ovOk, $ovRows.Count, $script:Ui.OvlSub.Text
        if ($failed.Count) { $script:Snapshot['Overlays'] += ' - ' + (($failed | ForEach-Object { "$($_.Side): $($_.Bad)" }) -join '; ') }
        if (-not $allOk) { Write-GuiLog "Overlay check: $($script:Snapshot['Overlays'])" 'WARN' }
        Set-Err 'overlay check' $null
    } catch {
        $script:Ui.OvlVal.Text = '[FAIL] check failed'; $script:Ui.OvlVal.ForeColor = $script:Col.Red
        Set-Err 'overlay check' $_.Exception.Message
    }
}

# ------------------------------------------------------------------ actions
function Invoke-ProfileSwitch([string]$Name) {
    if (-not $script:IsAdmin) { [void][System.Windows.Forms.MessageBox]::Show('Profile switching needs administrator rights. Restart the GUI and accept the UAC prompt.', 'Read-only mode', 'OK', 'Information'); return }
    $cur = [string](Get-StateValue 'Profile')
    if ($Name -eq $cur) { Set-Msg "$Name is already active."; return }
    $iNew = $script:ProfileOrder.IndexOf($Name); $iCur = $script:ProfileOrder.IndexOf($cur)
    if ((Get-StateValue 'AutoLowered') -and $iNew -ge 0 -and $iCur -ge 0 -and $iNew -lt $iCur) {
        $q = [System.Windows.Forms.MessageBox]::Show("The health monitor lowered the profile to $cur after it detected instability.`n`nRaise it to $Name anyway?", 'Raise the profile?', 'YesNo', 'Warning', 'Button2')
        if ($q -ne 'Yes') { Write-GuiLog "Switch $cur -> $Name cancelled at the auto-lowered warning"; return }
    }
    $script:Busy = $true; Update-Buttons; $form.UseWaitCursor = $true
    Set-Msg "Applying $Name to every power scheme and overlay (AC and DC)..."; [System.Windows.Forms.Application]::DoEvents()
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        # default -Source ('manual'): a deliberate user choice, so the module also clears the auto-lowered flag
        $r = Set-CpuProfile -Name $Name
        Write-GuiLog ('Set-CpuProfile {0} (was {1}): {2} targets, {3} values changed, {4} ms' -f $Name, $cur, $r.Targets, $r.ValuesChanged, $sw.ElapsedMilliseconds) 'ACTION'
        Set-Msg ('{0} applied in {1:N1} s ({2} values changed). Verifying AC/DC...' -f $Name, $sw.Elapsed.TotalSeconds, $r.ValuesChanged) $script:Col.Green
        Set-Err 'profile switch' $null
    } catch {
        Set-Err 'profile switch' $_.Exception.Message; Set-Msg "Switching to $Name failed - see the red banner." $script:Col.Red
    } finally { $script:Busy = $false; $form.UseWaitCursor = $false }
    Update-FastStatus; Start-StatusCheck -Force
}

function Invoke-ResetDefaults {
    if (-not $script:IsAdmin) { return }
    $msg = "Reset to Defaults removes ALL frequency caps from every power scheme and overlay (stock clocks, turbo on).`n`n" +
           "At stock clocks this CPU fails the CPU0 fault test, so crashes become more likely.`n`n" +
           "The boot/logon task re-applies the default profile at the next restart or sign-in, and the health monitor " +
           "re-applies it if it detects instability.`n`nRemove all caps now?"
    if ([System.Windows.Forms.MessageBox]::Show($msg, 'Reset to Defaults', 'YesNo', 'Warning', 'Button2') -ne 'Yes') { Write-GuiLog 'Reset to Defaults cancelled'; return }
    $script:Busy = $true; Update-Buttons; $form.UseWaitCursor = $true
    Set-Msg 'Removing all caps...'; [System.Windows.Forms.Application]::DoEvents()
    try {
        Reset-CpuGovernor -ToDefaults
        Write-GuiLog 'Reset-CpuGovernor -ToDefaults completed (user confirmed)' 'ACTION'
        Set-Msg 'All caps removed (stock). Pick a profile to re-apply protection.' $script:Col.Amber
        Set-Err 'reset' $null
    } catch { Set-Err 'reset' $_.Exception.Message; Set-Msg 'Reset failed - see the red banner.' $script:Col.Red }
    finally { $script:Busy = $false; $form.UseWaitCursor = $false }
    Update-FastStatus; Start-StatusCheck -Force
}

function Invoke-HealthCheckNow {
    if (-not $script:IsAdmin) { return }
    try {
        Start-ScheduledTask -TaskName $script:MonitorTask -ErrorAction Stop
        $script:HealthStarted = Get-Date
        Write-GuiLog "Started scheduled task $($script:MonitorTask)" 'ACTION'
        Set-Msg 'Health check running as SYSTEM...'
        Set-Err 'health check' $null
    } catch { Set-Err 'health check' $_.Exception.Message }
    Update-Buttons
}

function Test-HealthCheckDone {
    $age = ((Get-Date) - $script:HealthStarted).TotalSeconds
    if ($age -lt 4) { return }
    $t = Get-ScheduledTask -TaskName $script:MonitorTask -ErrorAction SilentlyContinue
    if ($t -and [string]$t.State -eq 'Running' -and $age -lt 200) { return }
    $ti = Get-ScheduledTaskInfo -TaskName $script:MonitorTask -ErrorAction SilentlyContinue
    $script:HealthStarted = $null
    $code = if ($ti) { [int64]$ti.LastTaskResult } else { -1 }
    Set-Msg ('Health check finished: task result 0x{0:X}{1}' -f $code, $(if ($code -eq 0) { ' (OK)' } else { '' })) $(if ($code -eq 0) { $script:Col.Green } else { $script:Col.Red })
    Write-GuiLog ('Health check task finished, result 0x{0:X}' -f $code)
    Update-FastStatus; Start-StatusCheck -Force
}

function Invoke-OpenReport {
    # via explorer.exe so the viewer opens un-elevated with the default .md association
    if (-not (Test-Path -LiteralPath $script:ReportPath)) { Set-Msg 'No calibration result yet - run Calibrate.ps1 first.' $script:Col.Amber; return }
    try { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $script:ReportPath); Write-GuiLog 'Opened calibration result' 'ACTION' }
    catch { Set-Err 'open report' $_.Exception.Message }
}

function Invoke-OpenLog {
    try { Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f $script:GovLog); Write-GuiLog 'Opened governor.log in Notepad' 'ACTION' }
    catch { Set-Err 'open log' $_.Exception.Message }
}

function Invoke-FaultTest {
    if ($script:TestProc) { return }
    if (-not (Test-Path -LiteralPath $script:FaultTool)) { Set-Err 'fault test' "tool not found: $($script:FaultTool)"; return }
    $cur = [string](Get-StateValue 'Profile'); if (-not $cur) { $cur = 'unknown' }
    $msg = "CPU0 FAULT TEST (diagnostic)`n`n" +
           "Runs the stack-unwinder torture test from the calibration on CPU 0 - the core with the known defect - for 60 seconds " +
           "of bursty load, under the CURRENT profile ($cur).`n`n" +
           "Expected: PASS under a capped profile. At stock clocks this CPU FAILS (corrupted stack walks) - that is the defect.`n`n" +
           "WARNING: the test deliberately stresses an unstable core and MAY CRASH THE SYSTEM. Save your work first.`n`nRun it now?"
    if ([System.Windows.Forms.MessageBox]::Show($msg, 'Run CPU0 Fault Test', 'YesNo', 'Warning', 'Button2') -ne 'Yes') { Write-GuiLog 'CPU0 fault test cancelled at the warning'; return }
    New-Item -ItemType Directory -Force $script:TestRunRoot | Out-Null
    $script:TestLabel = 'gui_cpu0_{0:yyyyMMdd_HHmmss}_{1}' -f (Get-Date), ($cur -replace '[^\w\-]', '_')
    $argsList = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $script:FaultTool),
                  '-Label', $script:TestLabel, '-Minutes', '1', '-LogicalProcessors', '0', '-Bursty', '-RunRoot', ('"{0}"' -f $script:TestRunRoot))
    try {
        $script:TestProc = Start-Process -FilePath $script:Pwsh -ArgumentList $argsList -WindowStyle Hidden -PassThru
        Write-GuiLog "CPU0 fault test started (profile $cur, label $($script:TestLabel)); user confirmed the warning" 'ACTION'
        Set-Msg 'CPU0 fault test running (about 70 s)...' $script:Col.Amber
    } catch { Set-Err 'fault test' $_.Exception.Message; $script:TestProc = $null }
    Update-Buttons
}

function Format-FaultResult($r) {
    $walks = if ($r.Walks) { '{0:N1} M' -f ([double]$r.Walks / 1e6) } else { '0' }
    $extra = @()
    if ($r.TestProcessCrashed) { $extra += 'test process crashed (exit 0x{0:X8})' -f ([int64]$r.ExitCode -band 0xFFFFFFFFL) }
    if ($r.WheaEvents) { $extra += "$($r.WheaEvents) WHEA event(s)" }
    if ($r.NewDumps) { $extra += "$($r.NewDumps) new crash dump(s)" }
    '{0}: {1} corrupted walks in {2} walks{3}' -f $r.Verdict, $r.Mismatches, $walks, $(if ($extra) { '; ' + ($extra -join '; ') } else { '' })
}

function Complete-FaultTest {
    $label = $script:TestLabel; $script:TestProc = $null
    try {
        $dir = Get-ChildItem -LiteralPath $script:TestRunRoot -Directory -ErrorAction SilentlyContinue | Where-Object Name -like "*_$label" | Sort-Object Name | Select-Object -Last 1
        $file = if ($dir) { Join-Path $dir.FullName 'result.json' } else { '' }
        if (-not $file -or -not (Test-Path -LiteralPath $file)) { throw "the test produced no result (run folder: $(if ($dir) { $dir.FullName } else { 'missing' }))" }
        $r = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
        $text = Format-FaultResult $r
        $pass = $r.Verdict -eq 'PASS'
        Write-GuiLog "CPU0 fault test finished: $text ($($dir.FullName))" 'ACTION'
        Set-Msg "CPU0 fault test $text" $(if ($pass) { $script:Col.Green } else { $script:Col.Red })
        $script:Snapshot['LastFaultTest'] = '{0:yyyy-MM-dd HH:mm} {1} (profile {2})' -f (Get-Date), $text, ($label -replace '^gui_cpu0_\d{8}_\d{6}_', '')
        $more = if ($pass) { 'No corruption was detected on CPU 0 under the current profile.' }
                else { 'CPU 0 produced errors under the current profile. Switch to a lower profile and keep the health monitor enabled.' }
        [void][System.Windows.Forms.MessageBox]::Show("$text`n`n$more`n`nDetails: $($dir.FullName)", 'CPU0 fault test result', 'OK', $(if ($pass) { 'Information' } else { 'Error' }))
        Set-Err 'fault test' $null
    } catch { Set-Err 'fault test' $_.Exception.Message }
    Update-Buttons; Update-FastStatus
}

function Get-StatusText {
    $pc = Get-StateValue 'PCoreMHz'
    $caps = if ($null -ne $pc) { 'P-cores {0}, E-cores {1}, max state P {2}% / E {3}%' -f (Format-GHz $pc), (Format-GHz (Get-StateValue 'ECoreMHz')), (Get-StateValue 'PMaxStatePct'), (Get-StateValue 'EMaxStatePct') } else { 'none (stock)' }
    $snap = { param($k, $d) if ($script:Snapshot.Contains($k)) { $script:Snapshot[$k] } else { $d } }
    @(
        "CPU Stability Governor - status $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        "Machine       : $($script:Machine)"
        "Profile       : $($script:Ui.ProfileVal.Text) - $($script:Ui.ProfileSub.Text)"
        "Caps          : $caps"
        "AC/DC         : $(& $snap 'Overlays' 'not checked yet')"
        "Uptime        : $(& $snap 'Uptime' 'n/a')"
        "WHEA (24 h)   : $(& $snap 'Whea24' 'n/a')"
        "BSODs (24 h)  : $(& $snap 'Bsod24' 'n/a')"
        "Since install : $(& $snap 'SinceInstall' 'n/a')"
        "Health monitor: $(& $snap 'Monitor' 'n/a')"
        "CPU0 test     : $(& $snap 'LastFaultTest' 'not run from the GUI in this session')"
        'Background    : the CPU0 fault test exercises the core with the known defect; see your calibration_result.md for this chip''s safe frequency'
    ) -join [Environment]::NewLine
}

function Invoke-Uninstall {
    # Confirm here, then hand off to Remove.ps1 (which restores power settings, removes the task, deletes the install).
    $removeScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'Remove.ps1'
    if (-not (Test-Path -LiteralPath $removeScript)) {
        [void][System.Windows.Forms.MessageBox]::Show("Remove.ps1 was not found next to the install (expected $removeScript). If you installed manually, run Remove.ps1 from the release folder.", 'Uninstall', 'OK', 'Warning')
        return
    }
    $msg = "Remove CPU Governor and restore default power settings?`n`n" +
           "This stops the background health monitor, removes its scheduled task, restores the power settings saved before install, and deletes the installed files. Your CPU returns to stock behaviour.`n`n" +
           "A separate elevated window will carry out the removal."
    if ([System.Windows.Forms.MessageBox]::Show($msg, 'Uninstall CPU Governor', 'YesNo', 'Warning', 'Button2') -ne 'Yes') { Write-GuiLog 'Uninstall cancelled at the GUI confirmation'; return }
    try {
        # -Confirmed: the user already confirmed here, so Remove.ps1 skips its own text prompt (it still shows the UAC prompt).
        Start-Process -FilePath $script:Pwsh -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $removeScript), '-Confirmed') -ErrorAction Stop | Out-Null
        Write-GuiLog "Launched Remove.ps1 elevated ($removeScript); closing the GUI" 'ACTION'
        $script:Timer.Stop(); $form.Close()
    } catch {
        Write-GuiLog "Uninstall launch failed: $($_.Exception.Message)" 'ERROR'
        [void][System.Windows.Forms.MessageBox]::Show("Could not start the uninstaller: $($_.Exception.Message)", 'Uninstall', 'OK', 'Error')
    }
}

function Invoke-CopyStatus {
    try {
        $t = Get-StatusText
        [System.Windows.Forms.Clipboard]::SetText($t)
        Write-GuiLog 'Status summary copied to the clipboard' 'ACTION'
        Set-Msg "Status summary copied to the clipboard ($(($t -split [Environment]::NewLine).Count) lines)." $script:Col.Green
    } catch { Set-Err 'clipboard' $_.Exception.Message }
}

# ------------------------------------------------------------------ timer (UI thread) & lifecycle
$script:Timer = New-Object System.Windows.Forms.Timer
$script:Timer.Interval = 1000
$script:Timer.Add_Tick({
    $script:Tick++
    try {
        if ($script:StatusProc -and $script:StatusProc.HasExited) { Complete-StatusCheck }
        if ($script:TestProc -and $script:TestProc.HasExited) { Complete-FaultTest }
        if ($script:HealthStarted) { Test-HealthCheckDone }
        if ($script:Tick % 30 -eq 0) { Update-FastStatus }
        if ($script:Tick % 120 -eq 0) { Start-StatusCheck }
    } catch { Set-Err 'timer' $_.Exception.Message }
})

$form.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq 'F5') { Update-FastStatus; Start-StatusCheck -Force; Set-Msg 'Refreshed; AC/DC check running...' } })
$form.Add_FormClosing({
    $script:Timer.Stop()
    if ($script:TestProc -and -not $script:TestProc.HasExited) { try { $script:TestProc.Kill($true) } catch {}; Write-GuiLog 'GUI closed while a CPU0 test was running; test stopped' 'WARN' }
    if ($script:StatusProc -and -not $script:StatusProc.HasExited) { try { $script:StatusProc.Kill($true) } catch {} }
    Write-GuiLog 'GUI closed'
})
$form.Add_Shown({
    Set-FormFit
    Update-WrapWidths
    Set-Err 'startup' $null   # shows the module error, if any
    Update-FastStatus
    Show-LogTail
    Start-StatusCheck
    Set-Msg $(if ($script:IsAdmin) { 'Ready.' } else { 'Read-only mode.' })
    $form.ActiveControl = $null     # no caret or focus rectangle at start; F5 still works (KeyPreview)
    $script:Timer.Start()
    if ($SelfTest) {
        # wait for the child status check, then capture the window and the displayed values; nothing is clicked
        $deadline = (Get-Date).AddSeconds(45)
        while ($script:StatusProc -and -not $script:StatusProc.HasExited -and (Get-Date) -lt $deadline) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 }
        if ($script:StatusProc -and $script:StatusProc.HasExited) { Complete-StatusCheck }
        Update-WrapWidths; Show-LogTail
        $form.TopMost = $true; $form.Activate()
        for ($i = 0; $i -lt 8; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 }
        if ($Mock) {
            # screenshot hygiene: replace live event history / dates with placeholders so the published image has no personal data
            $script:Timer.Stop()
            $script:Ui.WheaVal.Text = '0      none on record'; $script:Ui.WheaVal.ForeColor = $script:Col.Green
            $script:Ui.BsodVal.Text = '0      none on record'; $script:Ui.BsodVal.ForeColor = $script:Col.Green
            $script:Ui.MonVal.Text = 'health monitor not installed'; $script:Ui.MonVal.ForeColor = $script:Col.Muted
            $script:Ui.MonAge.Text = 'health monitor: not installed'; $script:Ui.Dot.Tag = $script:Col.Muted; $script:Ui.Dot.Invalidate()
            $script:Ui.SinceKey.Text = 'Since install'; $script:Ui.SinceVal.Text = 'n/a'; $script:Ui.SinceVal.ForeColor = $script:Col.Muted
            $script:Ui.UpSub.Text = 'since install'
            $script:Ui.Updated.Text = 'Last updated: just now'
            [System.Windows.Forms.Application]::DoEvents()
        }
        $outDir = if ($SelfTestOut) { $SelfTestOut } else { Join-Path $PSScriptRoot 'data\selftest' }
        New-Item -ItemType Directory -Force $outDir | Out-Null
        # PNGs go through a MemoryStream: GDI+ cannot save to paths longer than 260 characters
        $savePng = { param($Bitmap, $Path) $ms = New-Object IO.MemoryStream; $Bitmap.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png); [IO.File]::WriteAllBytes($Path, $ms.ToArray()); $ms.Dispose(); $Bitmap.Dispose() }
        $bmp = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
        $form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
        & $savePng $bmp (Join-Path $outDir 'selftest.png')
        try {
            $scr = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
            $g = [System.Drawing.Graphics]::FromImage($scr); $g.CopyFromScreen($form.Location, [System.Drawing.Point]::Empty, $form.Size); $g.Dispose()
            & $savePng $scr (Join-Path $outDir 'selftest_screen.png')
        } catch { Write-GuiLog "Self-test screen capture failed: $($_.Exception.Message)" 'WARN' }
        [ordered]@{
            Elevated = $script:IsAdmin; Commands = $script:Commands; ModuleError = $script:ModuleError; DeviceDpi = $form.DeviceDpi
            Profile = $script:Ui.ProfileVal.Text; ProfileSub = $script:Ui.ProfileSub.Text
            PCap = $script:Ui.PCapVal.Text; PCapSub = $script:Ui.PCapSub.Text; ECap = $script:Ui.ECapVal.Text; ECapSub = $script:Ui.ECapSub.Text
            Overlays = $script:Ui.OvlVal.Text; OverlaysSub = $script:Ui.OvlSub.Text; OverlaysTip = $script:Tips.GetToolTip($script:Ui.OvlVal)
            Uptime = "$($script:Ui.UpVal.Text) ($($script:Ui.UpSub.Text))"
            Whea24 = $script:Ui.WheaVal.Text; Bsod24 = $script:Ui.BsodVal.Text; SinceInstall = "$($script:Ui.SinceKey.Text): $($script:Ui.SinceVal.Text)"; Monitor = $script:Ui.MonVal.Text
            MonitorDot = ([System.Drawing.Color]$script:Ui.Dot.Tag).Name; Banner = $script:Ui.Banner.Tag; Note = $script:Ui.Note.Text; LastUpdated = $script:Ui.Updated.Text
            LogTail = $script:Ui.Log.Text; ProfileButtonsEnabled = $script:Ui.ProfileButtons['Productivity'].Enabled
            HighlightedProfile = @($script:Ui.ProfileButtons.Keys | Where-Object { $script:Ui.ProfileButtons[$_].BackColor -eq $script:Col.Blue })
            ClipboardText = Get-StatusText; WindowSize = "$($form.Width)x$($form.Height)"
            Screen = '{0} working area {1}' -f [System.Windows.Forms.Screen]::FromControl($form).DeviceName, [System.Windows.Forms.Screen]::FromControl($form).WorkingArea
            LogBoxSize = "$($script:Ui.Log.Width)x$($script:Ui.Log.Height)"
        } | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $outDir 'selftest.json') -Encoding utf8
        Write-GuiLog "Self-test captured to $outDir"
        $form.Close()
    }
})

[System.Windows.Forms.Application]::Run($form)
