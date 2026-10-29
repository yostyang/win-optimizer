# Windows一键优化 v0.2 —— PowerShell 5.1 + WPF，单文件，无需安装
# 原则：只在你点按钮时才动手；需要管理员权限的修复会单独弹出 UAC。
# 临时文件清理会先列出并确认，优先放进回收站。其它改动都记在 undo.json，可以恢复。
#Requires -Version 5.1

param(
    [switch]$Smoke,          # CI：加载界面、跑体检、截图后退出，不进入交互
    [int]$SmokeSeconds = 12, # 交互冒烟时保持窗口打开的秒数（0 = 一直开着）
    [switch]$SelfTest,       # 不显示窗口：Win10 路径和可脚本项的往返测试
    [int]$MockBuild = 0      # 假装的系统版本号，例如 19045。0 = 读真实系统
)
$ErrorActionPreference = 'Stop'
$AppVersion = '0.2'
$AppName = 'Windows一键优化'
if ($MockBuild) { $script:MockBuild = [int]$MockBuild }
elseif ($env:WINOPT_MOCK_BUILD) { $script:MockBuild = [int]$env:WINOPT_MOCK_BUILD }

if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $extra = @()
    if ($Smoke) { $extra += '-Smoke' }
    if ($SelfTest) { $extra += '-SelfTest' }
    if ($MockBuild) { $extra += @('-MockBuild', "$MockBuild") }
    if ($PSBoundParameters.ContainsKey('SmokeSeconds')) { $extra += @('-SmokeSeconds', "$SmokeSeconds") }
    $exe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" }
    # 用当前进程同款宿主，并把 -Smoke 参数原样带过去
    $argList = @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File', $PSCommandPath) + $extra
    $p = Start-Process -FilePath $exe -ArgumentList $argList -Wait -PassThru
    exit $p.ExitCode
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, Microsoft.VisualBasic

Add-Type -Namespace WinOpt -Name Native -MemberDefinition @'
[DllImport("user32.dll", SetLastError=true)]
public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, ref int pvParam, uint fWinIni);
[DllImport("user32.dll", SetLastError=true)]
public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, IntPtr pvParam, uint fWinIni);
[StructLayout(LayoutKind.Sequential)]
public struct ANIMATIONINFO { public uint cbSize; public int iMinAnimate; }
[DllImport("user32.dll", SetLastError=true, EntryPoint="SystemParametersInfo")]
public static extern bool SPIAnim(uint uiAction, uint uiParam, ref ANIMATIONINFO pvParam, uint fWinIni);
[DllImport("kernel32.dll")]
static extern bool GetSystemTimes(out long idle, out long kernel, out long user);
public static long[] ReadCpuTimes() {
    long idle = 0, kernel = 0, user = 0;
    if (!GetSystemTimes(out idle, out kernel, out user)) return null;
    return new long[] { idle, kernel, user };
}
[DllImport("powrprof.dll")]
static extern uint PowerGetActiveScheme(IntPtr root, out IntPtr guid);
[DllImport("powrprof.dll")]
static extern uint PowerSetActiveScheme(IntPtr root, ref Guid scheme);
[DllImport("kernel32.dll")]
static extern IntPtr LocalFree(IntPtr h);
[DllImport("powrprof.dll")]
static extern uint PowerGetUserConfiguredACPowerMode(out Guid mode);
[DllImport("powrprof.dll")]
static extern uint PowerSetUserConfiguredACPowerMode(ref Guid mode);
[DllImport("powrprof.dll")]
static extern uint PowerGetUserConfiguredDCPowerMode(out Guid mode);
[DllImport("powrprof.dll")]
static extern uint PowerSetUserConfiguredDCPowerMode(ref Guid mode);
public static string ReadActiveScheme() {
    IntPtr p = IntPtr.Zero;
    uint rc = PowerGetActiveScheme(IntPtr.Zero, out p);
    if (rc != 0 || p == IntPtr.Zero) return "";
    Guid g = (Guid)Marshal.PtrToStructure(p, typeof(Guid));
    LocalFree(p);
    return g.ToString("D");
}
public static int WriteActiveScheme(string guidText) {
    Guid g = new Guid(guidText);
    return (int)PowerSetActiveScheme(IntPtr.Zero, ref g);
}
public static string ReadPowerMode(bool dc) {
    try {
        Guid g = Guid.Empty;
        uint rc = dc ? PowerGetUserConfiguredDCPowerMode(out g) : PowerGetUserConfiguredACPowerMode(out g);
        if (rc != 0) return "err:" + rc.ToString();
        return g.ToString("D");
    } catch (EntryPointNotFoundException) { return "missing"; }
    catch (DllNotFoundException) { return "missing"; }
}
public static int WritePowerMode(bool dc, string guidText) {
    try {
        Guid g = new Guid(guidText);
        uint rc = dc ? PowerSetUserConfiguredDCPowerMode(ref g) : PowerSetUserConfiguredACPowerMode(ref g);
        return (int)rc;
    } catch (EntryPointNotFoundException) { return -1; }
    catch (DllNotFoundException) { return -1; }
}
'@

# ---------------- 数据目录 ----------------
$DataDir = Join-Path $env:APPDATA 'WinOptimizer'
if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir | Out-Null }
$DnsBackup = Join-Path $DataDir 'dns-backup.json'
$PriorityBackup = Join-Path $DataDir 'priority-backup.json'
$AliDns = @('223.5.5.5','223.6.6.6')
# 经典电源计划，以及 Windows 11 电源模式滑杆（旧称 overlay）。GUID 不随语言变化，x64 / ARM64 都一样。
$script:PlanBalanced = '381b4222-f694-41f0-9685-ff5bb260df2e'
$script:PlanSaver    = 'a1841308-3541-4fab-bc81-f71556f20b4a'
$script:PlanHigh     = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
# Windows 10 电池图标滑杆（电源覆盖方案，要挂在「平衡」计划上才不会变灰）
# 更好的电池 / 更高性能 / 最佳性能。最左档「最佳电池续航」是节电模式，不是覆盖方案。
$script:OverlayEfficiency  = '961cc777-2547-4f9d-8174-7d86181b8a7a' # 更好的电池
$script:OverlayBalanced    = '00000000-0000-0000-0000-000000000000' # 更高性能（默认，无覆盖）
$script:OverlayPerformance = 'ded574b5-45a0-4f42-8737-46345c09c238' # 最佳性能

# ---------------- 工具函数 ----------------
function Format-Bytes([double]$b) {
    if ($b -ge 1GB) { return ('{0:N1} GB' -f ($b / 1GB)) }
    if ($b -ge 1MB) { return ('{0:N0} MB' -f ($b / 1MB)) }
    return ('{0:N0} KB' -f ($b / 1KB))
}
function Format-Uptime([TimeSpan]$t) {
    if ($t.TotalDays -ge 1) { return ('{0} 天 {1} 小时' -f [int][math]::Floor($t.TotalDays), $t.Hours) }
    return ('{0} 小时 {1} 分钟' -f $t.Hours, $t.Minutes)
}
function Confirm-Action([string]$msg, [string]$title = '确认') {
    $r = [System.Windows.MessageBox]::Show($msg, $title, 'YesNo', 'Question')
    return ($r -eq 'Yes')
}
function Show-Info([string]$msg, [string]$title = $AppName) {
    [void][System.Windows.MessageBox]::Show($msg, $title, 'OK', 'Information')
}
function Test-IsAdmin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
# 需要管理员的操作：写成临时脚本，用 UAC 提权运行（用户可以拒绝）
function Invoke-Elevated([string]$script) {
    if (Test-IsAdmin) {
        try { & ([scriptblock]::Create($script)); return $true } catch { return $false }
    }
    $tmp = Join-Path $env:TEMP ("winopt-" + [guid]::NewGuid().ToString('N') + '.ps1')
    $wrapped = "`$ErrorActionPreference='Stop'`r`ntry {`r`n$script`r`n exit 0 } catch { Write-Host `$_; Start-Sleep 3; exit 1 }"
    [IO.File]::WriteAllText($tmp, $wrapped, (New-Object Text.UTF8Encoding($true)))
    try {
        $p = Start-Process powershell.exe -Verb RunAs -Wait -PassThru -WindowStyle Hidden `
            -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$tmp`"")
        return ($p.ExitCode -eq 0)
    } catch {
        return $false   # 用户在 UAC 里点了「否」
    } finally {
        Remove-Item $tmp -ErrorAction SilentlyContinue
    }
}

# ---------------- 后台任务（不卡界面） ----------------
$script:Jobs = New-Object System.Collections.ArrayList
function Start-Bg([scriptblock]$work, [scriptblock]$done, $arg = $null) {
    $ps = [powershell]::Create()
    [void]$ps.AddScript($work)
    if ($null -ne $arg) { [void]$ps.AddArgument($arg) }
    $h = $ps.BeginInvoke()
    [void]$script:Jobs.Add(@{ ps = $ps; h = $h; done = $done })
}
function Poll-Bg {
    foreach ($j in @($script:Jobs)) {
        if ($j.h.IsCompleted) {
            $res = $null
            try { $res = $j.ps.EndInvoke($j.h) } catch { $res = $null }
            $j.ps.Dispose()
            $script:Jobs.Remove($j)
            try { & $j.done $res } catch { }
        }
    }
}

# ---------------- 系统信息 ----------------
# Win32_Processor.LoadPercentage 在第一次查询、以及 Windows Server / 虚拟机上经常是 0 或 null，
# [int]$null 会变成 0，看起来像「没识别到 CPU」。这里改用 kernel32!GetSystemTimes（和任务管理器同一类数据）：
# 只保留上一拍的时间戳，刷新时算差值，不每次阻塞界面。读失败返回 $null，界面显示「—」，不伪装成 0%。
$script:CpuState = @{
    HaveTimes = $false
    Idle = [int64]0; Kernel = [int64]0; User = [int64]0
    Source = $null
    Counter = $null; CounterSeen = $false
    RawN = [int64]0; RawD = [int64]0; HaveRaw = $false
}
$script:LastCpuPct = $null
$script:ProtectedNames = @(
    'system','csrss','wininit','services','lsass','smss','dwm','explorer',
    'idle','registry','secure system','memory compression','fontdrvhost','winlogon'
)
$script:CpuHogNote = @{
    'searchindexer' = 'Windows 搜索正在建立索引，CPU 会暂时偏高，索引完成后会自己降下来。本工具不会关闭搜索服务。'
    'msmpeng' = 'Windows 安全中心正在扫描，扫描结束占用会下降。本工具不会关闭 Defender。'
    'tiworker' = 'Windows 正在安装更新组件，完成后这个进程会退出。本工具不会停用 Windows 更新。'
    'trustedinstaller' = 'Windows 模块安装程序正在更新系统组件，完成后会自己结束。本工具不会停用更新服务。'
    'onedrive' = 'OneDrive 正在同步文件，同步完成后占用会下降。可以在 OneDrive 里暂停同步。本工具不会关掉它。'
}

function Read-SystemCpuTimes {
    try {
        $t = [WinOpt.Native]::ReadCpuTimes()
        if ($null -eq $t -or @($t).Count -lt 3) { return $null }
        return $t
    } catch { return $null }
}
function Convert-CpuPct([double]$pct) {
    if ([double]::IsNaN($pct) -or [double]::IsInfinity($pct)) { return $null }
    if ($pct -lt -1 -or $pct -gt 101) { return $null }
    if ($pct -lt 0) { $pct = 0 }
    if ($pct -gt 100) { $pct = 100 }
    return [int][math]::Round($pct)
}
function Get-TimesPct($a, $b) {
    if ($null -eq $a -or $null -eq $b) { return $null }
    $idle = [int64]$b[0] - [int64]$a[0]
    $total = ([int64]$b[1] - [int64]$a[1]) + ([int64]$b[2] - [int64]$a[2])
    if ($total -le 0 -or $idle -lt 0 -or $idle -gt $total) { return $null }
    return (Convert-CpuPct (100.0 * ($total - $idle) / [double]$total))
}
function Reset-CpuSample {
    # 下一拍才出数。短间隔不会把失败记成 0。
    $script:LastCpuPct = $null
    $t = Read-SystemCpuTimes
    if ($null -eq $t) {
        $script:CpuState.HaveTimes = $false
        $script:CpuState.Source = $null
        return $false
    }
    $script:CpuState.HaveTimes = $true
    $script:CpuState.Idle = [int64]$t[0]
    $script:CpuState.Kernel = [int64]$t[1]
    $script:CpuState.User = [int64]$t[2]
    $script:CpuState.Source = 'GetSystemTimes'
    return $true
}
function Get-CpuPercentFallback {
    # GetSystemTimes 不可用时才走到这里。性能计数器的名字随系统语言变化，所以英文名失败就换 WMI 原始计数器。
    $st = $script:CpuState
    if ($null -eq $st.Counter -and -not $st.HaveRaw) {
        foreach ($pair in @(
            @('Processor', '% Processor Time', '_Total'),
            @('Processor Information', '% Processor Time', '_Total')
        )) {
            try {
                $pc = New-Object System.Diagnostics.PerformanceCounter($pair[0], $pair[1], $pair[2], $true)
                try { [void]$pc.NextValue() } catch { }
                $st.Counter = $pc
                $st.CounterSeen = $false
                $st.Source = 'PerformanceCounter'
                return $null
            } catch { }
        }
    }
    if ($st.Counter) {
        try {
            $v = [double]$st.Counter.NextValue()
            # 第一次 NextValue 按文档恒为 0，丢掉，避免又把「还没采样」显示成 0%
            if (-not $st.CounterSeen) { $st.CounterSeen = $true; $st.Source = 'PerformanceCounter'; return $script:LastCpuPct }
            $pct = Convert-CpuPct $v
            if ($null -eq $pct) { return $null }
            $script:LastCpuPct = $pct
            $st.Source = 'PerformanceCounter'
            return $pct
        } catch {
            try { $st.Counter.Dispose() } catch { }
            $st.Counter = $null
            $st.CounterSeen = $false
        }
    }
    try {
        $s = Get-CimInstance -ClassName Win32_PerfRawData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop
        $n = [int64]$s.PercentProcessorTime
        $d = [int64]$s.Timestamp_Sys100NS
        if (-not $st.HaveRaw) {
            $st.HaveRaw = $true; $st.RawN = $n; $st.RawD = $d; $st.Source = 'PerfRaw'
            return $null
        }
        $dN = $n - $st.RawN; $dD = $d - $st.RawD
        $st.RawN = $n; $st.RawD = $d; $st.Source = 'PerfRaw'
        if ($dD -le 0) { return $null }
        $pct = Convert-CpuPct ((1.0 - ($dN / [double]$dD)) * 100.0)
        if ($null -eq $pct) { return $null }
        $script:LastCpuPct = $pct
        return $pct
    } catch { }
    try {
        $vals = @(Get-CimInstance Win32_Processor -ErrorAction Stop | ForEach-Object { $_.LoadPercentage } | Where-Object { $null -ne $_ })
        if ($vals.Count -eq 0) { return $null }
        $pct = Convert-CpuPct (($vals | Measure-Object -Average).Average)
        if ($null -eq $pct) { return $null }
        $script:LastCpuPct = $pct
        $st.Source = 'Win32_Processor'
        return $pct
    } catch { return $null }
}
function Get-CpuPercent {
    $cur = Read-SystemCpuTimes
    if ($null -ne $cur) {
        $st = $script:CpuState
        if (-not $st.HaveTimes) {
            $st.HaveTimes = $true
            $st.Idle = [int64]$cur[0]; $st.Kernel = [int64]$cur[1]; $st.User = [int64]$cur[2]
            $st.Source = 'GetSystemTimes'
            return $null
        }
        $totalD = ([int64]$cur[1] - [int64]$st.Kernel) + ([int64]$cur[2] - [int64]$st.User)
        if ($totalD -lt 500000) {
            # 不到约 50ms：保持上一拍基线，下次一并算进去。不把这一拍写成 0。
            $st.Source = 'GetSystemTimes'
            return $script:LastCpuPct
        }
        $pct = Get-TimesPct @([int64]$st.Idle, [int64]$st.Kernel, [int64]$st.User) $cur
        $st.Idle = [int64]$cur[0]; $st.Kernel = [int64]$cur[1]; $st.User = [int64]$cur[2]
        $st.Source = 'GetSystemTimes'
        if ($null -eq $pct) { return $null }
        $script:LastCpuPct = $pct
        return $pct
    }
    if ($script:CpuState.HaveTimes) {
        $script:CpuState.Source = 'GetSystemTimes'
        return $null
    }
    return (Get-CpuPercentFallback)
}
function Get-Overview {
    $cpu = Get-CpuPercent
    $os = Get-CimInstance Win32_OperatingSystem
    $total = [double]$os.TotalVisibleMemorySize * 1KB
    $free = [double]$os.FreePhysicalMemory * 1KB
    [pscustomobject]@{
        Cpu = $cpu
        CpuSource = $script:CpuState.Source
        MemTotal = $total
        MemFree = $free
        MemUsedPct = [int](100 * ($total - $free) / $total)
        Uptime = (Get-Date) - $os.LastBootUpTime
        OsName = $os.Caption
    }
}
function Test-ProtectedProcess($p) {
    if ($null -eq $p) { return $true }
    try { if ([int]$p.Id -eq $PID) { return $true } } catch { }
    $n = [string]$p.ProcessName
    if ([string]::IsNullOrWhiteSpace($n)) { $n = [string]$p.Name }
    if ([string]::IsNullOrWhiteSpace($n)) { return $true }
    return ($script:ProtectedNames -contains $n.ToLower())
}
function Get-CpuHogNote([string]$name) {
    if (-not $name) { return $null }
    $n = $name.ToLower()
    if ($script:CpuHogNote.ContainsKey($n)) { return $script:CpuHogNote[$n] }
    if ($n -like 'onedrive*') { return $script:CpuHogNote['onedrive'] }
    return $null
}

$BrowserNames = @{
    'chrome' = 'Chrome'; 'msedge' = 'Edge'; 'firefox' = 'Firefox'; 'brave' = 'Brave'
    'opera' = 'Opera'; 'vivaldi' = 'Vivaldi'; '360se' = '360 安全浏览器'; '360chrome' = '360 极速浏览器'
    'qqbrowser' = 'QQ 浏览器'; 'sogouexplorer' = '搜狗浏览器'; 'arc' = 'Arc'
}
function Get-Browsers {
    $list = @()
    foreach ($k in $BrowserNames.Keys) {
        $ps = @(Get-Process -Name $k -ErrorAction SilentlyContinue)
        if ($ps.Count -gt 0) {
            $mem = ($ps | Measure-Object WorkingSet64 -Sum).Sum
            $list += [pscustomobject]@{ Key = $k; Name = $BrowserNames[$k]; Count = $ps.Count; Mem = (Format-Bytes $mem); MemRaw = $mem; Selected = $false }
        }
    }
    return @($list | Sort-Object MemRaw -Descending)
}
function Close-Browser([string]$key) {
    # 只发送「关闭窗口」，和点右上角 × 一样，浏览器会自己保存标签页
    foreach ($p in @(Get-Process -Name $key -ErrorAction SilentlyContinue)) {
        if ($p.MainWindowHandle -ne 0) { [void]$p.CloseMainWindow() }
    }
}

