#Requires -Version 5.1
# AutoInstaller v3 - แยกหน้า User (เลือกแล้วกดติดตั้ง) กับหน้า Admin (จัดการรายการโปรแกรม)
# รองรับ 3 แบบ: winget (ระบุ id), url (ดาวน์โหลดตัวติดตั้งตรง) และ file (ไฟล์ตัวติดตั้งในโฟลเดอร์ Installers)

param([string]$BaseDir, [string]$EmbeddedFonts, [string]$EmbeddedInstallers, [string]$AppsPath, [switch]$Auto, [switch]$Go, [switch]$Prefetch, [switch]$Updated)

# --- เวอร์ชันและอัพเดทออนไลน์ ---
$script:Version   = '28.2'
$script:UpdateUrl  = 'https://raw.githubusercontent.com/borssza74/auto-installer-update/main'

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:Prefetch = [bool]$Prefetch
$ScriptDir = if ($BaseDir) { $BaseDir } else { $PSScriptRoot }
$ScriptDir = ([string]$ScriptDir).TrimEnd('\', '.')
if (-not $ScriptDir) { $ScriptDir = (Get-Location).Path }
# ไม่สร้างไฟล์ข้าง exe: เก็บทุกอย่างที่ต้องจำไว้ใน %ProgramData%\AutoInstaller
$DataDir = Join-Path $env:ProgramData 'AutoInstaller'
try { if (-not (Test-Path -LiteralPath $DataDir)) { [void](New-Item -ItemType Directory -Path $DataDir -Force) } } catch { $DataDir = $env:TEMP }
$AppsSaveFile = Join-Path $DataDir 'apps.json'
# รายการโปรแกรม: (โหมด /auto เท่านั้น) apps.json ข้าง exe -> apps.json ที่แก้ไว้ใน DataDir -> รายการที่ฝังใน exe
$AppsFile = $AppsSaveFile
$besideApps = Join-Path $ScriptDir 'apps.json'
if ($Auto -and (Test-Path -LiteralPath $besideApps)) { $AppsFile = $besideApps }
elseif (-not (Test-Path -LiteralPath $AppsSaveFile) -and $AppsPath) { $AppsFile = $AppsPath }
$SettingsFile = Join-Path $DataDir 'settings.json'
$InstallLog   = Join-Path $DataDir 'AutoInstaller-install.log'

# แยกพาธแบบมีเครื่องหมาย * (เช่น Installers\NVIDIA\*.exe) เป็นโฟลเดอร์กับชื่อไฟล์ โดยไม่ใช้ Join-Path/Split-Path กับตัวอักษรพิเศษ
function Resolve-InstallerPath([string]$spec) {
    $isAbs = ($spec -match '^[A-Za-z]:\\') -or $spec.StartsWith('\\')
    $full = if ($isAbs) { $spec } else { $ScriptDir + '\' + $spec }
    $i = $full.LastIndexOf('\')
    $dir = $full.Substring(0, $i)
    $leaf = $full.Substring($i + 1)
    return [pscustomobject]@{ Dir = $dir; Leaf = $leaf }
}

# ---------- ขอสิทธิ์ Administrator ----------
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin  = ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$PSCommandPath`" -BaseDir `"$ScriptDir`""
    exit
}

# ---------- ตรวจสอบอัพเดทออนไลน์ ----------
# ถ้า $UpdateUrl ถูกตั้งค่า → เช็ค version.json จาก GitHub ก่อนเปิดหน้าต่าง
# ถ้ามีเวอร์ชันใหม่ → ดาวน์โหลด apps.json + ps1 ใหม่ → re-exec ด้วย -Updated กันลูป
# เทคนิค: ใช้ Start-Process -PassThru + WaitForExit() เพื่อให้ ps1 ตัวเก่ารอ ps1 ใหม่ทำงานเสร็จ
# ก่อนจะ exit → launcher.c เห็น ps1 ตัวเก่ายังทำงานอยู่ → ไม่ลบ temp dir (Fonts/Installers ปลอดภัย)
function Invoke-OnlineUpdate {
    if ($Updated -or -not $script:UpdateUrl) { return }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $base = $script:UpdateUrl.TrimEnd('/')
        $oldProg = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
        try {
            # 1) เช็คเวอร์ชัน (ไฟล์เล็ก timeout 5 วินาที)
            $vj = Invoke-RestMethod -Uri "$base/version.json" -UseBasicParsing -TimeoutSec 5
            $remote = [version]$vj.version
            $local  = [version]$script:Version
            if ($remote -le $local) { return }
            # 2) ดาวน์โหลด apps.json ใหม่
            $aTmp = Join-Path $env:TEMP "ai-apps-$PID.json"
            Invoke-WebRequest -Uri "$base/apps.json" -OutFile $aTmp -UseBasicParsing -TimeoutSec 15
            Copy-Item -LiteralPath $aTmp -Destination $AppsSaveFile -Force
            Remove-Item $aTmp -Force -ErrorAction SilentlyContinue
            $script:AppsFile = $AppsSaveFile
            # 3) ดาวน์โหลด ps1 ใหม่
            $pTmp = Join-Path $env:TEMP "ai-ps1-$PID.ps1"
            Invoke-WebRequest -Uri "$base/AutoInstaller.ps1" -OutFile $pTmp -UseBasicParsing -TimeoutSec 30
            $hOld = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
            $hNew = (Get-FileHash -LiteralPath $pTmp -Algorithm SHA256).Hash
            if ($hOld -eq $hNew) {
                # เฉพาะ apps.json เปลี่ยน ไม่ต้อง re-exec
                $script:Version = [string]$remote
                Remove-Item $pTmp -Force -ErrorAction SilentlyContinue
                return
            }
            # บันทึกสำเนาไว้ใน cache (สำหรับอนาคต launcher.c จะเช็คจากที่นี่)
            $cacheDir = Join-Path $DataDir 'cache'
            if (-not (Test-Path -LiteralPath $cacheDir)) { [void](New-Item -ItemType Directory -Path $cacheDir -Force) }
            Copy-Item -LiteralPath $pTmp -Destination (Join-Path $cacheDir 'AutoInstaller.ps1') -Force
            # เขียนทับ ps1 ตัวปัจจุบัน (ตัวเก่าโหลดใน RAM แล้ว เขียนทับไฟล์ได้ปลอดภัย)
            Copy-Item -LiteralPath $pTmp -Destination $PSCommandPath -Force
            Remove-Item $pTmp -Force -ErrorAction SilentlyContinue
            # re-exec: เปิด ps1 ใหม่ + รอให้เสร็จก่อน exit (เพื่อไม่ให้ launcher.c ลบ temp dir)
            $a = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "' + $PSCommandPath + '" -Updated'
            if ($BaseDir)            { $a += ' -BaseDir "' + $BaseDir + '"' }
            if ($EmbeddedFonts)      { $a += ' -EmbeddedFonts "' + $EmbeddedFonts + '"' }
            if ($EmbeddedInstallers) { $a += ' -EmbeddedInstallers "' + $EmbeddedInstallers + '"' }
            if ($AppsPath)           { $a += ' -AppsPath "' + $AppsPath + '"' }
            if ($Auto)    { $a += ' -Auto' }
            if ($Go)      { $a += ' -Go' }
            if ($Prefetch){ $a += ' -Prefetch' }
            $proc = Start-Process powershell.exe -ArgumentList $a -PassThru
            $proc.WaitForExit()
            exit $proc.ExitCode
        } finally {
            $ProgressPreference = $oldProg
        }
    } catch {
        # ออฟไลน์หรือ URL ไม่ถูกต้อง — ข้ามอัพเดท ใช้เวอร์ชันปัจจุบัน
    }
}
Invoke-OnlineUpdate

$script:Apps       = @()
$script:Cancel     = $false
$script:Busy       = $false
$script:LogBuilder = New-Object System.Text.StringBuilder
$script:LogBox     = $null

# ---------- บันทึกความคืบหน้า ----------
function Write-Log([string]$msg) {
    $line = ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $msg)
    [void]$script:LogBuilder.AppendLine($line)
    if ($script:LogBox) { $script:LogBox.AppendText($line + "`r`n") }
    try { Add-Content -LiteralPath $InstallLog -Value $line -Encoding UTF8 } catch {}
    [System.Windows.Forms.Application]::DoEvents()
}

# ---------- บันทึกสิ่งที่โปรแกรมนี้ลงไว้ (ใช้สำหรับปุ่มลบ) ----------
$UndoFile = Join-Path $env:ProgramData 'AutoInstaller\installed.json'
$script:Undo = New-Object System.Collections.ArrayList

function Load-Undo {
    $script:Undo = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $UndoFile)) { return }
    try {
        $parsed = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $UndoFile -Raw -Encoding UTF8)
        foreach ($x in $parsed) {
            if ($x -is [System.Array]) { foreach ($y in $x) { [void]$script:Undo.Add($y) } }
            elseif ($null -ne $x) { [void]$script:Undo.Add($x) }
        }
    } catch { }
}

function Save-Undo {
    try {
        $dir = Split-Path -Parent $UndoFile
        if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        $json = if ($script:Undo.Count -eq 0) { '[]' } else { ConvertTo-Json -InputObject $script:Undo.ToArray() -Depth 6 }
        Set-Content -LiteralPath $UndoFile -Value $json -Encoding UTF8
    } catch { }
}

function Add-Undo([hashtable]$h) {
    [void]$script:Undo.Add([pscustomobject]$h)
    Save-Undo
}

# ---------- รายการโปรแกรม ----------
function Get-GpuVendors {
    $v = @()
    try {
        $names = @(Get-CimInstance Win32_VideoController -ErrorAction Stop | ForEach-Object { [string]$_.Name })
        if (@($names | Where-Object { $_ -match 'NVIDIA' }).Count -gt 0)       { $v += 'nvidia' }
        if (@($names | Where-Object { $_ -match 'AMD|Radeon' }).Count -gt 0)   { $v += 'amd' }
    } catch {}
    return $v
}

function Set-Prop($o, [string]$name, $value) {
    if ($o.PSObject.Properties[$name]) { $o.$name = $value }
    else { Add-Member -InputObject $o -NotePropertyName $name -NotePropertyValue $value }
}

function Remove-Prop($o, [string]$name) {
    if ($o.PSObject.Properties[$name]) { [void]$o.PSObject.Properties.Remove($name) }
}

function Clone-App($a) {
    $c = New-Object psobject
    foreach ($p in $a.PSObject.Properties) { Add-Member -InputObject $c -NotePropertyName $p.Name -NotePropertyValue $p.Value }
    return $c
}

function Load-Apps {
    $list = New-Object System.Collections.ArrayList
    if (Test-Path -LiteralPath $AppsFile) {
        $raw = Get-Content -LiteralPath $AppsFile -Raw -Encoding UTF8
        # Windows PowerShell 5.1 ส่งอาร์เรย์ JSON กลับมาเป็นก้อนเดียว ต้องแตกทีละรายการเอง
        $parsed = ConvertFrom-Json -InputObject $raw
        foreach ($x in $parsed) {
            if ($x -is [System.Array]) { foreach ($y in $x) { [void]$list.Add($y) } }
            else { [void]$list.Add($x) }
        }
    }
    $script:Apps = $list.ToArray()
    # ค่าเริ่มต้นตอนเปิด: ใช้ค่า checked ในไฟล์ (ไม่มี = ติ๊ก) ส่วนไดรเวอร์การ์ดจอติ๊กเฉพาะยี่ห้อที่ตรวจเจอในเครื่อง
    $gpus = Get-GpuVendors
    foreach ($a in $script:Apps) {
        if ($a.gpu) { $on = ($gpus -contains ([string]$a.gpu).ToLower()) }
        elseif ($a.type -eq 'fonts') { $on = (@(Get-FontFiles ([string]$a.folder)).Count -gt 0) }
        elseif ($a.PSObject.Properties['checked']) { $on = [bool]$a.checked }
        else { $on = $true }
        Set-Prop $a 'checked' $on
    }
}

function Save-Apps {
    $out = New-Object System.Collections.ArrayList
    foreach ($a in $script:Apps) {
        $c = Clone-App $a
        if ($c.gpu -or $c.type -eq 'fonts') { Remove-Prop $c 'checked' }   # ไดรเวอร์การ์ดจอ/ฟอนต์: ตัดสินใจอัตโนมัติทุกครั้ง ไม่บันทึก
        [void]$out.Add($c)
    }
    $json = ConvertTo-Json -InputObject $out.ToArray() -Depth 5
    Set-Content -LiteralPath $AppsSaveFile -Value $json -Encoding UTF8
}

# ---------- รหัสผ่านผู้ดูแล (ไม่บังคับ) ----------
function Get-PinHash([string]$pin) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes('AutoInstaller|' + $pin))
    return ([BitConverter]::ToString($bytes) -replace '-', '')
}

function Get-AdminPinHash {
    if (-not (Test-Path -LiteralPath $SettingsFile)) { return '' }
    try {
        $s = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $SettingsFile -Raw -Encoding UTF8)
        if ($s.adminPinHash) { return [string]$s.adminPinHash }
    } catch {}
    return ''
}

function Set-AdminPinHash([string]$hash) {
    $json = ConvertTo-Json -InputObject ([pscustomobject]@{ adminPinHash = $hash })
    Set-Content -LiteralPath $SettingsFile -Value $json -Encoding UTF8
}

# รันโปรเซสแบบไม่ให้หน้าต่างค้าง คืนค่า exit code (หรือ $null ถ้าถูกหยุด)
# ---------- ช่วยกดหน้าต่างติดตั้งที่ต้องติ๊กยอมรับเงื่อนไข (เช่น LINE) ----------
function Ensure-WinApi {
    if ('AutoInstaller.Win' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System; using System.Collections.Generic; using System.Runtime.InteropServices;
namespace AutoInstaller {
  public static class Win {
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern void mouse_event(uint f, int dx, int dy, uint d, UIntPtr e);
    public static List<IntPtr> Windows(uint[] pids) {
      var res = new List<IntPtr>(); var set = new HashSet<uint>(pids);
      EnumWindows((h, l) => { uint p; GetWindowThreadProcessId(h, out p);
        if (set.Contains(p) && IsWindowVisible(h)) { RECT r; GetWindowRect(h, out r); if (r.R - r.L > 200 && r.B - r.T > 150) res.Add(h); }
        return true; }, IntPtr.Zero);
      return res;
    }
    public static int[] Rect(IntPtr h) { RECT r; GetWindowRect(h, out r); return new int[] { r.L, r.T, r.R, r.B }; }
    public static void Front(IntPtr h) { SetForegroundWindow(h); }
    public static void Click(int x, int y) { SetCursorPos(x, y); mouse_event(2, 0, 0, 0, UIntPtr.Zero); mouse_event(4, 0, 0, 0, UIntPtr.Zero); }
  }
}
'@
}

function Find-UiaElement($hwnd, [string]$kind, [string]$namePattern) {
    try {
        Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes -ErrorAction Stop
        $root = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
        $ct = if ($kind -eq 'check') { [System.Windows.Automation.ControlType]::CheckBox } else { [System.Windows.Automation.ControlType]::Button }
        $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, $ct)
        $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)
        foreach ($e in $all) {
            if ($kind -eq 'check' -or [string]$e.Current.Name -match $namePattern) { return $e }
        }
    } catch {}
    return $null
}

function Invoke-LineAssist([int]$rootPid) {
    if ($script:LineStage -ge 2) { return }
    Ensure-WinApi
    $ids = @([uint32]$rootPid) + @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(?i)line' } | ForEach-Object { [uint32]$_.Id })
    $ws = [AutoInstaller.Win]::Windows([uint32[]]$ids)
    if ($ws.Count -eq 0) { return }
    $now = Get-Date
    if ($null -eq $script:LineT0) { $script:LineT0 = $now; $script:LineLast = $now; return }
    if (($now - $script:LineT0).TotalSeconds -lt 4) { return }
    if (($now - $script:LineLast).TotalSeconds -lt 2) { return }
    $script:LineLast = $now
    $h = $ws[0]
    [AutoInstaller.Win]::Front($h)
    $r = [AutoInstaller.Win]::Rect($h)
    $w = $r[2] - $r[0]; $ht = $r[3] - $r[1]
    if ($script:LineStage -eq 0) {
        $done = $false
        $cb = Find-UiaElement $h 'check' ''
        if ($cb) {
            try {
                $tp = $cb.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
                if ([string]$tp.Current.ToggleState -ne 'On') { $tp.Toggle() }
                $done = $true; Write-Log '    ติ๊กยอมรับเงื่อนไขในหน้าต่างติดตั้งให้แล้ว (UIA)'
            } catch {}
        }
        if (-not $done) {
            [AutoInstaller.Win]::Click([int]($r[0] + 0.077 * $w), [int]($r[1] + 0.904 * $ht))
            Write-Log '    ติ๊กยอมรับเงื่อนไขในหน้าต่างติดตั้งให้แล้ว (คลิกตามตำแหน่ง)'
        }
        $script:LineStage = 1
        return
    }
    if ($script:LineStage -eq 1) {
        $done = $false
        $bt = Find-UiaElement $h 'button' '^(?i)(install|ติดตั้ง)'
        if ($bt) {
            try {
                $ip = $bt.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
                $ip.Invoke(); $done = $true; Write-Log '    กดปุ่ม Install ให้แล้ว (UIA)'
            } catch {}
        }
        if (-not $done) {
            [AutoInstaller.Win]::Click([int]($r[0] + 0.851 * $w), [int]($r[1] + 0.872 * $ht))
            Write-Log '    กดปุ่ม Install ให้แล้ว (คลิกตามตำแหน่ง)'
        }
        $script:LineStage = 2
    }
}

function Find-UiaByName($hwnd, [string]$kind, [string]$namePattern) {
    try {
        Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes -ErrorAction Stop
        $root = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
        $ct = if ($kind -eq 'check') { [System.Windows.Automation.ControlType]::CheckBox } else { [System.Windows.Automation.ControlType]::Button }
        $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, $ct)
        foreach ($e in $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)) {
            if ([string]$e.Current.Name -match $namePattern) { return $e }
        }
    } catch {}
    return $null
}
function Invoke-GenericAssist([int]$rootPid, [string]$procPattern) {
    Ensure-WinApi
    $ids = @([uint32]$rootPid) + @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $procPattern } | ForEach-Object { [uint32]$_.Id })
    $ws = [AutoInstaller.Win]::Windows([uint32[]]$ids)
    foreach ($h in $ws) {
        $cb = Find-UiaByName $h 'check' '(?i)(agree|accept|license|ยอมรับ)'
        if ($cb) {
            try {
                $tp = $cb.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
                if ([string]$tp.Current.ToggleState -ne 'On') { $tp.Toggle(); Write-Log '    ติ๊กยอมรับเงื่อนไขให้แล้ว (UIA)' }
            } catch {}
        }
        $bt = Find-UiaByName $h 'button' '(?i)^(quick install|install|next|ติดตั้ง|ถัดไป|finish|close)$'
        if ($bt) {
            try {
                if ($bt.Current.IsEnabled) {
                    $bt.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
                    Write-Log ('    กดปุ่ม ' + $bt.Current.Name + ' ให้แล้ว (UIA)')
                }
            } catch {}
        }
    }
}

