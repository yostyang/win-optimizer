# 不弹窗：只验证本机 CIM / 进程 / 网络 API 和脚本能被解析
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$main = Join-Path $root 'WinOptimizer.ps1'
$e=$null;$t=$null
[void][System.Management.Automation.Language.Parser]::ParseFile($main,[ref]$t,[ref]$e)
if ($e) { $e | ForEach-Object { Write-Error $_ }; exit 1 }

$os = Get-CimInstance Win32_OperatingSystem
$cpu = (Get-CimInstance Win32_Processor | Measure-Object LoadPercentage -Average).Average
$freeMB = [int]($os.FreePhysicalMemory / 1024)
$procs = @(Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 5)
Write-Host "CPU=$cpu%  FreeMem=${freeMB}MB  Top=$($procs.ProcessName -join ',')"

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
foreach ($needle in @('RenderTargetBitmap','Invoke-Checkup','Set-AliDns','Get-StartupItems','-Smoke')) {
    if ($src -notmatch [regex]::Escape($needle)) { Write-Error "missing $needle"; exit 1 }
}
Write-Host 'HEADLESS SMOKE OK'
exit 0