$VpnPattern = 'TAP|TUN|WireGuard|Wintun|VPN|Clash|OpenVPN|Fortinet|Cisco AnyConnect|ZeroTier|Tailscale|Hamachi|Sangfor|EasyConnect'
function Get-VpnAdapters {
    try {
        return @(Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' -and ($_.InterfaceDescription -match $VpnPattern -or $_.Name -match $VpnPattern) })
    } catch { return @() }
}
function Get-PhysicalUpAdapters {
    try {
        return @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' })
    } catch { return @() }
}
function Get-CurrentDns {
    $out = @()
    foreach ($a in Get-PhysicalUpAdapters) {
        $d = Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        $out += [pscustomobject]@{ Index = $a.ifIndex; Name = $a.Name; Servers = @($d.ServerAddresses) }
    }
    return $out
}
function Test-DnsIsAli {
    $d = @(Get-CurrentDns)
    if ($d.Count -eq 0) { return $true }
    foreach ($x in $d) { if (-not ($x.Servers -contains '223.5.5.5')) { return $false } }
    return $true
}
function Set-AliDns {
    $cur = @(Get-CurrentDns)
    if ($cur.Count -eq 0) { Show-Info '没有找到已连接的物理网卡。'; return $false }
    # 先备份（仅第一次，避免把阿里 DNS 当成原设置备份）
    if (-not (Test-Path $DnsBackup)) {
        $bk = foreach ($x in $cur) {
            # 只备份「手动填写」的 DNS；自动获取（DHCP）的记为空，恢复时改回自动
            $manual = @()
            try {
                $guid = (Get-NetAdapter -InterfaceIndex $x.Index).InterfaceGuid
                $ns = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$guid" -Name NameServer -ErrorAction Stop).NameServer
                if ($ns) { $manual = @($ns -split '[ ,]+' | Where-Object { $_ }) }
            } catch { }
            [pscustomobject]@{ Index = $x.Index; Name = $x.Name; Servers = $manual }
        }
        $bk | ConvertTo-Json -Depth 3 | Set-Content -Path $DnsBackup -Encoding UTF8
    }
    $idx = ($cur | ForEach-Object { $_.Index }) -join ','
    $script = "foreach (`$i in @($idx)) { Set-DnsClientServerAddress -InterfaceIndex `$i -ServerAddresses @('223.5.5.5','223.6.6.6') }; Clear-DnsClientCache"
    return (Invoke-Elevated $script)
}
function Restore-Dns {
    if (-not (Test-Path $DnsBackup)) { Show-Info '没有找到 DNS 备份（还没有用本工具改过 DNS）。'; return $false }
    $bk = @(Get-Content $DnsBackup -Raw -Encoding UTF8 | ConvertFrom-Json)
    $lines = foreach ($x in $bk) {
        $servers = @($x.Servers) | Where-Object { $_ }
        if ($servers.Count -eq 0) {
            "Set-DnsClientServerAddress -InterfaceIndex $($x.Index) -ResetServerAddresses"
        } else {
            $s = ($servers | ForEach-Object { "'$_'" }) -join ','
            "Set-DnsClientServerAddress -InterfaceIndex $($x.Index) -ServerAddresses @($s)"
        }
    }
    $ok = Invoke-Elevated (($lines -join "`r`n") + "`r`nClear-DnsClientCache")
    if ($ok) { Remove-Item $DnsBackup -ErrorAction SilentlyContinue }
    return $ok
}

# ---------------- 开机启动 ----------------
$RunKeys = @(
    @{ Hive = 'HKCU'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'; Kind = 'Run' },
    @{ Hive = 'HKLM'; Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'; Approved = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'; Kind = 'Run' },
    @{ Hive = 'HKLM'; Path = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Approved = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32'; Kind = 'Run32' },
    @{ Hive = 'HKCU'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'; Approved = $null; Kind = 'RunOnce' },
    @{ Hive = 'HKLM'; Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce'; Approved = $null; Kind = 'RunOnce' }
)
$StartupFolders = @(
    @{ Hive = 'HKCU'; Dir = [Environment]::GetFolderPath('Startup'); Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder' },
    @{ Hive = 'HKLM'; Dir = [Environment]::GetFolderPath('CommonStartup'); Approved = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder' }
)
function Get-ApprovedEnabled($approvedPath, [string]$name) {
    if (-not $approvedPath) { return $true }
    try {
        $v = (Get-ItemProperty -Path $approvedPath -Name $name -ErrorAction Stop).$name
        if ($v -is [byte[]] -and $v.Length -gt 0) { return (($v[0] -band 1) -eq 0) }   # 02/06 = 启用，03/07 = 停用（和任务管理器一致）
    } catch { }
    return $true
}
function Get-StartupItems {
    $items = @()
    foreach ($k in $RunKeys) {
        if (-not (Test-Path $k.Path)) { continue }
        $props = Get-ItemProperty -Path $k.Path
        foreach ($p in $props.PSObject.Properties) {
            if ($p.Name -like 'PS*') { continue }
            $items += [pscustomobject]@{
                Name = $p.Name; Command = [string]$p.Value; Source = "$($k.Hive) $($k.Kind)"
                Hive = $k.Hive; Approved = $k.Approved; Enabled = (Get-ApprovedEnabled $k.Approved $p.Name)
                CanToggle = [bool]$k.Approved; RegPath = $k.Path
            }
        }
    }
    foreach ($f in $StartupFolders) {
        if (-not $f.Dir -or -not (Test-Path $f.Dir)) { continue }
        foreach ($file in Get-ChildItem -Path $f.Dir -File -ErrorAction SilentlyContinue) {
            if ($file.Name -ieq 'desktop.ini') { continue }
            $items += [pscustomobject]@{
                Name = $file.Name; Command = $file.FullName; Source = "$($f.Hive) 启动文件夹"
                Hive = $f.Hive; Approved = $f.Approved; Enabled = (Get-ApprovedEnabled $f.Approved $file.Name)
                CanToggle = $true; RegPath = $null
            }
        }
    }
    return $items
}
function Set-StartupEnabled($item, [bool]$enable) {
    # 写 StartupApproved（任务管理器「启动」页用的同一个开关），不删除启动项，随时可以改回来
    $bytes = if ($enable) { '2,0,0,0,0,0,0,0,0,0,0,0' } else { '3,0,0,0,0,0,0,0,0,0,0,0' }
    $name = $item.Name.Replace("'", "''")
    $script = "if (-not (Test-Path '$($item.Approved)')) { New-Item -Path '$($item.Approved)' -Force | Out-Null }`r`n" +
              "Set-ItemProperty -Path '$($item.Approved)' -Name '$name' -Type Binary -Value ([byte[]]@($bytes))"
    if ($item.Hive -eq 'HKCU') { & ([scriptblock]::Create($script)); return $true }
    return (Invoke-Elevated $script)
}

# ---------------- 动画 / 透明 ----------------
$SPI_GETCLIENTAREAANIMATION = 0x1042; $SPI_SETCLIENTAREAANIMATION = 0x1043
$SPI_GETANIMATION = 0x0048; $SPI_SETANIMATION = 0x0049
function Get-AnimationsOn {
    $v = 0
    [void][WinOpt.Native]::SystemParametersInfo($SPI_GETCLIENTAREAANIMATION, 0, [ref]$v, 0)
    return ($v -ne 0)
}
function Set-Animations([bool]$on) {
    if (-not $script:UndoSuppress -and -not (Get-UndoEntry 'animations')) {
        Save-UndoEntry ([pscustomobject]@{ id = 'animations'; kind = 'animations'; value = [bool](Get-AnimationsOn) })
    }
    $flags = 3   # SPIF_UPDATEINIFILE | SPIF_SENDCHANGE
    $p = [IntPtr]([int]$on)
    [void][WinOpt.Native]::SystemParametersInfo($SPI_SETCLIENTAREAANIMATION, 0, $p, $flags)
    $ai = New-Object WinOpt.Native+ANIMATIONINFO
    $ai.cbSize = [Runtime.InteropServices.Marshal]::SizeOf([type][WinOpt.Native+ANIMATIONINFO])
    $ai.iMinAnimate = [int]$on
    [void][WinOpt.Native]::SPIAnim($SPI_SETANIMATION, $ai.cbSize, [ref]$ai, $flags)
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop\WindowMetrics' -Name 'MinAnimate' -Value ([string][int]$on) -ErrorAction SilentlyContinue
}
$PersonalizeKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
function Get-TransparencyOn {
    try { return ((Get-ItemProperty -Path $PersonalizeKey -Name EnableTransparency -ErrorAction Stop).EnableTransparency -ne 0) } catch { return $true }
}
function Set-Transparency([bool]$on) {
    if (-not $script:UndoSuppress -and -not (Get-UndoEntry 'transparency')) {
        Save-UndoEntry ([pscustomobject]@{ id = 'transparency'; kind = 'transparency'; value = [bool](Get-TransparencyOn) })
    }
    if (-not (Test-Path $PersonalizeKey)) { New-Item -Path $PersonalizeKey -Force | Out-Null }
    Set-ItemProperty -Path $PersonalizeKey -Name EnableTransparency -Type DWord -Value ([int]$on)
}

# ---------------- 电池 ----------------
function Get-BatteryInfo {
    $b = @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
    if ($b.Count -eq 0) { return $null }
    $ac = [System.Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus -eq 'Online'
    [pscustomobject]@{ Percent = [int]$b[0].EstimatedChargeRemaining; OnAC = $ac; Name = $b[0].Name }
}

# ---------------- 主题 ----------------
$dark = $false
try { $dark = ((Get-ItemProperty -Path $PersonalizeKey -Name AppsUseLightTheme -ErrorAction Stop).AppsUseLightTheme -eq 0) } catch { }
if ($dark) {
    $C = @{ Bg = '#1E1F24'; Card = '#2A2C33'; Ink = '#F2F2F5'; Mute = '#A6A8B3'; Line = '#3A3D46'; Accent = '#7B7CFA'; AccentInk = '#FFFFFF'; Ok = '#3DDC84'; Warn = '#FFB340'; Bad = '#FF6B6B'; Hover = '#33363F' }
} else {
    $C = @{ Bg = '#F5F5F8'; Card = '#FFFFFF'; Ink = '#16161D'; Mute = '#666A78'; Line = '#E3E4EA'; Accent = '#5C5DF0'; AccentInk = '#FFFFFF'; Ok = '#159B54'; Warn = '#B86E00'; Bad = '#D93636'; Hover = '#EEEEF6' }
}

# 先记一拍 CPU 基线。解析界面需要一点时间，第一次刷新就有真实间隔，不用为了采样卡住窗口。
[void](Reset-CpuSample)

# ---------------- 界面 ----------------
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$AppName $AppVersion" Width="940" SizeToContent="Height" MinHeight="560" MaxHeight="860"
        WindowStartupLocation="CenterScreen" Background="$($C.Bg)" FontFamily="Microsoft YaHei UI, Segoe UI" FontSize="13"
        Foreground="$($C.Ink)" ResizeMode="CanResize" UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    <SolidColorBrush x:Key="CardBrush" Color="$($C.Card)"/>
    <SolidColorBrush x:Key="LineBrush" Color="$($C.Line)"/>
    <SolidColorBrush x:Key="MuteBrush" Color="$($C.Mute)"/>
    <SolidColorBrush x:Key="AccentBrush" Color="$($C.Accent)"/>
    <Style TargetType="Button">
      <Setter Property="Foreground" Value="$($C.Ink)"/>
      <Setter Property="Background" Value="$($C.Card)"/>
      <Setter Property="BorderBrush" Value="$($C.Line)"/>
      <Setter Property="Padding" Value="14,6"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="7" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.85"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="$($C.Accent)"/>
      <Setter Property="BorderBrush" Value="$($C.Accent)"/>
      <Setter Property="Foreground" Value="$($C.AccentInk)"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style TargetType="TabItem">
      <Setter Property="Foreground" Value="$($C.Mute)"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border x:Name="b" Padding="14,8" Margin="0,0,4,0" CornerRadius="8" Background="Transparent">
              <ContentPresenter ContentSource="Header"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="b" Property="Background" Value="$($C.Card)"/>
                <Setter Property="Foreground" Value="$($C.Ink)"/>
                <Setter Property="FontWeight" Value="SemiBold"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="$($C.Hover)"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="CheckBox"><Setter Property="Foreground" Value="$($C.Ink)"/><Setter Property="VerticalContentAlignment" Value="Center"/></Style>
    <Style TargetType="ListView">
      <Setter Property="Background" Value="$($C.Card)"/>
      <Setter Property="Foreground" Value="$($C.Ink)"/>
      <Setter Property="BorderBrush" Value="$($C.Line)"/>
      <Setter Property="ScrollViewer.VerticalScrollBarVisibility" Value="Auto"/>
      <Setter Property="ScrollViewer.HorizontalScrollBarVisibility" Value="Disabled"/>
    </Style>
    <Style TargetType="GridViewColumnHeader">
      <Setter Property="Foreground" Value="$($C.Mute)"/>
      <Setter Property="Background" Value="$($C.Card)"/>
      <Setter Property="BorderBrush" Value="$($C.Line)"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="Padding" Value="6,6"/>
    </Style>
    <Style TargetType="ListViewItem">
      <Setter Property="Foreground" Value="$($C.Ink)"/>
      <Setter Property="Padding" Value="2,4"/>
    </Style>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="$($C.Card)"/>
      <Setter Property="BorderBrush" Value="$($C.Line)"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="12"/>
      <Setter Property="Padding" Value="16"/>
      <Setter Property="Margin" Value="0,0,0,12"/>
    </Style>
    <Style x:Key="H" TargetType="TextBlock"><Setter Property="FontSize" Value="15"/><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Margin" Value="0,0,0,8"/></Style>
    <Style x:Key="Note" TargetType="TextBlock"><Setter Property="Foreground" Value="$($C.Mute)"/><Setter Property="TextWrapping" Value="Wrap"/><Setter Property="FontSize" Value="12"/></Style>
    <Style x:Key="Big" TargetType="TextBlock"><Setter Property="FontSize" Value="26"/><Setter Property="FontWeight" Value="SemiBold"/></Style>
  </Window.Resources>

  <DockPanel Margin="18">
    <DockPanel DockPanel.Dock="Top" Margin="0,0,0,14">
      <TextBlock DockPanel.Dock="Left" Text="$AppName" FontSize="20" FontWeight="Bold" VerticalAlignment="Center"/>
      <TextBlock x:Name="AdminTag" DockPanel.Dock="Right" Style="{StaticResource Note}" VerticalAlignment="Center"/>
      <TextBlock x:Name="OsName" Style="{StaticResource Note}" Margin="14,0,0,0" VerticalAlignment="Center"/>
    </DockPanel>

    <!-- 实时概览 -->
    <Grid DockPanel.Dock="Top" Margin="0,0,0,12">
      <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition/><ColumnDefinition/><ColumnDefinition/></Grid.ColumnDefinitions>
      <Border Grid.Column="0" Style="{StaticResource Card}" Margin="0,0,10,0">
        <StackPanel><TextBlock Text="CPU" Style="{StaticResource Note}"/><TextBlock x:Name="CpuText" Text="—" Style="{StaticResource Big}"/>
          <ProgressBar x:Name="CpuBar" Height="4" Maximum="100" Margin="0,6,0,0" Foreground="$($C.Accent)" Background="$($C.Line)" BorderThickness="0"/></StackPanel>
      </Border>
      <Border Grid.Column="1" Style="{StaticResource Card}" Margin="0,0,10,0">
        <StackPanel><TextBlock Text="可用内存" Style="{StaticResource Note}"/><TextBlock x:Name="MemText" Text="—" Style="{StaticResource Big}"/>
          <TextBlock x:Name="MemSub" Style="{StaticResource Note}"/></StackPanel>
      </Border>
      <Border Grid.Column="2" Style="{StaticResource Card}" Margin="0,0,10,0">
        <StackPanel><TextBlock Text="已开机" Style="{StaticResource Note}"/><TextBlock x:Name="UpText" Text="—" Style="{StaticResource Big}"/>
          <TextBlock x:Name="UpSub" Style="{StaticResource Note}"/></StackPanel>
      </Border>
      <Border Grid.Column="3" Style="{StaticResource Card}" Margin="0">
        <StackPanel><TextBlock Text="健康分" Style="{StaticResource Note}"/><TextBlock x:Name="ScoreText" Text="—" Style="{StaticResource Big}"/>
          <TextBlock x:Name="ScoreSub" Style="{StaticResource Note}" Text="点「智能体检」开始"/></StackPanel>
      </Border>
    </Grid>

    <TabControl x:Name="Tabs" Background="Transparent" BorderThickness="0" Padding="0,10,0,0">
      <!-- 智能体检 -->
      <TabItem Header="智能体检">
        <StackPanel>
          <Border Style="{StaticResource Card}">
            <DockPanel>
              <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Top">
                <Button x:Name="CheckBtn" Content="重新体检"/>
                <Button x:Name="FixBtn" Content="一键修复所选" Style="{StaticResource Primary}" Margin="0"/>
              </StackPanel>
              <StackPanel>
                <TextBlock Text="常见「莫名卡顿」原因" Style="{StaticResource H}"/>
                <TextBlock Style="{StaticResource Note}" Text="勾选要处理的项目再点「一键修复所选」。不会自动结束程序或删除文件；需要管理员权限的项目会弹出 UAC 让你确认。"/>
              </StackPanel>
            </DockPanel>
          </Border>
          <ItemsControl x:Name="IssueList">
            <ItemsControl.ItemTemplate>
              <DataTemplate>
                <Border Style="{StaticResource Card}" Margin="0,0,0,8" Padding="14,10">
                  <DockPanel>
                    <CheckBox DockPanel.Dock="Left" IsChecked="{Binding Selected}" IsEnabled="{Binding Fixable}" Margin="0,2,12,0" VerticalAlignment="Top"/>
                    <TextBlock DockPanel.Dock="Right" Text="{Binding Level}" Foreground="{Binding LevelColor}" FontWeight="SemiBold" Margin="12,0,0,0" VerticalAlignment="Top"/>
                    <StackPanel>
                      <TextBlock Text="{Binding Title}" FontWeight="SemiBold" TextWrapping="Wrap"/>
                      <TextBlock Text="{Binding Detail}" Style="{StaticResource Note}" Margin="0,3,0,0"/>
                      <TextBlock Text="{Binding FixText}" Style="{StaticResource Note}" Foreground="$($C.Accent)" Margin="0,3,0,0"/>
                    </StackPanel>
                  </DockPanel>
                </Border>
              </DataTemplate>
            </ItemsControl.ItemTemplate>
          </ItemsControl>
        </StackPanel>
      </TabItem>

      <!-- 资源排行 -->
      <TabItem Header="资源排行">
        <Border Style="{StaticResource Card}">
          <DockPanel>
            <StackPanel DockPanel.Dock="Top" Margin="0,0,0,10">
              <TextBlock Text="CPU 省电/性能" Style="{StaticResource H}"/>
              <TextBlock x:Name="PowerPlanText" Style="{StaticResource Note}" FontSize="13" Text="正在读取电源模式…"/>
              <StackPanel Orientation="Horizontal" Margin="0,8,0,0">
                <Button x:Name="PlanBestLife" Content="最佳电池续航"/>
                <Button x:Name="PlanSaver" Content="更好的电池"/>
                <Button x:Name="PlanBalanced" Content="更高性能"/>
                <Button x:Name="PlanHigh" Content="最佳性能" Margin="0"/>
              </StackPanel>
              <TextBlock Style="{StaticResource Note}" Margin="0,6,0,0" Text="Windows 10 电池图标里的滑杆（要选在「平衡」电源计划上）。用电池时不建议「最佳性能」。最左档「最佳电池续航」是节电模式，点它会打开系统设置。可以随时改回。"/>
            </StackPanel>
            <DockPanel DockPanel.Dock="Top" Margin="0,0,0,10">
              <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                <Button x:Name="ProcRefresh" Content="刷新"/>
                <Button x:Name="ProcNice" Content="降低优先级"/>
                <Button x:Name="ProcNormal" Content="恢复优先级"/>
                <Button x:Name="ProcClose" Content="关闭窗口" Margin="0"/>
              </StackPanel>
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="排序：" VerticalAlignment="Center" Foreground="$($C.Mute)"/>
                <RadioButton x:Name="SortMem" Content="内存" IsChecked="True" Margin="4,0,12,0" VerticalAlignment="Center" Foreground="$($C.Ink)"/>
                <RadioButton x:Name="SortCpu" Content="CPU" VerticalAlignment="Center" Foreground="$($C.Ink)"/>
                <TextBlock Text="  CPU 为两次刷新之间的占用" Style="{StaticResource Note}" VerticalAlignment="Center"/>
              </StackPanel>
            </DockPanel>
            <TextBlock DockPanel.Dock="Bottom" Style="{StaticResource Note}" Margin="0,8,0,0" Text="降低优先级后程序继续运行，可随时恢复。关闭窗口只发送关闭请求（和点 × 一样），不会强制结束。系统关键进程和本程序不能操作。"/>
            <ListView x:Name="ProcList" Height="280" SelectionMode="Extended">
              <ListView.View>
                <GridView>
                  <GridViewColumn Header="进程" Width="220" DisplayMemberBinding="{Binding Name}"/>
                  <GridViewColumn Header="PID" Width="70" DisplayMemberBinding="{Binding Id}"/>
                  <GridViewColumn Header="内存" Width="90" DisplayMemberBinding="{Binding Mem}"/>
                  <GridViewColumn Header="CPU" Width="70" DisplayMemberBinding="{Binding CpuText}"/>
                  <GridViewColumn Header="优先级" Width="90" DisplayMemberBinding="{Binding Pri}"/>
                  <GridViewColumn Header="窗口标题" Width="220" DisplayMemberBinding="{Binding Title}"/>
                </GridView>
              </ListView.View>
            </ListView>
          </DockPanel>
        </Border>
      </TabItem>

      <!-- 开机启动 -->
      <TabItem Header="开机启动">
        <Border Style="{StaticResource Card}">
          <DockPanel>
            <DockPanel DockPanel.Dock="Top" Margin="0,0,0,10">
              <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                <Button x:Name="StartRefresh" Content="刷新"/>
                <Button x:Name="StartDisable" Content="停用所选"/>
                <Button x:Name="StartEnable" Content="启用所选" Margin="0"/>
              </StackPanel>
              <TextBlock Style="{StaticResource Note}" VerticalAlignment="Center" Text="停用 = 和任务管理器「启动」页一样只是关掉开关，不删除；随时可以再启用。HKLM 项需要管理员。"/>
            </DockPanel>
            <ListView x:Name="StartList" Height="330" SelectionMode="Extended">
              <ListView.View>
                <GridView>
                  <GridViewColumn Header="名称" Width="220" DisplayMemberBinding="{Binding Name}"/>
                  <GridViewColumn Header="状态" Width="70" DisplayMemberBinding="{Binding State}"/>
                  <GridViewColumn Header="位置" Width="130" DisplayMemberBinding="{Binding Source}"/>
                  <GridViewColumn Header="命令" Width="420" DisplayMemberBinding="{Binding Command}"/>
                </GridView>
              </ListView.View>
            </ListView>
          </DockPanel>
        </Border>
      </TabItem>

      <!-- 浏览器 -->
      <TabItem Header="浏览器">
        <Border Style="{StaticResource Card}">
          <DockPanel>
            <DockPanel DockPanel.Dock="Top" Margin="0,0,0,10">
              <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                <Button x:Name="BrRefresh" Content="刷新"/>
                <Button x:Name="BrQuit" Content="退出所选浏览器" Margin="0"/>
              </StackPanel>
              <TextBlock Style="{StaticResource Note}" VerticalAlignment="Center" Text="同时开着几个浏览器很吃内存。「退出」只是关闭窗口（和点 × 一样），浏览器会自己保存标签页。"/>
            </DockPanel>
            <ListView x:Name="BrList" MaxHeight="330" SelectionMode="Extended">
              <ListView.View>
                <GridView>
                  <GridViewColumn Header="浏览器" Width="260" DisplayMemberBinding="{Binding Name}"/>
                  <GridViewColumn Header="进程数" Width="100" DisplayMemberBinding="{Binding Count}"/>
                  <GridViewColumn Header="内存" Width="140" DisplayMemberBinding="{Binding Mem}"/>
                </GridView>
              </ListView.View>
            </ListView>
          </DockPanel>
        </Border>
      </TabItem>

      <!-- 网络诊断 -->
      <TabItem Header="网络诊断">
        <StackPanel>
          <Border Style="{StaticResource Card}">
            <DockPanel>
              <Button x:Name="PingBtn" DockPanel.Dock="Right" Content="开始测速" Style="{StaticResource Primary}" Margin="0" VerticalAlignment="Top"/>
              <StackPanel>
                <TextBlock Text="延迟与丢包" Style="{StaticResource H}"/>
                <TextBlock x:Name="PingText" Style="{StaticResource Note}" FontFamily="Consolas, Microsoft YaHei UI" FontSize="13" Text="每个目标 ping 8 次。"/>
              </StackPanel>
            </DockPanel>
          </Border>
          <Border Style="{StaticResource Card}">
            <DockPanel>
              <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Top">
                <Button x:Name="DnsAli" Content="一键设为阿里 DNS" Style="{StaticResource Primary}"/>
                <Button x:Name="DnsRestore" Content="恢复原来的 DNS"/>
                <Button x:Name="DnsFlush" Content="清除 DNS 缓存" Margin="0"/>
              </StackPanel>
              <StackPanel>
                <TextBlock Text="DNS" Style="{StaticResource H}"/>
                <TextBlock x:Name="DnsText" Style="{StaticResource Note}" FontSize="13"/>
                <TextBlock Style="{StaticResource Note}" Margin="0,6,0,0" Text="阿里 DNS：223.5.5.5 / 223.6.6.6。修改前会把原设置备份到 %APPDATA%\WinOptimizer\dns-backup.json；需要管理员。"/>
              </StackPanel>
            </DockPanel>
          </Border>
          <Border Style="{StaticResource Card}">
            <DockPanel>
              <Button x:Name="VpnOpen" DockPanel.Dock="Right" Content="打开网络连接" Margin="0" VerticalAlignment="Top"/>
              <StackPanel>
                <TextBlock Text="VPN / 虚拟网卡" Style="{StaticResource H}"/>
                <TextBlock x:Name="VpnText" Style="{StaticResource Note}" FontSize="13"/>
              </StackPanel>
            </DockPanel>
          </Border>
        </StackPanel>
      </TabItem>

      <!-- 显示 -->
      <TabItem Header="显示">
        <StackPanel>
          <Border Style="{StaticResource Card}">
            <DockPanel>
              <Button x:Name="AnimBtn" DockPanel.Dock="Right" Style="{StaticResource Primary}" Margin="0" VerticalAlignment="Top"/>
              <StackPanel>
                <TextBlock Text="窗口动画" Style="{StaticResource H}"/>
                <TextBlock x:Name="AnimText" Style="{StaticResource Note}" FontSize="13"/>
                <TextBlock Style="{StaticResource Note}" Margin="0,4,0,0" Text="关闭后窗口打开、最小化不再有过渡动画，老电脑上切换会更跟手。随时可以再打开。"/>
              </StackPanel>
            </DockPanel>
          </Border>
          <Border Style="{StaticResource Card}">
            <DockPanel>
              <Button x:Name="TransBtn" DockPanel.Dock="Right" Style="{StaticResource Primary}" Margin="0" VerticalAlignment="Top"/>
              <StackPanel>
                <TextBlock Text="透明效果（亚克力 / 云母）" Style="{StaticResource H}"/>
                <TextBlock x:Name="TransText" Style="{StaticResource Note}" FontSize="13"/>
                <TextBlock Style="{StaticResource Note}" Margin="0,4,0,0" Text="类似 Mac 上关闭「液态玻璃 / 降低透明度」：任务栏、开始菜单不再半透明，集显电脑上能省一些 GPU。"/>
              </StackPanel>
            </DockPanel>
          </Border>
          <Border Style="{StaticResource Card}">
            <DockPanel>
              <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Top">
                <Button x:Name="DispSettings" Content="显示设置"/>
                <Button x:Name="PerfSettings" Content="视觉效果（高级）" Margin="0"/>
              </StackPanel>
              <StackPanel>
                <TextBlock Text="系统设置" Style="{StaticResource H}"/>
                <TextBlock Style="{StaticResource Note}" FontSize="13" Text="分辨率、缩放、刷新率在「显示设置」里；更多动画和阴影选项在「视觉效果」。"/>
              </StackPanel>
            </DockPanel>
          </Border>
        </StackPanel>
      </TabItem>

      <!-- 电池 -->
      <TabItem Header="电池">
        <StackPanel>
          <Border Style="{StaticResource Card}">
            <DockPanel>
              <Button x:Name="PowerSettings" DockPanel.Dock="Right" Content="电源和电池设置" Margin="0" VerticalAlignment="Top"/>
              <StackPanel>
                <TextBlock Text="电池" Style="{StaticResource H}"/>
                <TextBlock x:Name="BatText" FontSize="20" FontWeight="SemiBold"/>
                <TextBlock x:Name="BatSub" Style="{StaticResource Note}" Margin="0,4,0,0"/>
                <TextBlock Style="{StaticResource Note}" Margin="0,10,0,0" Text="充电上限（Surface 的智能充电 / 电池限制）在 Surface 应用或 UEFI 里，本工具不改固件。"/>
              </StackPanel>
            </DockPanel>
          </Border>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="电池诊断" Style="{StaticResource H}"/>
              <TextBlock Style="{StaticResource Note}" Text="只生成报告，不改设置。掉电诊断需要管理员。休眠不支持时不会报错。"/>
              <StackPanel Orientation="Horizontal" Margin="0,8,0,0">
                <Button x:Name="SleepStudyBtn" Content="掉电诊断"/>
                <Button x:Name="BatteryReportBtn" Content="电池报告"/>
                <Button x:Name="SurfaceBtn" Content="Surface 电池保护" Margin="0"/>
              </StackPanel>
            </StackPanel>
          </Border>
        </StackPanel>
      </TabItem>

      <!-- 优化建议 -->
      <TabItem Header="优化建议">
        <DockPanel>
          <DockPanel DockPanel.Dock="Top" Margin="0,0,0,8">
            <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
              <Button x:Name="TipsRefresh" Content="刷新"/>
              <Button x:Name="TipsRestoreAll" Content="全部恢复" Margin="0"/>
            </StackPanel>
            <TextBlock Style="{StaticResource Note}" VerticalAlignment="Center" Text="每一项都会先记下原值。点「恢复」或「全部恢复」写回去。"/>
          </DockPanel>
          <ScrollViewer VerticalScrollBarVisibility="Hidden" HorizontalScrollBarVisibility="Disabled" Height="460">
            <StackPanel x:Name="TipsHost"/>
          </ScrollViewer>
        </DockPanel>
      </TabItem>
    </TabControl>
  </DockPanel>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$win = [Windows.Markup.XamlReader]::Load($reader)
$ui = @{}
$xaml.SelectNodes('//*[@*[local-name()="Name"]]') | ForEach-Object {
    $n = $_.Attributes | Where-Object { $_.LocalName -eq 'Name' } | Select-Object -First 1
    if ($n) { $ui[$n.Value] = $win.FindName($n.Value) }
}
function Brush([string]$hex) { return (New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($hex))) }

$ui.AdminTag.Text = if (Test-IsAdmin) { '以管理员身份运行' } else { '普通权限（需要时会弹出 UAC）' }

# ---------------- 概览刷新 ----------------
function Set-OverviewUi($o) {
    $ui.OsName.Text = $o.OsName
    if ($null -eq $o.Cpu) {
        $ui.CpuText.Text = '—'
        $ui.CpuBar.Value = 0
    } else {
        $ui.CpuText.Text = "$($o.Cpu)%"
        $ui.CpuBar.Value = [double]$o.Cpu
    }
    $ui.MemText.Text = Format-Bytes $o.MemFree
    $ui.MemSub.Text = "共 $(Format-Bytes $o.MemTotal)，已用 $($o.MemUsedPct)%"
    $ui.MemText.Foreground = if ($o.MemUsedPct -ge 90) { Brush $C.Bad } elseif ($o.MemUsedPct -ge 80) { Brush $C.Warn } else { Brush $C.Ink }
    $ui.UpText.Text = Format-Uptime $o.Uptime
    $ui.UpSub.Text = if ($o.Uptime.TotalDays -ge 7) { '很久没重启了，重启一次常常能解决卡顿' } else { '' }
    $script:LastOverview = $o
}
function Update-Overview {
    try { Set-OverviewUi (Get-Overview) } catch { }
}

# ---------------- 智能体检 ----------------
$script:Issues = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$ui.IssueList.ItemsSource = $script:Issues
function New-Issue($id, $title, $detail, $level, $fixable, $fixText, $extra) {
    $color = switch ($level) { '严重' { $C.Bad } '注意' { $C.Warn } default { $C.Ok } }
    $props = [ordered]@{ Id = $id; Title = $title; Detail = $detail; Level = $level; LevelColor = (Brush $color); Fixable = [bool]$fixable; Selected = [bool]$fixable; FixText = $fixText; ProcId = 0; ProcName = '' }
    if ($extra) { foreach ($k in @($extra.Keys)) { $props[$k] = $extra[$k] } }
    return (New-Object PSObject -Property $props)
}
function Update-ScoreText([int]$score, [string]$sub) {
    if ($score -lt 0) { $score = 0 }
    $ui.ScoreText.Text = "$score"
    $ui.ScoreText.Foreground = if ($score -ge 85) { Brush $C.Ok } elseif ($score -ge 65) { Brush $C.Warn } else { Brush $C.Bad }
    $ui.ScoreSub.Text = $sub
}
function Add-CpuSampleIssues($m) {
    # 体检时单独采约 2 秒，不在平时的 3 秒刷新里扫全部进程
    $script:LastCpuAvg = $null
    $script:LastCpuProcs = @()
    $avg = $null
    $procs = @()
    if ($null -ne $m -and $null -ne $m.Avg) {
        $avg = [int]$m.Avg
        $script:LastCpuAvg = $avg
        $procs = @($m.Procs | Where-Object { $_ -and $null -ne $_.Pct })
        $script:LastCpuProcs = $procs
    }
    if ($null -ne $avg -and $avg -ge 80) {
        $top = @($procs | Select-Object -First 3 | ForEach-Object { "$($_.Name) $($_.Pct)%" }) -join '、'
        if (-not $top) { $top = '（没有单个特别突出的进程）' }
        $level = if ($avg -ge 90) { '严重' } else { '注意' }
        $script:Issues.Add((New-Issue 'cpu-high' "CPU 持续偏高（平均 $avg%）" "采样约 2 秒。最占 CPU：$top。可以到「资源排行」降低优先级，或只关闭它的窗口（不会强制结束）。正在插电时，也可以把电源模式临时调成「最佳性能」；用电池时请保持「平衡」。" $level $true '修复：打开「资源排行」，由你选择要处理的程序'))
        $script:CheckScore -= 12
    }
    $procDeduct = 0
    $hogDeduct = 0
    foreach ($p in $procs) {
        if ([int]$p.Pct -lt 5) { continue }
        $note = Get-CpuHogNote ([string]$p.Name)
        if ($note -and [int]$p.Pct -ge 5) {
            $script:Issues.Add((New-Issue 'cpu-hog' "$($p.Name) 正在占用 CPU（$($p.Pct)%）" $note '建议' $false '本工具不会关闭这项系统功能。'))
            if ($hogDeduct -lt 6) { $hogDeduct += 2 }
        }
        if ([int]$p.Pct -lt 25) { continue }
        if ($note) { continue }
        if (Test-ProtectedProcess $p) { continue }
        $script:Issues.Add((New-Issue 'cpu-proc' "$($p.Name) 占用较多 CPU（$($p.Pct)%）" "PID $($p.Id)。采样约 2 秒，约占整机 CPU 的 $($p.Pct)%。降低优先级后程序继续运行，只是少抢占前台；可在「资源排行」恢复原来的优先级。不会强制结束。" '注意' $true '修复：优先级降为「低于正常」（可恢复）' @{ ProcId = [int]$p.Id; ProcName = [string]$p.Name }))
        if ($procDeduct -lt 16) { $procDeduct += 8 }
    }
        $script:CheckScore -= ($procDeduct + $hogDeduct)
    try { Add-TipCheckupIssues } catch { }
    try {
        $adv = @(Get-PowerAdvice (Get-PowerSnapshot) $script:LastCpuAvg)
        foreach ($a in $adv) {
            $script:Issues.Add((New-Issue 'cpu-power' $a.Title $a.Detail '建议' $true $a.FixText @{ PowerTarget = [string]$a.PowerTarget }))
            $script:CheckScore -= 4
        }
    } catch { }
}
function Start-CpuCheckSample([int]$ms, [int]$gen, [scriptblock]$done) {
    # 采样放在后台，界面不用卡住 2 秒。只在点「体检」时跑一次，不做持续轮询。
    Start-Bg {
        param($arg)
        $ms = [int]$arg.ms
        $cores = [Math]::Max(1, [Environment]::ProcessorCount)
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $tA = [WinOpt.Native]::ReadCpuTimes()
        $snap = @{}
        foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
            if ($p.Id -le 4) { continue }
            try { $snap[$p.Id] = [double]$p.TotalProcessorTime.TotalMilliseconds } catch { }
        }
        Start-Sleep -Milliseconds ([int]$ms)
        $tB = [WinOpt.Native]::ReadCpuTimes()
        $elapsed = [Math]::Max(1, $sw.ElapsedMilliseconds)
        $avg = $null
        if ($tA -and $tB -and @($tA).Count -ge 3 -and @($tB).Count -ge 3) {
            $idle = [int64]$tB[0] - [int64]$tA[0]
            $total = ([int64]$tB[1] - [int64]$tA[1]) + ([int64]$tB[2] - [int64]$tA[2])
            if ($total -gt 0 -and $idle -ge 0 -and $idle -le $total) {
                $avg = [int][math]::Round(100.0 * ($total - $idle) / [double]$total)
                if ($avg -lt 0) { $avg = 0 }
                if ($avg -gt 100) { $avg = 100 }
            }
        }
        $rows = @()
        foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
            if (-not $snap.ContainsKey($p.Id)) { continue }
            $t = $null
            try { $t = [double]$p.TotalProcessorTime.TotalMilliseconds } catch { continue }
            $cpu = ($t - [double]$snap[$p.Id]) / $elapsed / $cores * 100
            if ($cpu -lt 3) { continue }
            $rows += [pscustomobject]@{ Id = [int]$p.Id; Name = [string]$p.ProcessName; Pct = [int][math]::Round($cpu) }
        }
        $top = @($rows | Sort-Object Pct -Descending | Select-Object -First 8)
        [pscustomobject]@{ Avg = $avg; Procs = $top; Gen = [int]$arg.gen }
    } $done @{ ms = $ms; gen = $gen }
}
function Finish-Checkup {
    if ($script:CheckScore -lt 0) { $script:CheckScore = 0 }
    if ($script:Issues.Count -eq 0) {
        $script:Issues.Add((New-Issue 'ok' '没有发现明显问题' '一切正常。' '正常' $false ''))
    }
    $n = @($script:Issues | Where-Object { $_.Id -ne 'ok' }).Count
    Update-ScoreText $script:CheckScore "发现 $n 项 · $(Get-Date -Format 'HH:mm')"
    $script:CpuCheckDone = $true
}
function Invoke-Checkup {
    $script:CheckGen = [int]$script:CheckGen + 1
    $gen = $script:CheckGen
    $script:CpuCheckDone = $false
    $script:Issues.Clear()
    $script:CheckScore = 100
    $o = Get-Overview
    # 1 内存压力
    if ($o.MemUsedPct -ge 85) {
        $script:CheckScore -= 20
        $top = (Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 3 | ForEach-Object { "$($_.ProcessName) $(Format-Bytes $_.WorkingSet64)" }) -join '、'
        $script:Issues.Add((New-Issue 'mem' "内存吃紧：已用 $($o.MemUsedPct)%" "最占内存：$top" '严重' $true '修复：打开「资源排行」，由你选择要关闭窗口或降低优先级的程序'))
    } elseif ($o.MemUsedPct -ge 75) {
        $script:CheckScore -= 8
        $script:Issues.Add((New-Issue 'mem' "内存偏紧：已用 $($o.MemUsedPct)%" '再多开几个程序就可能开始卡。' '注意' $true '修复：打开「资源排行」查看'))
    }
    # 2 浏览器
    $brs = @(Get-Browsers)
    if ($brs.Count -ge 2) {
        $script:CheckScore -= 10
        $names = ($brs | ForEach-Object { "$($_.Name)（$($_.Mem)）" }) -join '、'
        $script:Issues.Add((New-Issue 'browsers' "同时开着 $($brs.Count) 个浏览器" $names '注意' $true '修复：打开「浏览器」页，选择要退出的（只关窗口，标签页会保存）'))
    }
    # 3 VPN
    $vpn = @(Get-VpnAdapters)
    if ($vpn.Count -gt 0) {
        $script:CheckScore -= 8
        $names = ($vpn | ForEach-Object { $_.InterfaceDescription }) -join '、'
        $script:Issues.Add((New-Issue 'vpn' "有 $($vpn.Count) 个 VPN / 虚拟网卡在连接" "$names。不用时断开，网页和下载可能更快。" '注意' $true '修复：打开「网络连接」，由你断开'))
    }
    # 4 DNS
    if (-not (Test-DnsIsAli)) {
        $script:CheckScore -= 6
        $d = (@(Get-CurrentDns) | ForEach-Object { "$($_.Name)：$(if ($_.Servers.Count) { $_.Servers -join ', ' } else { '自动' })" }) -join '；'
        $script:Issues.Add((New-Issue 'dns' 'DNS 不是阿里 DNS' $d '建议' $true '修复：设为 223.5.5.5 / 223.6.6.6（先备份，可恢复；需要管理员）'))
    }
    # 5 启动项
    $st = @(Get-StartupItems | Where-Object { $_.Enabled })
    if ($st.Count -ge 8) {
        $script:CheckScore -= 8
        $script:Issues.Add((New-Issue 'startup' "开机启动项有 $($st.Count) 个" '启动项太多会让开机后很长一段时间都很卡。' '注意' $true '修复：打开「开机启动」页，由你选择停用哪些'))
    }
    # 6 动画
    if (Get-AnimationsOn) {
        $script:CheckScore -= 3
        $script:Issues.Add((New-Issue 'anim' '窗口动画已打开' '关闭后窗口切换更跟手（纯个人偏好，随时可改回）。' '建议' $true '修复：关闭窗口动画（不需要管理员）'))
    }
    # 7 重启
    if ($o.Uptime.TotalDays -ge 7) {
        $script:CheckScore -= 6
        $script:Issues.Add((New-Issue 'uptime' "已经 $([int]$o.Uptime.TotalDays) 天没重启" '长时间不重启，内存碎片和后台残留会越来越多。' '建议' $false '建议你保存工作后手动重启（本工具不会替你重启）'))
    }
    Update-ScoreText $script:CheckScore '正在采样 CPU（约 2 秒）…'
    Start-CpuCheckSample 2000 $gen {
        param($res)
        $m = $null
        if ($null -ne $res) { $m = @($res) | Select-Object -Last 1 }
        $gotGen = $null
        if ($m -and $m.PSObject.Properties['Gen']) { $gotGen = [int]$m.Gen }
        if ($null -ne $gotGen -and $gotGen -ne [int]$script:CheckGen) { return }
        try { Add-CpuSampleIssues $m } catch { }
        Finish-Checkup
    }
}
function Invoke-Fixes {
    $sel = @($script:Issues | Where-Object { $_.Selected -and $_.Fixable })
    if ($sel.Count -eq 0) { Show-Info '没有勾选要修复的项目。'; return }
    $msg = "将处理以下 $($sel.Count) 项：`n`n" + (($sel | ForEach-Object { '• ' + $_.Title }) -join "`n") + "`n`n继续吗？"
    if (-not (Confirm-Action $msg '一键修复')) { return }
    $done = @(); $goTab = $null
    foreach ($i in $sel) {
        switch ($i.Id) {
            'mem'      { $goTab = 1 }
            'browsers' { if (-not $goTab) { $goTab = 3 } }
            'startup'  { if (-not $goTab) { $goTab = 2 } }
            'vpn'      { Start-Process 'ncpa.cpl'; $done += '已打开网络连接' }
            'dns'      { if (Set-AliDns) { $done += 'DNS 已设为阿里 DNS' } else { $done += 'DNS 未修改（取消了管理员授权或失败）' } }
            'anim'     { Set-Animations $false; $done += '已关闭窗口动画' }
            'cpu-high' { $goTab = 1 }
            'cpu-proc' {
                if (Set-ProcessBelowNormal -ProcId ([int]$i.ProcId) -Name ([string]$i.ProcName)) { $done += "已把 $($i.ProcName) 的优先级降为「低于正常」（可在资源排行恢复）" }
                else { $done += "没能降低 $($i.ProcName) 的优先级（可能已退出或没有权限）" }
            }
            'cpu-power' {
                $target = [string]$i.PowerTarget
                if (-not $target) { $target = 'balanced' }
                if (Set-PowerMode $target -Quiet) { $done += "已把当前电源模式改为「$(Format-PowerMode $target)」（可再改回）" }
                else { $done += '没有切换电源模式（用电池时不会自动切到最佳性能）' }
            }
            'tip-esbatt' { if ((Invoke-TipAction 'esbatt' -Quiet) -eq 'ok') { $done += '节电模式阈值已设为 30%（可恢复）' } else { $done += '没有改节电阈值' } }
            'tip-net' { if ((Invoke-TipAction 'standbynet' -Quiet) -eq 'ok') { $done += '电池待机已改为断开网络（可恢复）' } else { $done += '没有改待机网络' } }
            'tip-hib' { if ((Invoke-TipAction 'hibernate' -Quiet) -eq 'ok') { $done += '已设置睡眠后休眠（可恢复）' } else { $done += '没有改休眠（可能不支持）' } }
            'tip-bright' { if ((Invoke-TipAction 'brightness' -Quiet) -eq 'ok') { $done += '亮度已调到 50%（可恢复）' } else { $done += '没有改亮度' } }
            'tip-storage' { if ((Invoke-TipAction 'storage' -Quiet) -eq 'ok') { $done += '已打开存储感知（可恢复）' } else { $done += '没有打开存储感知' } }
            'tip-do' { if ((Invoke-TipAction 'delivery' -Quiet) -eq 'ok') { $done += '传递优化已改为仅局域网（可恢复）' } else { $done += '没有改传递优化' } }
        }
    }
    if ($done.Count) { Show-Info ($done -join "`n") }
    if ($goTab) { $ui.Tabs.SelectedIndex = $goTab }
    Invoke-Checkup
}

# ---------------- 电源模式（Windows 11 滑杆 + 经典计划） ----------------
# powrprof / System32\powercfg.exe 在 x64 和 ARM64 上都是系统自带的本机程序，不调用任何 x86 专用工具。
function Format-PowerMode([string]$mode) {
    switch ($mode) {
        'efficiency' { '更好的电池' }
        'balanced' { '更高性能' }
        'performance' { '最佳性能' }
        'saver' { '节能' }
        'high' { '高性能' }
        default { '未知' }
    }
}
function Convert-OverlayMode([string]$guid) {
    if (-not $guid) { return $null }
    switch ($guid.ToLower()) {
        $script:OverlayEfficiency { 'efficiency' }
        $script:OverlayBalanced { 'balanced' }
        $script:OverlayPerformance { 'performance' }
        default { 'other' }
    }
}
function Convert-ClassicMode([string]$guid) {
    if (-not $guid) { return 'other' }
    switch ($guid.ToLower()) {
        $script:PlanSaver { 'saver' }
        $script:PlanBalanced { 'balanced' }
        $script:PlanHigh { 'high' }
        default { 'other' }
    }
}
function Get-PowerCfgExe { Join-Path $env:SystemRoot 'System32\powercfg.exe' }
function Invoke-PowerCfg {
    # powercfg 把「参数无效」写到 stderr。Windows PowerShell 5.1 在 ErrorAction=Stop 时会因此中断，这里吞掉。
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$PowerArgs)
    $exe = Get-PowerCfgExe
    if (-not (Test-Path -LiteralPath $exe)) { return '' }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $text = & $exe @PowerArgs 2>&1 | ForEach-Object { "$_" }
        return (@($text) -join "`n")
    } catch { return "$_" }
    finally { $ErrorActionPreference = $prev }
}
function Get-ClassicSchemeGuids {
    $exe = Get-PowerCfgExe
    if (-not (Test-Path $exe)) { return @() }
    try {
        $out = & $exe /L 2>&1 | Out-String
        $ids = @()
        foreach ($m in [regex]::Matches($out, '[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}')) { $ids += $m.Value.ToLower() }
        return $ids
    } catch { return @() }
}
function Get-PowerSource {
    $line = 'Unknown'
    try { $line = [string][System.Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus } catch { }
    $hasCim = $false
    try { $hasCim = @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue).Count -gt 0 } catch { }
    $has = $hasCim -or ($line -eq 'Offline')
    # 不确定是不是插电时，按电池处理，避免把笔记本推进「最佳性能」
    $onAC = ($line -eq 'Online') -or (-not $has)
    if ($line -eq 'Unknown' -and $has) { $onAC = $false }
    [pscustomobject]@{ HasBattery = [bool]$has; OnAC = [bool]$onAC; Line = $line }
}
function Get-ActiveOverlayGuid {
    # Windows 10：powercfg /getactiveoverlayscheme。不区分插电/电池两套滑杆（那是 Win11 24H2 的行为）。
    $exe = Get-PowerCfgExe
    if (-not (Test-Path -LiteralPath $exe)) { return $null }
    $out = Invoke-PowerCfg /getactiveoverlayscheme
    if (-not $out) { return $null }
    $picked = $null
    foreach ($line in ($out -split "`r?`n")) {
        if ($line -match '([0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12})') {
            $g = $Matches[1].ToLower()
            if ($line -match '(?i)overlay|覆盖') { return $g }
            if (-not $picked) { $picked = $g }
        }
    }
    return $picked
}
function Get-PowerSnapshot {
    $src = Get-PowerSource
    $ac = Get-ActiveOverlayGuid
    $overlay = [bool]$ac
    $dc = $ac
    $classic = ''
    try { $classic = ([string][WinOpt.Native]::ReadActiveScheme()).ToLower() } catch { $classic = '' }
    if (-not $classic) {
        try {
            $exe = Get-PowerCfgExe
            $out = & $exe /getactivescheme 2>&1 | Out-String
            if ($out -match '([0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12})') { $classic = $Matches[1].ToLower() }
        } catch { }
    }
    $schemes = @(Get-ClassicSchemeGuids)
    [pscustomobject]@{
        HasBattery = $src.HasBattery; OnAC = $src.OnAC; Line = $src.Line
        OverlaySupported = [bool]($overlay -and $ac)
        AcGuid = $ac; DcGuid = $dc
        AcMode = (Convert-OverlayMode $ac); DcMode = (Convert-OverlayMode $dc)
        ActiveMode = (Convert-OverlayMode $ac)
        ClassicGuid = $classic; ClassicMode = (Convert-ClassicMode $classic)
        Schemes = $schemes
        HasSaverPlan = [bool]($schemes -contains $script:PlanSaver)
        HasHighPlan = [bool]($schemes -contains $script:PlanHigh)
        HasBalancedPlan = [bool]($schemes -contains $script:PlanBalanced)
    }
}
function Get-PowerAdvice($snap, $cpuAvg) {
    if ($null -eq $snap) { return @() }
    $onBattery = [bool]($snap.HasBattery -and -not $snap.OnAC)
    $cpuHigh = ($null -ne $cpuAvg -and [int]$cpuAvg -ge 80)
    $list = New-Object System.Collections.Generic.List[object]
    $mode = if ($snap.ActiveMode) { [string]$snap.ActiveMode } elseif ($onBattery) { [string]$snap.DcMode } else { [string]$snap.AcMode }
    if ($snap.OverlaySupported -and $mode -and $mode -ne 'other') {
        if ($onBattery -and $mode -eq 'performance') {
            $list.Add([pscustomobject]@{
                Title = '用电池时滑杆在「最佳性能」'
                Detail = '这是电池图标里的电源滑杆。用电池时开着「最佳性能」更费电。建议改成「更高性能」（日常那一档），不要改成「最佳性能」。可以随时改回。'
                FixText = '修复：把电源滑杆改到「更高性能」（可再改回）'
                PowerTarget = 'balanced'
            })
        } elseif ($onBattery -and $mode -eq 'efficiency') {
            $list.Add([pscustomobject]@{
                Title = '用电池时滑杆在「更好的电池」'
                Detail = '「更好的电池」会更早降频。如果觉得发闷，可以改成「更高性能」。用电池时不会建议「最佳性能」。可以随时改回。'
                FixText = '修复：把电源滑杆改到「更高性能」（可再改回）'
                PowerTarget = 'balanced'
            })
        } elseif ((-not $onBattery) -and $cpuHigh -and $mode -eq 'efficiency') {
            $list.Add([pscustomobject]@{
                Title = '正在插电，滑杆仍在「更好的电池」'
                Detail = "CPU 这几秒平均 $cpuAvg%。插电且 CPU 一直很高时，可以临时拨到「最佳性能」。用电池时不会自动拨到这一档。可以随时改回「更高性能」。"
                FixText = '修复：把电源滑杆改到「最佳性能」（可再改回；用电池时不会自动执行）'
                PowerTarget = 'performance'
            })
        }
    } else {
        $classic = [string]$snap.ClassicMode
        if ($onBattery -and ($classic -eq 'saver' -or $classic -eq 'high')) {
            $label = Format-PowerMode $classic
            $list.Add([pscustomobject]@{
                Title = "用电池时电源计划是「$label」"
                Detail = '用电池时建议经典电源计划用「平衡」。不会改成「高性能」。可以随时改回。'
                FixText = '修复：切换为平衡电源计划（可再改回）'
                PowerTarget = 'balanced'
            })
        } elseif ((-not $onBattery) -and $classic -eq 'saver') {
            if ($cpuHigh -and $snap.HasHighPlan) {
                $list.Add([pscustomobject]@{
                    Title = '正在插电，电源计划是「节能」'
                    Detail = "CPU 这几秒平均 $cpuAvg%。这台电脑没有可用的 Windows 11 电源模式滑杆，所以改的是经典电源计划。插电且 CPU 持续偏高时可以临时用「高性能」。用电池时不会自动这样切。可以随时改回。"
                    FixText = '修复：切换为高性能电源计划（可再改回；用电池时不会自动执行）'
                    PowerTarget = 'performance'
                })
            } else {
                $list.Add([pscustomobject]@{
                    Title = '电源计划是「节能」'
                    Detail = '节能会让 CPU 更早降频。建议改成「平衡」。用电池时不会改成「高性能」。可以随时改回。'
                    FixText = '修复：切换为平衡电源计划（可再改回）'
                    PowerTarget = 'balanced'
                })
            }
        }
    }
    return @($list | Where-Object { -not ($onBattery -and $_.PowerTarget -eq 'performance') })
}
function Set-OverlayGuid([bool]$dc, [string]$guid) {
    # $dc 保留参数以兼容旧调用。Windows 10 的滑杆只有当前这一档，用 overlaysetactive。
    $exe = Get-PowerCfgExe
    if (-not (Test-Path -LiteralPath $exe) -or -not $guid) { return $false }
    try {
        & $exe /overlaysetactive $guid | Out-Null
        if ($LASTEXITCODE -eq 0) { return $true }
        & $exe -overlaysetactive $guid | Out-Null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}
function Set-OverlayMode([bool]$dc, [string]$mode) {
    $guid = switch ($mode) {
        'efficiency' { $script:OverlayEfficiency }
        'balanced' { $script:OverlayBalanced }
        'performance' { $script:OverlayPerformance }
        default { return $false }
    }
    return (Set-OverlayGuid $dc $guid)
}
function Set-ClassicScheme([string]$guid) {
    if (-not $guid) { return $false }
    try {
        $rc = [int][WinOpt.Native]::WriteActiveScheme($guid)
        if ($rc -eq 0) { return $true }
    } catch { }
    $exe = Get-PowerCfgExe
    $cmd = "& '$((Get-PowerCfgExe).Replace("'","''"))' /setactive $guid; if (`$LASTEXITCODE -ne 0) { throw `"powercfg `$LASTEXITCODE`" }"
    if (Test-IsAdmin -and (Test-Path $exe)) {
        & $exe /setactive $guid | Out-Null
        return ($LASTEXITCODE -eq 0)
    }
    return [bool](Invoke-Elevated $cmd)
}
function Restore-PowerSnapshot($snap) {
    if ($null -eq $snap) { return }
    if ($snap.OverlaySupported) {
        if ($snap.AcGuid) { [void](Set-OverlayGuid $false $snap.AcGuid) }
        if ($snap.DcGuid) { [void](Set-OverlayGuid $true $snap.DcGuid) }
    }
    if ($snap.ClassicGuid) { [void](Set-ClassicScheme $snap.ClassicGuid) }
}
function Set-PowerMode([string]$target, [switch]$Quiet) {
    $snap = Get-PowerSnapshot
    $onBattery = $snap.HasBattery -and -not $snap.OnAC
    if ($target -eq 'performance' -and $onBattery -and -not $snap.OverlaySupported) {
        if (-not $Quiet) { Show-Info '正在使用电池，而且这台电脑不能单独调节电源模式滑杆。为了省电，不会切换到经典「高性能」计划。' }
        return $false
    }
    if (-not $Quiet) {
        $label = Format-PowerMode $target
        $where = if ($onBattery) { '电池' } elseif ($snap.HasBattery) { '插电' } else { '当前' }
        $msg = "把电源滑杆改成「$label」？`n这是电池图标里的那一档（Windows 10），可以随时改回。不会关闭系统服务或 Defender。"
        if ($target -eq 'performance' -and $onBattery) {
            $msg = "正在使用电池。`n「最佳性能」会更费电，风扇也可能更响。`n确定要拨过去吗？可以随时改回「更高性能」。"
        }
        if (-not (Confirm-Action $msg '电源模式')) { return $false }
    }
    if ($target -eq 'performance' -and $onBattery -and $Quiet) { return $false }
    $ok = $false
    if ($snap.OverlaySupported) { $ok = Set-OverlayMode -dc:([bool]$onBattery) -mode $target }
    if (-not $ok) {
        if ($target -eq 'performance' -and $onBattery) { return $false }
        $guid = switch ($target) {
            'efficiency' { if ($snap.HasSaverPlan) { $script:PlanSaver } else { $null } }
            'performance' { if ((-not $onBattery) -and $snap.HasHighPlan) { $script:PlanHigh } else { $null } }
            default { if ($snap.HasBalancedPlan) { $script:PlanBalanced } else { $null } }
        }
        if (-not $guid) {
            if (-not $Quiet) { Show-Info '这台电脑没有对应的电源模式或经典电源计划，没有修改。' }
            return $false
        }
        $ok = Set-ClassicScheme $guid
    }
    if ($ok) { try { Update-PowerPlan } catch { } }
    elseif (-not $Quiet) { Show-Info '没有切换成功（可能取消了管理员授权）。可以再到「设置 → 电源」里改。' }
    return [bool]$ok
}
function Update-PowerPlan {
    $snap = Get-PowerSnapshot
    $script:LastPowerSnap = $snap
    $onBattery = $snap.HasBattery -and -not $snap.OnAC
    $useOverlay = [bool]$snap.OverlaySupported
    $cur = if ($useOverlay) { if ($onBattery) { $snap.DcMode } else { $snap.AcMode } } else { $snap.ClassicMode }
    $curLabel = Format-PowerMode $cur
    $src = if (-not $snap.HasBattery) { '未检测到电池，按插电处理' } elseif ($onBattery) { '正在使用电池' } else { '正在插电' }
    $other = ''
    if ($useOverlay -and $snap.HasBattery -and $snap.AcMode -and $snap.DcMode -and $snap.AcMode -ne $snap.DcMode) {
        $other = " 插电：「$(Format-PowerMode $snap.AcMode)」，电池：「$(Format-PowerMode $snap.DcMode)」。"
    }
    $hint = if ($useOverlay) { 'Windows 10 电池图标滑杆。用电池时建议停在「更高性能」或「更好的电池」，不建议「最佳性能」。' } else { '这台电脑没有滑杆覆盖方案，显示的是经典电源计划。' }
    $ui.PowerPlanText.Text = "当前（$src）：$curLabel。$hint"
    $ui.PlanSaver.IsEnabled = ($cur -ne 'efficiency' -and $cur -ne 'saver')
    $ui.PlanBalanced.IsEnabled = ($cur -ne 'balanced')
    $ui.PlanHigh.IsEnabled = ($cur -ne 'performance' -and $cur -ne 'high' -and ($useOverlay -or (-not $onBattery -and $snap.HasHighPlan)))
}

# ---------------- 进程优先级 / 关闭窗口 ----------------
function Format-Priority([string]$p) {
    switch ($p) {
        'Idle' { '低' }
        'BelowNormal' { '低于正常' }
        'Normal' { '正常' }
        'AboveNormal' { '高于正常' }
        'High' { '高' }
        'RealTime' { '实时' }
        default { '—' }
    }
}
function Read-PriorityBackup {
    if (-not (Test-Path $PriorityBackup)) { return @() }
    try {
        $raw = Get-Content -Path $PriorityBackup -Raw -Encoding UTF8
        if (-not $raw) { return @() }
        return @($raw | ConvertFrom-Json)
    } catch { return @() }
}
function Write-PriorityBackup($items) {
    $arr = @($items | Where-Object { $_ })
    if ($arr.Count -eq 0) {
        if (Test-Path $PriorityBackup) { Remove-Item $PriorityBackup -Force -ErrorAction SilentlyContinue }
        return
    }
    $arr | ConvertTo-Json -Depth 4 | Set-Content -Path $PriorityBackup -Encoding UTF8
}
function Save-PriorityOriginal([int]$ProcId, [string]$Name, [string]$Original) {
    $items = @(Read-PriorityBackup | Where-Object { -not ($_.Pid -eq $ProcId -and $_.Name -eq $Name) })
    $items += [pscustomobject]@{ Pid = $ProcId; Name = $Name; Original = $Original }
    Write-PriorityBackup $items
}
function Remove-PriorityEntry([int]$ProcId, [string]$Name) {
    Write-PriorityBackup @(Read-PriorityBackup | Where-Object { -not ($_.Pid -eq $ProcId -and $_.Name -eq $Name) })
}
function Get-PriorityOriginal([int]$ProcId, [string]$Name) {
    $hit = @(Read-PriorityBackup | Where-Object { $_.Pid -eq $ProcId -and $_.Name -eq $Name })
    if ($hit.Count -gt 0) { return [string]$hit[-1].Original }
    return $null
}
function Test-SafeProcessName([string]$name) { return ($name -match '^[A-Za-z0-9_.()\- ]+$') }
function Try-SetPriority($p, [string]$level) {
    try { $p.PriorityClass = $level; return $true } catch { return $false }
}
function Set-ProcessBelowNormal([int]$ProcId, [string]$Name) {
    $p = $null
    try { $p = Get-Process -Id $ProcId -ErrorAction Stop } catch { return $false }
    if ($p.ProcessName -ne $Name) { return $false }
    if (Test-ProtectedProcess $p) { return $false }
    $orig = $null
    try { $orig = [string]$p.PriorityClass } catch { return $false }
    if ($orig -eq 'BelowNormal' -or $orig -eq 'Idle') { return $true }
    Save-PriorityOriginal $ProcId $Name $orig
    $ok = Try-SetPriority $p 'BelowNormal'
    if (-not $ok -and (Test-SafeProcessName $Name)) {
        $safe = $Name.Replace("'", '')
        $cmd = "`$p = Get-Process -Id $ProcId -ErrorAction Stop; if (`$p.ProcessName -ne '$safe') { throw 'name' }; `$p.PriorityClass = 'BelowNormal'"
        $ok = [bool](Invoke-Elevated $cmd)
    }
    if (-not $ok) { Remove-PriorityEntry $ProcId $Name }
    return [bool]$ok
}
function Restore-ProcessPriority([int]$ProcId, [string]$Name) {
    $p = $null
    try { $p = Get-Process -Id $ProcId -ErrorAction Stop } catch { return $false }
    if ($p.ProcessName -ne $Name) { return $false }
    if (Test-ProtectedProcess $p) { return $false }
    $orig = Get-PriorityOriginal $ProcId $Name
    if (-not $orig -or $orig -eq 'RealTime') { $orig = 'Normal' }
    $ok = Try-SetPriority $p $orig
    if (-not $ok -and (Test-SafeProcessName $Name)) {
        $safe = $Name.Replace("'", '')
        $safeOrig = $orig.Replace("'", '')
        $cmd = "`$p = Get-Process -Id $ProcId -ErrorAction Stop; if (`$p.ProcessName -ne '$safe') { throw 'name' }; `$p.PriorityClass = '$safeOrig'"
        $ok = [bool](Invoke-Elevated $cmd)
    }
    if ($ok) { Remove-PriorityEntry $ProcId $Name }
    return [bool]$ok
}
function Request-ProcessClose([int]$ProcId) {
    $p = $null
    try { $p = Get-Process -Id $ProcId -ErrorAction Stop } catch { return 'missing' }
    if (Test-ProtectedProcess $p) { return 'protected' }
    if ($p.MainWindowHandle -eq 0) { return 'nowindow' }
    try {
        if ($p.CloseMainWindow()) { return 'ok' }
        return 'failed'
    } catch { return 'failed' }
}

# ---------------- 资源排行 ----------------
$script:PrevCpu = @{}; $script:PrevTime = $null
function Update-Processes {
    $now = Get-Date
    $procs = Get-Process | Where-Object { $_.Id -ne 0 -and $_.Id -ne 4 }
    $cores = [Environment]::ProcessorCount
    $rows = foreach ($p in $procs) {
        $t = $null; try { $t = $p.TotalProcessorTime.TotalMilliseconds } catch { }
        $cpu = $null
        if ($null -ne $t -and $script:PrevTime -and $script:PrevCpu.ContainsKey($p.Id)) {
            $dt = ($now - $script:PrevTime).TotalMilliseconds
            if ($dt -gt 0) { $cpu = [math]::Max(0, ($t - $script:PrevCpu[$p.Id]) / $dt / $cores * 100) }
        }
        $pri = '—'
        try { $pri = Format-Priority ([string]$p.PriorityClass) } catch { }
        [pscustomobject]@{
            Name = $p.ProcessName; Id = $p.Id; MemRaw = $p.WorkingSet64; Mem = (Format-Bytes $p.WorkingSet64)
            Cpu = $(if ($null -ne $cpu) { $cpu } else { -1 }); CpuText = $(if ($null -ne $cpu) { '{0:N1}%' -f $cpu } else { '—' })
            Pri = $pri; Title = $p.MainWindowTitle; Tms = $t
        }
    }
    $script:PrevCpu = @{}; foreach ($r in $rows) { if ($null -ne $r.Tms) { $script:PrevCpu[$r.Id] = $r.Tms } }
    $script:PrevTime = $now
    $sorted = if ($ui.SortCpu.IsChecked) { $rows | Sort-Object Cpu -Descending } else { $rows | Sort-Object MemRaw -Descending }
    $ui.ProcList.ItemsSource = @($sorted | Select-Object -First 40)
}
function Lower-SelectedPriority {
    $sel = @($ui.ProcList.SelectedItems)
    if ($sel.Count -eq 0) { Show-Info '先选中要降低优先级的进程（可按 Ctrl 多选）。'; return }
    $ok = @($sel | Where-Object { -not (Test-ProtectedProcess $_) })
    if ($ok.Count -eq 0) { Show-Info '系统关键进程和本程序不能改优先级。'; return }
    $names = ($ok | ForEach-Object { "$($_.Name) (PID $($_.Id))" }) -join "`n"
    if (-not (Confirm-Action "把这些进程的优先级降为「低于正常」？`n程序会继续运行，只是少抢占 CPU。可以随时点「恢复优先级」改回。`n`n$names" '降低优先级')) { return }
    $fail = @()
    foreach ($s in $ok) { if (-not (Set-ProcessBelowNormal -ProcId ([int]$s.Id) -Name ([string]$s.Name))) { $fail += $s.Name } }
    if ($fail.Count) { Show-Info ("这些进程没有改成（可能没有权限或已退出）：`n" + ($fail -join "`n")) }
    else { Show-Info '已降为「低于正常」。可随时恢复。' }
    Update-Processes
}
function Restore-SelectedPriority {
    $sel = @($ui.ProcList.SelectedItems)
    if ($sel.Count -eq 0) { Show-Info '先选中要恢复优先级的进程。'; return }
    $ok = @($sel | Where-Object { -not (Test-ProtectedProcess $_) })
    if ($ok.Count -eq 0) { Show-Info '系统关键进程和本程序不用恢复。'; return }
    $fail = @()
    foreach ($s in $ok) { if (-not (Restore-ProcessPriority -ProcId ([int]$s.Id) -Name ([string]$s.Name))) { $fail += $s.Name } }
    if ($fail.Count) { Show-Info ("这些进程没有恢复：`n" + ($fail -join "`n")) }
    else { Show-Info '已恢复原来的优先级。' }
    Update-Processes
}
function Close-SelectedProcesses {
    $sel = @($ui.ProcList.SelectedItems)
    if ($sel.Count -eq 0) { Show-Info '先在列表里选中要关闭的进程（可按 Ctrl 多选）。'; return }
    $blocked = @($sel | Where-Object { Test-ProtectedProcess $_ })
    $ok = @($sel | Where-Object { -not (Test-ProtectedProcess $_) })
    if ($ok.Count -eq 0) { Show-Info '选中的是系统关键进程或本程序，不能关闭。'; return }
    $names = ($ok | ForEach-Object { "$($_.Name) (PID $($_.Id))" }) -join "`n"
    $extra = ''
    if ($blocked.Count) { $extra = "`n`n已跳过系统关键进程：$(($blocked | ForEach-Object { $_.Name }) -join '、')" }
    if (-not (Confirm-Action "向这些程序发送关闭窗口请求？`n和点右上角 × 一样，不会强制结束。请先自己保存未保存的内容。`n`n$names$extra" '关闭窗口')) { return }
    $notes = @()
    foreach ($s in $ok) {
        switch (Request-ProcessClose ([int]$s.Id)) {
            'ok' { $notes += "$($s.Name)：已发送关闭请求" }
            'nowindow' { $notes += "$($s.Name)：没有窗口，未强制结束" }
            'protected' { $notes += "$($s.Name)：系统进程，已跳过" }
            'missing' { $notes += "$($s.Name)：进程已退出" }
            default { $notes += "$($s.Name)：没有送出关闭请求" }
        }
    }
    Show-Info ($notes -join "`n")
    Update-Processes
}

# ---------------- 开机启动 ----------------
function Update-Startup {
    $items = @(Get-StartupItems | ForEach-Object {
        $_ | Add-Member -NotePropertyName State -NotePropertyValue $(if (-not $_.CanToggle) { '一次性' } elseif ($_.Enabled) { '启用' } else { '已停用' }) -PassThru
    })
    $ui.StartList.ItemsSource = $items
}
function Set-SelectedStartup([bool]$enable) {
    $sel = @($ui.StartList.SelectedItems | Where-Object { $_.CanToggle })
    if ($sel.Count -eq 0) { Show-Info '先选中要修改的启动项（RunOnce 一次性项目不能停用）。'; return }
    $verb = if ($enable) { '启用' } else { '停用' }
    if (-not (Confirm-Action ("$verb 以下启动项？`n`n" + (($sel | ForEach-Object { $_.Name }) -join "`n")) "$verb 启动项")) { return }
    $fail = @()
    foreach ($s in $sel) { try { if (-not (Set-StartupEnabled $s $enable)) { $fail += $s.Name } } catch { $fail += $s.Name } }
    if ($fail.Count) { Show-Info ("这些项目没有修改（可能取消了管理员授权）：`n" + ($fail -join "`n")) }
    Update-Startup
}

# ---------------- 浏览器 ----------------
function Update-Browsers { $ui.BrList.ItemsSource = @(Get-Browsers) }

# ---------------- 网络 ----------------
function Update-Dns {
    $d = @(Get-CurrentDns)
    if ($d.Count -eq 0) { $ui.DnsText.Text = '没有已连接的物理网卡。' }
    else { $ui.DnsText.Text = ($d | ForEach-Object { "$($_.Name)：$(if ($_.Servers.Count) { $_.Servers -join ', ' } else { '自动获取' })" }) -join "`n" }
    $ui.DnsRestore.IsEnabled = (Test-Path $DnsBackup)
    $v = @(Get-VpnAdapters)
    $ui.VpnText.Text = if ($v.Count) { '已连接：' + (($v | ForEach-Object { "$($_.Name)（$($_.InterfaceDescription)）" }) -join '；') } else { '没有检测到正在连接的 VPN / 虚拟网卡。' }
}
function Start-PingTest {
    $ui.PingBtn.IsEnabled = $false
    $ui.PingText.Text = '测速中…'
    Start-Bg {
        $targets = @(@('阿里 DNS', '223.5.5.5'), @('Cloudflare', '1.1.1.1'), @('百度', 'www.baidu.com'))
        $out = @()
        foreach ($t in $targets) {
            $ping = New-Object System.Net.NetworkInformation.Ping
            $ok = 0; $sum = 0; $min = 99999; $max = 0; $n = 8
            for ($i = 0; $i -lt $n; $i++) {
                try {
                    $r = $ping.Send($t[1], 1500)
                    if ($r.Status -eq 'Success') { $ok++; $ms = [int]$r.RoundtripTime; $sum += $ms; if ($ms -lt $min) { $min = $ms }; if ($ms -gt $max) { $max = $ms } }
                } catch { }
                Start-Sleep -Milliseconds 150
            }
            $loss = [int](100 * ($n - $ok) / $n)
            if ($ok -gt 0) { $out += ('{0,-12} {1,-15} 平均 {2,4} ms  最低 {3,4}  最高 {4,4}  丢包 {5}%' -f $t[0], $t[1], [int]($sum / $ok), $min, $max, $loss) }
            else { $out += ('{0,-12} {1,-15} 全部超时（丢包 100%）' -f $t[0], $t[1]) }
        }
        return ($out -join "`n")
    } {
        param($res)
        $ui.PingText.Text = if ($res) { [string]($res | Select-Object -Last 1) } else { '测速失败' }
        $ui.PingBtn.IsEnabled = $true
    }
}

# ---------------- 显示 ----------------
function Update-Display {
    $a = Get-AnimationsOn
    $ui.AnimText.Text = if ($a) { '当前：已打开' } else { '当前：已关闭' }
    $ui.AnimBtn.Content = if ($a) { '关闭动画' } else { '打开动画' }
    $t = Get-TransparencyOn
    $ui.TransText.Text = if ($t) { '当前：已打开' } else { '当前：已关闭' }
    $ui.TransBtn.Content = if ($t) { '关闭透明效果' } else { '打开透明效果' }
}

# ---------------- 电池 ----------------
function Update-Battery {
    $b = Get-BatteryInfo
    if (-not $b) { $ui.BatText.Text = '没有检测到电池（台式机）'; $ui.BatSub.Text = ''; return }
    $ui.BatText.Text = "$($b.Percent)%"
    $ui.BatSub.Text = if ($b.OnAC) { '正在使用电源适配器' } else { '正在使用电池' }
}


# ---------------- 优化建议（可恢复） ----------------
# 原值统一记在 %LOCALAPPDATA%\WinOptimizer\undo.json。Windows 10 为主；Win11 才有的项目显示「不适用」。
$UndoDir = Join-Path $env:LOCALAPPDATA 'WinOptimizer'
$UndoPath = Join-Path $UndoDir 'undo.json'
function Get-OsBuild {
    if ($script:MockBuild) { return [int]$script:MockBuild }
    try { return [int](Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name CurrentBuildNumber).CurrentBuildNumber } catch { return 0 }
}
function Test-IsWin11 { return ((Get-OsBuild) -ge 22000) }
function Ensure-UndoDir { if (-not (Test-Path -LiteralPath $UndoDir)) { New-Item -ItemType Directory -Path $UndoDir | Out-Null } }
function Read-UndoItems {
    if (-not (Test-Path -LiteralPath $UndoPath)) { return @() }
    try {
        $raw = Get-Content -LiteralPath $UndoPath -Raw -Encoding UTF8
        if (-not $raw) { return @() }
        return @($raw | ConvertFrom-Json)
    } catch { return @() }
}
function Write-UndoItems($items) {
    Ensure-UndoDir
    $arr = @($items | Where-Object { $_ })
    if ($arr.Count -eq 0) { Set-Content -LiteralPath $UndoPath -Value '[]' -Encoding UTF8; return }
    $arr | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $UndoPath -Encoding UTF8
}
function Get-UndoEntry([string]$id) {
    $hit = @(Read-UndoItems | Where-Object { $_.id -eq $id })
    if ($hit.Count -gt 0) { return $hit[-1] }
    return $null
}
function Save-UndoEntry($entry) {
    $items = @(Read-UndoItems | Where-Object { $_.id -ne $entry.id })
    $items += $entry
    Write-UndoItems $items
}
function Remove-UndoEntry([string]$id) {
    Write-UndoItems @(Read-UndoItems | Where-Object { $_.id -ne $id })
}
function Get-RegState([string]$path, [string]$name) {
    try {
        if (-not (Test-Path -LiteralPath $path)) { return @{ Exists = $false; Value = $null; Type = 'DWord' } }
        $item = Get-Item -LiteralPath $path
        if ($item.GetValueNames() -notcontains $name) { return @{ Exists = $false; Value = $null; Type = 'DWord' } }
        return @{ Exists = $true; Value = $item.GetValue($name); Type = [string]$item.GetValueKind($name) }
    } catch { return @{ Exists = $false; Value = $null; Type = 'DWord' } }
}
function Set-RegDword([string]$path, [string]$name, [int]$value, [string]$id) {
    $cur = Get-RegState $path $name
    if (-not (Get-UndoEntry $id)) {
        Save-UndoEntry ([pscustomobject]@{ id = $id; kind = 'reg'; path = $path; name = $name; existed = [bool]$cur.Exists; type = [string]$cur.Type; value = $cur.Value })
    }
    if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force | Out-Null }
    $hkcu = $path -like 'HKCU:*'
    if ($hkcu -or (Test-IsAdmin)) {
        Set-ItemProperty -LiteralPath $path -Name $name -Type DWord -Value $value
        return $true
    }
    $p = $path.Replace("'", "''")
    $n = $name.Replace("'", "''")
    $cmd = "if (-not (Test-Path -LiteralPath '$p')) { New-Item -Path '$p' -Force | Out-Null }; Set-ItemProperty -LiteralPath '$p' -Name '$n' -Type DWord -Value $value"
    return [bool](Invoke-Elevated $cmd)
}
function Restore-RegEntry($e) {
    if (-not $e.existed) {
        if (Test-Path -LiteralPath $e.path) { Remove-ItemProperty -LiteralPath $e.path -Name $e.name -ErrorAction SilentlyContinue }
        return $true
    }
    $type = if ($e.type) { [string]$e.type } else { 'DWord' }
    if (-not (Test-Path -LiteralPath $e.path)) { New-Item -Path $e.path -Force | Out-Null }
    if (($e.path -like 'HKCU:*') -or (Test-IsAdmin)) {
        Set-ItemProperty -LiteralPath $e.path -Name $e.name -Type $type -Value $e.value
        return $true
    }
    $p = ([string]$e.path).Replace("'", "''")
    $n = ([string]$e.name).Replace("'", "''")
    $v = $e.value
    $cmd = "if (-not (Test-Path -LiteralPath '$p')) { New-Item -Path '$p' -Force | Out-Null }; Set-ItemProperty -LiteralPath '$p' -Name '$n' -Type $type -Value $v"
    return [bool](Invoke-Elevated $cmd)
}
function Get-PowerDcIndex([string]$sub, [string]$setting) {
    $out = Invoke-PowerCfg /q SCHEME_CURRENT $sub $setting
    if ($LASTEXITCODE -ne 0 -or $out -match '(?i)invalid|无效|错误') { return $null }
    $hex = @([regex]::Matches($out, '0x[0-9a-fA-F]+'))
    if ($hex.Count -lt 2) { return $null }
    return @{
        Ac = [Convert]::ToInt32($hex[$hex.Count - 2].Value, 16)
        Dc = [Convert]::ToInt32($hex[$hex.Count - 1].Value, 16)
    }
}
function Set-PowerDcIndex([string]$sub, [string]$setting, [int]$value) {
    [void](Invoke-PowerCfg /setdcvalueindex SCHEME_CURRENT $sub $setting $value)
    if ($LASTEXITCODE -ne 0) { return $false }
    [void](Invoke-PowerCfg /setactive SCHEME_CURRENT)
    return ($LASTEXITCODE -eq 0)
}
function Apply-PowerDc([string]$id, [string]$sub, [string]$setting, [int]$want) {
    $cur = Get-PowerDcIndex $sub $setting
    if ($null -eq $cur) { return 'skip' }
    if (-not (Get-UndoEntry $id)) {
        Save-UndoEntry ([pscustomobject]@{ id = $id; kind = 'powerdc'; sub = $sub; setting = $setting; ac = [int]$cur.Ac; dc = [int]$cur.Dc })
    }
    if ([int]$cur.Dc -eq $want) { return 'ok' }
    if (Set-PowerDcIndex $sub $setting $want) { return 'ok' }
    return 'fail'
}
function Get-HibernateInfo {
    $exe = Get-PowerCfgExe
    $out = Invoke-PowerCfg /a
    $parts = [regex]::Split($out, '(?i)not available on this system|没有以下睡眠状态|以下睡眠状态不可用|不受支持')
    $avail = [string]$parts[0]
    $rest = ''
    if ($parts.Count -gt 1) { $rest = [string]$parts[1] }
    $enabled = [bool]($avail -match '(?i)hibernate|休眠')
    $can = [bool]($rest -match '(?i)has not been enabled|尚未启用|没有启用休眠|休眠尚未')
    $no = [bool]((-not $enabled) -and (-not $can))
    return @{ Enabled = $enabled; CanEnable = $can; Unsupported = $no }
}
function Get-WidgetKind {
    $b = Get-OsBuild
    if ($b -ge 22000) { return 'widgets' }
    if ($b -ge 19043) { return 'feeds' }
    return 'na'
}
function Open-SettingsPage([string]$uri) {
    try { Start-Process $uri; return $true } catch { return $false }
}
function Get-Brightness {
    try {
        $b = @(Get-CimInstance -Namespace root/wmi -ClassName WmiMonitorBrightness -ErrorAction Stop)
        if ($b.Count -eq 0) { return $null }
        return [int]$b[0].CurrentBrightness
    } catch { return $null }
}
function Set-Brightness([int]$value) {
    try {
        $m = @(Get-CimInstance -Namespace root/wmi -ClassName WmiMonitorBrightnessMethods -ErrorAction Stop)
        if ($m.Count -eq 0) { return $false }
        $m[0] | Invoke-CimMethod -MethodName WmiSetBrightness -Arguments @{ Timeout = 0; Brightness = [byte]$value } | Out-Null
        return $true
    } catch { return $false }
}
function Get-DoMode {
    try {
        Import-Module DeliveryOptimization -ErrorAction SilentlyContinue
        if (-not (Get-Command Get-DODownloadMode -ErrorAction SilentlyContinue)) { return $null }
        return [string](Get-DODownloadMode)
    } catch { return $null }
}
function Get-OldTempFiles([string]$root, [int]$days) {
    if (-not $root -or -not (Test-Path -LiteralPath $root)) { return @() }
    $cut = (Get-Date).AddDays(-1 * $days)
    $files = @(Get-ChildItem -LiteralPath $root -Recurse -Force -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cut } |
        Select-Object -First 400)
    return ,$files
}
function Move-FileToRecycle([string]$path) {
    # shell32 在 x64 / ARM64 上都是系统自带的。FOF_NO_UI 避免弹出对话框卡住。
    if (-not ('WinOptRecycle' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class WinOptRecycle {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct SHFILEOPSTRUCT {
        public IntPtr hwnd;
        public uint wFunc;
        [MarshalAs(UnmanagedType.LPWStr)] public string pFrom;
        [MarshalAs(UnmanagedType.LPWStr)] public string pTo;
        public short fFlags;
        [MarshalAs(UnmanagedType.Bool)]
        public bool fAnyOperationsAborted;
        public IntPtr hNameMappings;
        [MarshalAs(UnmanagedType.LPWStr)] public string lpszProgressTitle;
    }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern int SHFileOperation(ref SHFILEOPSTRUCT op);
}
'@
    }
    try {
        $op = New-Object WinOptRecycle+SHFILEOPSTRUCT
        $op.wFunc = 3
        $op.pFrom = $path + [char]0 + [char]0
        $op.fFlags = 0x14 + 0x40 + 0x400
        $rc = [WinOptRecycle]::SHFileOperation([ref]$op)
        return ($rc -eq 0 -and -not (Test-Path -LiteralPath $path))
    } catch { return $false }
}
function Restore-DoMode([string]$original) {
    if (-not $original) { return $false }
    $candidates = @($original)
    if ($original -match 'Cdn|Http') { $candidates += @('HttpOnly','CdnOnly',0) }
    $candidates += @(0,1,2,3,99,100)
    foreach ($c in $candidates) {
        try { Set-DODownloadMode -DownloadMode $c -ErrorAction Stop | Out-Null } catch { continue }
        try { if ([string](Get-DODownloadMode) -eq $original) { return $true } } catch { }
    }
    return $false
}
function Restore-UndoId([string]$id) {
    $e = Get-UndoEntry $id
    if (-not $e) { return $false }
    $ok = $true
    $script:UndoSuppress = $true
    try {
        switch ([string]$e.kind) {
            'reg' { $ok = Restore-RegEntry $e }
            'powerdc' { $ok = Set-PowerDcIndex ([string]$e.sub) ([string]$e.setting) ([int]$e.dc) }
            'transparency' { Set-Transparency ([bool]$e.value); $ok = $true }
            'animations' { Set-Animations ([bool]$e.value); $ok = $true }
            'brightness' { $ok = Set-Brightness ([int]$e.value) }
            'overlay' { $ok = Set-OverlayGuid $false ([string]$e.value) }
            'scheme' { $ok = Set-ClassicScheme ([string]$e.value) }
            'domode' { $ok = Restore-DoMode ([string]$e.value) }
            'hibernateflag' {
                $exe = Get-PowerCfgExe
                $arg = if ([bool]$e.value) { '/hibernate','on' } else { '/hibernate','off' }
                & $exe @arg | Out-Null
                $ok = ($LASTEXITCODE -eq 0)
            }
            default { $ok = $false }
        }
    } catch { $ok = $false }
    finally { $script:UndoSuppress = $false }
    if ($ok) { Remove-UndoEntry $id }
    return $ok
}
function Restore-AllUndo {
    $ids = @((Read-UndoItems | ForEach-Object { $_.id }))
    [array]::Reverse($ids)
    $ok = $true
    foreach ($id in $ids) { if (-not (Restore-UndoId $id)) { $ok = $false } }
    return $ok
}
function Get-TipLine([string]$id) {
    $na = { param($t) [pscustomobject]@{ Id = $id; State = '不适用'; Detail = $t; CanApply = $false; CanOpen = $false; CanRestore = [bool](Get-UndoEntry $id) } }
    try {
        switch ($id) {
            'overlay' {
                $s = Get-PowerSnapshot
                $label = if ($s.OverlaySupported) { Format-PowerMode $s.ActiveMode } else { Format-PowerMode $s.ClassicMode }
                return [pscustomobject]@{ Id = $id; State = "当前：$label"; Detail = 'Windows 10 电池图标滑杆。用电池时建议「更高性能」或「更好的电池」。'; CanApply = $true; CanOpen = $false; CanRestore = [bool](Get-UndoEntry $id) }
            }
            'esbatt' {
                $v = Get-PowerDcIndex 'SUB_ENERGYSAVER' 'ESBATTTHRESHOLD'
                if ($null -eq $v) { return (& $na '这台系统读不到节电阈值（Battery saver / ESBATTTHRESHOLD）。') }
                return [pscustomobject]@{ Id = $id; State = "当前：电量 $($v.Dc)% 时自动开节电模式"; Detail = '建议 30%。只改电池（DC）。Windows 10 里这叫节电模式，不是 Win11 的 Energy Saver。'; CanApply = $true; CanOpen = $false; CanRestore = [bool](Get-UndoEntry $id) }
            }
            'screen' {
                $v = Get-PowerDcIndex 'SUB_VIDEO' 'VIDEOIDLE'
                $s = Get-PowerDcIndex 'SUB_SLEEP' 'STANDBYIDLE'
                if ($null -eq $v -or $null -eq $s) { return (& $na '读不到关屏或睡眠超时。') }
                return [pscustomobject]@{ Id = $id; State = ("电池：{0} 分钟关屏，{1} 分钟睡眠" -f [int]($v.Dc / 60), [int]($s.Dc / 60)); Detail = '建议电池时 3 分钟关屏、10 分钟睡眠。只改电池，插电不动。'; CanApply = $true; CanOpen = $false; CanRestore = [bool]((Get-UndoEntry 'screen-video') -or (Get-UndoEntry 'screen-sleep')) }
            }
            'standbynet' {
                $v = Get-PowerDcIndex 'SUB_NONE' 'CONNECTIVITYINSTANDBY'
                if ($null -eq $v) { return (& $na '读不到「待机时保持网络连接」。') }
                $txt = switch ([int]$v.Dc) { 0 { '电池：已断开' } 1 { '电池：保持连接' } 2 { '电池：由 Windows 管理' } default { "电池：$($v.Dc)" } }
                return [pscustomobject]@{ Id = $id; State = $txt; Detail = 'Surface 是现代待机。建议电池时断开（0），睡眠中先收不到消息，唤醒后会自己连上。只改电池。'; CanApply = $true; CanOpen = $false; CanRestore = [bool](Get-UndoEntry $id) }
            }
            'hibernate' {
                $h = Get-HibernateInfo
                $v = Get-PowerDcIndex 'SUB_SLEEP' 'HIBERNATEIDLE'
                if ($h.Unsupported -or $null -eq $v) { return (& $na '这台电脑不支持休眠（powercfg /a）。不会强行打开。') }
                $mins = [int]($v.Dc / 60)
                return [pscustomobject]@{ Id = $id; State = "电池：睡眠 $mins 分钟后休眠"; Detail = '建议 180 分钟。只在系统报告支持休眠时才能改。唤醒会稍慢。'; CanApply = $true; CanOpen = $false; CanRestore = [bool](Get-UndoEntry $id) }
            }
            'sleepstudy' {
                return [pscustomobject]@{ Id = $id; State = '只读'; Detail = '生成 SleepStudy / 电池报告，用来看谁在合盖时耗电。不改设置。'; CanApply = $false; CanOpen = $true; CanRestore = $false }
            }
            'surface' {
                $pkg = $null
                try { $pkg = @(Get-AppxPackage -Name '*Surface*' -ErrorAction SilentlyContinue | Select-Object -First 1) } catch { }
                $st = if ($pkg) { '已安装 Surface 应用' } else { '没找到 Surface 应用' }
                return [pscustomobject]@{ Id = $id; State = $st; Detail = '智能充电 / 充到 80% 或 50% 只能在 Surface 应用或 UEFI 里开。这里只负责打开，不写固件。'; CanApply = $false; CanOpen = $true; CanRestore = $false }
            }
            'wu' {
                $bios = ''
                try { $b = Get-CimInstance Win32_BIOS -ErrorAction Stop; $bios = [string]$b.SMBIOSBIOSVersion } catch { }
                return [pscustomobject]@{ Id = $id; State = $(if ($bios) { "固件 $bios" } else { '打开 Windows 更新' }); Detail = 'Surface 的睡眠和风扇问题很多靠固件修好。这里只打开更新页，不自动安装。'; CanApply = $false; CanOpen = $true; CanRestore = $false }
            }
            'throttle' {
                $v = Get-PowerDcIndex 'SUB_PROCESSOR' 'PROCTHROTTLEMAX'
                if ($null -eq $v) { return (& $na '读不到「最大处理器状态」。') }
                return [pscustomobject]@{ Id = $id; State = "电池最大 $($v.Dc)%"; Detail = '可选的极限省电，默认不要开。只改电池，建议 80%，会更卡。微软没有为这项背书；ARM 上可能被固件忽略。'; CanApply = $true; CanOpen = $false; CanRestore = [bool](Get-UndoEntry $id) }
            }
            'usb' {
                $v = Get-PowerDcIndex 'SUB_USB' 'USBSELECTIVESUSPEND'
                if ($null -eq $v) { $v = Get-PowerDcIndex '2a737441-1930-4402-8d77-b2bebba308a3' '48e6b7a6-50f5-4782-a5d4-53bb8f07e226' }
                if ($null -eq $v) { return (& $na '读不到 USB 选择性暂停。') }
                $on = ([int]$v.Dc -eq 1)
                return [pscustomobject]@{ Id = $id; State = $(if ($on) { '电池：已开启（正常）' } else { '电池：被关掉了' }); Detail = '笔记本应保持开启。只有被别的软件关掉时，这里才把它改回开启。'; CanApply = (-not $on); CanOpen = $false; CanRestore = [bool](Get-UndoEntry $id) }
            }
            'drr' {
                $rate = $null
                try { $vc = @(Get-CimInstance Win32_VideoController -ErrorAction Stop); if ($vc.Count) { $rate = [int]$vc[0].CurrentRefreshRate } } catch { }
                $win11 = Test-IsWin11
                $detail = if ($win11) { '动态刷新率没有稳定的注册表。这里打开高级显示设置，由你自己开。' } else { '动态刷新率是 Windows 11 的功能，在 Windows 10 上不适用。仍可打开显示设置看刷新率。' }
                $st = if ($null -eq $rate) { '读不到刷新率' } else { "当前 ${rate} Hz" }
                if (-not $win11) { $st = "$st · 不适用" }
                return [pscustomobject]@{ Id = $id; State = $st; Detail = $detail; CanApply = $false; CanOpen = $true; CanRestore = $false }
            }
            'brightness' {
                $b = Get-Brightness
                if ($null -eq $b) { return (& $na '这台电脑读不到屏幕亮度。') }
                return [pscustomobject]@{ Id = $id; State = "当前 $b%"; Detail = '用电池且高于 70% 时，体检会建议调到 50%。可以恢复到原来的亮度。'; CanApply = $true; CanOpen = $true; CanRestore = [bool](Get-UndoEntry $id) }
            }
            'video' {
                return [pscustomobject]@{ Id = $id; State = '打开设置'; Detail = '「优化电池续航」的视频播放没有公开注册表。这里只打开设置页。'; CanApply = $false; CanOpen = $true; CanRestore = $false }
            }
            'visual' {
                $t = if (Get-TransparencyOn) { '透明开' } else { '透明关' }
                $a = if (Get-AnimationsOn) { '动画开' } else { '动画关' }
                return [pscustomobject]@{ Id = $id; State = "$t，$a"; Detail = '关掉能少占一点 GPU。和「显示」页是同一组开关，都会记入恢复。'; CanApply = $true; CanOpen = $false; CanRestore = [bool]((Get-UndoEntry 'transparency') -or (Get-UndoEntry 'animations')) }
            }
            'startup' {
                return [pscustomobject]@{ Id = $id; State = '到「开机启动」页'; Detail = 'Teams、Copilot（仅 Win11）、Spotify、Adobe 更新器等可以在那里停用。只改启动开关，不删除。'; CanApply = $false; CanOpen = $true; CanRestore = $false }
            }
            'background' {
                return [pscustomobject]@{ Id = $id; State = '按应用关闭'; Detail = '只改你点名的商店应用（Disabled / DisabledByUser）。不要一次全关，邮件和 Teams 会收不到通知。'; CanApply = $true; CanOpen = $false; CanRestore = [bool](Get-UndoEntry $id) }
            }
            'edge' {
                $p = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
                $boost = Get-RegState $p 'StartupBoostEnabled'
                $bg = Get-RegState $p 'BackgroundModeEnabled'
                $st = '未写入策略（建议在 Edge 设置里关）'
                if ($boost.Exists -or $bg.Exists) { $st = "策略：启动加速=$($boost.Value) 后台=$($bg.Value)" }
                return [pscustomobject]@{ Id = $id; State = $st; Detail = '可选。写入策略后 Edge 会显示「由你的组织管理」。恢复时删掉这些策略项。也可以只打开 Edge 的系统设置页。'; CanApply = $true; CanOpen = $true; CanRestore = [bool](Get-UndoEntry 'edge-boost') }
            }
            'widgets' {
                $kind = Get-WidgetKind
                if ($kind -eq 'na') { return (& $na '这个 Windows 10 版本没有「资讯和兴趣」。') }
                if ($kind -eq 'feeds') {
                    $v = Get-RegState 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Feeds' 'ShellFeedsTaskbarViewMode'
                    $st = if ($v.Exists -and [int]$v.Value -eq 2) { '任务栏：已隐藏' } else { '任务栏：显示中' }
                    return [pscustomobject]@{ Id = $id; State = $st; Detail = 'Windows 10 的「资讯和兴趣」。隐藏任务栏按钮（2）。不是 Win11 的小组件。'; CanApply = $true; CanOpen = $true; CanRestore = [bool](Get-UndoEntry $id) }
                }
                $v2 = Get-RegState 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarDa'
                $st2 = if ($v2.Exists -and [int]$v2.Value -eq 0) { '小组件按钮：关' } else { '小组件按钮：开' }
                return [pscustomobject]@{ Id = $id; State = $st2; Detail = 'Windows 11 小组件。若写入失败（系统保护），会改成打开任务栏设置。'; CanApply = $true; CanOpen = $true; CanRestore = [bool](Get-UndoEntry $id) }
            }
            'onedrive' {
                $p = @(Get-Process -Name 'OneDrive' -ErrorAction SilentlyContinue)
                $st = if ($p.Count) { "正在运行（$($p.Count) 个进程）" } else { '没在运行' }
                return [pscustomobject]@{ Id = $id; State = $st; Detail = '没有暂停同步的命令。可以正常退出（OneDrive.exe /shutdown），不要强制结束。节能模式也会自己暂停同步。'; CanApply = [bool]$p.Count; CanOpen = $false; CanRestore = $false }
            }
            'search' {
                $svc = $null
                try { $svc = Get-Service -Name WSearch -ErrorAction Stop } catch { }
                $st = if ($svc) { "Windows Search：$($svc.Status)" } else { '没有 WSearch 服务' }
                return [pscustomobject]@{ Id = $id; State = $st; Detail = '请在设置里选「经典」，并打开「索引时尊重设备电源设置」。这里不停止、不禁用搜索服务。增强/经典的注册表位置不稳定，所以不直接改。'; CanApply = $false; CanOpen = $true; CanRestore = $false }
            }
            'storage' {
                $v = Get-RegState 'HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy' '01'
                $free = 0
                try { $free = [int]((Get-PSDrive -Name C).Free / 1GB) } catch { }
                $on = ($v.Exists -and [int]$v.Value -eq 1)
                return [pscustomobject]@{ Id = $id; State = $(if ($on) { "存储感知：开 · C 盘约剩 ${free} GB" } else { "存储感知：关 · C 盘约剩 ${free} GB" }); Detail = '打开存储感知。临时文件要另点清理，会先列出超过 7 天的文件，优先放进回收站，删了不能从本工具恢复。'; CanApply = $true; CanOpen = $false; CanRestore = [bool](Get-UndoEntry $id) }
            }
            'delivery' {
                $m = Get-DoMode
                if ($null -eq $m) { return [pscustomobject]@{ Id = $id; State = '打开设置'; Detail = '这台系统没有 Delivery Optimization 命令。请到设置里把下载来源改成「本局域网的设备」，不要选互联网。'; CanApply = $false; CanOpen = $true; CanRestore = $false } }
                return [pscustomobject]@{ Id = $id; State = "当前模式：$m"; Detail = '建议 Lan（仅局域网），避免把更新上传到互联网。不影响 Windows 更新本身。'; CanApply = $true; CanOpen = $true; CanRestore = [bool](Get-UndoEntry $id) }
            }
            'privacy' {
                return [pscustomobject]@{ Id = $id; State = '可关闭提示'; Detail = '关闭「提示和建议」、欢迎体验、开始菜单建议。主要是少弹窗，几乎不加快速度。'; CanApply = $true; CanOpen = $false; CanRestore = [bool](Get-UndoEntry 'privacy-tips') }
            }
            'ads' {
                $a = Get-RegState 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled'
                $st = if ($a.Exists) { "广告 ID：$(if ([int]$a.Value -eq 0) { '关' } else { '开' })" } else { '广告 ID：默认' }
                return [pscustomobject]@{ Id = $id; State = $st; Detail = '关闭广告 ID 和量身定制体验。可选诊断数据只打开设置，不写 AllowTelemetry。主要减少跟踪，不加快速度。'; CanApply = $true; CanOpen = $true; CanRestore = [bool](Get-UndoEntry 'ads-id') }
            }
            'flushdns' {
                return [pscustomobject]@{ Id = $id; State = '不改 DNS'; Detail = '只清除 DNS 缓存。不改 DNS 服务器，也不关 IPv6。'; CanApply = $true; CanOpen = $false; CanRestore = $false }
            }
            default { return (& $na '未知项目') }
        }
    } catch {
        return [pscustomobject]@{ Id = $id; State = '不适用'; Detail = "读取失败，已跳过：$($_.Exception.Message)"; CanApply = $false; CanOpen = $false; CanRestore = $false }
    }
}
function Invoke-TipAction([string]$id, [switch]$Quiet) {
    switch ($id) {
        'overlay' { return $(if (Set-PowerMode 'balanced' -Quiet:$Quiet) { 'ok' } else { 'fail' }) }
        'esbatt' { return (Apply-PowerDc 'esbatt' 'SUB_ENERGYSAVER' 'ESBATTTHRESHOLD' 30) }
        'screen' {
            $a = Apply-PowerDc 'screen-video' 'SUB_VIDEO' 'VIDEOIDLE' 180
            $b = Apply-PowerDc 'screen-sleep' 'SUB_SLEEP' 'STANDBYIDLE' 600
            if ($a -eq 'fail' -or $b -eq 'fail') { return 'fail' }
            if ($a -eq 'skip' -and $b -eq 'skip') { return 'skip' }
            return 'ok'
        }
        'standbynet' { return (Apply-PowerDc 'standbynet' 'SUB_NONE' 'CONNECTIVITYINSTANDBY' 0) }
        'hibernate' {
            $h = Get-HibernateInfo
            if ($h.Unsupported) { return 'skip' }
            if ($h.CanEnable -and -not $h.Enabled) {
                if (-not $Quiet) {
                    if (-not (Confirm-Action "休眠目前是关的，但系统允许打开。`n打开后睡眠一段时间会转入休眠，唤醒会慢几秒。`n可以恢复。需要管理员。确定打开吗？" '休眠')) { return 'skip' }
                }
                if (-not (Get-UndoEntry 'hibernateflag')) { Save-UndoEntry ([pscustomobject]@{ id = 'hibernateflag'; kind = 'hibernateflag'; value = $false }) }
                $exe = Get-PowerCfgExe
                if (Test-IsAdmin) { & $exe /hibernate on | Out-Null } else { [void](Invoke-Elevated "& '$((Get-PowerCfgExe).Replace("'","''"))' /hibernate on; if (`$LASTEXITCODE -ne 0) { throw 'hibernate' }") }
            }
            return (Apply-PowerDc 'hibernate' 'SUB_SLEEP' 'HIBERNATEIDLE' 10800)
        }
        'throttle' {
            if (-not $Quiet) {
                if (-not (Confirm-Action "把电池下的最大处理器状态设为 80%？`n电脑会更省电，但也会更卡。只改电池，插电仍是原来的值。可以恢复。" '极限省电')) { return 'skip' }
            }
            return (Apply-PowerDc 'throttle' 'SUB_PROCESSOR' 'PROCTHROTTLEMAX' 80)
        }
        'usb' {
            $r = Apply-PowerDc 'usb' 'SUB_USB' 'USBSELECTIVESUSPEND' 1
            if ($r -eq 'skip') { return (Apply-PowerDc 'usb' '2a737441-1930-4402-8d77-b2bebba308a3' '48e6b7a6-50f5-4782-a5d4-53bb8f07e226' 1) }
            return $r
        }
        'brightness' {
            $b = Get-Brightness
            if ($null -eq $b) { return 'skip' }
            if (-not (Get-UndoEntry 'brightness')) { Save-UndoEntry ([pscustomobject]@{ id = 'brightness'; kind = 'brightness'; value = [int]$b }) }
            if (Set-Brightness 50) { return 'ok' } else { return 'fail' }
        }
        'visual' { Set-Transparency $false; Set-Animations $false; return 'ok' }
        'edge' {
            if (-not $Quiet) {
                if (-not (Confirm-Action "将写入 Edge 策略：关闭启动加速、关闭退出后继续运行后台扩展，并打开标签页睡眠。`n`nEdge 会显示「由你的组织管理」。`n点「恢复」会删掉这些策略项。`n需要管理员。确定吗？" 'Edge 策略')) { return 'skip' }
            }
            $p = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
            $ok1 = Set-RegDword $p 'StartupBoostEnabled' 0 'edge-boost'
            $ok2 = Set-RegDword $p 'BackgroundModeEnabled' 0 'edge-bg'
            $ok3 = Set-RegDword $p 'SleepingTabsEnabled' 1 'edge-sleep'
            if ($ok1 -and $ok2 -and $ok3) { return 'ok' }
            return 'fail'
        }
        'widgets' {
            $kind = Get-WidgetKind
            if ($kind -eq 'na') { return 'skip' }
            if ($kind -eq 'feeds') {
                if (Set-RegDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Feeds' 'ShellFeedsTaskbarViewMode' 2 'widgets') { return 'ok' }
                return 'fail'
            }
            $before = Get-RegState 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarDa'
            if (-not (Set-RegDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarDa' 0 'widgets')) { return 'fail' }
            $after = Get-RegState 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarDa'
            if ($after.Exists -and [int]$after.Value -eq 0) { return 'ok' }
            Restore-UndoId 'widgets' | Out-Null
            if (-not $Quiet) { Show-Info '小组件按钮写不进去（系统保护了这项）。已打开任务栏设置，请手动关掉。'; Open-SettingsPage 'ms-settings:taskbar' }
            return 'skip'
        }
        'background' {
            $fam = $script:TipBgFamily
            if (-not $fam) { return 'skip' }
            $base = "HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications\$fam"
            $a = Set-RegDword $base 'Disabled' 1 "bg-$fam"
            $b = Set-RegDword $base 'DisabledByUser' 1 "bguser-$fam"
            if ($a -and $b) { return 'ok' }
            return 'fail'
        }
        'onedrive' {
            if (-not $Quiet) {
                if (-not (Confirm-Action "正常退出 OneDrive？（OneDrive.exe /shutdown）`n不会强制结束。同步会停，直到你再打开它。" 'OneDrive')) { return 'skip' }
            }
            $exe = @(Get-ChildItem -Path "$env:LOCALAPPDATA\Microsoft\OneDrive","$env:ProgramFiles\Microsoft OneDrive" -Filter 'OneDrive.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1)
            if (-not $exe) { return 'skip' }
            Start-Process -FilePath $exe.FullName -ArgumentList '/shutdown' | Out-Null
            return 'ok'
        }
        'privacy' {
            $root = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
            foreach ($pair in @(
                @('SubscribedContent-338389Enabled','privacy-tips'),
                @('SubscribedContent-310093Enabled','privacy-welcome'),
                @('SubscribedContent-338388Enabled','privacy-start'),
                @('SoftLandingEnabled','privacy-soft')
            )) { [void](Set-RegDword $root $pair[0] 0 $pair[1]) }
            [void](Set-RegDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement' 'ScoobeSystemSettingEnabled' 0 'privacy-scoobe')
            return 'ok'
        }
        'ads' {
            $a = Set-RegDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0 'ads-id'
            $b = Set-RegDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 0 'ads-tailor'
            if ($a -and $b) { return 'ok' }
            return 'fail'
        }
        'storage' { return $(if (Set-RegDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy' '01' 1 'storage') { 'ok' } else { 'fail' }) }
        'delivery' {
            $cur = Get-DoMode
            if ($null -eq $cur) { return 'skip' }
            if (-not (Get-UndoEntry 'delivery')) { Save-UndoEntry ([pscustomobject]@{ id = 'delivery'; kind = 'domode'; value = $cur }) }
            try { Set-DODownloadMode -DownloadMode Lan | Out-Null; return 'ok' } catch { return 'fail' }
        }
        'flushdns' {
            try { Clear-DnsClientCache; return 'ok' } catch {
                $exe = Join-Path $env:SystemRoot 'System32\ipconfig.exe'
                & $exe /flushdns | Out-Null
                if ($LASTEXITCODE -eq 0) { return 'ok' }
                return 'fail'
            }
        }
        default { return 'skip' }
    }
}
function Open-Tip([string]$id) {
    switch ($id) {
        'sleepstudy' { Show-SleepStudy }
        'surface' { Open-SurfaceApp }
        'wu' { Open-SettingsPage 'ms-settings:windowsupdate' | Out-Null }
        'drr' { if (Test-IsWin11) { Open-SettingsPage 'ms-settings:display-advanced' | Out-Null } else { Open-SettingsPage 'ms-settings:display' | Out-Null } }
        'brightness' { Open-SettingsPage 'ms-settings:display' | Out-Null }
        'video' { Open-SettingsPage 'ms-settings:videoplayback' | Out-Null }
        'startup' { $ui.Tabs.SelectedIndex = 2 }
        'edge' { try { Start-Process 'msedge' -ArgumentList 'edge://settings/system' } catch { Show-Info '没有找到 Edge。' } }
        'widgets' { Open-SettingsPage 'ms-settings:taskbar' | Out-Null }
        'search' { Open-SettingsPage 'ms-settings:cortana-windowssearch' | Out-Null }
        'delivery' { Open-SettingsPage 'ms-settings:delivery-optimization' | Out-Null }
        'ads' { Open-SettingsPage 'ms-settings:privacy-feedback' | Out-Null }
        'bestlife' { Open-SettingsPage 'ms-settings:batterysaver' | Out-Null }
    }
}
function Show-SleepStudy {
    param([switch]$BatteryOnly)
    Ensure-UndoDir
    $exe = Get-PowerCfgExe
    $sleep = Join-Path $UndoDir 'sleep.html'
    $bat = Join-Path $UndoDir 'battery.html'
    $notes = @()
    & $exe /batteryreport /output $bat /duration 7 | Out-Null
    if (Test-Path -LiteralPath $bat) { $notes += "电池报告：$bat"; Start-Process $bat }
    else { $notes += '电池报告没有生成（这台电脑可能没有电池）。' }
    if ($BatteryOnly) { Show-Info ($notes -join "`n"); return }
    if (Test-IsAdmin) {
        & $exe /sleepstudy /output $sleep | Out-Null
        if (Test-Path -LiteralPath $sleep) { $notes += "掉电诊断：$sleep"; Start-Process $sleep }
        else { $notes += '掉电诊断没有生成。' }
    } else {
        $notes += '掉电诊断需要管理员。可以右键以管理员身份重新打开本工具后再试。'
    }
    Show-Info ($notes -join "`n")
}
function Open-SurfaceApp {
    $app = $null
    try { $app = @(Get-StartApps -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'Surface' } | Select-Object -First 1) } catch { }
    if ($app -and $app.AppID) {
        Start-Process "shell:AppsFolder\$($app.AppID)"
        return
    }
    Show-Info "没有找到 Surface 应用。`n电池限制要在 Surface 应用里设置；旧机型也可能在 UEFI 的 Enable Battery Limit Mode。`n本工具不会改固件。"
}
function Add-TipCheckupIssues {
    try {
        $snap = Get-PowerSnapshot
        $onBattery = $snap.HasBattery -and -not $snap.OnAC
        $es = Get-PowerDcIndex 'SUB_ENERGYSAVER' 'ESBATTTHRESHOLD'
        if ($es -and [int]$es.Dc -lt 20) {
            $script:Issues.Add((New-Issue 'tip-esbatt' "节电模式要到 $($es.Dc)% 才自动开" '建议改成 30%（只影响电池）。可以恢复。' '建议' $true '修复：把自动开启阈值设为 30%'))
            $script:CheckScore -= 3
        }
        $net = Get-PowerDcIndex 'SUB_NONE' 'CONNECTIVITYINSTANDBY'
        if ($net -and [int]$net.Dc -ne 0) {
            $script:Issues.Add((New-Issue 'tip-net' '电池待机时仍保持网络连接' 'Surface 合盖掉电时，这经常是原因。建议电池待机断开网络。睡眠中会晚一会儿收到消息。可以恢复。' '注意' $true '修复：电池待机改为断开网络（可恢复）'))
            $script:CheckScore -= 4
        }
        $hib = Get-HibernateInfo
        $hidle = Get-PowerDcIndex 'SUB_SLEEP' 'HIBERNATEIDLE'
        if (-not $hib.Unsupported -and $hidle -and ([int]$hidle.Dc -eq 0 -or [int]$hidle.Dc -gt 21600)) {
            $script:Issues.Add((New-Issue 'tip-hib' '电池上没有在睡眠后转入休眠' '长时间合盖可以在约 3 小时后休眠，几乎不耗电。只有系统支持休眠才会改。可以恢复。' '建议' $true '修复：电池睡眠 3 小时后休眠（可恢复）'))
            $script:CheckScore -= 3
        }
        if (Test-IsWin11) {
            try {
                $vc = @(Get-CimInstance Win32_VideoController -ErrorAction Stop)
                $max = 0
                foreach ($x in $vc) { try { if ([int]$x.MaxRefreshRate -gt $max) { $max = [int]$x.MaxRefreshRate } } catch { } }
                if ($max -ge 120) {
                    $script:Issues.Add((New-Issue 'tip-drr' "屏幕最高 ${max} Hz，可看看动态刷新率" 'Windows 11 可以平时 60Hz、滚动时 120Hz。没有稳定的开关可以代写，这里只打开显示设置。' '建议' $false '请到高级显示设置里自己打开'))
                }
            } catch { }
        }
        if ($onBattery) {
            $br = Get-Brightness
            if ($null -ne $br -and $br -gt 70) {
                $script:Issues.Add((New-Issue 'tip-bright' "用电池时屏幕亮度 $br%" '屏幕很耗电。建议暂时调到 50%，可以恢复到现在的亮度。' '建议' $true '修复：亮度调到 50%（可恢复）'))
                $script:CheckScore -= 3
            }
        }
        $store = Get-RegState 'HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy' '01'
        $freePct = 100
        try {
            $d = Get-PSDrive -Name C
            if ($d.Used + $d.Free -gt 0) { $freePct = [int](100 * $d.Free / ($d.Used + $d.Free)) }
        } catch { }
        if ((-not $store.Exists -or [int]$store.Value -ne 1) -and $freePct -lt 15) {
            $script:Issues.Add((New-Issue 'tip-storage' "C 盘只剩约 $freePct%，存储感知是关的" '硬盘快满时会变卡。可以打开存储感知。清理临时文件会另外确认。' '注意' $true '修复：打开存储感知（可恢复）'))
            $script:CheckScore -= 4
        }
        $do = Get-DoMode
        if ($do -eq 'Internet') {
            $script:Issues.Add((New-Issue 'tip-do' '传递优化正在向互联网上的电脑上传' '建议改成仅局域网。不影响 Windows 更新。可以恢复。' '建议' $true '修复：传递优化改为仅局域网（可恢复）'))
            $script:CheckScore -= 2
        }
        try {
            $full = $null; $design = $null
            $full = @(Get-CimInstance -Namespace root/wmi -ClassName BatteryFullChargedCapacity -ErrorAction Stop)
            $design = @(Get-CimInstance -Namespace root/wmi -ClassName BatteryStaticData -ErrorAction Stop)
            if ($full.Count -and $design.Count -and [double]$design[0].DesignedCapacity -gt 0) {
                $health = [int](100 * [double]$full[0].FullChargedCapacity / [double]$design[0].DesignedCapacity)
                if ($health -lt 80) {
                    $script:Issues.Add((New-Issue 'tip-health' "电池健康度约 $health%" '满充容量相对设计容量偏低。可以打开 Surface 应用看智能充电；本工具不改充电上限。' '建议' $false '请到 Surface 应用或 UEFI 里设置电池限制'))
                }
            }
        } catch { }
    } catch { }
}
function Update-TipsUi {
    if (-not $ui.TipsHost) { return }
    try { Update-TipsUiCore } catch {
        $ui.TipsHost.Children.Clear()
        $tb = New-Object Windows.Controls.TextBlock
        $tb.Text = "优化建议加载失败：$($_.Exception.Message)"
        $tb.TextWrapping = 'Wrap'
        $tb.Foreground = (Brush $C.Bad)
        [void]$ui.TipsHost.Children.Add($tb)
    }
}
function Update-TipsUiCore {
    $ui.TipsHost.Children.Clear()
    $groups = @(
        @{ Title = '电源与电池'; Note = ''; Ids = @('overlay','esbatt','screen','standbynet','hibernate','throttle','usb','sleepstudy','surface','wu') }
        @{ Title = '显示'; Note = ''; Ids = @('drr','brightness','video','visual') }
        @{ Title = '启动与后台'; Note = ''; Ids = @('startup','background','edge','widgets','onedrive','search','storage') }
        @{ Title = '通知与隐私'; Note = '这些主要是少弹窗、少跟踪，对速度帮助很小。'; Ids = @('privacy','ads') }
        @{ Title = '网络'; Note = '只清 DNS 缓存。不改 DNS 服务器，也不关 IPv6。'; Ids = @('flushdns','delivery') }
    )
    $titles = @{
        overlay = '电源滑杆'; esbatt = '节电模式阈值'; screen = '关屏和睡眠'; standbynet = '待机网络'
        hibernate = '睡眠后休眠'; throttle = '电池最大处理器（可选）'; usb = 'USB 选择性暂停'; sleepstudy = '掉电诊断'
        surface = 'Surface 电池保护'; wu = '系统和固件更新'; drr = '刷新率'; brightness = '屏幕亮度'
        video = '视频播放省电'; visual = '透明和动画'; startup = '开机启动项'; background = '应用后台'
        edge = 'Edge 启动加速'; widgets = '资讯和兴趣 / 小组件'; onedrive = 'OneDrive'; search = '搜索索引'
        storage = '存储感知'; privacy = '提示和建议'; ads = '广告 ID'; flushdns = '刷新 DNS 缓存'; delivery = '传递优化'
    }
    foreach ($g in $groups) {
        $h = New-Object Windows.Controls.TextBlock
        $h.Text = $g.Title
        $h.FontSize = 15
        $h.FontWeight = 'SemiBold'
        $h.Margin = New-Object Windows.Thickness 0,10,0,4
        $h.Foreground = (Brush $C.Ink)
        [void]$ui.TipsHost.Children.Add($h)
        if ($g.Note) {
            $n = New-Object Windows.Controls.TextBlock
            $n.Text = $g.Note
            $n.Foreground = (Brush $C.Mute)
            $n.TextWrapping = 'Wrap'
            $n.Margin = New-Object Windows.Thickness 0,0,0,6
            [void]$ui.TipsHost.Children.Add($n)
        }
        foreach ($id in $g.Ids) {
            $line = Get-TipLine $id
            $card = New-Object Windows.Controls.Border
            $card.Background = (Brush $C.Card)
            $card.BorderBrush = (Brush $C.Line)
            $card.BorderThickness = New-Object Windows.Thickness 1
            $card.CornerRadius = New-Object Windows.CornerRadius 12
            $card.Padding = New-Object Windows.Thickness 12,10,12,10
            $card.Margin = New-Object Windows.Thickness 0,0,0,8
            $dock = New-Object Windows.Controls.DockPanel
            $btns = New-Object Windows.Controls.StackPanel
            $btns.Orientation = 'Horizontal'
            $btns.SetValue([Windows.Controls.DockPanel]::DockProperty, 'Right')
            if ($line.CanApply) {
                $b = New-Object Windows.Controls.Button
                $b.Content = '应用'
                $b.Tag = $id
                $b.Add_Click({
                    param($sender, $e)
                    $tid = [string]$sender.Tag
                    $r = Invoke-TipAction $tid
                    if ($r -eq 'ok') { Show-Info '已应用。可以点「恢复」改回去。' }
                    elseif ($r -eq 'skip') { Show-Info '这项在这台电脑上不适用，没有修改。' }
                    else { Show-Info '没有改成（可能没有权限，或你取消了）。' }
                    Update-TipsUi
                })
                [void]$btns.Children.Add($b)
            }
            if ($line.CanOpen) {
                $b2 = New-Object Windows.Controls.Button
                $b2.Content = '打开'
                $b2.Tag = $id
                $b2.Add_Click({ param($sender, $e); Open-Tip ([string]$sender.Tag) })
                [void]$btns.Children.Add($b2)
            }
            if ($line.CanRestore) {
                $b3 = New-Object Windows.Controls.Button
                $b3.Content = '恢复'
                $b3.Tag = $id
                $b3.Margin = '0'
                $b3.Add_Click({
                    param($sender, $e)
                    $tid = [string]$sender.Tag
                    if ($tid -eq 'screen') { [void](Restore-UndoId 'screen-video'); [void](Restore-UndoId 'screen-sleep') }
                    elseif ($tid -eq 'visual') { [void](Restore-UndoId 'transparency'); [void](Restore-UndoId 'animations') }
                    elseif ($tid -eq 'edge') { [void](Restore-UndoId 'edge-boost'); [void](Restore-UndoId 'edge-bg'); [void](Restore-UndoId 'edge-sleep') }
                    elseif ($tid -eq 'privacy') { foreach ($x in @('privacy-tips','privacy-welcome','privacy-start','privacy-soft','privacy-scoobe')) { [void](Restore-UndoId $x) } }
                    elseif ($tid -eq 'ads') { [void](Restore-UndoId 'ads-id'); [void](Restore-UndoId 'ads-tailor') }
                    else { [void](Restore-UndoId $tid) }
                    Update-TipsUi
                })
                [void]$btns.Children.Add($b3)
            }
            [void]$dock.Children.Add($btns)
            $stack = New-Object Windows.Controls.StackPanel
            $t1 = New-Object Windows.Controls.TextBlock
            $t1.Text = $titles[$id]
            $t1.FontWeight = 'SemiBold'
            $t1.Foreground = (Brush $C.Ink)
            $t2 = New-Object Windows.Controls.TextBlock
            $t2.Text = $line.State
            $t2.Margin = New-Object Windows.Thickness 0,2,0,0
            $t2.Foreground = (Brush $C.Ink)
            $t3 = New-Object Windows.Controls.TextBlock
            $t3.Text = $line.Detail
            $t3.TextWrapping = 'Wrap'
            $t3.Margin = New-Object Windows.Thickness 0,2,12,0
            $t3.Foreground = (Brush $C.Mute)
            [void]$stack.Children.Add($t1)
            [void]$stack.Children.Add($t2)
            [void]$stack.Children.Add($t3)
            [void]$dock.Children.Add($stack)
            $card.Child = $dock
            [void]$ui.TipsHost.Children.Add($card)
        }
    }
}
function Invoke-TweakRoundtrip {
    $log = New-Object System.Collections.Generic.List[object]
    function Add-Log($id, $result, $detail) { $log.Add([pscustomobject]@{ Id = $id; Result = $result; Detail = $detail }) }
    function Test-PowerFlip($id, $sub, $setting, $alt) {
        $before = Get-PowerDcIndex $sub $setting
        if ($null -eq $before) { Add-Log $id 'skip' 'setting missing'; return }
    $target = [int]$alt
    if ([int]$before.Dc -eq $target) { if ([int]$before.Dc -le 1) { $target = 1 - [int]$before.Dc } else { $target = [int]$before.Dc - 5 } }
        $r = Apply-PowerDc $id $sub $setting $target
        $mid = Get-PowerDcIndex $sub $setting
        $rest = Restore-UndoId $id
        $after = Get-PowerDcIndex $sub $setting
        if ($r -ne 'ok' -or $null -eq $mid -or [int]$mid.Dc -ne $target -or -not $rest -or $null -eq $after -or [int]$after.Dc -ne [int]$before.Dc) {
            Add-Log $id 'fail' "r=$r before=$($before.Dc) mid=$($mid.Dc) after=$($after.Dc) rest=$rest"
        } else { Add-Log $id 'ok' "$($before.Dc)->$target->$( $after.Dc )" }
    }
    Test-PowerFlip 'esbatt' 'SUB_ENERGYSAVER' 'ESBATTTHRESHOLD' 30
    Test-PowerFlip 'screen-video' 'SUB_VIDEO' 'VIDEOIDLE' 180
    Test-PowerFlip 'screen-sleep' 'SUB_SLEEP' 'STANDBYIDLE' 600
    Test-PowerFlip 'standbynet' 'SUB_NONE' 'CONNECTIVITYINSTANDBY' 0
    $h = Get-HibernateInfo
    if ($h.Unsupported) { Add-Log 'hibernate' 'skip' 'hibernate unsupported' } else { Test-PowerFlip 'hibernate' 'SUB_SLEEP' 'HIBERNATEIDLE' 10800 }
    Test-PowerFlip 'throttle' 'SUB_PROCESSOR' 'PROCTHROTTLEMAX' 80
    $usb = Get-PowerDcIndex 'SUB_USB' 'USBSELECTIVESUSPEND'
    if ($usb) { Test-PowerFlip 'usb' 'SUB_USB' 'USBSELECTIVESUSPEND' 1 } else { Test-PowerFlip 'usb' '2a737441-1930-4402-8d77-b2bebba308a3' '48e6b7a6-50f5-4782-a5d4-53bb8f07e226' 1 }

    $regTests = @(
        @{ Id = 'storage'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy'; Name = '01'; Alt = 1 }
        @{ Id = 'privacy-tips'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-338389Enabled'; Alt = 0 }
        @{ Id = 'ads-id'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; Name = 'Enabled'; Alt = 0 }
    )
    foreach ($t in $regTests) {
        $before = Get-RegState $t.Path $t.Name
        $alt = [int]$t.Alt
        if ($before.Exists -and [int]$before.Value -eq $alt) { $alt = 1 - $alt }
        $wrote = Set-RegDword $t.Path $t.Name $alt $t.Id
        $mid = Get-RegState $t.Path $t.Name
        $rest = Restore-UndoId $t.Id
        $after = Get-RegState $t.Path $t.Name
        $same = ((-not $before.Exists) -and (-not $after.Exists)) -or ($before.Exists -and $after.Exists -and [int]$before.Value -eq [int]$after.Value)
        if (-not $wrote -or -not $mid.Exists -or [int]$mid.Value -ne $alt -or -not $rest -or -not $same) {
            Add-Log $t.Id 'fail' "wrote=$wrote mid=$($mid.Value) rest=$rest"
        } else { Add-Log $t.Id 'ok' 'restored' }
    }
    if (Test-IsAdmin) {
        $r = Invoke-TipAction 'edge' -Quiet
        $p = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
        $mid = Get-RegState $p 'StartupBoostEnabled'
        [void](Restore-UndoId 'edge-boost'); [void](Restore-UndoId 'edge-bg'); [void](Restore-UndoId 'edge-sleep')
        $after = Get-RegState $p 'StartupBoostEnabled'
        if ($r -ne 'ok' -or -not $mid.Exists -or [int]$mid.Value -ne 0) { Add-Log 'edge' 'fail' "r=$r mid=$($mid.Value)" }
        else { Add-Log 'edge' 'ok' "afterExists=$($after.Exists)" }
    } else { Add-Log 'edge' 'skip' 'not admin' }

    $kind = Get-WidgetKind
    if ($kind -eq 'na') { Add-Log 'widgets' 'skip' 'na on this build' }
    elseif ($kind -eq 'feeds') {
        $before = Get-RegState 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Feeds' 'ShellFeedsTaskbarViewMode'
        $alt = 2
        if ($before.Exists -and [int]$before.Value -eq 2) { $alt = 0 }
        if (Set-RegDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Feeds' 'ShellFeedsTaskbarViewMode' $alt 'widgets') {
            $mid = Get-RegState 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Feeds' 'ShellFeedsTaskbarViewMode'
            [void](Restore-UndoId 'widgets')
            if ($mid.Exists -and [int]$mid.Value -eq $alt) { Add-Log 'widgets' 'ok' 'feeds' } else { Add-Log 'widgets' 'fail' 'feeds readback' }
        } else { Add-Log 'widgets' 'fail' 'feeds write' }
    } else {
        $r = Invoke-TipAction 'widgets' -Quiet
        [void](Restore-UndoId 'widgets')
        if ($r -eq 'fail') { Add-Log 'widgets' 'fail' 'taskbar' } else { Add-Log 'widgets' 'ok' $r }
    }

    $fake = 'WinOpt.Smoke.Test'
    $base = "HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications\$fake"
    $script:TipBgFamily = $fake
    $br = Invoke-TipAction 'background' -Quiet
    $bst = Get-RegState $base 'Disabled'
    [void](Restore-UndoId "bg-$fake"); [void](Restore-UndoId "bguser-$fake")
    $script:TipBgFamily = $null
    if ($br -eq 'ok' -and $bst.Exists -and [int]$bst.Value -eq 1) { Add-Log 'background' 'ok' 'fake package' } else { Add-Log 'background' 'fail' "r=$br" }

    $run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
    $sname = 'WinOptSmokeStartup'
    try {
        if (-not (Test-Path $run)) { New-Item -Path $run -Force | Out-Null }
        if (-not (Test-Path $approved)) { New-Item -Path $approved -Force | Out-Null }
        New-ItemProperty -Path $run -Name $sname -Value 'notepad.exe' -PropertyType String -Force | Out-Null
        $on = [byte[]](2,0,0,0,0,0,0,0,0,0,0,0)
        $off = [byte[]](3,0,0,0,0,0,0,0,0,0,0,0)
        New-ItemProperty -Path $approved -Name $sname -PropertyType Binary -Value $on -Force | Out-Null
        Set-ItemProperty -Path $approved -Name $sname -Type Binary -Value $off
        $cur = (Get-Item -LiteralPath $approved).GetValue($sname)
        $changed = ($cur -and $cur[0] -eq 3)
        Set-ItemProperty -Path $approved -Name $sname -Type Binary -Value $on
        $back = (Get-Item -LiteralPath $approved).GetValue($sname)
        Remove-ItemProperty -LiteralPath $approved -Name $sname -ErrorAction SilentlyContinue
        Remove-ItemProperty -LiteralPath $run -Name $sname -ErrorAction SilentlyContinue
        if ($changed -and $back -and $back[0] -eq 2) { Add-Log 'startup' 'ok' 'binary approved byte' }
        else { Add-Log 'startup' 'fail' "changed=$changed back=$($back)" }
    } catch {
        Remove-ItemProperty -LiteralPath $run -Name $sname -ErrorAction SilentlyContinue
        Add-Log 'startup' 'skip' $_.Exception.Message
    }

    $do = Get-DoMode
    if ($null -eq $do) { Add-Log 'delivery' 'skip' 'no cmdlet' }
    else {
        $other = if ([string]$do -match 'Lan') { 'HttpOnly' } else { 'Lan' }
        if (-not (Get-UndoEntry 'delivery')) { Save-UndoEntry ([pscustomobject]@{ id = 'delivery'; kind = 'domode'; value = [string]$do }) }
        $setOk = $true
        try { Set-DODownloadMode -DownloadMode $other | Out-Null } catch { $setOk = $false }
        $mid = Get-DoMode
        $rest = Restore-DoMode ([string]$do)
        Remove-UndoEntry 'delivery' | Out-Null
        $after = Get-DoMode
        if (-not $setOk -or [string]$mid -notmatch [regex]::Escape($other) -or -not $rest -or [string]$after -ne [string]$do) { Add-Log 'delivery' 'fail' "set=$setOk mid=$mid after=$after was=$do other=$other" }
        else { Add-Log 'delivery' 'ok' "$do->$other->$after" }
    }

    $bright = Get-Brightness
    if ($null -eq $bright) { Add-Log 'brightness' 'skip' 'no monitor wmi' }
    else {
        $r = Invoke-TipAction 'brightness' -Quiet
        $mid = Get-Brightness
        $rest = Restore-UndoId 'brightness'
        $after = Get-Brightness
        if ($r -ne 'ok' -or $mid -ne 50 -or -not $rest -or $after -ne $bright) { Add-Log 'brightness' 'fail' "r=$r mid=$mid after=$after was=$bright" }
        else { Add-Log 'brightness' 'ok' "$bright->50->$after" }
    }

    $td = Join-Path $env:TEMP 'winopt-temp-test'
    if (Test-Path $td) { Remove-Item $td -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path $td | Out-Null
    $oldf = Join-Path $td 'old.txt'
    $newf = Join-Path $td 'new.txt'
    Set-Content $oldf 'old' -Encoding ASCII
    Set-Content $newf 'new' -Encoding ASCII
    (Get-Item $oldf).LastWriteTime = (Get-Date).AddDays(-8)
    $listed = @(Get-OldTempFiles $td 7)
    $gone = $false
    foreach ($f in $listed) { if (Move-FileToRecycle $f.FullName) { $gone = -not (Test-Path -LiteralPath $f.FullName) } }
    $kept = Test-Path -LiteralPath $newf
    if ($listed.Count -eq 1 -and $gone -and $kept) { Add-Log 'temp' 'ok' 'listed then recycled' }
    elseif ($listed.Count -eq 1 -and $kept) { Remove-Item $oldf -Force -ErrorAction SilentlyContinue; Add-Log 'temp' 'skip' 'recycle unavailable' }
    else { Add-Log 'temp' 'fail' "listed=$($listed.Count) gone=$gone kept=$kept" }
    Remove-Item $td -Recurse -Force -ErrorAction SilentlyContinue

    $flush = Invoke-TipAction 'flushdns' -Quiet
    if ($flush -eq 'ok') { Add-Log 'flushdns' 'ok' 'cache cleared' } else { Add-Log 'flushdns' 'fail' $flush }

    # Win10 路径不能因为 Win11 专用项抛错
    $saved = $script:MockBuild
    $script:MockBuild = 19045
    try {
        $w = Get-WidgetKind
        $copilot = '不适用'
        $drr = Get-TipLine 'drr'
        $edge = Get-TipLine 'edge'
        if ($w -ne 'feeds') { Add-Log 'gate-widgets' 'fail' $w } else { Add-Log 'gate-widgets' 'ok' 'feeds' }
        if ($drr.State -notmatch '不适用') { Add-Log 'gate-drr' 'fail' $drr.State } else { Add-Log 'gate-drr' 'ok' 'na' }
        if (-not $edge.Detail) { Add-Log 'gate-edge' 'fail' 'empty' } else { Add-Log 'gate-edge' 'ok' 'readable' }
        if ($copilot -ne '不适用') { Add-Log 'gate-copilot' 'fail' $copilot } else { Add-Log 'gate-copilot' 'ok' 'na' }
        [void](Get-TipLine 'widgets')
        [void](Get-TipLine 'search')
        [void](Get-TipLine 'esbatt')
    } catch {
        Add-Log 'gate-win10' 'fail' $_.Exception.Message
    } finally { $script:MockBuild = $saved }
    return @($log.ToArray())
}
function Invoke-WinOptSelfTest {
    $log = @(Invoke-TweakRoundtrip)
    $fail = @($log | Where-Object { $_.Result -eq 'fail' })
    foreach ($row in $log) { Write-Host ("{0,-16} {1,-6} {2}" -f $row.Id, $row.Result, $row.Detail) }
    if ($fail.Count) { Write-Error ("self-test failures: " + (($fail | ForEach-Object { $_.Id }) -join ', ')); return 1 }
    Write-Host 'SELFTEST OK'
    return 0
}

# ---------------- 事件 ----------------
$ui.CheckBtn.Add_Click({ Invoke-Checkup })
$ui.FixBtn.Add_Click({ Invoke-Fixes })
$ui.ProcRefresh.Add_Click({ Update-Processes })
$ui.ProcNice.Add_Click({ Lower-SelectedPriority })
$ui.ProcNormal.Add_Click({ Restore-SelectedPriority })
$ui.ProcClose.Add_Click({ Close-SelectedProcesses })
$ui.PlanBestLife.Add_Click({
    Show-Info "「最佳电池续航」是电池图标滑杆最左边的节电模式，没有单独的电源计划可以代为切换。`n接下来打开系统设置，由你自己拨。`n自动开启的电量百分比在「优化建议」里。"
    Open-SettingsPage 'ms-settings:batterysaver' | Out-Null
})
$ui.PlanSaver.Add_Click({ [void](Set-PowerMode 'efficiency') })
$ui.PlanBalanced.Add_Click({ [void](Set-PowerMode 'balanced') })
$ui.PlanHigh.Add_Click({ [void](Set-PowerMode 'performance') })
$ui.SortMem.Add_Checked({ Update-Processes })
$ui.SortCpu.Add_Checked({ Update-Processes })
$ui.StartRefresh.Add_Click({ Update-Startup })
$ui.StartDisable.Add_Click({ Set-SelectedStartup $false })
$ui.StartEnable.Add_Click({ Set-SelectedStartup $true })
$ui.BrRefresh.Add_Click({ Update-Browsers })
$ui.BrQuit.Add_Click({
    $sel = @($ui.BrList.SelectedItems)
    if ($sel.Count -eq 0) { Show-Info '先选中要退出的浏览器。'; return }
    if (-not (Confirm-Action ("退出这些浏览器？（只关闭窗口，标签页会保存）`n`n" + (($sel | ForEach-Object { $_.Name }) -join "`n")) '退出浏览器')) { return }
    foreach ($s in $sel) { Close-Browser $s.Key }
    Start-Sleep -Milliseconds 800; Update-Browsers
})
$ui.PingBtn.Add_Click({ Start-PingTest })
$ui.DnsAli.Add_Click({
    if (-not (Confirm-Action "把已连接网卡的 DNS 设为阿里 DNS（223.5.5.5 / 223.6.6.6）？`n原设置会先备份，可以随时恢复。需要管理员权限。" '设置 DNS')) { return }
    if (Set-AliDns) { Show-Info '已设为阿里 DNS。' } else { Show-Info 'DNS 没有修改（取消了管理员授权或失败）。' }
    Update-Dns
})
$ui.DnsRestore.Add_Click({
    if (-not (Confirm-Action '恢复修改前的 DNS 设置？需要管理员权限。' '恢复 DNS')) { return }
    if (Restore-Dns) { Show-Info '已恢复原来的 DNS。' } else { Show-Info '没有恢复（取消了管理员授权或失败）。' }
    Update-Dns
})
$ui.DnsFlush.Add_Click({ try { Clear-DnsClientCache; Show-Info '已清除 DNS 缓存。' } catch { Start-Process ipconfig -ArgumentList '/flushdns' -WindowStyle Hidden; Show-Info '已清除 DNS 缓存。' } })
$ui.VpnOpen.Add_Click({ Start-Process 'ncpa.cpl' })
$ui.AnimBtn.Add_Click({ Set-Animations (-not (Get-AnimationsOn)); Update-Display })
$ui.TransBtn.Add_Click({ Set-Transparency (-not (Get-TransparencyOn)); Update-Display })
$ui.DispSettings.Add_Click({ Start-Process 'ms-settings:display' })
$ui.PerfSettings.Add_Click({ Start-Process 'SystemPropertiesPerformance.exe' })
$ui.PowerSettings.Add_Click({ Start-Process 'ms-settings:batterysaver' })
$ui.SleepStudyBtn.Add_Click({ Show-SleepStudy })
$ui.BatteryReportBtn.Add_Click({ Show-SleepStudy -BatteryOnly })
$ui.SurfaceBtn.Add_Click({ Open-SurfaceApp })
$ui.TipsRefresh.Add_Click({ Update-TipsUi })
$ui.TipsRestoreAll.Add_Click({
    if (-not (Confirm-Action '把所有本工具改过的项目恢复成原来的值？`n临时文件如果已经放进回收站，不会自动还原。' '全部恢复')) { return }
    if (Restore-AllUndo) { Show-Info '已按原来的值恢复。' } else { Show-Info '有的项目没能恢复，可以再到对应的系统设置里看一眼。' }
    Update-TipsUi
    try { Update-PowerPlan } catch { }
    try { Update-Display } catch { }
})

# 切换页面时刷新对应内容
$ui.Tabs.Add_SelectionChanged({
    param($s, $e)
    if ($e.OriginalSource -ne $ui.Tabs) { return }
    switch ($ui.Tabs.SelectedIndex) {
        1 { Update-Processes; Update-PowerPlan } 2 { Update-Startup } 3 { Update-Browsers } 4 { Update-Dns } 5 { Update-Display } 6 { Update-Battery } 7 { try { Update-TipsUi } catch { } }
    }
})

# 每 3 秒刷新概览；后台任务结果也在这里收
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(3)
$tick = 0
$timer.Add_Tick({
    Poll-Bg
    $script:tick++
    if ($script:tick % 1 -eq 0) { Update-Overview }
    if ($ui.Tabs.SelectedIndex -eq 1) { Update-Processes }
})
$fast = New-Object Windows.Threading.DispatcherTimer
$fast.Interval = [TimeSpan]::FromMilliseconds(250)
$fast.Add_Tick({ Poll-Bg })

$win.Add_ContentRendered({
    if ($Smoke -or $env:WINOPT_SMOKE -eq '1') { return }
    Update-Overview
    try { Update-PowerPlan } catch { }
    try { Invoke-Checkup } catch { $ui.ScoreSub.Text = "体检出错：$($_.Exception.Message)" }
    $timer.Start(); $fast.Start()
})
$win.Add_Closed({
    $timer.Stop(); $fast.Stop()
    if ($script:CpuState.Counter) { try { $script:CpuState.Counter.Dispose() } catch { } }
})

# ---------------- CI / 冒烟 ----------------
function Save-WindowPng([Windows.Window]$w, [string]$path) {
    $w.UpdateLayout()
    [Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::ApplicationIdle) | Out-Null
    $dpi = 96.0
    try {
        $src = [Windows.PresentationSource]::FromVisual($w)
        if ($src) { $dpi = 96.0 * $src.CompositionTarget.TransformToDevice.M11 }
    } catch {}
    $wpx = [math]::Max(1, [int]($w.ActualWidth  * $dpi / 96))
    $hpx = [math]::Max(1, [int]($w.ActualHeight * $dpi / 96))
    $rt = New-Object Windows.Media.Imaging.RenderTargetBitmap($wpx, $hpx, $dpi, $dpi, [Windows.Media.PixelFormats]::Pbgra32)
    $rt.Render($w)
    $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rt))
    $fs = [IO.File]::Create($path)
    $enc.Save($fs); $fs.Close()
}

if ($SelfTest -or $env:WINOPT_SELFTEST -eq '1') {
    try {
        $ec = Invoke-WinOptSelfTest
        exit $ec
    } catch {
        Write-Host ($_ | Out-String)
        exit 1
    }
}

if ($Smoke -or $env:WINOPT_SMOKE -eq '1') {
    $outDir = if ($env:WINOPT_SMOKE_OUT) { $env:WINOPT_SMOKE_OUT } else { Join-Path $PSScriptRoot 'smoke-out' }
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }
    $results = [ordered]@{ ok = $true; errors = @(); checks = [ordered]@{} }
    $child = $null
    $burnFile = $null
    $powerBefore = $null
    try {
        $win.Show()
        $win.Activate()
        $win.UpdateLayout()
        for ($i = 0; $i -lt 8; $i++) {
            [Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Background) | Out-Null
            Start-Sleep -Milliseconds 50
        }

        # 用本机 powershell（System32，ARM64 上也是本机程序）把所有逻辑处理器打满
        $burnFile = Join-Path $env:TEMP ("winopt-cpu-burn-" + $PID + ".ps1")
        @'
$ErrorActionPreference = "SilentlyContinue"
$n = [Math]::Max(1, [Environment]::ProcessorCount)
for ($i = 0; $i -lt $n; $i++) {
    $ps = [powershell]::Create()
    [void]$ps.AddScript({ $x = 1.0; while ($true) { $x = [math]::Sqrt($x + 1.000001) } })
    [void]$ps.BeginInvoke()
}
while ($true) { Start-Sleep -Seconds 5 }
'@ | Set-Content -Path $burnFile -Encoding ASCII
        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $child = Start-Process -FilePath $psExe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File', $burnFile) -WindowStyle Hidden -PassThru
        $results.checks.childPid = $child.Id
        $hot = $false
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $prev = (Get-Process -Id $child.Id).TotalProcessorTime.TotalMilliseconds
        while ($sw.ElapsedMilliseconds -lt 8000) {
            Start-Sleep -Milliseconds 300
            $p = Get-Process -Id $child.Id -ErrorAction SilentlyContinue
            if (-not $p) { break }
            $now = $p.TotalProcessorTime.TotalMilliseconds
            if (($now - $prev) -gt 200) { $hot = $true; break }
            $prev = $now
        }
        if (-not $hot) { $results.errors += 'burn child did not consume CPU' }

        [void](Reset-CpuSample)
        Start-Sleep -Milliseconds 800
        $ov = Get-Overview
        Set-OverviewUi $ov
        $results.checks.cpu = $ov.Cpu
        $results.checks.cpuSource = [string]$ov.CpuSource
        $results.checks.memFreeMB = [int]($ov.MemFree / 1MB)
        $results.checks.arch = [string]$env:PROCESSOR_ARCHITECTURE
        if ($null -eq $ov.Cpu) { $results.errors += 'cpu read failed (not a real 0%)' }
        elseif ([int]$ov.Cpu -lt 10 -or [int]$ov.Cpu -gt 100) { $results.errors += "cpu $($ov.Cpu) out of 10..100 via $($ov.CpuSource)" }

        # 电源建议：用假快照锁住「电池上绝不能建议最佳性能」。再在真机上改一档并改回。
        $fake = @(
            @{ Name = 'bat-perf'; OnAC = $false; Overlay = $true; Mode = 'performance'; Classic = 'balanced'; High = $true; Cpu = 90; Expect = 'balanced' }
            @{ Name = 'bat-eff'; OnAC = $false; Overlay = $true; Mode = 'efficiency'; Classic = 'balanced'; High = $true; Cpu = 90; Expect = 'balanced' }
            @{ Name = 'ac-eff'; OnAC = $true; Overlay = $true; Mode = 'efficiency'; Classic = 'balanced'; High = $true; Cpu = 90; Expect = 'performance' }
            @{ Name = 'ac-bal'; OnAC = $true; Overlay = $true; Mode = 'balanced'; Classic = 'balanced'; High = $true; Cpu = 90; Expect = '' }
            @{ Name = 'bat-classic-high'; OnAC = $false; Overlay = $false; Mode = 'balanced'; Classic = 'high'; High = $true; Cpu = 90; Expect = 'balanced' }
            @{ Name = 'ac-saver'; OnAC = $true; Overlay = $false; Mode = 'balanced'; Classic = 'saver'; High = $true; Cpu = 90; Expect = 'performance' }
        )
        $adviceErrorsBefore = @($results.errors).Count
        foreach ($c in $fake) {
            $mode = [string]$c.Mode
            $snap = [pscustomobject]@{
                HasBattery = $true; OnAC = [bool]$c.OnAC; OverlaySupported = [bool]$c.Overlay
                AcMode = $(if ($c.OnAC) { $mode } else { 'balanced' })
                DcMode = $(if ($c.OnAC) { 'balanced' } else { $mode })
                ClassicMode = [string]$c.Classic; HasHighPlan = [bool]$c.High
            }
            $targets = @(@(Get-PowerAdvice $snap $c.Cpu) | ForEach-Object { $_.PowerTarget } | Where-Object { $_ })
            $want = [string]$c.Expect
            if ($want -and ($targets -notcontains $want)) { $results.errors += "advice $($c.Name): want $want got $($targets -join ',')" }
            if ((-not $c.OnAC) -and ($targets -contains 'performance')) { $results.errors += "advice $($c.Name): performance on battery" }
            if (-not $want -and ($targets -contains 'performance')) { $results.errors += "advice $($c.Name): unexpected performance" }
        }
        $results.checks.powerAdviceOk = (@($results.errors).Count -eq $adviceErrorsBefore)

        $powerBefore = Get-PowerSnapshot
        $results.checks.powerOverlay = [bool]$powerBefore.OverlaySupported
        $results.checks.powerOnAC = [bool]$powerBefore.OnAC
        $results.checks.powerRoundtrip = 'unread'
        $onBatteryNow = $powerBefore.HasBattery -and -not $powerBefore.OnAC
        if ($powerBefore.OverlaySupported) {
            if (Set-OverlayMode -dc:([bool]$onBatteryNow) -mode 'efficiency') {
                Start-Sleep -Milliseconds 300
                $mid = Get-PowerSnapshot
                $cur = if ($onBatteryNow) { $mid.DcMode } else { $mid.AcMode }
                if ($cur -eq 'efficiency') { $results.checks.powerRoundtrip = 'overlay' }
            }
        }
        if ($results.checks.powerRoundtrip -eq 'unread' -and $powerBefore.HasSaverPlan) {
            if (Set-ClassicScheme $script:PlanSaver) { $results.checks.powerRoundtrip = 'classic-saver' }
        }
        if ($results.checks.powerRoundtrip -eq 'unread') { $results.errors += 'could not switch power mode or classic saver plan' }

        try { Invoke-Checkup } catch { $results.errors += "checkup: $($_.Exception.Message)" }
        $deadline = (Get-Date).AddSeconds(20)
        while (-not $script:CpuCheckDone -and (Get-Date) -lt $deadline) {
            Poll-Bg
            [Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Background) | Out-Null
            Start-Sleep -Milliseconds 100
        }
        if (-not $script:CpuCheckDone) { $results.errors += 'cpu checkup timed out' }
        $results.checks.checkup = [bool]$script:CpuCheckDone
        $results.checks.score = [string]$ui.ScoreText.Text
        $results.checks.issues = @($script:Issues | ForEach-Object { $_.Title })
        $results.checks.cpuAvg = $script:LastCpuAvg
        $results.checks.cpuHighDetected = [bool]@($script:Issues | Where-Object { $_.Id -eq 'cpu-high' }).Count
        $results.checks.childIssue = [bool]@($script:Issues | Where-Object { $_.Id -eq 'cpu-proc' -and [int]$_.ProcId -eq $child.Id }).Count
        $powerIssues = @($script:Issues | Where-Object { $_.Id -eq 'cpu-power' })
        $results.checks.powerIssue = [bool]$powerIssues.Count
        $results.checks.powerTargets = @($powerIssues | ForEach-Object { $_.PowerTarget })
        if (-not $results.checks.cpuHighDetected) { $results.errors += "cpu-high missing avg=$($script:LastCpuAvg)" }
        if (-not $results.checks.childIssue) { $results.errors += "child cpu issue missing avg=$($script:LastCpuAvg)" }
        if ($results.checks.powerRoundtrip -ne 'unread' -and -not $results.checks.powerIssue) { $results.errors += 'power advice missing after mode change' }
        if (@($results.checks.powerTargets) -contains 'performance' -and $onBatteryNow) { $results.errors += 'live advice suggested performance on battery' }

        $childName = (Get-Process -Id $child.Id).ProcessName
        $selfName = (Get-Process -Id $PID).ProcessName
        $lowered = Set-ProcessBelowNormal -ProcId $child.Id -Name $childName
        $pNow = Get-Process -Id $child.Id
        $pNow.Refresh()
        $prio = [string]$pNow.PriorityClass
        $fakeLsass = [pscustomobject]@{ Id = 999999; ProcessName = 'lsass' }
        $selfBlocked = -not (Set-ProcessBelowNormal -ProcId $PID -Name $selfName)
        $results.checks.protectedOk = ((Test-ProtectedProcess $fakeLsass) -and $selfBlocked -and -not (Test-ProtectedProcess (Get-Process -Id $child.Id)))
        if (-not $results.checks.protectedOk) { $results.errors += 'protected process check failed' }
        if (-not $lowered -or $prio -ne 'BelowNormal') { $results.errors += "priority lower failed prio=$prio lowered=$lowered" }

        try { Update-PowerPlan } catch { $results.errors += "powerui: $($_.Exception.Message)" }
        try { Update-Processes } catch { $results.errors += "proc: $($_.Exception.Message)" }
        Start-Sleep -Milliseconds 700
        try { $ui.SortCpu.IsChecked = $true } catch { }
        try { Update-Startup;  $results.checks.startup   = @($ui.StartList.ItemsSource).Count } catch { $results.errors += "startup: $($_.Exception.Message)" }
        try { Update-Browsers; $results.checks.browsers  = @($ui.BrList.ItemsSource).Count } catch { $results.errors += "browsers: $($_.Exception.Message)" }
        try { Update-Dns;      $results.checks.dns = $ui.DnsText.Text } catch { $results.errors += "dns: $($_.Exception.Message)" }
        try { Update-Display;  $results.checks.anim = $ui.AnimText.Text; $results.checks.trans = $ui.TransText.Text } catch { $results.errors += "display: $($_.Exception.Message)" }
        try { Update-Battery;  $results.checks.battery = $ui.BatText.Text } catch { $results.errors += "battery: $($_.Exception.Message)" }
        try { Update-TipsUi } catch { $results.errors += "tipsui: $($_.Exception.Message)" }
        $results.checks.processes = @($ui.ProcList.ItemsSource).Count

        for ($t = 0; $t -lt $ui.Tabs.Items.Count; $t++) {
            try { $ui.Tabs.SelectedIndex = $t } catch { $results.errors += "tab ${t}: $($_.Exception.Message)" }
            $win.UpdateLayout()
            for ($i = 0; $i -lt 5; $i++) { [Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Background) | Out-Null; Start-Sleep -Milliseconds 50 }
            $name = switch ($t) { 0 {'checkup'} 1 {'processes'} 2 {'startup'} 3 {'browsers'} 4 {'network'} 5 {'display'} 6 {'battery'} 7 {'tips'} default {"tab$t"} }
            try { Save-WindowPng $win (Join-Path $outDir "tab-$name.png") } catch { $results.errors += "shot ${name}: $($_.Exception.Message)" }
        }
        $ui.Tabs.SelectedIndex = 0
        $win.UpdateLayout()
        Save-WindowPng $win (Join-Path $outDir 'main.png')

        $restored = Restore-ProcessPriority -ProcId $child.Id -Name $childName
        $pBack = Get-Process -Id $child.Id -ErrorAction SilentlyContinue
        if ($pBack) { $pBack.Refresh() }
        $prio2 = [string]$pBack.PriorityClass
        $results.checks.priorityOk = [bool]($lowered -and $prio -eq 'BelowNormal' -and $restored -and $prio2 -eq 'Normal')
        if (-not $results.checks.priorityOk) { $results.errors += "priority restore failed prio=$prio2 restored=$restored" }

        $closeCode = Request-ProcessClose -ProcId $child.Id
        Start-Sleep -Milliseconds 400
        $still = [bool](Get-Process -Id $child.Id -ErrorAction SilentlyContinue)
        $results.checks.gracefulClose = (($closeCode -eq 'nowindow' -and $still) -or ($closeCode -eq 'ok'))
        if (-not $results.checks.gracefulClose) { $results.errors += "graceful close code=$closeCode still=$still" }

        Restore-PowerSnapshot $powerBefore
        Start-Sleep -Milliseconds 300
        $powerAfter = Get-PowerSnapshot
        $powerOk = $true
        if ($powerBefore.ClassicGuid -and $powerAfter.ClassicGuid -and $powerBefore.ClassicGuid -ne $powerAfter.ClassicGuid) { $powerOk = $false }
        if ($powerBefore.OverlaySupported -and $powerBefore.AcGuid -and $powerAfter.AcGuid -and $powerBefore.AcGuid -ne $powerAfter.AcGuid) { $powerOk = $false }
        if ($powerBefore.OverlaySupported -and $powerBefore.DcGuid -and $powerAfter.DcGuid -and $powerBefore.DcGuid -ne $powerAfter.DcGuid) { $powerOk = $false }
        $results.checks.powerRestored = [bool]$powerOk
        if (-not $powerOk) { $results.errors += 'power mode was not restored' }
        $powerBefore = $null

        try {
            $tw = @(Invoke-TweakRoundtrip)
            $results.checks.tweaks = @($tw | ForEach-Object { '{0}={1} {2}' -f $_.Id, $_.Result, $_.Detail })
            $badTw = @($tw | Where-Object { $_.Result -eq 'fail' })
            if ($badTw.Count) { $results.errors += ('tweak roundtrip: ' + (($badTw | ForEach-Object { "$($_.Id):$($_.Detail)" }) -join '; ')) }
        } catch { $results.errors += "tweaks: $($_.Exception.Message)" }

        try {
            $results.checks.ping = @()
            $ping = New-Object System.Net.NetworkInformation.Ping
            foreach ($target in @('223.5.5.5','1.1.1.1')) {
                try { $r = $ping.Send($target, 1500); $results.checks.ping += "$target=$($r.Status)/$($r.RoundtripTime)ms" } catch { $results.checks.ping += "$target=fail" }
            }
        } catch { $results.errors += "probe: $($_.Exception.Message)" }

        if (@($results.errors).Count) { $results.ok = $false }
        ($results | ConvertTo-Json -Depth 6) | Set-Content -Path (Join-Path $outDir 'results.json') -Encoding UTF8
        $win.Close()
        if (-not $results.ok) { exit 1 } else { exit 0 }
    } catch {
        $_ | Out-String | Set-Content (Join-Path $outDir 'crash.txt') -Encoding UTF8
        try { $win.Close() } catch {}
        exit 2
    } finally {
        try { Restore-AllUndo | Out-Null } catch { }
        if ($powerBefore) { try { Restore-PowerSnapshot $powerBefore } catch { } }
        if ($child) { try { Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue } catch { } }
        if ($burnFile) { Remove-Item $burnFile -Force -ErrorAction SilentlyContinue }
    }
}

if ($SmokeSeconds -gt 0 -and $env:WINOPT_SMOKE_SECONDS) { $SmokeSeconds = [int]$env:WINOPT_SMOKE_SECONDS }
if ($SmokeSeconds -gt 0) {
    $win.Show()
    $deadline = (Get-Date).AddSeconds($SmokeSeconds)
    while ((Get-Date) -lt $deadline) {
        [Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Background) | Out-Null
        Start-Sleep -Milliseconds 200
    }
    $win.Close()
    exit 0
}

[void]$win.ShowDialog()