function Invoke-Proc([string]$file, [string]$arguments, [string]$outFile, [int]$timeoutSec = 0, [string]$doneCheck = '', [bool]$uiAssist = $false, [string]$uiKind = 'line') {
    $script:LineStage = 0; $script:LineT0 = $null; $script:LineLast = $null
    $lastAssist = [DateTime]::MinValue
    $doneAt = $null
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $ws = if ($uiAssist) { 'Normal' } else { 'Hidden' }
    $p = Start-Process -FilePath $file -ArgumentList $arguments -WindowStyle $ws -PassThru `
         -RedirectStandardOutput $outFile
    $null = $p.Handle   # ทำให้อ่าน ExitCode ได้แน่นอน
    while (-not $p.HasExited) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 100
        if ($script:Cancel) {
            try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}
            return $null
        }
        if ($uiAssist -and (([DateTime]::Now - $lastAssist).TotalMilliseconds -gt 800)) {
            $lastAssist = [DateTime]::Now
            try { if ($uiKind -eq 'line') { Invoke-LineAssist $p.Id } else { Invoke-GenericAssist $p.Id '(?i)foxit' } } catch { }
        }
        if ($doneCheck) {
            # ตัวติดตั้งบางตัว (เช่น LINE) ลงเสร็จแล้วแต่ไม่ยอมปิดตัวเอง: ถ้าเจอปลายทางค้างอยู่ 25 วินาที ให้ถือว่าเสร็จและปิดตัวติดตั้ง
            $hit = $false
            foreach ($c in ($doneCheck -split '\|')) { if ($c -and (Test-Path -LiteralPath ([Environment]::ExpandEnvironmentVariables($c)))) { $hit = $true; break } }
            if ($hit) { if ($null -eq $doneAt) { $doneAt = $sw.Elapsed.TotalSeconds } elseif (($sw.Elapsed.TotalSeconds - $doneAt) -gt 25) {
                try { & taskkill.exe /PID $p.Id /T /F 2>&1 | Out-Null } catch {}
                return -88888 } }
        }
        if ($timeoutSec -gt 0 -and $sw.Elapsed.TotalSeconds -gt $timeoutSec) {
            try { & taskkill.exe /PID $p.Id /T /F 2>&1 | Out-Null } catch {}
            return -99999
        }
    }
    return $p.ExitCode
}

function Get-AppTimeout($app, [int]$def) { if ($app.timeout) { return [int]$app.timeout } else { return $def } }
function Test-TimeoutOk($app, $code) {
    # ตัวติดตั้งค้างจนหมดเวลา: ถ้าโปรแกรมถูกติดตั้งแล้ว (เจอไฟล์ตาม "check") ถือว่าสำเร็จ
    if ($code -eq -88888) { Write-Log '    โปรแกรมถูกติดตั้งแล้ว (ตัวติดตั้งไม่ปิดตัวเอง จึงปิดให้) - ถือว่าสำเร็จ'; return $true }
    if ($code -ne -99999) { return $false }
    if ($app.check) {
        foreach ($cc in ([string]$app.check -split '\|')) {
            $c = [Environment]::ExpandEnvironmentVariables($cc)
            if ($c -and (Test-Path -LiteralPath $c)) { Write-Log '    ตัวติดตั้งไม่ปิดตัวเอง แต่โปรแกรมถูกติดตั้งแล้ว - ถือว่าสำเร็จ'; return $true }
        }
    }
    return $false
}

function Write-Tail([string]$outFile) {
    if (-not (Test-Path -LiteralPath $outFile)) { return }
    $lines = Get-Content -LiteralPath $outFile -Encoding UTF8 -ErrorAction SilentlyContinue |
             Where-Object { $_ -and $_.Trim() -and $_ -notmatch '^[\s\-\\|/]+$' -and $_ -notmatch '█|▒|â–|\d+(\.\d+)?\s*(KB|MB|GB)\s*/\s*\d' } |
             Select-Object -Last 4
    foreach ($l in $lines) { Write-Log ('    ' + $l.Trim()) }
}


# ---------- ตรวจว่าโปรแกรมมีในเครื่องแล้วหรือยัง (ถ้ามีแล้วจะข้าม) ----------
function Get-UninstallNames {
    if ($null -ne $script:UninstNames) { return $script:UninstNames }
    $names = New-Object System.Collections.ArrayList
    foreach ($k in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
        foreach ($e in @(Get-ItemProperty -Path $k -ErrorAction SilentlyContinue)) { if ($e.DisplayName) { [void]$names.Add([string]$e.DisplayName) } }
    }
    $script:UninstNames = $names.ToArray()
    return $script:UninstNames
}

# ---- ตรวจว่า task ตั้งค่าเสร็จแล้วหรือยัง ----
function Test-TaskDone($app) {
    try { switch ([string]$app.task) {
        'timezone'    { if ((Get-TimeZone).Id -eq 'SE Asia Standard Time') { return 'โซนเวลากรุงเทพ (UTC+07:00)' } }
        'thai-input'  { foreach ($l in (Get-WinUserLanguageList)) { if ([string]$l.LanguageTag -like 'th*') { return 'ภาษาไทย' } } }
        'thai-region' { if ((Get-Culture).Name -eq 'th-TH') { return 'ไทย (th-TH)' } }
        'thai-locale' { if ((Get-WinSystemLocale).Name -eq 'th-TH') { return 'non-Unicode ภาษาไทย' } }
        'lang-hotkey' {
            $key = 'HKCU:\Keyboard Layout\Toggle'
            if (Test-Path -LiteralPath $key) {
                $v = (Get-ItemProperty -LiteralPath $key -Name 'Language Hotkey' -ErrorAction SilentlyContinue).'Language Hotkey'
                if ([string]$v -eq '4') { return 'ปุ่ม ` (Grave)' }
            }
        }
        'desktop-icons' {
            $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel'
            if (-not (Test-Path -LiteralPath $key)) { return '' }
            $gs = @('{20D04FE0-3AEA-1069-A2D8-08002B30309D}','{645FF040-5081-101B-9F08-00AA002F954F}',
                    '{59031a47-3f72-44a7-89c5-5595fe6b30ee}','{5399E694-6CE5-4D6D-8792-F2EA6BA3EA82}')
            foreach ($g in $gs) {
                $v = (Get-ItemProperty -LiteralPath $key -Name $g -ErrorAction SilentlyContinue).$g
                if ($null -eq $v -or [int]$v -ne 0) { return '' }
            }
            return 'ไอคอนเดสก์ท็อปครบ 4 ตัว'
        }
        'chrome-thai' {
            $key = 'HKLM:\SOFTWARE\Policies\Google\Chrome'
            if (Test-Path -LiteralPath $key) {
                $v = (Get-ItemProperty -LiteralPath $key -Name 'ApplicationLocaleValue' -ErrorAction SilentlyContinue).ApplicationLocaleValue
                if ([string]$v -eq 'th') { return 'Chrome ภาษาไทย' }
            }
        }
        'web-shortcuts' {
            $pubDesk = Join-Path $env:PUBLIC 'Desktop'; $userDesk = [Environment]::GetFolderPath('Desktop')
            foreach ($nm in @('Facebook','YouTube','Messenger')) {
                $ok = $false
                foreach ($dd in @($pubDesk,$userDesk)) { foreach ($ext in @('.lnk','.url')) { if (Test-Path -LiteralPath (Join-Path $dd ($nm + $ext))) { $ok = $true } } }
                if (-not $ok) { return '' }
            }
            return 'ช็อตคัตเว็บครบ 3 อัน'
        }
        'desktop-shortcuts' {
            # ตรวจว่ามีช็อตคัตบนเดสก์ท็อปของโปรแกรมที่ติดตั้งไว้อย่างน้อย 3 ตัวหรือยัง
            $pubDesk = Join-Path $env:PUBLIC 'Desktop'; $userDesk = [Environment]::GetFolderPath('Desktop')
            $cnt = 0
            foreach ($a in $script:Apps) {
                if (-not $a.shortcut) { continue }
                foreach ($nm in @($a.shortcut)) {
                    foreach ($dd in @($pubDesk, $userDesk)) { if (Test-Path -LiteralPath (Join-Path $dd "$nm.lnk")) { $cnt++; break } }
                    if ($cnt -gt 0) { break }
                }
            }
            if ($cnt -ge 3) { return "ช็อตคัตบนเดสก์ท็อป $cnt อัน" }
        }
    } } catch {}
    return ''
}

# ---- ตรวจว่าฟอนต์ลงเครื่องครบแล้วหรือยัง ----
function Test-FontsDone($app) {
    try {
        $files = Get-FontFiles ([string]$app.folder)
        if ($files.Count -eq 0) { return '' }
        $fontDir = Join-Path $env:windir 'Fonts'
        $reg = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
        $had = 0; $valid = 0
        foreach ($f in $files) {
            if (-not (Test-FontHeader $f.FullName)) { continue }
            $valid++
            $dest = Join-Path $fontDir $f.Name
            $kind = if ($f.Extension -match '(?i)otf|otc') { 'OpenType' } else { 'TrueType' }
            $valName = "$($f.BaseName) ($kind)"
            $same = (Test-Path -LiteralPath $dest) -and ((Get-Item -LiteralPath $dest).Length -eq $f.Length) -and
                    ($null -ne (Get-ItemProperty -LiteralPath $reg -Name $valName -ErrorAction SilentlyContinue))
            if ($same) { $had++ }
        }
        if ($valid -gt 0 -and $had -eq $valid) { return "ฟอนต์ครบ $had ตัว" }
    } catch {}
    return ''
}

# คืนข้อความบอกว่าเจออะไร (หรือ '' ถ้ายังไม่มี) ; detect = "re:ชื่อในรายการโปรแกรม|C:\path\to\file.exe"
function Test-AppInstalled($app) {
    if ($app.type -eq 'task')  { return Test-TaskDone $app }
    if ($app.type -eq 'fonts') { return Test-FontsDone $app }
    if (@('winget', 'url', 'file') -notcontains [string]$app.type) { return '' }
    $items = @()
    if ($app.detect) { $items += ([string]$app.detect -split '##') }
    if ($app.check)  { $items += ([string]$app.check -split '\|') }
    foreach ($it in $items) {
        $it = $it.Trim(); if (-not $it) { continue }
        if ($it.StartsWith('re:')) {
            $rx = $it.Substring(3)
            foreach ($n in (Get-UninstallNames)) { if ($n -match $rx) { return $n } }
        } else {
            $pth = [Environment]::ExpandEnvironmentVariables($it)
            if (Test-Path -LiteralPath $pth) { return $pth }
        }
    }
    return ''
}

# เครื่องใหม่ที่ไม่มี winget: ดาวน์โหลด App Installer จาก Microsoft มาติดตั้งให้เอง
function Ensure-Winget {
    if ($script:WingetTried) { return (Get-Command winget -ErrorAction SilentlyContinue) }
    $script:WingetTried = $true
    Write-Log '    ไม่พบ winget - กำลังติดตั้ง App Installer จาก Microsoft ...'
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $ProgressPreference = 'SilentlyContinue'
        $t = Join-Path ([IO.Path]::GetTempPath()) 'wg_boot'
        New-Item -ItemType Directory -Path $t -Force | Out-Null
        $deps = @()
        foreach ($d in @(@('https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx', 'vclibs.appx'),
                         @('https://github.com/microsoft/microsoft-ui-xaml/releases/download/v2.8.6/Microsoft.UI.Xaml.2.8.x64.appx', 'uixaml.appx'))) {
            try { Invoke-WebRequest -Uri $d[0] -OutFile (Join-Path $t $d[1]) -UseBasicParsing; $deps += (Join-Path $t $d[1]) } catch { Write-Log ('    โหลด ' + $d[1] + ' ไม่ได้: ' + $_.Exception.Message) }
        }
        # App Installer รุ่นใหม่ต้องใช้ Windows App Runtime 1.8 ก่อน
        try {
            $ra = if ($script:Is64) { 'x64' } else { 'x86' }
            $rt = Join-Path $t 'winapprt.exe'
            Invoke-WebRequest -Uri "https://aka.ms/windowsappsdk/1.8/latest/windowsappruntimeinstall-$ra.exe" -OutFile $rt -UseBasicParsing
            Write-Log '    ติดตั้ง Windows App Runtime ...'
            $rp = Start-Process -FilePath $rt -ArgumentList '--quiet' -PassThru -WindowStyle Hidden
            while (-not $rp.HasExited) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 200 }
        } catch { Write-Log ('    ติดตั้ง Windows App Runtime ไม่สำเร็จ: ' + $_.Exception.Message) }
        $bundle = Join-Path $t 'winget.msixbundle'
        Invoke-WebRequest -Uri 'https://aka.ms/getwinget' -OutFile $bundle -UseBasicParsing
        foreach ($d in $deps) { try { Add-AppxPackage -Path $d -ErrorAction Stop } catch {} }
        Add-AppxPackage -Path $bundle -ErrorAction Stop
    } catch { Write-Log ('    ติดตั้ง winget ไม่สำเร็จ: ' + $_.Exception.Message) }
    $env:Path += ';' + (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps')
    Start-Sleep -Seconds 2
    $wg = Get-Command winget -ErrorAction SilentlyContinue
    if ($wg) { Write-Log '    ติดตั้ง winget เรียบร้อย' }
    return $wg
}

