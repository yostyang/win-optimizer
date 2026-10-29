# Windows一键优化 v0.1 —— PowerShell + WPF，单文件，无需安装
# 原则：只在你点按钮时才动手；需要管理员权限的修复会单独弹出 UAC；不删除任何文件。
#Requires -Version 5.1

param(
    [switch]$Smoke,          # CI：加载界面、跑体检、截图后退出，不进入交互
    [int]$SmokeSeconds = 12  # 交互冒烟时保持窗口打开的秒数（0 = 一直开着）
)
$ErrorActionPreference = 'Stop'
$AppVersion = '0.1'
$AppName = 'Windows一键优化'

if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $extra = @()
    if ($Smoke) { $extra += '-Smoke' }
    if ($PSBoundParameters.ContainsKey('SmokeSeconds')) { $extra += @('-SmokeSeconds', "$SmokeSeconds") }
    $exe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { (Get-Command pwsh).Source } else { "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" }
    # 用当前进程同款宿主，并把 -Smoke 参数原样带过去
    $argList = @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File', $PSCommandPath) + $extra
    $p = Start-Process -FilePath $exe -ArgumentList $argList -Wait -PassThru
    exit $p.ExitCode
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

Add-Type -Namespace WinOpt -Name Native -MemberDefinition @'
[DllImport("user32.dll", SetLastError=true)]
public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, ref int pvParam, uint fWinIni);
[DllImport("user32.dll", SetLastError=true)]
public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, IntPtr pvParam, uint fWinIni);
[StructLayout(LayoutKind.Sequential)]
public struct ANIMATIONINFO { public uint cbSize; public int iMinAnimate; }
[DllImport("user32.dll", SetLastError=true, EntryPoint="SystemParametersInfo")]
public static extern bool SPIAnim(uint uiAction, uint uiParam, ref ANIMATIONINFO pvParam, uint fWinIni);
'@

