# 不弹窗：只验证本机 CIM / 进程 / 网络 API 和脚本能被解析
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$main = Join-Path $root 'WinOptimizer.ps1'
$e=$null;$t=$null
[void][System.Management.Automation.Language.Parser]::ParseFile($main,[ref]$t,[ref]$e)
if ($e) { $e | ForEach-Object { Write-Error $_ }; exit 1 }

$os = Get-CimInstance Win32_OperatingSystem
$freeMB = [int]($os.FreePhysicalMemory / 1024)
$procs = @(Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 5)
Add-Type -Namespace WinOptHeadless -Name Native -MemberDefinition @'
[DllImport("kernel32.dll")]
static extern bool GetSystemTimes(out long idle, out long kernel, out long user);
public static long[] ReadCpuTimes() {
    long idle = 0, kernel = 0, user = 0;
    if (!GetSystemTimes(out idle, out kernel, out user)) return null;
    return new long[] { idle, kernel, user };
}
'@
$n = [Math]::Max(1, [Environment]::ProcessorCount)
$workers = @()
for ($i = 0; $i -lt $n; $i++) {
    $ps = [powershell]::Create()
    [void]$ps.AddScript({ $x = 1.0; $sw = [Diagnostics.Stopwatch]::StartNew(); while ($sw.ElapsedMilliseconds -lt 1500) { $x = [math]::Sqrt($x + 1.000001) }; $x })
    $workers += @{ ps = $ps; h = $ps.BeginInvoke() }
}
Start-Sleep -Milliseconds 200
$t0 = [WinOptHeadless.Native]::ReadCpuTimes()
Start-Sleep -Milliseconds 600
$t1 = [WinOptHeadless.Native]::ReadCpuTimes()
foreach ($w in $workers) { try { [void]$w.ps.EndInvoke($w.h) } catch { }; try { $w.ps.Dispose() } catch { } }
$cpu = $null
if ($t0 -and $t1) {
    $idle = [int64]$t1[0] - [int64]$t0[0]
    $total = ([int64]$t1[1] - [int64]$t0[1]) + ([int64]$t1[2] - [int64]$t0[2])
    if ($total -gt 0 -and $idle -ge 0 -and $idle -le $total) { $cpu = [int][math]::Round(100.0 * ($total - $idle) / [double]$total) }
}
$wmi = (Get-CimInstance Win32_Processor | Measure-Object LoadPercentage -Average).Average
Write-Host "CPU(GetSystemTimes under stress)=$cpu%  WMI LoadPercentage=$wmi (diagnostic, often stuck at 0)  FreeMem=${freeMB}MB  Arch=$env:PROCESSOR_ARCHITECTURE  Top=$($procs.ProcessName -join ',')"
if ($null -eq $cpu) { Write-Error 'GetSystemTimes produced no CPU sample'; exit 1 }
if ($cpu -lt 10 -or $cpu -gt 100) { Write-Error "CPU sample $cpu not in 10..100 under stress"; exit 1 }

$ping = New-Object System.Net.NetworkInformation.Ping
foreach ($target in @('223.5.5.5','1.1.1.1')) {
    try {
        $r = $ping.Send($target, 2000)
        Write-Host "ping $target $($r.Status) $($r.RoundtripTime)ms"
    } catch { Write-Host "ping $target fail: $_" }
}

try {
    $adapters = @(Get-NetAdapter -ErrorAction Stop | Select-Object -First 3 Name, Status, InterfaceDescription)
    $adapters | Format-Table | Out-String | Write-Host
} catch { Write-Host "Get-NetAdapter: $_" }

# 确认主脚本含关键入口
$src = Get-Content $main -Raw
foreach ($needle in @('RenderTargetBitmap','Invoke-Checkup','Set-AliDns','Get-StartupItems','-Smoke','GetSystemTimes','BelowNormal','961cc777-2547-4f9d-8174-7d86181b8a7a','overlaysetactive','undo.json','ESBATTTHRESHOLD')) {
    if ($src -notmatch [regex]::Escape($needle)) { Write-Error "missing $needle"; exit 1 }
}
Write-Host 'HEADLESS SMOKE OK'
exit 0