function Install-Winget($app) {
    $wg = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $wg) { $wg = Ensure-Winget }
    if (-not $wg) { throw 'ไม่พบ winget และติดตั้งให้อัตโนมัติไม่สำเร็จ (ต้องมีเน็ต + Windows 10 1809 ขึ้นไป)' }
    $out = [IO.Path]::GetTempFileName()
    $argStr = "install --id `"$($app.id)`" -e --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity"
    $code = Invoke-Proc $wg.Source $argStr $out
    if ($null -eq $code) { return 'cancel' }
    Write-Tail $out
    Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
    # 0 = สำเร็จ, 0x8A150061 = มีอยู่แล้ว, 0x8A15002B = ไม่มีอัปเดตที่ใช้ได้
    if ($code -eq 0) { Add-Undo @{ kind = 'winget'; id = [string]$app.id; name = [string]$app.name }; return 'ok' }
    if ($code -in @(-1978335135, -1978335189)) { return 'exists' }
    throw "winget ส่ง exit code $code"
}


$script:Is64 = [Environment]::Is64BitOperatingSystem
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
function Get-WebText([string]$u) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $ProgressPreference = 'SilentlyContinue'
    return (Invoke-WebRequest -Uri $u -UseBasicParsing -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AutoInstaller' -TimeoutSec 30).Content
}

# หาลิงก์ดาวน์โหลดของเวอร์ชันล่าสุดจากเว็บผู้ผลิตโดยตรง (แบบเดียวกับ Ninite) ; 32-bit ใช้ url32 ถ้ามี
function Resolve-AppUrl($app) {
    $u = [string]$app.url
    if (-not $script:Is64 -and $app.url32) { $u = [string]$app.url32 }
    switch ([string]$app.resolve) {
        'vlc' {
            $arch = if ($script:Is64) { 'win64' } else { 'win32' }
            $base = "https://download.videolan.org/pub/videolan/vlc/last/$arch/"
            $m = [regex]::Match((Get-WebText $base), "vlc-[0-9][0-9.]*-$arch\.exe")
            if (-not $m.Success) { throw 'หาเวอร์ชันล่าสุดของ VLC ไม่เจอ' }
            return $base + $m.Value
        }
        'foxit' {
            # Foxit เวอร์ชันใหม่ (exe) บังคับให้กดเอง: ใช้ตัวติดตั้งแบบ MSI จากเซิร์ฟเวอร์ทางการของ Foxit แทน (ติดตั้งเงียบได้)
            $base = 'https://cdn01.foxitsoftware.com/product/reader/desktop/win/'
            foreach ($rel in @('2026.2.1/FoxitPDFReader202621_L10N_Setup.msi', '2026.1.1/FoxitPDFReader202611_L10N_Setup.msi', '2025.1.0/FoxitPDFReader20251_L10N_Setup.msi')) {
                try {
                    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                    $r = Invoke-WebRequest -Uri ($base + $rel) -Method Head -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
                    if ([int]$r.StatusCode -eq 200) { Write-Log ('    พบตัวติดตั้ง Foxit MSI: ' + $rel); return ($base + $rel) }
                } catch {}
            }
            throw 'ไม่พบตัวติดตั้ง Foxit แบบ MSI บนเซิร์ฟเวอร์'
        }
        'winrar' {
            $arch = if ($script:Is64) { 'x64' } else { 'x32' }
            $m = [regex]::Match((Get-WebText 'https://www.rarlab.com/download.htm'), "/rar/winrar-$arch-[0-9]+\.exe")
            if (-not $m.Success) { throw 'หาเวอร์ชันล่าสุดของ WinRAR ไม่เจอ' }
            return 'https://www.rarlab.com' + $m.Value
        }
    }
    return $u
}

function Install-Url($app) {
    # ลำดับ: ดาวน์โหลดตรงจากเว็บผู้ผลิต -> ถ้าไม่สำเร็จ ค่อยลอง winget (ถ้ามี/ติดตั้งให้ได้)
    try { return (Install-UrlCore $app) }
    catch {
        if (-not $app.wingetId) { throw }
        Write-Log ("    โหลดตรงไม่สำเร็จ ($($_.Exception.Message)) - ลองผ่าน winget แทน")
        return (Install-Winget ([pscustomobject]@{ id = [string]$app.wingetId; name = [string]$app.name }))
    }
}

function Copy-FileResponsive([string]$src, [string]$dst) {
    # ก๊อปไฟล์เป็นชิ้นๆ พร้อมให้หน้าต่างโปรแกรมตอบสนองระหว่างก๊อป (ไม่ค้าง "Not Responding")
    $in = $null; $out = $null
    try {
        $in = New-Object IO.FileStream($src, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $out = [IO.File]::Create($dst)
        $buf = New-Object byte[] (1MB)
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
            $out.Write($buf, 0, $n)
            if ($sw.ElapsedMilliseconds -gt 80) { [System.Windows.Forms.Application]::DoEvents(); $sw.Restart() }
        }
    } finally {
        if ($out) { $out.Dispose() }
        if ($in) { $in.Dispose() }
    }
}

function Install-UrlCore($app) {
    $dlUrl = Resolve-AppUrl $app
    if (-not $dlUrl) { throw 'ไม่ได้ระบุ URL' }
    $fileName = $app.fileName
    if (-not $fileName) {
        $fileName = [IO.Path]::GetFileName(([Uri]$dlUrl).AbsolutePath)
        if (-not $fileName -or -not [IO.Path]::HasExtension($fileName)) { $fileName = ($app.name -replace '[^\w\.-]', '_') + '.exe' }
    }
    $dest = Join-Path ([IO.Path]::GetTempPath()) $fileName
    # แคชตัวติดตั้งบนแฟลชไดรฟ์: ถ้าเคยโหลดไว้แล้ว (ไม่เกิน 45 วัน) ใช้ไฟล์นั้นเลย ไม่ต้องโหลดใหม่
    $cacheFile = Join-Path $ScriptDir ('Installers\Cache\' + $fileName)
    $fromCache = $false
    try {
        if ((Test-Path -LiteralPath $cacheFile) -and (((Get-Date) - (Get-Item -LiteralPath $cacheFile).LastWriteTime).TotalDays -le 45) -and ((Get-Item -LiteralPath $cacheFile).Length -gt 100KB)) {
            Copy-FileResponsive $cacheFile $dest
            $fromCache = $true
            Write-Log "    ใช้ไฟล์จากแคชในแฟลชไดรฟ์ ($fileName) - ไม่ต้องดาวน์โหลด"
        }
    } catch { $fromCache = $false }

    if (-not $fromCache) {
    Write-Log "    ดาวน์โหลด $dlUrl"
    $job = Start-Job -ScriptBlock {
        param($u, $o)
        $ProgressPreference = 'SilentlyContinue'
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor 12288 } catch { try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {} }
        $errs = @()
        try { Invoke-WebRequest -Uri $u -OutFile $o -UseBasicParsing -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AutoInstaller'; if ((Test-Path $o) -and (Get-Item $o).Length -gt 0) { return } } catch { $errs += ('IWR: ' + $_.Exception.Message) }
        try { $wc = New-Object System.Net.WebClient; $wc.Headers.Add('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AutoInstaller'); $wc.DownloadFile($u, $o); if ((Test-Path $o) -and (Get-Item $o).Length -gt 0) { return } } catch { $errs += ('WebClient: ' + $_.Exception.Message) }
        try { Start-BitsTransfer -Source $u -Destination $o -ErrorAction Stop; if ((Test-Path $o) -and (Get-Item $o).Length -gt 0) { return } } catch { $errs += ('BITS: ' + $_.Exception.Message) }
        try { & curl.exe -L -f -s -o $o $u; if ($LASTEXITCODE -eq 0 -and (Test-Path $o) -and (Get-Item $o).Length -gt 0) { return } else { $errs += ('curl: exit ' + $LASTEXITCODE) } } catch { $errs += ('curl: ' + $_.Exception.Message) }
        throw ($errs -join ' | ')
    } -ArgumentList $dlUrl, $dest
    while ($job.State -eq 'Running') {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 150
        if ($script:Cancel) { Stop-Job $job; Remove-Job $job -Force; return 'cancel' }
    }
    $failed = $job.State -ne 'Completed'
    $reason = if ($failed) { $job.ChildJobs[0].JobStateInfo.Reason.Message } else { '' }
    Remove-Job $job -Force
    if ($failed) { throw "ดาวน์โหลดไม่สำเร็จ: $reason" }
    }
    # ต้องเป็นไฟล์ติดตั้งจริง (exe = MZ, msi = D0CF) ไม่ใช่หน้าเว็บ/หน้า error ที่เซิร์ฟเวอร์ตอบกลับมา
    try {
        $hb = New-Object byte[] 4; $fsx = [IO.File]::OpenRead($dest)
        try { [void]$fsx.Read($hb, 0, 4) } finally { $fsx.Dispose() }
        $okHead = (($hb[0] -eq 0x4D -and $hb[1] -eq 0x5A) -or ($hb[0] -eq 0xD0 -and $hb[1] -eq 0xCF))
    } catch { $okHead = $false }
    if (-not $okHead) { Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue; throw 'ไฟล์ที่ได้ไม่ใช่ตัวติดตั้ง (อาจเป็นหน้าเว็บ/ถูกบล็อกโดยเครือข่าย)' }

    if ($app.sha256) {
        $h = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash
        if ($h -ne ([string]$app.sha256).ToUpper()) {
            Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
            throw 'SHA256 ไม่ตรง - ยกเลิกการติดตั้งเพื่อความปลอดภัย'
        }
    }

    # ตรวจลายเซ็นดิจิทัลของผู้เผยแพร่ (ใช้แทน SHA256 กับโปรแกรมที่ตัวติดตั้งเปลี่ยนตามรุ่นตลอด)
    if ($app.signer) {
        $sj = Start-Job -ScriptBlock { param($f) $x = Get-AuthenticodeSignature -LiteralPath $f; @{ Status = [string]$x.Status; Subject = $(if ($x.SignerCertificate) { [string]$x.SignerCertificate.Subject } else { '' }) } } -ArgumentList $dest
        while ($sj.State -eq 'Running') { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 }
        $sr = @(Receive-Job $sj -ErrorAction SilentlyContinue)[0]; Remove-Job $sj -Force
        $sig = [pscustomobject]@{ Status = $(if ($sr) { $sr.Status } else { 'UnknownError' }) }
        $subj = if ($sr) { [string]$sr.Subject } else { '' }
        if ($sig.Status -ne 'Valid' -or $subj -notmatch [string]$app.signer) {
            Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
            throw "ลายเซ็นดิจิทัลของไฟล์ไม่ตรงกับผู้เผยแพร่ที่คาดไว้ (สถานะ: $($sig.Status), ผู้เซ็น: $subj) - ยกเลิกเพื่อความปลอดภัย"
        }
        Write-Log "    ตรวจลายเซ็นดิจิทัลผ่าน: $subj"
    }

    if ($script:Prefetch) {
        # โหมดเตรียมแคช: เก็บตัวติดตั้งลงแฟลชไดรฟ์ แต่ไม่ติดตั้ง
        $cd = Split-Path -Parent $cacheFile
        if (-not (Test-Path -LiteralPath $cd)) { [void](New-Item -ItemType Directory -Path $cd -Force) }
        if (-not $fromCache) { Copy-FileResponsive $dest $cacheFile; Write-Log "    เก็บไว้ในแคชแล้ว: $fileName" }
        Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
        return 'ok'
    }
    $cfgFile = $null
    $sil = if ($app.args) { [string]$app.args } elseif ($dest -like '*.msi') { '/qn /norestart' } else { '/S' }
    if ($app.config) {
        $cfgFile = Join-Path ([IO.Path]::GetTempPath()) ($fileName + '.config.xml')
        [IO.File]::WriteAllText($cfgFile, [string]$app.config, (New-Object System.Text.UTF8Encoding($false)))
        $sil = $sil.Replace('{config}', $cfgFile)
    }
    $out = [IO.Path]::GetTempFileName()
    if ($dest -like '*.msi') { $code = Invoke-Proc 'msiexec.exe' "/i `"$dest`" $sil" $out }
    else { $code = Invoke-Proc $dest $sil $out (Get-AppTimeout $app 1800) ([string]$app.check) ([bool]($app.ui)) ([string]$app.ui) }
    Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
    $okc = @(0, 3010); if ($app.okCodes) { $okc += @($app.okCodes | ForEach-Object { [int]$_ }) }
    if ((-not $fromCache) -and $null -ne $code -and ($code -in $okc) -and (Test-Path -LiteralPath $dest)) {
        # ติดตั้งสำเร็จแล้ว: เก็บตัวติดตั้งไว้ในแฟลชไดรฟ์ รอบหน้าจะเร็วขึ้น
        try {
            $cd = Split-Path -Parent $cacheFile
            if (-not (Test-Path -LiteralPath $cd)) { [void](New-Item -ItemType Directory -Path $cd -Force) }
            Copy-FileResponsive $dest $cacheFile
            Write-Log '    เก็บตัวติดตั้งไว้ในแคช (Installers\Cache) สำหรับเครื่องถัดไป'
        } catch {}
    }
    Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
    if ($cfgFile) { Remove-Item -LiteralPath $cfgFile -Force -ErrorAction SilentlyContinue }
    if ($null -eq $code) { return 'cancel' }
    if ($code -in $okc -or (Test-TimeoutOk $app $code)) {
        if ($code -eq 1638) { Write-Log '    มีเวอร์ชันใหม่กว่าติดตั้งอยู่แล้ว - ถือว่าสำเร็จ' }
        if ($app.wingetId) { Add-Undo @{ kind = 'winget'; id = [string]$app.wingetId; name = [string]$app.name; viaUrl = $true } }
        return 'ok'
    }
    if ($code -eq -99999) { throw 'ตัวติดตั้งค้างจนหมดเวลา (ถูกปิดแล้ว)' }
    throw "ตัวติดตั้งส่ง exit code $code"
}

function Find-ImgFile([string]$name) {
    # หาไฟล์ .img/.iso (Office ออฟไลน์) ในโฟลเดอร์โปรแกรม, Installers, Installers\Office, Downloads และรากของทุกไดรฟ์
    $dirs = @($ScriptDir, (Join-Path $ScriptDir 'Installers'), (Join-Path $ScriptDir 'Installers\Office'), (Join-Path $env:USERPROFILE 'Downloads'))
    foreach ($d in @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        if ($d.Root) { $dirs += $d.Root; $dirs += (Join-Path $d.Root 'Installers\Office'); $dirs += (Join-Path $d.Root 'Installers') }
    }
    foreach ($d in ($dirs | Select-Object -Unique)) {
        if (-not $d -or -not (Test-Path -LiteralPath $d)) { continue }
        $f = Join-Path $d $name
        if (Test-Path -LiteralPath $f) { return [pscustomobject]@{ FullName = (Get-Item -LiteralPath $f).FullName; Parts = @() } }
        # แฟลชไดรฟ์ FAT32 เก็บไฟล์ใหญ่กว่า 4 GB ไม่ได้: ไฟล์ถูกแบ่งเป็น ชื่อ.img.001, .002, ... แล้วต่อกลับตอนติดตั้ง
        $pp = @(Get-ChildItem -LiteralPath $d -Filter ($name + '.0*') -File -ErrorAction SilentlyContinue | Sort-Object Name)
        if ($pp.Count -gt 0) { return [pscustomobject]@{ FullName = (Join-Path $d $name); Parts = @($pp | ForEach-Object { $_.FullName }) } }
    }
    return $null
}