# ---------------- 数据目录 ----------------
$DataDir = Join-Path $env:APPDATA 'WinOptimizer'
if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir | Out-Null }
$DnsBackup = Join-Path $DataDir 'dns-backup.json'
$AliDns = @('223.5.5.5','223.6.6.6')

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
function Get-Overview {
    $os = Get-CimInstance Win32_OperatingSystem
    $cpu = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
    $total = [double]$os.TotalVisibleMemorySize * 1KB
    $free = [double]$os.FreePhysicalMemory * 1KB
    [pscustomobject]@{
        Cpu = [int]$cpu
        MemTotal = $total
        MemFree = $free
        MemUsedPct = [int](100 * ($total - $free) / $total)
        Uptime = (Get-Date) - $os.LastBootUpTime
        OsName = $os.Caption
    }
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
            <DockPanel DockPanel.Dock="Top" Margin="0,0,0,10">
              <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                <Button x:Name="ProcRefresh" Content="刷新"/>
                <Button x:Name="ProcEnd" Content="结束所选进程…" Margin="0"/>
              </StackPanel>
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="排序：" VerticalAlignment="Center" Foreground="$($C.Mute)"/>
                <RadioButton x:Name="SortMem" Content="内存" IsChecked="True" Margin="4,0,12,0" VerticalAlignment="Center" Foreground="$($C.Ink)"/>
                <RadioButton x:Name="SortCpu" Content="CPU" VerticalAlignment="Center" Foreground="$($C.Ink)"/>
                <TextBlock Text="  （CPU 为两次刷新之间的占用）" Style="{StaticResource Note}" VerticalAlignment="Center"/>
              </StackPanel>
            </DockPanel>
            <ListView x:Name="ProcList" Height="330" SelectionMode="Extended">
              <ListView.View>
                <GridView>
                  <GridViewColumn Header="进程" Width="300" DisplayMemberBinding="{Binding Name}"/>
                  <GridViewColumn Header="PID" Width="80" DisplayMemberBinding="{Binding Id}"/>
                  <GridViewColumn Header="内存" Width="120" DisplayMemberBinding="{Binding Mem}"/>
                  <GridViewColumn Header="CPU" Width="90" DisplayMemberBinding="{Binding CpuText}"/>
                  <GridViewColumn Header="窗口标题" Width="250" DisplayMemberBinding="{Binding Title}"/>
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
        <Border Style="{StaticResource Card}">
          <DockPanel>
            <Button x:Name="PowerSettings" DockPanel.Dock="Right" Content="电源和电池设置" Margin="0" VerticalAlignment="Top"/>
            <StackPanel>
              <TextBlock Text="电池" Style="{StaticResource H}"/>
              <TextBlock x:Name="BatText" FontSize="20" FontWeight="SemiBold"/>
              <TextBlock x:Name="BatSub" Style="{StaticResource Note}" Margin="0,4,0,0"/>
              <TextBlock Style="{StaticResource Note}" Margin="0,10,0,0" Text="充电上限（例如只充到 80%）由各品牌自己的软件控制：联想 Vantage、华硕 MyASUS、戴尔 Power Manager、惠普 / 微软 Surface 在 BIOS 或自带应用里设置。本工具不修改。"/>
            </StackPanel>
          </DockPanel>
        </Border>
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
function Update-Overview {
    try {
        $o = Get-Overview
        $ui.OsName.Text = $o.OsName
        $ui.CpuText.Text = "$($o.Cpu)%"
        $ui.CpuBar.Value = $o.Cpu
        $ui.MemText.Text = Format-Bytes $o.MemFree
        $ui.MemSub.Text = "共 $(Format-Bytes $o.MemTotal)，已用 $($o.MemUsedPct)%"
        $ui.MemText.Foreground = if ($o.MemUsedPct -ge 90) { Brush $C.Bad } elseif ($o.MemUsedPct -ge 80) { Brush $C.Warn } else { Brush $C.Ink }
        $ui.UpText.Text = Format-Uptime $o.Uptime
        $ui.UpSub.Text = if ($o.Uptime.TotalDays -ge 7) { '很久没重启了，重启一次常常能解决卡顿' } else { '' }
        $script:LastOverview = $o
    } catch { }
}

# ---------------- 智能体检 ----------------
$script:Issues = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$ui.IssueList.ItemsSource = $script:Issues
function New-Issue($id, $title, $detail, $level, $fixable, $fixText) {
    $color = switch ($level) { '严重' { $C.Bad } '注意' { $C.Warn } default { $C.Ok } }
    $o = New-Object PSObject -Property ([ordered]@{ Id = $id; Title = $title; Detail = $detail; Level = $level; LevelColor = (Brush $color); Fixable = [bool]$fixable; Selected = [bool]$fixable; FixText = $fixText })
    return $o
}
function Invoke-Checkup {
    $script:Issues.Clear()
    $score = 100
    $o = Get-Overview
    # 1 内存压力
    if ($o.MemUsedPct -ge 85) {
        $score -= 20
        $top = (Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 3 | ForEach-Object { "$($_.ProcessName) $(Format-Bytes $_.WorkingSet64)" }) -join '、'
        $script:Issues.Add((New-Issue 'mem' "内存吃紧：已用 $($o.MemUsedPct)%" "最占内存：$top" '严重' $true '修复：打开「资源排行」，由你选择要结束的程序'))
    } elseif ($o.MemUsedPct -ge 75) {
        $score -= 8
        $script:Issues.Add((New-Issue 'mem' "内存偏紧：已用 $($o.MemUsedPct)%" '再多开几个程序就可能开始卡。' '注意' $true '修复：打开「资源排行」查看'))
    }
    # 2 浏览器
    $brs = @(Get-Browsers)
    if ($brs.Count -ge 2) {
        $score -= 10
        $names = ($brs | ForEach-Object { "$($_.Name)（$($_.Mem)）" }) -join '、'
        $script:Issues.Add((New-Issue 'browsers' "同时开着 $($brs.Count) 个浏览器" $names '注意' $true '修复：打开「浏览器」页，选择要退出的（只关窗口，标签页会保存）'))
    }
    # 3 VPN
    $vpn = @(Get-VpnAdapters)
    if ($vpn.Count -gt 0) {
        $score -= 8
        $names = ($vpn | ForEach-Object { $_.InterfaceDescription }) -join '、'
        $script:Issues.Add((New-Issue 'vpn' "有 $($vpn.Count) 个 VPN / 虚拟网卡在连接" "$names。不用时断开，网页和下载可能更快。" '注意' $true '修复：打开「网络连接」，由你断开'))
    }
    # 4 DNS
    if (-not (Test-DnsIsAli)) {
        $score -= 6
        $d = (@(Get-CurrentDns) | ForEach-Object { "$($_.Name)：$(if ($_.Servers.Count) { $_.Servers -join ', ' } else { '自动' })" }) -join '；'
        $script:Issues.Add((New-Issue 'dns' 'DNS 不是阿里 DNS' $d '建议' $true '修复：设为 223.5.5.5 / 223.6.6.6（先备份，可恢复；需要管理员）'))
    }
    # 5 启动项
    $st = @(Get-StartupItems | Where-Object { $_.Enabled })
    if ($st.Count -ge 8) {
        $score -= 8
        $script:Issues.Add((New-Issue 'startup' "开机启动项有 $($st.Count) 个" '启动项太多会让开机后很长一段时间都很卡。' '注意' $true '修复：打开「开机启动」页，由你选择停用哪些'))
    }
    # 6 动画
    if (Get-AnimationsOn) {
        $score -= 3
        $script:Issues.Add((New-Issue 'anim' '窗口动画已打开' '关闭后窗口切换更跟手（纯个人偏好，随时可改回）。' '建议' $true '修复：关闭窗口动画（不需要管理员）'))
    }
    # 7 重启
    if ($o.Uptime.TotalDays -ge 7) {
        $score -= 6
        $script:Issues.Add((New-Issue 'uptime' "已经 $([int]$o.Uptime.TotalDays) 天没重启" '长时间不重启，内存碎片和后台残留会越来越多。' '建议' $false '建议你保存工作后手动重启（本工具不会替你重启）'))
    }
    if ($script:Issues.Count -eq 0) {
        $script:Issues.Add((New-Issue 'ok' '没有发现明显问题' '一切正常。' '正常' $false ''))
    }
    if ($score -lt 0) { $score = 0 }
    $ui.ScoreText.Text = "$score"
    $ui.ScoreText.Foreground = if ($score -ge 85) { Brush $C.Ok } elseif ($score -ge 65) { Brush $C.Warn } else { Brush $C.Bad }
    $ui.ScoreSub.Text = "发现 $(@($script:Issues | Where-Object { $_.Id -ne 'ok' }).Count) 项 · $(Get-Date -Format 'HH:mm')"
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
        }
    }
    if ($done.Count) { Show-Info ($done -join "`n") }
    if ($goTab) { $ui.Tabs.SelectedIndex = $goTab }
    Invoke-Checkup
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
        [pscustomobject]@{
            Name = $p.ProcessName; Id = $p.Id; MemRaw = $p.WorkingSet64; Mem = (Format-Bytes $p.WorkingSet64)
            Cpu = $(if ($null -ne $cpu) { $cpu } else { -1 }); CpuText = $(if ($null -ne $cpu) { '{0:N1}%' -f $cpu } else { '—' })
            Title = $p.MainWindowTitle; Tms = $t
        }
    }
    $script:PrevCpu = @{}; foreach ($r in $rows) { if ($null -ne $r.Tms) { $script:PrevCpu[$r.Id] = $r.Tms } }
    $script:PrevTime = $now
    $sorted = if ($ui.SortCpu.IsChecked) { $rows | Sort-Object Cpu -Descending } else { $rows | Sort-Object MemRaw -Descending }
    $ui.ProcList.ItemsSource = @($sorted | Select-Object -First 40)
}
function Stop-Selected {
    $sel = @($ui.ProcList.SelectedItems)
    if ($sel.Count -eq 0) { Show-Info '先在列表里选中要结束的进程（可按 Ctrl 多选）。'; return }
    $names = ($sel | ForEach-Object { "$($_.Name) (PID $($_.Id))" }) -join "`n"
    if (-not (Confirm-Action "确定结束这些进程吗？未保存的内容可能会丢失。`n`n$names" '结束进程')) { return }
    $fail = @()
    foreach ($s in $sel) {
        try {
            $p = Get-Process -Id $s.Id -ErrorAction Stop
            # 有窗口的先礼貌关闭，3 秒后还在才强制结束（用户已经确认过）
            if ($p.MainWindowHandle -ne 0 -and $p.CloseMainWindow()) {
                if (-not $p.WaitForExit(3000)) { $p.Kill() }
            } else { $p.Kill() }
        } catch { $fail += "$($s.Name)：$($_.Exception.Message)" }
    }
    if ($fail.Count) { Show-Info ("有些进程没能结束（可能需要管理员）：`n" + ($fail -join "`n")) }
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

# ---------------- 事件 ----------------
$ui.CheckBtn.Add_Click({ Invoke-Checkup })
$ui.FixBtn.Add_Click({ Invoke-Fixes })
$ui.ProcRefresh.Add_Click({ Update-Processes })
$ui.ProcEnd.Add_Click({ Stop-Selected })
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

# 切换页面时刷新对应内容
$ui.Tabs.Add_SelectionChanged({
    param($s, $e)
    if ($e.OriginalSource -ne $ui.Tabs) { return }
    switch ($ui.Tabs.SelectedIndex) {
        1 { Update-Processes } 2 { Update-Startup } 3 { Update-Browsers } 4 { Update-Dns } 5 { Update-Display } 6 { Update-Battery }
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
    Update-Overview
    try { Invoke-Checkup } catch { $ui.ScoreSub.Text = "体检出错：$($_.Exception.Message)" }
    $timer.Start(); $fast.Start()
})
$win.Add_Closed({ $timer.Stop(); $fast.Stop() })

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

if ($Smoke -or $env:WINOPT_SMOKE -eq '1') {
    $outDir = if ($env:WINOPT_SMOKE_OUT) { $env:WINOPT_SMOKE_OUT } else { Join-Path $PSScriptRoot 'smoke-out' }
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }
    $results = [ordered]@{ ok = $true; errors = @(); checks = [ordered]@{} }
    try {
        # 不阻塞 ShowDialog：先 Show，强制布局，截图，跑体检，再关掉
        $win.Show()
        $win.Activate()
        $win.UpdateLayout()
        for ($i = 0; $i -lt 20; $i++) {
            [Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Background) | Out-Null
            Start-Sleep -Milliseconds 100
        }
        Update-Overview
        try { Invoke-Checkup; $results.checks.checkup = $true; $results.checks.score = $ui.ScoreText.Text; $results.checks.issues = @($script:Issues | ForEach-Object { $_.Title }) }
        catch { $results.checks.checkup = $false; $results.errors += "checkup: $($_.Exception.Message)" }
        try { Update-Processes; $results.checks.processes = @($ui.ProcList.ItemsSource).Count } catch { $results.errors += "proc: $($_.Exception.Message)" }
        try { Update-Startup;  $results.checks.startup   = @($ui.StartList.ItemsSource).Count } catch { $results.errors += "startup: $($_.Exception.Message)" }
        try { Update-Browsers; $results.checks.browsers  = @($ui.BrList.ItemsSource).Count } catch { $results.errors += "browsers: $($_.Exception.Message)" }
        try { Update-Dns;      $results.checks.dns = $ui.DnsText.Text } catch { $results.errors += "dns: $($_.Exception.Message)" }
        try { Update-Display;  $results.checks.anim = $ui.AnimText.Text; $results.checks.trans = $ui.TransText.Text } catch { $results.errors += "display: $($_.Exception.Message)" }
        try { Update-Battery;  $results.checks.battery = $ui.BatText.Text } catch { $results.errors += "battery: $($_.Exception.Message)" }

        # 切每个标签页截一张
        for ($t = 0; $t -lt $ui.Tabs.Items.Count; $t++) {
            $ui.Tabs.SelectedIndex = $t
            $win.UpdateLayout()
            for ($i = 0; $i -lt 5; $i++) { [Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Background) | Out-Null; Start-Sleep -Milliseconds 50 }
            $name = switch ($t) { 0 {'checkup'} 1 {'processes'} 2 {'startup'} 3 {'browsers'} 4 {'network'} 5 {'display'} 6 {'battery'} default {"tab$t"} }
            try { Save-WindowPng $win (Join-Path $outDir "tab-$name.png") } catch { $results.errors += "shot ${name}: $($_.Exception.Message)" }
        }
        $ui.Tabs.SelectedIndex = 0
        $win.UpdateLayout()
        Save-WindowPng $win (Join-Path $outDir 'main.png')

        # 非 UI 探测
        try {
            $o = Get-Overview
            $results.checks.cpu = $o.Cpu; $results.checks.memFreeMB = [int]($o.MemFree/1MB)
            $results.checks.ping = @()
            $ping = New-Object System.Net.NetworkInformation.Ping
            foreach ($target in @('223.5.5.5','1.1.1.1')) {
                try { $r = $ping.Send($target, 1500); $results.checks.ping += "$target=$($r.Status)/$($r.RoundtripTime)ms" } catch { $results.checks.ping += "$target=fail" }
            }
        } catch { $results.errors += "probe: $($_.Exception.Message)" }

        if ($results.errors.Count) { $results.ok = $false }
        ($results | ConvertTo-Json -Depth 6) | Set-Content -Path (Join-Path $outDir 'results.json') -Encoding UTF8
        $win.Close()
        if (-not $results.ok) { exit 1 } else { exit 0 }
    } catch {
        $_ | Out-String | Set-Content (Join-Path $outDir 'crash.txt') -Encoding UTF8
        try { $win.Close() } catch {}
        exit 2
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