function Install-Img($app, $img) {
    Write-Log "    ติดตั้งจากไฟล์ออฟไลน์ $($img.FullName)"
    $di = $null; $root = $null
    $imgPath = $img.FullName; $joined = $null
    if ($img.Parts -and $img.Parts.Count -gt 0) {
        $tot = 0; foreach ($pf in $img.Parts) { $tot += (Get-Item -LiteralPath $pf).Length }
        $tmpRoot = [IO.Path]::GetTempPath()
        $free = (New-Object IO.DriveInfo($tmpRoot.Substring(0,1))).AvailableFreeSpace
        if ($free -lt ($tot + 1GB)) { throw ('พื้นที่ว่างในเครื่องไม่พอสำหรับต่อไฟล์ .img (ต้องการ ' + [math]::Round(($tot + 1GB) / 1GB, 1) + ' GB)') }
        $joined = Join-Path $tmpRoot ('AI_' + [IO.Path]::GetFileName($img.FullName))
        Write-Log ('    กำลังต่อไฟล์ .img จาก ' + $img.Parts.Count + ' ชิ้น (ใช้เวลาสักครู่) ...')
        $out = [IO.File]::Create($joined)
        try {
            $buf = New-Object byte[] (8MB)
            foreach ($pf in $img.Parts) {
                $in = [IO.File]::OpenRead($pf)
                try { while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) { $out.Write($buf, 0, $n); [System.Windows.Forms.Application]::DoEvents(); if ($script:Cancel) { throw 'ยกเลิก' } } } finally { $in.Dispose() }
            }
        } catch { $out.Dispose(); Remove-Item -LiteralPath $joined -Force -ErrorAction SilentlyContinue; throw } 
        $out.Dispose()
        $imgPath = $joined
    }
    try {
        $di = Mount-DiskImage -ImagePath $imgPath -PassThru -ErrorAction Stop
        for ($i = 0; $i -lt 20 -and -not $root; $i++) {
            Start-Sleep -Milliseconds 500
            $v = $di | Get-Volume -ErrorAction SilentlyContinue
            if ($v -and $v.DriveLetter) { $root = ([string]$v.DriveLetter) + ':\' }
        }
    } catch { throw "เมานต์ไฟล์ .img ไม่ได้: $($_.Exception.Message)" }
    if (-not $root) { try { Dismount-DiskImage -ImagePath $imgPath | Out-Null } catch {}; if ($joined) { Remove-Item -LiteralPath $joined -Force -ErrorAction SilentlyContinue }; throw 'เมานต์ไฟล์ .img แล้วไม่พบตัวอักษรไดรฟ์' }
    try {
        $setup = Join-Path $root 'setup.exe'
        if (-not (Test-Path -LiteralPath $setup)) {
            $setup = (Get-ChildItem -LiteralPath $root -Filter 'setup*.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
        }
        if (-not $setup) { throw 'ไม่พบ setup.exe ในไฟล์ .img' }
        $paths = @(); foreach ($x in ([string]$app.detect -split '##')) { if ($x -and $x -notmatch '^re:') { $paths += [Environment]::ExpandEnvironmentVariables($x) } }
        $out = [IO.Path]::GetTempFileName()
        $tmo = Get-AppTimeout $app 3600
        $code = Invoke-Proc $setup ' ' $out $tmo '' $false
        Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
        if ($null -eq $code) { return 'cancel' }
        # ตัวติดตั้ง Office ส่งต่อให้ ClickToRun ทำงานต่อเบื้องหลัง: รอจนเสร็จ (เจอไฟล์โปรแกรม และ ClickToRun หยุดทำงาน)
        $sw = [Diagnostics.Stopwatch]::StartNew(); $ok = $false; $idle = 0
        while ($sw.Elapsed.TotalSeconds -lt $tmo) {
            [System.Windows.Forms.Application]::DoEvents()
            if ($script:Cancel) { return 'cancel' }
            Start-Sleep -Milliseconds 1500
            $have = $false; foreach ($pp in $paths) { if (Test-Path -LiteralPath $pp) { $have = $true; break } }
            $busy = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(OfficeC2RClient|OfficeClickToRun|setup)$' }).Count -gt 0
            if ($have -and -not $busy) { $idle++ } else { $idle = 0 }
            if ($idle -ge 6) { $ok = $true; break }
        }
        if (-not $ok) { throw 'ติดตั้ง Office จากไฟล์ .img ไม่สำเร็จหรือใช้เวลานานเกินกำหนด' }
        return 'ok'
    } finally {
        try { Dismount-DiskImage -ImagePath $imgPath | Out-Null } catch {}
        if ($joined) { Remove-Item -LiteralPath $joined -Force -ErrorAction SilentlyContinue }
    }
}

function Install-File($app) {
    if (-not $app.file) { throw 'ไม่ได้ระบุไฟล์ตัวติดตั้ง' }
    if ($app.img) {
        $imgf = Find-ImgFile ([string]$app.img)
        if ($imgf) {
            try { return (Install-Img $app $imgf) }
            catch { Write-Log ("    ติดตั้งจาก .img ไม่สำเร็จ: " + $_.Exception.Message + ' - ลองวิธีตัวติดตั้งออนไลน์แทน') }
        }
    }
    if ($app.gpu -and ((Get-GpuVendors) -notcontains ([string]$app.gpu).ToLower())) {
        Write-Log "    ไม่พบการ์ดจอ $($app.gpu) ในเครื่องนี้ - ข้าม"
        return 'skip'
    }
    $f = [string]$app.file
    $r = Resolve-InstallerPath $f
    $pattern = $r.Dir + '\' + $r.Leaf
    $found = $null
    if (Test-Path -LiteralPath $r.Dir) {
        $cands = @(Get-ChildItem -LiteralPath $r.Dir -Filter $r.Leaf -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
        if ($app.chassis) {
            # ไดรเวอร์โน้ตบุ๊กกับเดสก์ท็อปเป็นคนละไฟล์: ดูว่าเครื่องนี้มีแบตเตอรี่ไหม แล้วเลือกไฟล์ที่ชื่อตรงกัน
            $isNb = $false
            try { $isNb = [bool](Get-CimInstance Win32_Battery -ErrorAction Stop) } catch { try { $isNb = [bool](Get-WmiObject Win32_Battery) } catch {} }
            $pick = @($cands | Where-Object { ($_.Name -match 'notebook') -eq $isNb })
            Write-Log ('    เครื่องนี้เป็น' + $(if ($isNb) { 'โน้ตบุ๊ก' } else { 'เดสก์ท็อป' }) + ' - เลือกไดรเวอร์ให้ตรงรุ่น')
            $cands = $pick
        }
        $found = $cands | Select-Object -First 1
    }
    if (-not $found -and $app.alt) {
        $found = Get-ChildItem -LiteralPath $ScriptDir -Filter ([string]$app.alt) -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    }
    if (-not $found -and $EmbeddedInstallers -and ($f -match '^Installers\\(.+)$')) {
        $alt = $EmbeddedInstallers.TrimEnd('\') + '\' + $Matches[1]
        $ai = $alt.LastIndexOf('\')
        $ad = $alt.Substring(0, $ai); $al = $alt.Substring($ai + 1)
        if (Test-Path -LiteralPath $ad) {
            $found = Get-ChildItem -LiteralPath $ad -Filter $al -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { Write-Log '    ใช้ตัวติดตั้งที่ฝังอยู่ในโปรแกรม' }
        }
    }
    if (-not $found -and $app.url) {
        Write-Log "    ไม่พบไฟล์ในเครื่อง ($pattern) - ดาวน์โหลดจากเว็บทางการแทน"
        return (Install-Url $app)
    }
    if (-not $found -and $app.optional) {
        Write-Log '    ไม่มีไฟล์ตัวติดตั้งที่ตรงกับเครื่องนี้วางไว้ - ข้ามรายการนี้'
        return 'exists'
    }
    if (-not $found) {
        $hint = if ($app.pageUrl) { " - ดาวน์โหลดตัวติดตั้งได้ที่ $($app.pageUrl)" } else { '' }
        throw "ไม่พบไฟล์ตัวติดตั้งที่ $pattern$hint"
    }
    Write-Log "    ใช้ไฟล์ $($found.Name)"

    if ($app.sha256) {
        $h = (Get-FileHash -LiteralPath $found.FullName -Algorithm SHA256).Hash
        if ($h -ne ([string]$app.sha256).ToUpper()) { throw 'SHA256 ไม่ตรง - ยกเลิกการติดตั้งเพื่อความปลอดภัย' }
    }

    $out = [IO.Path]::GetTempFileName()
    if ($found.Extension -eq '.msi') {
        $sil = if ($app.args) { [string]$app.args } else { '/qn /norestart' }
        $code = Invoke-Proc 'msiexec.exe' "/i `"$($found.FullName)`" $sil" $out
    } else {
        $sil = if ($app.args) { [string]$app.args } else { '/S' }
        $code = Invoke-Proc $found.FullName $sil $out (Get-AppTimeout $app 1800) ([string]$app.check) ([bool]($app.ui)) ([string]$app.ui)
    }
    Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
    if ($null -eq $code) { return 'cancel' }
    $okc = @(0, 3010); if ($app.okCodes) { $okc += @($app.okCodes | ForEach-Object { [int]$_ }) }
    if ($code -in $okc -or (Test-TimeoutOk $app $code)) { return 'ok' }
    # exit code ไม่ตรง → ตรวจว่าโปรแกรมติดตั้งจริงหรือเปล่า (บางตัวเช่น NVIDIA return 1 แต่ลงสำเร็จ)
    if ($code -notin @(-99999)) {
        $script:UninstNames = $null
        $hit = ''; try { $hit = Test-AppInstalled $app } catch {}
        if ($hit) { Write-Log "    exit code $code แต่พบโปรแกรมในเครื่องแล้ว ($hit) - ถือว่าสำเร็จ"; return 'ok' }
    }
    if ($code -eq -99999) { throw 'ตัวติดตั้งค้างจนหมดเวลา (ถูกปิดแล้ว)' }
    throw "ตัวติดตั้งส่ง exit code $code"
}

# ---------- ฟอนต์ ----------
function Get-FontFiles([string]$spec) {
    # ฟอนต์จากโฟลเดอร์ข้างโปรแกรม (ถ้ามี) + ฟอนต์ที่ฝังอยู่ใน exe (ชื่อซ้ำ ใช้ไฟล์ในโฟลเดอร์ก่อน)
    $byName = @{}
    $dirs = @()
    if ($EmbeddedFonts) { $dirs += ([string]$EmbeddedFonts).TrimEnd('\') }
    if ($spec) {
        $isAbs = ($spec -match '^[A-Za-z]:\\') -or $spec.StartsWith('\\')
        $d = if ($isAbs) { $spec } else { $ScriptDir + '\' + $spec }
        $dirs += $d.TrimEnd('\')
    }
    foreach ($dir in $dirs) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        $found = @(Get-ChildItem -LiteralPath $dir -Recurse -File -ErrorAction SilentlyContinue |
                   Where-Object { $_.Extension -match '^\.(ttf|otf|ttc|otc)$' })
        foreach ($f in $found) { $byName[$f.Name.ToLower()] = $f }
    }
    return @($byName.Values | Sort-Object Name)
}

# ตรวจว่าเป็นไฟล์ฟอนต์จริง (หัวไฟล์ TrueType/OpenType/Collection) ก่อนลงเครื่อง
function Test-FontHeader([string]$path) {
    try {
        $fs = [System.IO.File]::OpenRead($path)
        try { $b = New-Object byte[] 4; [void]$fs.Read($b, 0, 4) } finally { $fs.Dispose() }
        $t = [System.Text.Encoding]::ASCII.GetString($b)
        return ($t -eq 'OTTO') -or ($t -eq 'ttcf') -or ($t -eq 'true') -or ($b[0] -eq 0 -and $b[1] -eq 1 -and $b[2] -eq 0 -and $b[3] -eq 0)
    } catch { return $false }
}

function Ensure-FontApi {
    if ('AutoInstaller.FontApi' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace AutoInstaller {
    public static class FontApi {
        [DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
        public static extern int AddFontResource(string file);
        [DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
        public static extern bool RemoveFontResource(string file);
        [DllImport("user32.dll", CharSet = CharSet.Auto)]
        public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out IntPtr result);
    }
}
'@
}

function Install-Fonts($app) {
    $files = Get-FontFiles ([string]$app.folder)
    if ($files.Count -eq 0) {
        Write-Log '    ไม่มีไฟล์ฟอนต์ในโฟลเดอร์ (ข้าม) - วางไฟล์ .ttf/.otf ไว้ในโฟลเดอร์ Fonts ข้างโปรแกรม'
        return 'skip'
    }
    Ensure-FontApi
    $fontDir = Join-Path $env:windir 'Fonts'
    $reg = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
    $added = 0; $had = 0; $failed = 0; $bad = 0
    foreach ($f in $files) {
        if ($script:Cancel) { return 'cancel' }
        if (-not (Test-FontHeader $f.FullName)) { $bad++; Write-Log "    ข้าม $($f.Name): ไฟล์ไม่ใช่ฟอนต์ที่ถูกต้อง (หัวไฟล์ผิด)"; continue }
        try {
            $dest = Join-Path $fontDir $f.Name
            $kind = if ($f.Extension -match '(?i)otf|otc') { 'OpenType' } else { 'TrueType' }
            $valName = "$($f.BaseName) ($kind)"
            $same = (Test-Path -LiteralPath $dest) -and ((Get-Item -LiteralPath $dest).Length -eq $f.Length) -and
                    ($null -ne (Get-ItemProperty -LiteralPath $reg -Name $valName -ErrorAction SilentlyContinue))
            if ($same) { $had++; continue }
            $existedBefore = Test-Path -LiteralPath $dest
            Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
            [void](New-ItemProperty -LiteralPath $reg -Name $valName -Value $f.Name -PropertyType String -Force)
            [void][AutoInstaller.FontApi]::AddFontResource($dest)
            $added++
            if (-not $existedBefore) { Add-Undo @{ kind = 'font'; file = $f.Name; reg = $valName } }
        } catch {
            $failed++
            Write-Log "    ฟอนต์ $($f.Name) ล้มเหลว: $($_.Exception.Message)"
        }
        [System.Windows.Forms.Application]::DoEvents()
    }
    try {
        $r = [IntPtr]::Zero
        [void][AutoInstaller.FontApi]::SendMessageTimeout([IntPtr]0xffff, 0x001D, [IntPtr]::Zero, [IntPtr]::Zero, 2, 1000, [ref]$r)
    } catch {}
    Write-Log "    ฟอนต์ใหม่ $added ไฟล์, มีอยู่แล้ว $had ไฟล์, ล้มเหลว $failed ไฟล์, ข้าม(ไฟล์เสีย) $bad ไฟล์"
    if ($failed -gt 0) { throw "ติดตั้งฟอนต์ไม่สำเร็จ $failed ไฟล์ (ฟอนต์ที่กำลังใช้งานอยู่อาจทับไม่ได้ ลองปิดโปรแกรมที่ใช้ฟอนต์นั้นก่อน)" }
    if ($added -gt 0) { return 'ok' }
    return 'exists'
}

# ---------- ตั้งค่าเครื่อง (ภาษา / เวลา / คีย์บอร์ด) ----------
function Install-Task($app) {
    switch ([string]$app.task) {
        'timezone' {
            $prevTz = ''
            try { $prevTz = (Get-TimeZone).Id } catch {}
            $ok = $false
            try { Set-TimeZone -Id 'SE Asia Standard Time' -ErrorAction Stop; $ok = $true }
            catch {
                Write-Log "    Set-TimeZone ไม่สำเร็จ ($($_.Exception.Message)) ลองใช้ tzutil แทน"
                try { & "$env:windir\System32\tzutil.exe" /s 'SE Asia Standard Time' 2>&1 | Out-Null } catch {}
            }
            $now = ''
            try { $now = (Get-TimeZone).Id } catch {}
            if ($now -ne 'SE Asia Standard Time') { throw "ตั้งโซนเวลาไม่สำเร็จ (ตอนนี้เป็น: $now)" }
            if ($prevTz -and $prevTz -ne 'SE Asia Standard Time') { Add-Undo @{ kind = 'timezone'; prev = $prevTz } }
            Write-Log '    ตั้งโซนเวลาเป็น (UTC+07:00) กรุงเทพ/ฮานอย/จาการ์ตา แล้ว'
            # ซิงค์เวลา: จำกัดเวลาไม่เกิน 8 วินาที ไม่ให้โปรแกรมค้าง
            try {
                $svc = Get-Service -Name w32time -ErrorAction Stop
                if ($svc.Status -ne 'Running') { Start-Service -Name w32time -ErrorAction Stop }
                $p = Start-Process -FilePath "$env:windir\System32\w32tm.exe" -ArgumentList '/resync','/force' -WindowStyle Hidden -PassThru
                if (-not $p.WaitForExit(8000)) { try { $p.Kill() } catch {}; Write-Log '    (ซิงค์เวลาใช้เวลานาน ข้ามไป - โซนเวลาตั้งเรียบร้อยแล้ว)' }
                else { Write-Log '    ส่งคำสั่งซิงค์เวลาแล้ว' }
            } catch {
                Write-Log '    (ซิงค์เวลาอัตโนมัติไม่สำเร็จ ข้ามได้ - โซนเวลาตั้งเรียบร้อยแล้ว)'
            }
            return 'ok'
        }
        'thai-input' {
            $list = Get-WinUserLanguageList
            $has = $false
            foreach ($l in $list) { if ([string]$l.LanguageTag -like 'th*') { $has = $true } }
            if ($has) {
                Write-Log '    มีภาษาไทยอยู่แล้ว'
            } else {
                $prevTags = @($list | ForEach-Object { [string]$_.LanguageTag })
                $list.Add('th-TH')
                Set-WinUserLanguageList $list -Force
                Add-Undo @{ kind = 'lang'; prev = $prevTags }
                Write-Log '    เพิ่มภาษาไทยและคีย์บอร์ดไทย (เกษมณี) แล้ว - ภาษาอังกฤษยังอยู่เหมือนเดิม'
            }
            # ไม่ดาวน์โหลดชุดภาษาเพิ่ม (ช้ามากและไม่จำเป็นสำหรับการพิมพ์ไทย) - ถ้าต้องการให้เพิ่มทีหลังผ่าน Settings > Time & language
            Write-Log '    หมายเหตุ: ออกจากระบบ (Sign out) หรือรีสตาร์ทหนึ่งครั้งเพื่อให้มีผลครบทุกโปรแกรม'
            return 'ok'
        }
        'thai-locale' {
            $prev = ''
            try { $prev = (Get-WinSystemLocale).Name } catch {}
            if ($prev -eq 'th-TH') {
                Write-Log '    ภาษาสำหรับโปรแกรม non-Unicode เป็นภาษาไทยอยู่แล้ว'
                return 'exists'
            }
            Set-WinSystemLocale -SystemLocale 'th-TH'
            Add-Undo @{ kind = 'syslocale'; prev = $prev }
            Write-Log '    ตั้งภาษาสำหรับโปรแกรมที่ไม่รองรับ Unicode เป็นภาษาไทยแล้ว'
            Write-Log '    หมายเหตุ: ต้องรีสตาร์ทเครื่องหนึ่งครั้งเพื่อให้มีผล'
            return 'ok'
        }
        'thai-region' {
            $errs = @()
            $prevCulture = ''; $prevGeo = 0
            try { $prevCulture = (Get-Culture).Name } catch {}
            try { $prevGeo = [int](Get-WinHomeLocation).GeoId } catch {}
            try { Set-Culture -CultureInfo 'th-TH' -ErrorAction Stop } catch { $errs += "Set-Culture: $($_.Exception.Message)" }
            try { Set-WinHomeLocation -GeoId 227 -ErrorAction Stop } catch { $errs += "Set-WinHomeLocation: $($_.Exception.Message)" }
            foreach ($e in $errs) { Write-Log "    $e" }
            if ($errs.Count -ge 2) { throw ($errs -join ' | ') }
            if ($prevCulture -or $prevGeo) { Add-Undo @{ kind = 'region'; culture = $prevCulture; geo = $prevGeo } }
            Write-Log '    ตั้งภูมิภาคเป็นประเทศไทย และรูปแบบวันที่/เวลา/ตัวเลขเป็นแบบไทยแล้ว'
            return 'ok'
        }
        'lang-hotkey' {
            # สลับภาษาด้วยปุ่ม ` (Grave Accent) / สลับเลย์เอาต์คีย์บอร์ดด้วย Ctrl+Shift / Caps Lock ปิดด้วยปุ่ม CAPS LOCK
            $key = 'HKCU:\Keyboard Layout\Toggle'
            if (-not (Test-Path -LiteralPath $key)) { [void](New-Item -Path $key -Force) }
            $prev = @{}
            foreach ($n in @('Language Hotkey', 'Hotkey', 'Layout Hotkey')) {
                $v = (Get-ItemProperty -LiteralPath $key -Name $n -ErrorAction SilentlyContinue).$n
                $prev[$n] = $(if ($null -eq $v) { '' } else { [string]$v })
            }
            Set-ItemProperty -LiteralPath $key -Name 'Language Hotkey' -Value '4'
            Set-ItemProperty -LiteralPath $key -Name 'Hotkey' -Value '4'
            Set-ItemProperty -LiteralPath $key -Name 'Layout Hotkey' -Value '2'
            Add-Undo @{ kind = 'hotkey'; lang = $prev['Language Hotkey']; hot = $prev['Hotkey']; layout = $prev['Layout Hotkey'] }
            Write-Log '    ตั้งปุ่มสลับภาษาเป็น ` (Grave Accent) และสลับเลย์เอาต์เป็น Ctrl+Shift แล้ว'
            Write-Log '    หมายเหตุ: ออกจากระบบ (Sign out) หรือรีสตาร์ทหนึ่งครั้งเพื่อให้มีผล'
            return 'ok'
        }
        'desktop-icons' {
            # แสดงไอคอนระบบบนเดสก์ท็อป: This PC, Recycle Bin, ไฟล์ของผู้ใช้, Control Panel (ค่า 0 = แสดง)
            $guids = @('{20D04FE0-3AEA-1069-A2D8-08002B30309D}', '{645FF040-5081-101B-9F08-00AA002F954F}',
                       '{59031a47-3f72-44a7-89c5-5595fe6b30ee}', '{5399E694-6CE5-4D6D-8792-F2EA6BA3EA82}')
            $prevIcons = @()
            foreach ($k in @('NewStartPanel', 'ClassicStartMenu')) {
                $key = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\$k"
                if (-not (Test-Path -LiteralPath $key)) { [void](New-Item -Path $key -Force) }
                foreach ($g in $guids) {
                    $pv = (Get-ItemProperty -LiteralPath $key -Name $g -ErrorAction SilentlyContinue).$g
                    $prevIcons += [pscustomobject]@{ key = $k; guid = $g; value = $(if ($null -eq $pv) { -1 } else { [int]$pv }) }
                }
                foreach ($g in $guids) { [void](New-ItemProperty -LiteralPath $key -Name $g -Value 0 -PropertyType DWord -Force) }
            }
            Add-Undo @{ kind = 'icons'; prev = $prevIcons }
            try {
                if (-not ('AutoInstaller.ShellApi' -as [type])) {
                    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace AutoInstaller {
    public static class ShellApi {
        [DllImport("shell32.dll")] public static extern void SHChangeNotify(int wEventId, uint uFlags, IntPtr dwItem1, IntPtr dwItem2);
    }
}
'@
                }
                [AutoInstaller.ShellApi]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)
            } catch {}
            Write-Log '    เปิดไอคอน This PC / Recycle Bin / ไฟล์ของผู้ใช้ / Control Panel บนเดสก์ท็อปแล้ว (ถ้ายังไม่เห็น กด F5 บนเดสก์ท็อป)'
            return 'ok'
        }
        'web-shortcuts' {
            # ช็อตคัตเว็บ Facebook / YouTube / Messenger แบบเปิดเป็นหน้าต่างแอป (เหมือน "Install as app" ของ Chrome) ไว้บนเดสก์ท็อปของทุกคน
            $pubDesk = Join-Path $env:PUBLIC 'Desktop'
            $userDesk = [Environment]::GetFolderPath('Desktop')
            if (-not (Test-Path -LiteralPath $pubDesk)) { [void](New-Item -ItemType Directory -Path $pubDesk -Force) }
            $chrome = $null
            foreach ($c in @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe", "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe")) {
                if ($c -and (Test-Path -LiteralPath $c)) { $chrome = $c; break }
            }
            $sh = New-Object -ComObject WScript.Shell
            $made = 0; $had = 0
            foreach ($site in @(@('Facebook', 'https://www.facebook.com/', 'facebook.com'), @('YouTube', 'https://www.youtube.com/', 'youtube.com'), @('Messenger', 'https://www.messenger.com/', 'messenger.com'))) {
                $exists = $false
                foreach ($dd in @($pubDesk, $userDesk)) {
                    foreach ($ext in @('.lnk', '.url')) { if (Test-Path -LiteralPath (Join-Path $dd ($site[0] + $ext))) { $exists = $true } }
                }
                if ($exists) { $had++; continue }
                $icon = ''
                try {
                    $idir = Join-Path $DataDir 'icons'
                    if (-not (Test-Path -LiteralPath $idir)) { [void](New-Item -ItemType Directory -Path $idir -Force) }
                    $ico = Join-Path $idir ($site[0] + '.ico')
                    if (-not (Test-Path -LiteralPath $ico)) {
                        $png = [IO.Path]::GetTempFileName()
                        Invoke-WebRequest -Uri ('https://www.google.com/s2/favicons?domain=' + $site[2] + '&sz=128') -OutFile $png -UseBasicParsing -TimeoutSec 15
                        $pb = [IO.File]::ReadAllBytes($png); Remove-Item -LiteralPath $png -Force -ErrorAction SilentlyContinue
                        if ($pb.Length -gt 100 -and $pb[1] -eq 0x50) {
                            $w = ($pb[18] * 256 + $pb[19]); if ($w -ge 256) { $w = 0 }
                            $hd = [byte[]](0,0,1,0,1,0, $w,$w,0,0,1,0,32,0) + [BitConverter]::GetBytes([int]$pb.Length) + [BitConverter]::GetBytes([int]22)
                            [IO.File]::WriteAllBytes($ico, ($hd + $pb))
                        }
                    }
                    if (Test-Path -LiteralPath $ico) { $icon = $ico }
                } catch {}
                if ($chrome) {
                    $lnk = Join-Path $pubDesk ($site[0] + '.lnk')
                    $sc = $sh.CreateShortcut($lnk)
                    $sc.TargetPath = $chrome; $sc.Arguments = '--app=' + $site[1]
                    $sc.IconLocation = $(if ($icon) { $icon } else { "$chrome,0" })
                    $sc.Description = $site[0]; $sc.Save()
                } else {
                    $lnk = Join-Path $pubDesk ($site[0] + '.url')
                    $txt = "[InternetShortcut]`r`nURL=$($site[1])`r`n"
                    if ($icon) { $txt += "IconFile=$icon`r`nIconIndex=0`r`n" }
                    [IO.File]::WriteAllText($lnk, $txt, [Text.Encoding]::ASCII)
                }
                Add-Undo @{ kind = 'shortcut'; path = $lnk }; $made++
            }
            Write-Log "    ช็อตคัตเว็บ: สร้างใหม่ $made อัน, มีอยู่แล้ว $had อัน"
            if (-not $chrome) { Write-Log '    (ยังไม่พบ Google Chrome - สร้างเป็นช็อตคัตเว็บธรรมดา เปิดด้วยเบราว์เซอร์เริ่มต้น)' }
            return 'ok'
        }
        'chrome-thai' {
            # ตั้งภาษาของ Google Chrome เป็นภาษาไทยผ่านนโยบาย (มีผลกับทุกผู้ใช้ในเครื่อง)
            $key = 'HKLM:\SOFTWARE\Policies\Google\Chrome'
            if (-not (Test-Path -LiteralPath $key)) { [void](New-Item -Path $key -Force) }
            $prev = (Get-ItemProperty -LiteralPath $key -Name 'ApplicationLocaleValue' -ErrorAction SilentlyContinue).ApplicationLocaleValue
            Set-ItemProperty -LiteralPath $key -Name 'ApplicationLocaleValue' -Value 'th' -Type String
            Add-Undo @{ kind = 'chromelang'; prev = $(if ($null -eq $prev) { '' } else { [string]$prev }) }
            Write-Log '    ตั้ง Google Chrome เป็นภาษาไทยแล้ว (ปิดแล้วเปิด Chrome ใหม่เพื่อให้มีผล)'
            return 'ok'
        }
        'desktop-shortcuts' {
            # สร้างช็อตคัตของโปรแกรมที่ติดตั้งแล้ว (หาจากชื่อในเมนู Start) ไว้บนเดสก์ท็อปของทุกคน
            $pubDesk = Join-Path $env:PUBLIC 'Desktop'
            $userDesk = [Environment]::GetFolderPath('Desktop')
            $roots = @((Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'),
                       (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'))
            foreach ($ud in @(Get-ChildItem -LiteralPath (Join-Path $env:SystemDrive 'Users') -Directory -ErrorAction SilentlyContinue)) {
                $roots += (Join-Path $ud.FullName 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs')
            }
            $roots = @($roots | Select-Object -Unique | Where-Object { Test-Path -LiteralPath $_ })
            $lnks = @(); foreach ($r in $roots) { $lnks += @(Get-ChildItem -LiteralPath $r -Recurse -Filter '*.lnk' -File -ErrorAction SilentlyContinue) }
            $made = 0; $had = 0; $missing = @()
            foreach ($a in $script:Apps) {
                if (-not $a.shortcut) { continue }
                $found = $false
                foreach ($nm in @($a.shortcut)) {
                    $hit = $lnks | Where-Object { $_.BaseName -ieq [string]$nm } | Select-Object -First 1
                    if (-not $hit) { continue }
                    $found = $true
                    $onDesk = (Test-Path -LiteralPath (Join-Path $pubDesk $hit.Name)) -or (Test-Path -LiteralPath (Join-Path $userDesk $hit.Name))
                    if ($onDesk) { $had++ }
                    else {
                        $dst = Join-Path $pubDesk $hit.Name
                        Copy-Item -LiteralPath $hit.FullName -Destination $dst -Force; $made++
                        Add-Undo @{ kind = 'shortcut'; path = $dst }
                    }
                }
                if (-not $found) { $missing += [string]$a.name }
            }
            Write-Log "    สร้างช็อตคัตใหม่ $made อัน, มีอยู่แล้ว $had อัน"
            if ($missing.Count -gt 0) { Write-Log ('    ไม่พบในเมนู Start (ยังไม่ได้ติดตั้ง?): ' + ($missing -join ', ')) }
            if ($made -gt 0) { return 'ok' }
            return 'exists'
        }
        default { throw "ไม่รู้จักงานตั้งค่า: $($app.task)" }
    }
}

# =====================================================================
#  หน้าจอ
# =====================================================================
$script:Accent = [System.Drawing.Color]::FromArgb(37, 99, 235)
$script:Gray   = [System.Drawing.Color]::FromArgb(107, 114, 128)
$script:Ink    = [System.Drawing.Color]::FromArgb(17, 24, 39)
$script:Paper  = [System.Drawing.Color]::FromArgb(246, 247, 249)
$script:Chip   = [System.Drawing.Color]::FromArgb(230, 233, 239)

function Apply-Round($c) {
    try {
        $r = [Math]::Min(10, [int]($c.Height / 2)); $d = $r * 2
        if ($c.Width -le $d -or $c.Height -le $d) { return }
        $gp = New-Object System.Drawing.Drawing2D.GraphicsPath
        $gp.AddArc(0, 0, $d, $d, 180, 90); $gp.AddArc($c.Width - $d - 1, 0, $d, $d, 270, 90)
        $gp.AddArc($c.Width - $d - 1, $c.Height - $d - 1, $d, $d, 0, 90); $gp.AddArc(0, $c.Height - $d - 1, $d, $d, 90, 90)
        $gp.CloseFigure(); $c.Region = New-Object System.Drawing.Region($gp)
    } catch {}
}
function Set-Round($c) { $c.Add_SizeChanged({ param($s, $e) Apply-Round $s }); Apply-Round $c }
function New-Chip([string]$text) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderSize = 0
    $b.Font = New-Font 10.5; $b.Size = New-Object System.Drawing.Size(96, 36)
    $b.BackColor = $script:Chip; $b.ForeColor = $script:Ink
    $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0); $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    Set-Round $b
    return $b
}
function Set-ChipOn($b, [bool]$on) {
    if ($on) { $b.BackColor = $script:Accent; $b.ForeColor = [System.Drawing.Color]::White }
    else { $b.BackColor = $script:Chip; $b.ForeColor = $script:Ink }
}

function Uninstall-All {
    if ($script:Undo.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show('ยังไม่มีรายการที่โปรแกรมนี้เคยติดตั้งไว้ (โปรแกรมที่มีอยู่ก่อนแล้วจะไม่ถูกลบ)', 'Auto Installer', 'OK', 'Information')
        return
    }
    $labels = @()
    foreach ($u in $script:Undo) {
        switch ([string]$u.kind) {
            'winget'   { $labels += "โปรแกรม: $($u.name)" }
            'font'     { $labels += "ฟอนต์: $($u.file)" }
            'shortcut' { $labels += "ช็อตคัต: $([IO.Path]::GetFileName([string]$u.path))" }
            'timezone' { $labels += 'คืนค่าโซนเวลา' }
            'lang'     { $labels += 'เอาภาษาไทยที่เพิ่มออก' }
            'region'   { $labels += 'คืนค่าภูมิภาค/รูปแบบวันที่' }
            'icons'    { $labels += 'คืนค่าไอคอนบนเดสก์ท็อป' }
            'hotkey'   { $labels += 'คืนค่าปุ่มสลับภาษา' }
            'chromelang' { $labels += 'คืนค่าภาษา Google Chrome' }
            'syslocale' { $labels += 'คืนค่าภาษา non-Unicode programs' }
        }
    }
    $show = if ($labels.Count -gt 15) { ($labels[0..14] -join "`r`n") + "`r`n... และอื่น ๆ อีก $($labels.Count - 15) รายการ" } else { $labels -join "`r`n" }
    $ans = [System.Windows.Forms.MessageBox]::Show(
        "จะลบเฉพาะสิ่งที่โปรแกรมนี้ติดตั้งไว้ ($($script:Undo.Count) รายการ) และคืนค่าตั้งเครื่องกลับ`r`nโปรแกรมที่มีอยู่ในเครื่องก่อนหน้านี้จะไม่ถูกแตะต้อง`r`n`r`n$show`r`n`r`nต้องการลบใช่ไหม?",
        'ยืนยันการลบ', 'YesNo', 'Warning')
    if ($ans -ne 'Yes') { return }

    $script:Cancel = $false
    Set-Busy $true
    Show-Detail $true
    $items = @($script:Undo.ToArray()); [array]::Reverse($items)
    $script:bar.Minimum = 0; $script:bar.Maximum = $items.Count; $script:bar.Value = 0
    Write-Log "เริ่มลบสิ่งที่ติดตั้งไว้ $($items.Count) รายการ"
    $n = 0; $fail = 0; $done = 0
    foreach ($u in $items) {
        if ($script:Cancel) { break }
        $n++
        $ok = $false
        try {
            switch ([string]$u.kind) {
                'winget' {
                    $script:status.Text = "($n/$($items.Count)) กำลังถอนการติดตั้ง $($u.name) ..."
                    Write-Log ">> ถอน $($u.name)"
                    $wg = Get-Command winget -ErrorAction Stop
                    $out = [IO.Path]::GetTempFileName()
                    $code = Invoke-Proc $wg.Source "uninstall --id `"$($u.id)`" -e --silent --accept-source-agreements --disable-interactivity" $out
                    if ($null -eq $code) { Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue; throw 'ถูกหยุด' }
                    Write-Tail $out
                    Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
                    # 0 = สำเร็จ, 0x8A150014 = ไม่พบโปรแกรมนี้ในเครื่องแล้ว
                    if ($code -eq 0) { $ok = $true }
                    elseif ($code -eq -1978335212) {
                        if ($u.viaUrl) { throw 'winget ไม่รู้จักโปรแกรมนี้ - ถอนเองที่ Settings > Apps' } else { $ok = $true }
                    }
                    else { throw "winget ส่ง exit code $code" }
                }
                'font' {
                    Ensure-FontApi
                    $dest = Join-Path (Join-Path $env:windir 'Fonts') ([string]$u.file)
                    [void][AutoInstaller.FontApi]::RemoveFontResource($dest)
                    $reg = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
                    Remove-ItemProperty -LiteralPath $reg -Name ([string]$u.reg) -ErrorAction SilentlyContinue
                    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Force -ErrorAction Stop }
                    $ok = $true
                }
                'chromelang' {
                    $ck = 'HKLM:\SOFTWARE\Policies\Google\Chrome'
                    if ([string]$u.prev) { Set-ItemProperty -LiteralPath $ck -Name 'ApplicationLocaleValue' -Value ([string]$u.prev) }
                    else { Remove-ItemProperty -LiteralPath $ck -Name 'ApplicationLocaleValue' -ErrorAction SilentlyContinue }
                    $ok = $true
                }
                'shortcut' {
                    if (Test-Path -LiteralPath ([string]$u.path)) { Remove-Item -LiteralPath ([string]$u.path) -Force -ErrorAction Stop }
                    $ok = $true
                }
                'timezone' { Set-TimeZone -Id ([string]$u.prev) -ErrorAction Stop; Write-Log "   คืนโซนเวลาเป็น $($u.prev)"; $ok = $true }
                'lang' {
                    $tags = @($u.prev | ForEach-Object { [string]$_ })
                    if ($tags.Count -gt 0) {
                        $l = New-WinUserLanguageList $tags[0]
                        for ($k = 1; $k -lt $tags.Count; $k++) { $l.Add($tags[$k]) }
                        Set-WinUserLanguageList $l -Force
                    }
                    Write-Log '   เอาภาษาไทยที่เพิ่มไว้ออกแล้ว'; $ok = $true
                }
                'region' {
                    if ($u.culture) { Set-Culture -CultureInfo ([string]$u.culture) -ErrorAction Stop }
                    if ([int]$u.geo -gt 0) { Set-WinHomeLocation -GeoId ([int]$u.geo) -ErrorAction Stop }
                    Write-Log '   คืนค่าภูมิภาค/รูปแบบวันที่แล้ว'; $ok = $true
                }
                'icons' {
                    foreach ($pi in @($u.prev)) {
                        $key = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\$($pi.key)"
                        if ([int]$pi.value -lt 0) { Remove-ItemProperty -LiteralPath $key -Name ([string]$pi.guid) -ErrorAction SilentlyContinue }
                        else { [void](New-ItemProperty -LiteralPath $key -Name ([string]$pi.guid) -Value ([int]$pi.value) -PropertyType DWord -Force) }
                    }
                    Write-Log '   คืนค่าไอคอนบนเดสก์ท็อปแล้ว'; $ok = $true
                }
                'syslocale' {
                    if ([string]$u.prev) { Set-WinSystemLocale -SystemLocale ([string]$u.prev) -ErrorAction Stop }
                    Write-Log "   คืนค่าภาษา non-Unicode programs เป็น $($u.prev)"; $ok = $true
                }
                'hotkey' {
                    $key = 'HKCU:\Keyboard Layout\Toggle'
                    foreach ($pair in @(@('Language Hotkey', [string]$u.lang), @('Hotkey', [string]$u.hot), @('Layout Hotkey', [string]$u.layout))) {
                        if ($pair[1] -eq '') { Remove-ItemProperty -LiteralPath $key -Name $pair[0] -ErrorAction SilentlyContinue }
                        else { Set-ItemProperty -LiteralPath $key -Name $pair[0] -Value $pair[1] }
                    }
                    Write-Log '   คืนค่าปุ่มสลับภาษาแล้ว'; $ok = $true
                }
                default { $ok = $true }
            }
        } catch {
            Write-Log "   ลบไม่สำเร็จ: $($_.Exception.Message)"
            $fail++
        }
        if ($ok) { $done++; [void]$script:Undo.Remove($u); Save-Undo }
        $script:bar.Value = [Math]::Min($n, $script:bar.Maximum)
    }
    try {
        Ensure-FontApi
        $r = [IntPtr]::Zero
        [void][AutoInstaller.FontApi]::SendMessageTimeout([IntPtr]0xffff, 0x001D, [IntPtr]::Zero, [IntPtr]::Zero, 2, 1000, [ref]$r)
    } catch {}
    $script:status.Text = "ลบเสร็จ: สำเร็จ $done รายการ" + $(if ($fail) { ", ไม่สำเร็จ $fail รายการ (ดูรายละเอียดด้านล่าง)" } else { '' })
    Write-Log $script:status.Text
    Set-Busy $false
    [void][System.Windows.Forms.MessageBox]::Show(($script:status.Text + "`r`n`r`nแนะนำให้รีสตาร์ทเครื่องหนึ่งครั้งเพื่อให้ค่าที่คืนมีผลครบ"), 'Auto Installer', 'OK', 'Information')
}

function Ensure-UiControls {
    if ('AutoInstaller.CardList' -as [type]) { return }
    Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;
namespace AutoInstaller {
  public class CardList : ListView {
    public Color Accent = Color.FromArgb(37, 99, 235);
    public Color Ink = Color.FromArgb(17, 24, 39);
    public Color Sub = Color.FromArgb(107, 114, 128);
    int hover = -1;
    public CardList() {
      SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint, true);
      OwnerDraw = true; View = View.Details; CheckBoxes = true; FullRowSelect = true;
      HeaderStyle = ColumnHeaderStyle.None; ShowItemToolTips = true; ShowGroups = false; BorderStyle = BorderStyle.None; MultiSelect = false;
    }
    static GraphicsPath Round(Rectangle r, int rad) {
      int d = rad * 2; var p = new GraphicsPath();
      p.AddArc(r.X, r.Y, d, d, 180, 90); p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
      p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90); p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
      p.CloseFigure(); return p;
    }
    protected override void OnDrawItem(DrawListViewItemEventArgs e) { e.DrawDefault = false; }
    protected override void OnDrawSubItem(DrawListViewSubItemEventArgs e) {
      if (e.ColumnIndex != 0) return;
      var g = e.Graphics; var b = e.Bounds; var it = e.Item;
      g.SmoothingMode = SmoothingMode.AntiAlias;
      using (var br = new SolidBrush(e.ItemIndex == hover ? Color.FromArgb(244, 247, 255) : Color.White)) g.FillRectangle(br, b);
      var box = new Rectangle(b.X + 18, b.Y + (b.Height - 22) / 2, 22, 22);
      using (var path = Round(box, 6)) {
        if (it.Checked) {
          using (var br = new SolidBrush(Accent)) g.FillPath(br, path);
          using (var pen = new Pen(Color.White, 2.6f) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round })
            g.DrawLines(pen, new Point[] { new Point(box.X + 5, box.Y + 11), new Point(box.X + 9, box.Y + 15), new Point(box.X + 17, box.Y + 7) });
        } else {
          using (var br = new SolidBrush(Color.White)) g.FillPath(br, path);
          using (var pen = new Pen(Color.FromArgb(203, 213, 225), 2f)) g.DrawPath(pen, path);
        }
      }
      var flags = TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding | TextFormatFlags.SingleLine;
      bool have = it.ToolTipText != null && it.ToolTipText.StartsWith("installed");
      var nameRect = new Rectangle(b.X + 56, b.Y, Math.Max(40, b.Width - 56 - 150 - (have ? 96 : 0)), b.Height);
      if (have) {
        var pill = new Rectangle(b.Right - 150 - 90, b.Y + (b.Height - 22) / 2, 84, 22);
        using (var path = Round(pill, 11)) {
          using (var br = new SolidBrush(Color.FromArgb(220, 252, 231))) g.FillPath(br, path);
        }
        using (var small2 = new Font(Font.FontFamily, Math.Max(8f, Font.Size - 2f), FontStyle.Bold))
          TextRenderer.DrawText(g, "ติดตั้งแล้ว", small2, pill, Color.FromArgb(22, 101, 52), TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding | TextFormatFlags.SingleLine);
      }
      TextRenderer.DrawText(g, it.Text, Font, nameRect, it.Checked ? Ink : Sub, flags | TextFormatFlags.EndEllipsis);
      var catRect = new Rectangle(b.Right - 150, b.Y, 136, b.Height);
      using (var small = new Font(Font.FontFamily, Math.Max(8f, Font.Size - 2.5f)))
        TextRenderer.DrawText(g, it.Name ?? "", small, catRect, Sub, TextFormatFlags.Right | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis);
      using (var pen = new Pen(Color.FromArgb(241, 243, 247))) g.DrawLine(pen, b.X + 16, b.Bottom - 1, b.Right - 16, b.Bottom - 1);
    }
    protected override void OnMouseMove(MouseEventArgs e) {
      base.OnMouseMove(e);
      var h = HitTest(e.Location).Item; int idx = h == null ? -1 : h.Index;
      if (idx != hover) { int old = hover; hover = idx; if (old >= 0 && old < Items.Count) RedrawItems(old, old, false); if (idx >= 0) RedrawItems(idx, idx, false); }
    }
    protected override void OnMouseLeave(EventArgs e) {
      base.OnMouseLeave(e);
      if (hover >= 0) { int old = hover; hover = -1; if (old < Items.Count) RedrawItems(old, old, false); }
    }
    protected override void OnMouseUp(MouseEventArgs e) {
      base.OnMouseUp(e);
      if (e.Button != MouseButtons.Left || e.X < 22) return;
      var it = HitTest(e.Location).Item;
      if (it != null) it.Checked = !it.Checked;
    }
  }
  public class SlimBar : Control {
    int min = 0, max = 100, val = 0;
    public Color Accent = Color.FromArgb(37, 99, 235);
    public SlimBar() { SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true); Height = 8; }
    public int Minimum { get { return min; } set { min = value; Invalidate(); } }
    public int Maximum { get { return max; } set { max = Math.Max(value, min + 1); Invalidate(); } }
    public int Value { get { return val; } set { val = Math.Max(min, Math.Min(value, max)); Invalidate(); } }
    protected override void OnPaint(PaintEventArgs e) {
      var g = e.Graphics; g.SmoothingMode = SmoothingMode.AntiAlias; g.Clear(Parent != null ? Parent.BackColor : Color.White);
      var r = new Rectangle(0, (Height - 8) / 2, Width - 1, 8);
      if (r.Width < 4) return;
      using (var br = new SolidBrush(Color.FromArgb(226, 230, 237))) g.FillPath(br, Round(r, 4));
      int w = (int)((r.Width) * ((double)(val - min) / (max - min)));
      if (w > 8) { var f = new Rectangle(r.X, r.Y, w, r.Height); using (var br = new SolidBrush(Accent)) g.FillPath(br, Round(f, 4)); }
    }
    static GraphicsPath Round(Rectangle r, int rad) {
      int d = rad * 2; var p = new GraphicsPath();
      p.AddArc(r.X, r.Y, d, d, 180, 90); p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
      p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90); p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
      p.CloseFigure(); return p;
    }
  }
}
'@
}

function New-Font([double]$size, [bool]$bold = $false) {
    $style = if ($bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
    return (New-Object System.Drawing.Font('Segoe UI', $size, $style))
}

function New-Link([string]$text) {
    $l = New-Object System.Windows.Forms.LinkLabel
    $l.Text = $text
    $l.AutoSize = $true
    $l.LinkColor = $script:Accent
    $l.ActiveLinkColor = $script:Accent
    $l.LinkBehavior = 'HoverUnderline'
    $l.Margin = New-Object System.Windows.Forms.Padding(0, 0, 18, 0)
    return $l
}

# ---------- กล่องถามข้อความสั้น ๆ (ใช้กับรหัสผ่าน) ----------
function Read-Text([string]$title, [string]$prompt, [bool]$secret) {
    $d = New-Object System.Windows.Forms.Form
    $d.Text = $title
    $d.Size = New-Object System.Drawing.Size(420, 190)
    $d.StartPosition = 'CenterParent'
    $d.FormBorderStyle = 'FixedDialog'
    $d.MaximizeBox = $false; $d.MinimizeBox = $false
    $d.Font = New-Font 10
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $prompt; $l.Location = New-Object System.Drawing.Point(16, 14); $l.Size = New-Object System.Drawing.Size(380, 44)
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location = New-Object System.Drawing.Point(16, 64); $t.Width = 372
    if ($secret) { $t.UseSystemPasswordChar = $true }
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'ตกลง'; $ok.Location = New-Object System.Drawing.Point(206, 108); $ok.Size = New-Object System.Drawing.Size(88, 32)
    $ok.DialogResult = 'OK'
    $cx = New-Object System.Windows.Forms.Button
    $cx.Text = 'ยกเลิก'; $cx.Location = New-Object System.Drawing.Point(300, 108); $cx.Size = New-Object System.Drawing.Size(88, 32)
    $cx.DialogResult = 'Cancel'
    $d.Controls.AddRange(@($l, $t, $ok, $cx))
    $d.AcceptButton = $ok; $d.CancelButton = $cx
    $res = $d.ShowDialog($script:form)
    $text = $t.Text
    $d.Dispose()
    if ($res -eq 'OK') { return $text }
    return $null
}

function Confirm-Admin {
    $hash = Get-AdminPinHash
    if (-not $hash) { return $true }
    while ($true) {
        $pin = Read-Text 'ผู้ดูแลระบบ' 'กรุณาใส่รหัสผ่านผู้ดูแลระบบ' $true
        if ($null -eq $pin) { return $false }
        if ((Get-PinHash $pin) -eq $hash) { return $true }
        [void][System.Windows.Forms.MessageBox]::Show('รหัสผ่านไม่ถูกต้อง', 'Auto Installer', 'OK', 'Warning')
    }
}

# ---------- กล่องเพิ่ม/แก้ไขโปรแกรม (คืนค่า $null ถ้ายกเลิก) ----------
function Show-AppDialog($existing) {
    $obj = if ($existing) { Clone-App $existing } else { [pscustomobject]@{ name = ''; category = 'กำหนดเอง'; type = 'winget'; checked = $true } }

    $d = New-Object System.Windows.Forms.Form
    $d.Text = $(if ($existing) { 'แก้ไขโปรแกรม' } else { 'เพิ่มโปรแกรม' })
    $d.Size = New-Object System.Drawing.Size(600, 420)
    $d.StartPosition = 'CenterParent'
    $d.FormBorderStyle = 'FixedDialog'
    $d.MaximizeBox = $false; $d.MinimizeBox = $false
    $d.Font = New-Font 10

    $y = 16
    $boxes = @{}
    foreach ($row in @(@('name', 'ชื่อโปรแกรม'), @('category', 'หมวดหมู่'))) {
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $row[1]; $l.Location = New-Object System.Drawing.Point(16, ($y + 3)); $l.AutoSize = $true
        $t = New-Object System.Windows.Forms.TextBox
        $t.Location = New-Object System.Drawing.Point(190, $y); $t.Width = 380
        $d.Controls.AddRange(@($l, $t)); $boxes[$row[0]] = $t
        $y += 38
    }
    $lt = New-Object System.Windows.Forms.Label
    $lt.Text = 'วิธีติดตั้ง'; $lt.Location = New-Object System.Drawing.Point(16, ($y + 3)); $lt.AutoSize = $true
    $cType = New-Object System.Windows.Forms.ComboBox
    $cType.DropDownStyle = 'DropDownList'; $cType.Location = New-Object System.Drawing.Point(190, $y); $cType.Width = 380
    [void]$cType.Items.Add('winget (ระบุ ID)')
    [void]$cType.Items.Add('ดาวน์โหลดตรง (ลิงก์ https)')
    [void]$cType.Items.Add('ไฟล์ในเครื่อง (โฟลเดอร์ Installers)')
    [void]$cType.Items.Add('ฟอนต์ (ชื่อโฟลเดอร์ เช่น Fonts)')
    [void]$cType.Items.Add('ตั้งค่าเครื่อง (timezone / thai-input / thai-region / lang-hotkey / desktop-icons / desktop-shortcuts)')
    $d.Controls.AddRange(@($lt, $cType))
    $y += 38
    foreach ($row in @(@('src', 'winget ID / ลิงก์ / ไฟล์'), @('args', 'Silent args (ลิงก์/ไฟล์)'), @('sha256', 'SHA256 (ไม่บังคับ)'))) {
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $row[1]; $l.Location = New-Object System.Drawing.Point(16, ($y + 3)); $l.AutoSize = $true
        $t = New-Object System.Windows.Forms.TextBox
        $t.Location = New-Object System.Drawing.Point(190, $y); $t.Width = 380
        $d.Controls.AddRange(@($l, $t)); $boxes[$row[0]] = $t
        $y += 38
    }
    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = "ตัวอย่าง winget ID: Google.Chrome  (ค้นหาด้วยคำสั่ง winget search ชื่อโปรแกรม)`r`nไฟล์ในเครื่อง: Installers\MyApp\*.exe    Silent args: /S หรือ /VERYSILENT /NORESTART"
    $hint.ForeColor = $script:Gray
    $hint.Location = New-Object System.Drawing.Point(16, $y); $hint.Size = New-Object System.Drawing.Size(560, 44)
    $d.Controls.Add($hint)
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'ตกลง'; $ok.Location = New-Object System.Drawing.Point(390, 336); $ok.Size = New-Object System.Drawing.Size(88, 34); $ok.DialogResult = 'OK'
    $cx = New-Object System.Windows.Forms.Button
    $cx.Text = 'ยกเลิก'; $cx.Location = New-Object System.Drawing.Point(484, 336); $cx.Size = New-Object System.Drawing.Size(88, 34); $cx.DialogResult = 'Cancel'
    $d.Controls.AddRange(@($ok, $cx)); $d.CancelButton = $cx

    # เติมค่าเดิม
    $boxes['name'].Text = [string]$obj.name
    $boxes['category'].Text = [string]$obj.category
    $kinds = @('winget', 'url', 'file', 'fonts', 'task')
    $idx = [Array]::IndexOf($kinds, [string]$obj.type); if ($idx -lt 0) { $idx = 0 }
    $cType.SelectedIndex = $idx
    $boxes['src'].Text = [string]$(switch ([string]$obj.type) { 'url' { $obj.url } 'file' { $obj.file } 'fonts' { $obj.folder } 'task' { $obj.task } default { $obj.id } })
    if ($obj.args) { $boxes['args'].Text = [string]$obj.args }
    if ($obj.sha256) { $boxes['sha256'].Text = [string]$obj.sha256 }

    while ($true) {
        if ($d.ShowDialog($script:form) -ne 'OK') { $d.Dispose(); return $null }
        $kind = $kinds[$cType.SelectedIndex]
        $src = $boxes['src'].Text.Trim()
        if (-not $boxes['name'].Text.Trim() -or -not $src) {
            [void][System.Windows.Forms.MessageBox]::Show('กรุณากรอกชื่อโปรแกรม และ ID / ลิงก์ / ไฟล์', 'Auto Installer', 'OK', 'Warning'); continue
        }
        if ($kind -eq 'url' -and $src -notmatch '^https://') {
            [void][System.Windows.Forms.MessageBox]::Show('ลิงก์ต้องขึ้นต้นด้วย https://', 'Auto Installer', 'OK', 'Warning'); continue
        }
        break
    }
    Set-Prop $obj 'name' $boxes['name'].Text.Trim()
    Set-Prop $obj 'category' $(if ($boxes['category'].Text.Trim()) { $boxes['category'].Text.Trim() } else { 'กำหนดเอง' })
    Set-Prop $obj 'type' $kind
    foreach ($k in @('id', 'url', 'file', 'folder', 'task')) { Remove-Prop $obj $k }
    Set-Prop $obj $(@{ winget = 'id'; url = 'url'; file = 'file'; fonts = 'folder'; task = 'task' }[$kind]) $src
    if (($kind -eq 'url' -or $kind -eq 'file') -and $boxes['args'].Text.Trim()) { Set-Prop $obj 'args' $boxes['args'].Text.Trim() } else { Remove-Prop $obj 'args' }
    if (($kind -eq 'url' -or $kind -eq 'file') -and $boxes['sha256'].Text.Trim()) { Set-Prop $obj 'sha256' $boxes['sha256'].Text.Trim() } else { Remove-Prop $obj 'sha256' }
    if (-not $obj.PSObject.Properties['checked']) { Set-Prop $obj 'checked' $true }
    $d.Dispose()
    return $obj
}

# =====================================================================
#  หน้า Admin
# =====================================================================
function Fill-AdminList([int]$select = -1) {
    $lvA = $script:adm.lv
    $lvA.BeginUpdate()
    $lvA.Items.Clear()
    foreach ($a in $script:adm.work) {
        $item = New-Object System.Windows.Forms.ListViewItem([string]$a.name)
        [void]$item.SubItems.Add([string]$a.category)
        if ($a.type -eq 'url') { [void]$item.SubItems.Add('ดาวน์โหลดตรง'); [void]$item.SubItems.Add([string]$a.url) }
        elseif ($a.type -eq 'file') { [void]$item.SubItems.Add('ไฟล์ในเครื่อง'); [void]$item.SubItems.Add([string]$a.file) }
        elseif ($a.type -eq 'fonts') { [void]$item.SubItems.Add('ฟอนต์'); [void]$item.SubItems.Add([string]$a.folder) }
        elseif ($a.type -eq 'task') { [void]$item.SubItems.Add('ตั้งค่าเครื่อง'); [void]$item.SubItems.Add([string]$a.task) }
        else { [void]$item.SubItems.Add('winget'); [void]$item.SubItems.Add([string]$a.id) }
        $item.Tag = $a
        $item.Checked = [bool]$a.checked
        [void]$lvA.Items.Add($item)
    }
    $lvA.EndUpdate()
    if ($select -ge 0 -and $select -lt $lvA.Items.Count) { $lvA.Items[$select].Selected = $true; $lvA.Items[$select].EnsureVisible() }
}

function Sync-AdminChecks {
    foreach ($it in $script:adm.lv.Items) { $it.Tag.checked = $it.Checked }
}

function Show-AdminForm {
    $script:adm = @{}
    $script:adm.work = New-Object System.Collections.ArrayList
    foreach ($a in $script:Apps) { [void]$script:adm.work.Add((Clone-App $a)) }

    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'ผู้ดูแลระบบ - จัดการรายการโปรแกรม'
    $f.Size = New-Object System.Drawing.Size(980, 640)
    $f.MinimumSize = New-Object System.Drawing.Size(860, 520)
    $f.StartPosition = 'CenterParent'
    $f.Font = New-Font 9.5
    $script:adm.form = $f

    $info = New-Object System.Windows.Forms.Label
    $info.Text = "หน้านี้สำหรับผู้ดูแล: เพิ่ม/แก้ไข/ลบโปรแกรม และเลือกว่าตัวไหน 'ติ๊กไว้ให้' ตอนเปิดโปรแกรม`r`n(ไดรเวอร์การ์ดจอจะติ๊กอัตโนมัติตามการ์ดจอที่ตรวจเจอในเครื่อง ไม่ขึ้นกับค่านี้)"
    $info.Location = New-Object System.Drawing.Point(14, 12); $info.Size = New-Object System.Drawing.Size(940, 44)
    $info.Anchor = 'Top,Left,Right'
    $f.Controls.Add($info)

    $lvA = New-Object System.Windows.Forms.ListView
    $lvA.View = 'Details'; $lvA.CheckBoxes = $true; $lvA.FullRowSelect = $true; $lvA.HideSelection = $false; $lvA.MultiSelect = $false
    $lvA.Location = New-Object System.Drawing.Point(14, 60); $lvA.Size = New-Object System.Drawing.Size(940, 430)
    $lvA.Anchor = 'Top,Bottom,Left,Right'
    [void]$lvA.Columns.Add('ชื่อโปรแกรม (ติ๊ก = ติ๊กไว้ตอนเปิด)', 300)
    [void]$lvA.Columns.Add('หมวดหมู่', 130)
    [void]$lvA.Columns.Add('วิธีติดตั้ง', 110)
    [void]$lvA.Columns.Add('winget ID / ลิงก์ / ไฟล์', 380)
    $f.Controls.Add($lvA)
    $script:adm.lv = $lvA

    function New-AdmBtn([string]$text, [int]$x, [int]$w) {
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $text; $b.Location = New-Object System.Drawing.Point($x, 502); $b.Size = New-Object System.Drawing.Size($w, 34)
        $b.Anchor = 'Bottom,Left'
        $f.Controls.Add($b)
        return $b
    }
    $bAdd  = New-AdmBtn 'เพิ่ม...' 14 90
    $bEdit = New-AdmBtn 'แก้ไข...' 110 90
    $bDel  = New-AdmBtn 'ลบ' 206 70
    $bUp   = New-AdmBtn '▲' 282 44
    $bDown = New-AdmBtn '▼' 332 44
    $bPin  = New-AdmBtn 'รหัสผ่านผู้ดูแล...' 392 150
    $bLog  = New-AdmBtn 'ดู log' 548 84

    $bSave = New-Object System.Windows.Forms.Button
    $bSave.Text = 'บันทึกและปิด'; $bSave.Location = New-Object System.Drawing.Point(714, 502); $bSave.Size = New-Object System.Drawing.Size(130, 34)
    $bSave.Anchor = 'Bottom,Right'
    $bSave.BackColor = $script:Accent; $bSave.ForeColor = [System.Drawing.Color]::White; $bSave.FlatStyle = 'Flat'
    $bSave.DialogResult = 'OK'
    $bCancel = New-Object System.Windows.Forms.Button
    $bCancel.Text = 'ยกเลิก'; $bCancel.Location = New-Object System.Drawing.Point(854, 502); $bCancel.Size = New-Object System.Drawing.Size(100, 34)
    $bCancel.Anchor = 'Bottom,Right'
    $bCancel.DialogResult = 'Cancel'
    $f.Controls.AddRange(@($bSave, $bCancel)); $f.CancelButton = $bCancel

    $bAdd.Add_Click({
        Sync-AdminChecks
        $n = Show-AppDialog $null
        if ($n) { [void]$script:adm.work.Add($n); Fill-AdminList ($script:adm.work.Count - 1) }
    })
    $bEdit.Add_Click({
        if ($script:adm.lv.SelectedItems.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show('คลิกเลือกรายการที่ต้องการแก้ไขก่อน'); return }
        Sync-AdminChecks
        $i = $script:adm.lv.SelectedItems[0].Index
        $n = Show-AppDialog $script:adm.work[$i]
        if ($n) { $script:adm.work[$i] = $n; Fill-AdminList $i }
    })
    $bDel.Add_Click({
        if ($script:adm.lv.SelectedItems.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show('คลิกเลือกรายการที่ต้องการลบก่อน'); return }
        $i = $script:adm.lv.SelectedItems[0].Index
        $nm = [string]$script:adm.work[$i].name
        if ([System.Windows.Forms.MessageBox]::Show("ลบ `"$nm`" ออกจากรายการ?", 'ยืนยัน', 'YesNo', 'Question') -ne 'Yes') { return }
        Sync-AdminChecks
        $script:adm.work.RemoveAt($i)
        Fill-AdminList ([Math]::Min($i, $script:adm.work.Count - 1))
    })
    $bUp.Add_Click({
        if ($script:adm.lv.SelectedItems.Count -eq 0) { return }
        $i = $script:adm.lv.SelectedItems[0].Index
        if ($i -le 0) { return }
        Sync-AdminChecks
        $t = $script:adm.work[$i]; $script:adm.work[$i] = $script:adm.work[$i - 1]; $script:adm.work[$i - 1] = $t
        Fill-AdminList ($i - 1)
    })
    $bDown.Add_Click({
        if ($script:adm.lv.SelectedItems.Count -eq 0) { return }
        $i = $script:adm.lv.SelectedItems[0].Index
        if ($i -ge $script:adm.work.Count - 1) { return }
        Sync-AdminChecks
        $t = $script:adm.work[$i]; $script:adm.work[$i] = $script:adm.work[$i + 1]; $script:adm.work[$i + 1] = $t
        Fill-AdminList ($i + 1)
    })
    $bPin.Add_Click({
        $pin = Read-Text 'รหัสผ่านผู้ดูแล' "ใส่รหัสผ่านใหม่ (เว้นว่างแล้วกดตกลง = ไม่ใช้รหัสผ่าน)" $true
        if ($null -eq $pin) { return }
        if ($pin.Length -eq 0) {
            Set-AdminPinHash ''
            [void][System.Windows.Forms.MessageBox]::Show('ปิดการใช้รหัสผ่านแล้ว (ใครก็เข้าหน้านี้ได้)', 'Auto Installer')
        } else {
            Set-AdminPinHash (Get-PinHash $pin)
            [void][System.Windows.Forms.MessageBox]::Show('ตั้งรหัสผ่านผู้ดูแลเรียบร้อย', 'Auto Installer')
        }
    })
    $bLog.Add_Click({
        $d = New-Object System.Windows.Forms.Form
        $d.Text = 'log การติดตั้ง'; $d.Size = New-Object System.Drawing.Size(780, 520); $d.StartPosition = 'CenterParent'
        $t = New-Object System.Windows.Forms.TextBox
        $t.Multiline = $true; $t.ReadOnly = $true; $t.ScrollBars = 'Vertical'; $t.Dock = 'Fill'
        $t.Font = New-Object System.Drawing.Font('Consolas', 10)
        $t.Text = $(if ($script:LogBuilder.Length -gt 0) { $script:LogBuilder.ToString() } else { '(ยังไม่มีการติดตั้งในรอบนี้)' })
        $d.Controls.Add($t)
        [void]$d.ShowDialog($script:adm.form)
        $d.Dispose()
    })
    $bSave.Add_Click({
        try {
            Sync-AdminChecks
            $script:Apps = $script:adm.work.ToArray()
            Save-Apps
        } catch {
            [void][System.Windows.Forms.MessageBox]::Show("บันทึกไม่สำเร็จ: $($_.Exception.Message)", 'Auto Installer', 'OK', 'Error')
            $script:adm.form.DialogResult = [System.Windows.Forms.DialogResult]::None
        }
    })

    Fill-AdminList 0
    $res = $f.ShowDialog($script:form)
    $f.Dispose()
    return ($res -eq 'OK')
}

# =====================================================================
#  หน้า User
# =====================================================================
$form = New-Object System.Windows.Forms.Form
$script:form = $form
$form.Text = "Auto Installer v$($script:Version)"
$form.Size = New-Object System.Drawing.Size(780, 720)
$form.MinimumSize = New-Object System.Drawing.Size(640, 560)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Font 11
$form.BackColor = $script:Paper

$tbl = New-Object System.Windows.Forms.TableLayoutPanel
$tbl.Dock = 'Fill'
$tbl.ColumnCount = 1
$tbl.RowCount = 6
[void]$tbl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$tbl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 92)))
[void]$tbl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 56)))
[void]$tbl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$tbl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 64)))
[void]$tbl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 74)))
[void]$tbl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 0)))
$script:tbl = $tbl

# --- ส่วนหัว ---
$header = New-Object System.Windows.Forms.Panel
$header.Dock = 'Fill'; $header.BackColor = $script:Paper; $header.Margin = New-Object System.Windows.Forms.Padding(0)
$hTitle = New-Object System.Windows.Forms.Label
$hTitle.Text = 'ติดตั้งโปรแกรม'; $hTitle.Font = New-Font 20 $true; $hTitle.ForeColor = $script:Ink
$hTitle.AutoSize = $true; $hTitle.Location = New-Object System.Drawing.Point(84, 14); $hTitle.BackColor = [System.Drawing.Color]::Transparent
$hSub = New-Object System.Windows.Forms.Label
$hSub.Text = 'เลือกชุด "ทำงาน" หรือ "เกม" หรือติ๊กเองด้านล่าง แล้วกดติดตั้ง'; $hSub.Font = New-Font 10; $hSub.ForeColor = $script:Gray
$hSub.AutoSize = $true; $hSub.Location = New-Object System.Drawing.Point(87, 58); $hSub.BackColor = [System.Drawing.Color]::Transparent
$hIcon = New-Object System.Windows.Forms.Label
$hIcon.Text = [string][char]0x2193; $hIcon.Font = New-Object System.Drawing.Font('Segoe UI', 22, [System.Drawing.FontStyle]::Bold)
$hIcon.ForeColor = [System.Drawing.Color]::White; $hIcon.BackColor = $script:Accent; $hIcon.TextAlign = 'MiddleCenter'
$hIcon.Size = New-Object System.Drawing.Size(48, 48); $hIcon.Location = New-Object System.Drawing.Point(28, 18); Set-Round $hIcon
$header.Controls.AddRange(@($hIcon, $hTitle, $hSub))
$tbl.Controls.Add($header, 0, 0)

# --- ปุ่มชุดโปรแกรม (ทำงาน / เกม / ทั้งหมด / ล้าง) + จำนวนที่เลือก ---
$toolbar = New-Object System.Windows.Forms.TableLayoutPanel
$toolbar.Dock = 'Fill'; $toolbar.ColumnCount = 2; $toolbar.RowCount = 1; $toolbar.Margin = New-Object System.Windows.Forms.Padding(0)
$toolbar.BackColor = $script:Paper
[void]$toolbar.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$toolbar.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$links1 = New-Object System.Windows.Forms.FlowLayoutPanel
$links1.Dock = 'Fill'; $links1.Padding = New-Object System.Windows.Forms.Padding(28, 10, 0, 0); $links1.AutoSize = $true; $links1.WrapContents = $false; $links1.FlowDirection = 'LeftToRight'; $links1.BackColor = $script:Paper
$script:chipWork = New-Chip 'ทำงาน'
$script:chipGame = New-Chip 'เกม'
$script:lnkAll   = New-Chip 'ทั้งหมด'
$script:lnkNone  = New-Chip 'ล้าง'
$script:lnkNone.Size = New-Object System.Drawing.Size(72, 36)
$links1.Controls.AddRange(@($script:chipWork, $script:chipGame, $script:lnkAll, $script:lnkNone))
$script:lblCount = New-Object System.Windows.Forms.Label
$script:lblCount.AutoSize = $true; $script:lblCount.ForeColor = $script:Gray; $script:lblCount.Font = New-Font 10
$script:lblCount.Anchor = 'Right'; $script:lblCount.Margin = New-Object System.Windows.Forms.Padding(0, 0, 28, 0)
$toolbar.Controls.Add($links1, 0, 0)
$toolbar.Controls.Add($script:lblCount, 1, 0)
$tbl.Controls.Add($toolbar, 0, 1)

# --- รายการโปรแกรม ---
Ensure-UiControls
$lv = New-Object AutoInstaller.CardList
$script:lv = $lv
$lv.View = 'Details'; $lv.CheckBoxes = $true; $lv.FullRowSelect = $true; $lv.HideSelection = $true
$lv.ShowGroups = $false; $lv.HeaderStyle = 'None'; $lv.BorderStyle = 'None'; $lv.MultiSelect = $false
$lv.Font = New-Font 12
$lv.Dock = 'Fill'; $lv.Margin = New-Object System.Windows.Forms.Padding(24, 4, 24, 4); $lv.BackColor = [System.Drawing.Color]::White; $lv.ForeColor = $script:Ink
[void]$lv.Columns.Add('', 400)
$rowImg = New-Object System.Windows.Forms.ImageList
$rowImg.ImageSize = New-Object System.Drawing.Size(1, 46)      # ทำให้แถวสูงขึ้น อ่านง่ายขึ้น
$lv.SmallImageList = $rowImg
$lv.Add_Resize({ $script:lv.Columns[0].Width = [Math]::Max(200, $script:lv.ClientSize.Width - 6) })
$tbl.Controls.Add($lv, 0, 2)

# --- แถบความคืบหน้า ---
$statusPanel = New-Object System.Windows.Forms.TableLayoutPanel
$statusPanel.BackColor = $script:Paper; $statusPanel.Dock = 'Fill'; $statusPanel.ColumnCount = 1; $statusPanel.RowCount = 2; $statusPanel.Margin = New-Object System.Windows.Forms.Padding(0)
[void]$statusPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 22)))
[void]$statusPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$script:bar = New-Object AutoInstaller.SlimBar
$script:bar.Dock = 'Fill'; $script:bar.Margin = New-Object System.Windows.Forms.Padding(28, 8, 28, 0)
$script:status = New-Object System.Windows.Forms.Label
$script:status.Text = 'พร้อมติดตั้ง'; $script:status.Dock = 'Fill'; $script:status.Font = New-Font 10
$script:status.ForeColor = $script:Gray; $script:status.Margin = New-Object System.Windows.Forms.Padding(28, 4, 28, 0)
$script:status.AutoEllipsis = $true
$statusPanel.Controls.Add($script:bar, 0, 0)
$statusPanel.Controls.Add($script:status, 0, 1)
$tbl.Controls.Add($statusPanel, 0, 3)

# --- ปุ่ม ---
$btnRow = New-Object System.Windows.Forms.TableLayoutPanel
$btnRow.BackColor = $script:Paper; $btnRow.Dock = 'Fill'; $btnRow.ColumnCount = 4; $btnRow.RowCount = 1; $btnRow.Margin = New-Object System.Windows.Forms.Padding(0)
[void]$btnRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$btnRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$btnRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 100)))
[void]$btnRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 210)))
$links2 = New-Object System.Windows.Forms.FlowLayoutPanel
$links2.BackColor = $script:Paper; $links2.Dock = 'Fill'; $links2.Padding = New-Object System.Windows.Forms.Padding(20, 24, 0, 0); $links2.AutoSize = $true
$script:lnkDetail = New-Link 'ดูรายละเอียด'
$script:lnkAdmin  = New-Link 'ผู้ดูแลระบบ'
$script:lnkDetail.Font = New-Font 10; $script:lnkAdmin.Font = New-Font 10
$links2.Controls.AddRange(@($script:lnkDetail, $script:lnkAdmin))
$script:btnStop = New-Object System.Windows.Forms.Button
$script:btnStop.Text = 'หยุด'; $script:btnStop.Dock = 'Fill'; $script:btnStop.Enabled = $false
$script:btnStop.Margin = New-Object System.Windows.Forms.Padding(4, 14, 4, 14)
$script:btnStop.FlatStyle = 'Flat'; $script:btnStop.FlatAppearance.BorderSize = 0; $script:btnStop.BackColor = $script:Chip; $script:btnStop.ForeColor = $script:Ink; Set-Round $script:btnStop
$script:btnInstall = New-Object System.Windows.Forms.Button
$script:btnInstall.Text = 'ติดตั้ง'; $script:btnInstall.Dock = 'Fill'
$script:btnInstall.BackColor = $script:Accent; $script:btnInstall.ForeColor = [System.Drawing.Color]::White
$script:btnInstall.FlatStyle = 'Flat'; $script:btnInstall.FlatAppearance.BorderSize = 0
$script:btnInstall.Font = New-Font 13 $true
$script:btnInstall.Margin = New-Object System.Windows.Forms.Padding(4, 12, 24, 12)
Set-Round $script:btnInstall
$script:btnUndo = New-Object System.Windows.Forms.Button
$script:btnUndo.Text = 'ลบทั้งหมดที่ลงไว้'; $script:btnUndo.Anchor = 'Right'
$script:btnUndo.Size = New-Object System.Drawing.Size(150, 34); $script:btnUndo.Font = New-Font 10
$script:btnUndo.FlatStyle = 'Flat'; $script:btnUndo.ForeColor = [System.Drawing.Color]::FromArgb(180, 40, 40)
$script:btnUndo.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(180, 40, 40)
$script:btnUndo.Margin = New-Object System.Windows.Forms.Padding(4, 0, 8, 0)
$script:btnUndo.FlatAppearance.BorderSize = 0; $script:btnUndo.BackColor = $script:Paper; $script:btnUndo.ForeColor = [System.Drawing.Color]::FromArgb(185, 28, 28)
$btnRow.Controls.Add($links2, 0, 0)
$btnRow.Controls.Add($script:btnUndo, 1, 0)
$btnRow.Controls.Add($script:btnStop, 2, 0)
$btnRow.Controls.Add($script:btnInstall, 3, 0)
$tbl.Controls.Add($btnRow, 0, 4)

# --- รายละเอียด (log) ซ่อนไว้ก่อน ---
$script:LogBox = New-Object System.Windows.Forms.TextBox
$script:LogBox.Multiline = $true; $script:LogBox.ReadOnly = $true; $script:LogBox.ScrollBars = 'Vertical'
$script:LogBox.Font = New-Object System.Drawing.Font('Consolas', 9.5)
$script:LogBox.BackColor = [System.Drawing.Color]::White
$script:LogBox.Dock = 'Fill'; $script:LogBox.Margin = New-Object System.Windows.Forms.Padding(16, 0, 16, 12)
$tbl.Controls.Add($script:LogBox, 0, 5)

$form.Controls.Add($tbl)

# =====================================================================
#  ฟังก์ชันของหน้า User
# =====================================================================
function Update-Count {
    $n = @($script:lv.CheckedItems).Count
    $script:lblCount.Text = "เลือกแล้ว $n จาก $($script:lv.Items.Count) รายการ" + $(if ($script:InstalledCount) { "  ·  ติดตั้งแล้ว $($script:InstalledCount)" } else { '' })
    Update-Chips
}

function Update-Chips {
    $all = $true; $none = $true; $mw = $true; $mg = $true
    foreach ($i in $script:lv.Items) {
        if ($i.ToolTipText -like 'installed*') { continue }
        $a = $i.Tag; $c = $i.Checked
        if ($c) { $none = $false } else { $all = $false }
        if ($a.sets) {
            $s = @($a.sets)
            if ($c -ne ($s -contains 'work')) { $mw = $false }
            if ($c -ne ($s -contains 'game')) { $mg = $false }
        }
    }
    Set-ChipOn $script:lnkAll $all; Set-ChipOn $script:lnkNone $none
    Set-ChipOn $script:chipWork $mw; Set-ChipOn $script:chipGame $mg
}

function Apply-Preset([string]$key) {
    $script:lv.BeginUpdate()
    foreach ($i in $script:lv.Items) {
        $a = $i.Tag
        if ($key -eq 'all') { $i.Checked = $true }
        elseif ($key -eq 'none') { $i.Checked = $false }
        elseif ($a.sets) { $i.Checked = (@($a.sets) -contains $key) }
        if ($i.ToolTipText -like 'installed*') { $i.Checked = $false }
    }
    $script:lv.EndUpdate()
    Update-Count
}

# ตรวจโปรแกรมที่มีอยู่แล้ว: ขึ้นป้าย "ติดตั้งแล้ว" และเอาติ๊กออกให้
function Mark-Installed {
    $script:UninstNames = $null
    $cnt = 0
    $script:lv.BeginUpdate()
    foreach ($i in $script:lv.Items) {
        $hit = ''
        try { $hit = Test-AppInstalled $i.Tag } catch { $hit = '' }
        if ($hit) { $i.ToolTipText = 'installed: ' + $hit; $i.Checked = $false; $cnt++ } else { $i.ToolTipText = '' }
    }
    $script:lv.EndUpdate()
    $script:InstalledCount = $cnt
    if ($cnt -gt 0) { Write-Log "ตรวจพบโปรแกรมที่ติดตั้งอยู่แล้ว $cnt รายการ (ขึ้นป้าย 'ติดตั้งแล้ว' และไม่ติ๊กให้)" }
    Update-Count
}

function Refresh-List {
    $script:lv.BeginUpdate()
    $script:lv.Items.Clear()
    $script:lv.Groups.Clear()
    $groups = @{}
    foreach ($a in $script:Apps) {
        $cat = if ($a.category) { [string]$a.category } else { 'อื่น ๆ' }
        if (-not $groups.ContainsKey($cat)) {
            $g = New-Object System.Windows.Forms.ListViewGroup($cat, $cat)
            [void]$script:lv.Groups.Add($g)
            $groups[$cat] = $g
        }
        $item = New-Object System.Windows.Forms.ListViewItem([string]$a.name)
        $item.Group = $groups[$cat]
        $item.Name = $cat
        $item.Tag = $a
        $item.Checked = [bool]$a.checked
        [void]$script:lv.Items.Add($item)
    }
    $script:lv.EndUpdate()
    $script:lv.Columns[0].Width = [Math]::Max(200, $script:lv.ClientSize.Width - 6)
    Update-Count
}

function Set-Busy([bool]$busy) {
    $script:Busy = $busy
    foreach ($c in @($script:lv, $script:btnInstall, $script:btnUndo, $script:lnkAll, $script:lnkNone, $script:chipWork, $script:chipGame, $script:lnkAdmin)) { $c.Enabled = -not $busy }
    $script:btnStop.Enabled = $busy
}

function Show-Detail([bool]$visible) {
    $script:tbl.RowStyles[5].Height = $(if ($visible) { 190 } else { 0 })
    $script:lnkDetail.Text = $(if ($visible) { 'ซ่อนรายละเอียด' } else { 'ดูรายละเอียด' })
}

$script:lv.Add_ItemChecked({ Update-Count })
$script:lnkAll.Add_Click({  Apply-Preset 'all' })
$script:lnkNone.Add_Click({ Apply-Preset 'none' })
$script:chipWork.Add_Click({ Apply-Preset 'work' })
$script:chipGame.Add_Click({ Apply-Preset 'game' })
$script:btnUndo.Add_Click({ Uninstall-All })
$script:btnStop.Add_Click({ $script:Cancel = $true; $script:status.Text = 'กำลังหยุด...' })
$script:lnkDetail.Add_LinkClicked({ Show-Detail ($script:tbl.RowStyles[5].Height -eq 0) })

$script:lnkAdmin.Add_LinkClicked({
    if (-not (Confirm-Admin)) { return }
    if (Show-AdminForm) {
        Refresh-List
        Write-Log 'ผู้ดูแลบันทึกรายการโปรแกรมใหม่แล้ว'
    }
})


# ---------- ส่งสรุปงานขึ้น Google Sheets (ผ่าน Apps Script Web App ของตัวเอง) ----------
$LogUrl = 'https://script.google.com/macros/s/AKfycbzvQ-WJwd7TrbbicqBIt8SYeDvv2Sk9CmO_f7mR8KstHxsBAsrKVZOl4ysMQ_8LDYdWyg/exec'      # ใส่ URL ของ Web App (ลงท้ายด้วย /exec)
$LogToken = 'kawtomservice'    # รหัสลับที่ตั้งไว้ใน Apps Script (ต้องตรงกัน)

function Get-LogConfig {
    $u = $LogUrl; $t = $LogToken
    try {
        if (Test-Path -LiteralPath $SettingsFile) {
            $st = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $SettingsFile -Raw -Encoding UTF8)
            if ($st.logUrl) { $u = [string]$st.logUrl }
            if ($st.logToken) { $t = [string]$st.logToken }
        }
    } catch {}
    return @{ url = $u; token = $t }
}

function Send-JsonToSheet([string]$url, [string]$json) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($json)
        [void](Invoke-WebRequest -Uri $url -Method Post -Body $bytes -ContentType 'application/json; charset=utf-8' -UseBasicParsing -TimeoutSec 20 -MaximumRedirection 0 -ErrorAction Stop)
        return $true
    } catch {
        # Apps Script ตอบกลับด้วย 302 หลังบันทึกแล้ว ถือว่าสำเร็จ
        try { if ([int]$_.Exception.Response.StatusCode -in @(301, 302, 303, 307)) { return $true } } catch {}
        return $false
    }
}

function Send-ReportToSheet($rows, [datetime]$t0) {
    $cfg = Get-LogConfig
    if (-not $cfg.url) { return }
    $cpu = ''; $ram = ''; $free = ''; $gpu = ''; $os = ''
    try { $cpu = ((Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1).Name).Trim() } catch {}
    try { $ram = [string][math]::Round((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory / 1GB) } catch {}
    try { $free = [string][math]::Round((Get-PSDrive -Name ($env:SystemDrive.Substring(0, 1))).Free / 1GB) } catch {}
    try { $gpu = (@(Get-CimInstance Win32_VideoController -ErrorAction Stop | ForEach-Object { $_.Name }) -join ', ') } catch {}
    try { $os = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Caption } catch { $os = [Environment]::OSVersion.VersionString }
    $ok = @($rows | Where-Object { $_.status -eq 'ok' }); $sk = @($rows | Where-Object { $_.status -eq 'skip' }); $fl = @($rows | Where-Object { $_.status -eq 'fail' })
    $payload = [ordered]@{
        token = $cfg.token
        time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        computer = $env:COMPUTERNAME
        os = $os; cpu = $cpu; ramGb = $ram; diskFreeGb = $free; gpu = $gpu
        ok = $ok.Count; skip = $sk.Count; fail = $fl.Count
        failed = (($fl | ForEach-Object { $_.name + ' (' + $_.note + ')' }) -join ' | ')
        installed = (($ok | ForEach-Object { $_.name }) -join ', ')
        skipped = (($sk | ForEach-Object { $_.name }) -join ', ')
        minutes = [math]::Round(((Get-Date) - $t0).TotalMinutes, 1)
    }
    $json = ConvertTo-Json -InputObject $payload -Compress
    $pend = Join-Path $DataDir 'pending'
    # ส่งงานที่ค้างจากครั้งก่อน (ตอนไม่มีเน็ต) ก่อน
    if (Test-Path -LiteralPath $pend) {
        foreach ($pf in @(Get-ChildItem -LiteralPath $pend -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
            if (Send-JsonToSheet $cfg.url (Get-Content -LiteralPath $pf.FullName -Raw -Encoding UTF8)) { Remove-Item -LiteralPath $pf.FullName -Force -ErrorAction SilentlyContinue }
        }
    }
    if (Send-JsonToSheet $cfg.url $json) { Write-Log 'ส่งสรุปงานขึ้น Google Sheets แล้ว' }
    else {
        try {
            if (-not (Test-Path -LiteralPath $pend)) { [void](New-Item -ItemType Directory -Path $pend -Force) }
            [IO.File]::WriteAllText((Join-Path $pend ((Get-Date).ToString('yyyyMMdd-HHmmss') + '.json')), $json, (New-Object System.Text.UTF8Encoding($false)))
        } catch {}
        Write-Log 'ส่งขึ้น Google Sheets ไม่สำเร็จ (ไม่มีเน็ต?) - เก็บไว้ส่งใหม่ครั้งหน้า'
    }
}

# ---------- รายงานสรุปท้ายงาน (HTML เก็บ/ส่งให้ลูกค้า) ----------
function Save-Report($rows) {
    $enc = { param($t) [System.Net.WebUtility]::HtmlEncode([string]$t) }
    $cnt = @{ ok = 0; skip = 0; fail = 0 }
    foreach ($r in $rows) { $cnt[$r.status]++ }
    $os = ''; try { $os = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Caption } catch { $os = [Environment]::OSVersion.VersionString }
    $now = Get-Date
    $label = @{ ok = 'ติดตั้ง/ตั้งค่าสำเร็จ'; skip = 'ข้าม'; fail = 'ไม่สำเร็จ' }
    $color = @{ ok = '#166534'; skip = '#92400e'; fail = '#b91c1c' }
    $bg = @{ ok = '#dcfce7'; skip = '#fef3c7'; fail = '#fee2e2' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<!doctype html><html lang="th"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>รายงานการติดตั้ง</title>')
    [void]$sb.AppendLine('<style>body{font-family:"Segoe UI","Leelawadee UI",Tahoma,sans-serif;background:#f4f6fb;color:#111827;margin:0;padding:24px}.card{max-width:820px;margin:0 auto;background:#fff;border-radius:16px;padding:28px 32px;box-shadow:0 2px 12px rgba(0,0,0,.06)}h1{margin:0 0 4px;font-size:24px}.sub{color:#6b7280;font-size:14px;margin-bottom:20px}.sum{display:flex;gap:12px;margin:18px 0}.box{flex:1;border-radius:12px;padding:12px 16px;font-size:14px}.box b{display:block;font-size:26px}table{width:100%;border-collapse:collapse;font-size:15px}td{padding:10px 8px;border-bottom:1px solid #eef0f4;vertical-align:top}.pill{display:inline-block;border-radius:999px;padding:2px 12px;font-size:13px;font-weight:600;white-space:nowrap}.note{color:#6b7280;font-size:13px}.foot{margin-top:22px;color:#9ca3af;font-size:12px}</style></head><body><div class="card">')
    [void]$sb.AppendLine('<h1>รายงานการติดตั้งโปรแกรม</h1>')
    [void]$sb.AppendLine('<div class="sub">เครื่อง: ' + (& $enc $env:COMPUTERNAME) + ' &nbsp;·&nbsp; ' + (& $enc $os) + ' &nbsp;·&nbsp; ' + $now.ToString('dd/MM/yyyy HH:mm') + '</div>')
    [void]$sb.AppendLine('<div class="sum">')
    foreach ($k in @('ok', 'skip', 'fail')) { [void]$sb.AppendLine('<div class="box" style="background:' + $bg[$k] + ';color:' + $color[$k] + '"><b>' + $cnt[$k] + '</b>' + $label[$k] + '</div>') }
    [void]$sb.AppendLine('</div><table>')
    foreach ($r in $rows) {
        [void]$sb.AppendLine('<tr><td>' + (& $enc $r.name) + '</td><td><span class="pill" style="background:' + $bg[$r.status] + ';color:' + $color[$r.status] + '">' + $label[$r.status] + '</span>' + $(if ($r.note) { '<div class="note">' + (& $enc $r.note) + '</div>' } else { '' }) + '</td></tr>')
    }
    [void]$sb.AppendLine('</table><div class="foot">สร้างโดย Auto Installer</div></div></body></html>')

    $name = 'AutoInstaller-Report_' + $env:COMPUTERNAME + '_' + $now.ToString('yyyyMMdd-HHmm') + '.html'
    $targets = @($ScriptDir, (Join-Path $DataDir 'Reports'))
    foreach ($dir in $targets) {
        try {
            if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
            $path = Join-Path $dir $name
            [IO.File]::WriteAllText($path, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
            return $path
        } catch { continue }
    }
    return ''
}

$script:btnInstall.Add_Click({
    $sel = @($script:lv.CheckedItems | ForEach-Object { $_.Tag })
    if ($sel.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show('ยังไม่ได้เลือกโปรแกรมที่จะติดตั้ง', 'Auto Installer', 'OK', 'Information')
        return
    }
    # เรียงลำดับ: ตั้งค่าเครื่องที่ไม่ต้องรอโปรแกรมก่อน -> ฟอนต์ -> โปรแกรมเล็กๆ -> ตัวใหญ่/ช้า (Office, ไดรเวอร์) -> ช็อตคัตท้ายสุด
    $i = 0
    $sel = @($sel | ForEach-Object {
        $rk = 2
        if ($_.type -eq 'task') { if ($_.task -in @('desktop-shortcuts', 'web-shortcuts', 'chrome-thai')) { $rk = 9 } else { $rk = 0 } }
        elseif ($_.type -eq 'fonts') { $rk = 1 }
        elseif ([string]$_.name -match 'Office|Project|Visio|NVIDIA|AMD') { $rk = 5 }
        [pscustomobject]@{ R = $rk; I = $i++; A = $_ }
    } | Sort-Object R, I | ForEach-Object { $_.A })
    $script:Cancel = $false
    Set-Busy $true
    $script:bar.Minimum = 0; $script:bar.Maximum = $sel.Count; $script:bar.Value = 0
    $okList = @(); $failList = @(); $rows = New-Object System.Collections.ArrayList; $t0 = Get-Date
    Write-Log "เริ่มติดตั้ง $($sel.Count) โปรแกรม"

    $script:UninstNames = $null
    $n = 0
    foreach ($app in $sel) {
        if ($script:Cancel) { break }
        $n++
        $script:status.Text = "($n/$($sel.Count)) กำลังติดตั้ง $($app.name) ..."
        Write-Log ">> $($app.name)"
        try {
            $already = ''
            if ($script:Prefetch -and $app.type -ne 'url') { Write-Log '   ข้าม (โหมดเตรียมแคชโหลดเฉพาะโปรแกรมที่ดาวน์โหลดจากเว็บ)'; $n2 = 1 }
            if ($script:Prefetch -and $app.type -ne 'url') { $script:bar.Value = [Math]::Min($n, $script:bar.Maximum); continue }
            if (-not $script:ForceReinstall -and -not $script:Prefetch) { try { $already = Test-AppInstalled $app } catch { $already = '' } }
            $res = if ($already) { "have:$already" } else { switch ($app.type) {
                'url'   { Install-Url $app }
                'file'  { Install-File $app }
                'fonts' { Install-Fonts $app }
                'task'  { Install-Task $app }
                default { Install-Winget $app }
            } }
            switch ($res) {
                'ok'     { Write-Log '   สำเร็จ'; $okList += $app.name; [void]$rows.Add(@{ name = $app.name; status = 'ok'; note = '' }) }
                'exists' { Write-Log '   มีอยู่แล้ว/เป็นเวอร์ชันล่าสุดแล้ว'; $okList += $app.name; [void]$rows.Add(@{ name = $app.name; status = 'skip'; note = 'มีอยู่แล้ว/เป็นเวอร์ชันล่าสุดแล้ว' }) }
                { $_ -like 'have:*' } { Write-Log ('   มีอยู่ในเครื่องแล้ว (' + $res.Substring(5) + ') - ข้าม'); $okList += $app.name; [void]$rows.Add(@{ name = $app.name; status = 'skip'; note = 'มีอยู่ในเครื่องแล้ว' }) }
                'cancel' { Write-Log '   ถูกหยุด'; [void]$rows.Add(@{ name = $app.name; status = 'skip'; note = 'ถูกหยุดกลางคัน' }) }
                'skip'   { Write-Log '   ข้าม (ไม่มีอะไรให้ทำ)'; [void]$rows.Add(@{ name = $app.name; status = 'skip'; note = 'ไม่จำเป็นสำหรับเครื่องนี้' }) }
            }
        } catch {
            Write-Log "   ล้มเหลว: $($_.Exception.Message)"
            $failList += $app.name
            $fm = [string]$_.Exception.Message; if ($fm.Length -gt 200) { $fm = $fm.Substring(0, 200) + '...' }
            [void]$rows.Add(@{ name = $app.name; status = 'fail'; note = $fm })
        }
        $script:bar.Value = [Math]::Min($n, $script:bar.Maximum)
    }

    if ($script:Cancel) { $script:status.Text = 'หยุดการติดตั้งแล้ว' }
    else { $script:status.Text = "เสร็จสิ้น: สำเร็จ $($okList.Count) รายการ" + $(if ($failList.Count) { ", ไม่สำเร็จ $($failList.Count) รายการ" } else { '' }) }
    Write-Log $script:status.Text
    Set-Busy $false
    $script:FailCount = $failList.Count
    # อัพเดทป้าย "ติดตั้งแล้ว" ทันทีหลังติดตั้งเสร็จ
    Mark-Installed

    $reportPath = ''
    if ($script:Prefetch) { $rows.Clear() }
    if ($rows.Count -gt 0) {
        try { $reportPath = Save-Report $rows } catch { $reportPath = '' }
        if ($reportPath) { Write-Log "บันทึกรายงานสรุปไว้ที่ $reportPath" }
    }
    if ($rows.Count -gt 0) { try { Send-ReportToSheet $rows $t0 } catch { Write-Log ('ส่งขึ้น Google Sheets ผิดพลาด: ' + $_.Exception.Message) } }
    if ($Auto) { return }
    if ($failList.Count -gt 0) {
        Show-Detail $true
        [void][System.Windows.Forms.MessageBox]::Show(
            ("ติดตั้งเสร็จแล้ว แต่มี $($failList.Count) รายการที่ไม่สำเร็จ:`r`n`r`n" + ($failList -join "`r`n") + "`r`n`r`nดูสาเหตุได้ในช่อง 'รายละเอียด' ด้านล่าง"),
            'Auto Installer', 'OK', 'Warning')
    } elseif (-not $script:Cancel) {
        [void][System.Windows.Forms.MessageBox]::Show('ติดตั้งครบทุกรายการเรียบร้อยแล้ว', 'Auto Installer', 'OK', 'Information')
    }
    if ($reportPath) {
        $q = [System.Windows.Forms.MessageBox]::Show("บันทึกรายงานสรุปแล้วที่:`r`n$reportPath`r`n`r`nเปิดดูเลยไหม?", 'รายงานสรุป', 'YesNo', 'Question')
        if ($q -eq 'Yes') { try { Start-Process -FilePath $reportPath } catch {} }
    }
})

$form.Add_FormClosing({
    if ($script:Busy) {
        [void][System.Windows.Forms.MessageBox]::Show('กำลังติดตั้งอยู่ กด "หยุด" ก่อนปิดโปรแกรม', 'Auto Installer', 'OK', 'Information')
        $_.Cancel = $true
    }
})


# ---------- รหัสผ่านก่อนใช้โปรแกรม + ตรวจอินเทอร์เน็ต ----------
$StartPinHash = 'F7FFB9B6EA0D91D85D86C75D82B4E06D200BCE0E68E368F0734D282E083159D0'
function Confirm-StartPin {
    if ($Auto) { return $true }   # โหมด /auto = งานอัตโนมัติ ไม่มีคนนั่งกรอก
    for ($i = 0; $i -lt 5; $i++) {
        $pin = Read-Text 'Auto Installer' 'กรุณาใส่รหัสผ่านเพื่อใช้งานโปรแกรม' $true
        if ($null -eq $pin) { return $false }
        if ((Get-PinHash $pin) -eq $StartPinHash) { return $true }
        [void][System.Windows.Forms.MessageBox]::Show('รหัสผ่านไม่ถูกต้อง', 'Auto Installer', 'OK', 'Warning')
    }
    return $false
}

function Test-Internet {
    foreach ($u in @('http://www.msftconnecttest.com/connecttest.txt', 'https://www.google.com/generate_204', 'https://www.cloudflare.com/cdn-cgi/trace')) {
        try {
            $rq = [System.Net.WebRequest]::Create($u)
            $rq.Timeout = 5000; $rq.Proxy = [System.Net.WebRequest]::GetSystemWebProxy()
            $rp = $rq.GetResponse(); $rp.Close()
            return $true
        } catch {}
    }
    return $false
}

function Confirm-Internet {
    while ($true) {
        if (Test-Internet) { Write-Log 'ตรวจอินเทอร์เน็ต: เชื่อมต่อได้'; $script:status.Text = 'เชื่อมต่ออินเทอร์เน็ตแล้ว'; return }
        Write-Log 'ตรวจอินเทอร์เน็ต: ไม่พบการเชื่อมต่อ'
        if ($Auto) { return }
        $r = [System.Windows.Forms.MessageBox]::Show("ไม่พบการเชื่อมต่ออินเทอร์เน็ต`n`nโปรแกรมที่ต้องดาวน์โหลด (Chrome, Zoom, Discord ฯลฯ และตัวติดตั้ง Office ที่ต้องโหลดไฟล์เพิ่ม) จะติดตั้งไม่ได้`n`nต่อเน็ตแล้วกด 'ลองใหม่' หรือกด 'ยกเลิก' เพื่อทำต่อแบบออฟไลน์", 'ตรวจสอบอินเทอร์เน็ต', 'RetryCancel', 'Warning')
        if ($r -ne 'Retry') { $script:status.Text = 'ออฟไลน์ - เฉพาะรายการที่ไม่ต้องดาวน์โหลด'; return }
    }
}

# ---------- เริ่มทำงาน ----------
try {
    Load-Apps
    Load-Undo
    Refresh-List
    Mark-Installed
    $gp = Get-GpuVendors
    Write-Log ('การ์ดจอที่ตรวจพบ: ' + $(if ($gp.Count) { ($gp -join ', ').ToUpper() } else { 'ไม่ใช่ NVIDIA/AMD' }))
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Log 'คำเตือน: ไม่พบ winget - รายการแบบ winget จะติดตั้งไม่ได้ (ต้องมี App Installer จาก Microsoft Store)'
        $script:status.Text = 'ไม่พบ winget ในเครื่องนี้ (ดูรายละเอียด)'
    }
} catch {
    [void][System.Windows.Forms.MessageBox]::Show("อ่านไฟล์ apps.json ไม่ได้:`n$($_.Exception.Message)", 'ผิดพลาด')
}

# ดึงหน้าต่างมาไว้ข้างหน้าเสมอ (โปรแกรมที่เพิ่งยกระดับสิทธิ์มักเปิดซ่อนอยู่ข้างหลัง)
$script:FailCount = 0
$form.Add_Shown({
    $script:form.WindowState = 'Normal'
    if (-not (Confirm-StartPin)) { $script:form.Opacity = 1; $script:form.Close(); return }
    $script:form.Opacity = 1
    Confirm-Internet
    $script:form.TopMost = $true
    [void]$script:form.Activate()
    $script:form.BringToFront()
    $script:form.TopMost = $false
    if ($Go -or $Prefetch) {
        if ($Prefetch) { Write-Log 'โหมดเตรียมแคช: ดาวน์โหลดตัวติดตั้งเก็บไว้ในแฟลชไดรฟ์ (ไม่ติดตั้งอะไร)' }
        Write-Log 'ติดตั้งทันที: เริ่มติดตั้งรายการที่ติ๊กไว้ทั้งหมด'
        $script:btnInstall.PerformClick()
    }
    if ($Auto) {
        # โหมดอัตโนมัติ: ติดตั้งรายการที่ติ๊กไว้ทั้งหมดโดยไม่ถามอะไร แล้วปิดตัวเอง
        Write-Log 'โหมดอัตโนมัติ (/auto): เริ่มติดตั้งทันที'
        $script:btnInstall.PerformClick()
        Write-Log 'โหมดอัตโนมัติ: เสร็จสิ้น'
        $script:form.Close()
    }
})
if (-not $Auto) { $form.Opacity = 0 }
[void]$form.ShowDialog()
if ($Auto) { exit $(if ($script:FailCount -gt 0) { 1 } else { 0 }) }
