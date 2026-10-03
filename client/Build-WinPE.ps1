#Requires -RunAsAdministrator
<#
.SYNOPSIS
  构建"WinPE 网络安装"启动介质（在 Windows 10/11 上运行，需安装 ADK + WinPE 插件）
.DESCRIPTION
  1. copype 复制 WinPE 工作目录
  2. 挂载 boot.wim，注入网络/PowerShell/DISM/存储/WiFi(可选)/中文字体等组件
  3. 打入 drivers\ 下的驱动（网卡等）到 boot.wim
  4. 复制本目录 winpe-files/（NetInstall.ps1 等）到 X:\NetInstall
  5. 写入 startnet.cmd 开机菜单（安装/命令行/重启/关机）
  6. 生成 ISO 和/或 U 盘启动盘；U 盘根目录生成 NetInstall.ini，
     改服务端地址、菜单默认项、安装模式无需重建优盘

  前置要求（在构建机上，一次性）：
  - 安装 Windows ADK（含 Deployment Tools）
    https://learn.microsoft.com/windows-hardware/get-started/adk-install
  - 安装 WinPE 附加组件（Windows PE add-on for the ADK），与 ADK 版本对应

.EXAMPLE
  .\Build-WinPE.ps1 -Server "192.168.1.10:8080" -Iso "C:\iso\netinstall.iso"
.EXAMPLE
  .\Build-WinPE.ps1 -Server "192.168.1.10:8080" -UsbDrive "E:" -Label "NETINSTALL"
.EXAMPLE
  .\Build-WinPE.ps1 -Server "192.168.1.10:8080" -UsbDrive "E:" -MenuTimeout 5 -DefaultChoice 1 -DefaultMode 2 -Wallpaper "C:\brand\winpe.jpg"
#>
param(
    [string]$Server = "192.168.1.10:8080",   # 网络安装服务端地址，写入 server.txt 与 NetInstall.ini
    [string]$WorkDir = "C:\WinPE_NetInstall", # copype 工作目录
    [string]$Iso,                             # 生成 ISO 路径（可选）
    [string]$UsbDrive,                        # 制作 U 盘启动盘（可选，如 "E:"）
    [switch]$AddWifi,                         # 加入 WinPE Wi-Fi 支持（需要较新 ADK）
    [switch]$Force,                           # 已存在工作目录时强制删除重建
    [int]$MenuTimeout = 10,                   # 开机菜单等待秒数（写入优盘 NetInstall.ini）
    [int]$DefaultChoice = 1,                  # 开机菜单默认项：1=安装 2=命令行 3=重启 4=关机
    [int]$DefaultMode = 0,                    # 默认安装模式：0=每次询问 1=整盘清空 2=保留分区
    [string]$Label = "NETINSTALL",            # 优盘卷标
    [string]$Wallpaper = ""                   # WinPE 背景图（jpg），留空不换
)

$ErrorActionPreference = "Stop"
$AdkRoot = "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit"
$PeOcRoot = "$AdkRoot\Windows Preinstallation Environment\amd64\WinPE_OCs"

function Write-Step([string]$m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Ok([string]$m)   { Write-Host "  [OK] $m" -ForegroundColor Green }

# ---------- 0. 环境检查 ----------
Write-Step "检查构建环境"
foreach ($p in @("$AdkRoot\Deployment Tools\amd64\DISM\dism.exe",
                 "$AdkRoot\Deployment Tools\amd64\Oscdimg\oscdimg.exe")) {
    if (-not (Test-Path $p)) { throw "未找到: $p。请先安装 Windows ADK（含 Deployment Tools）。" }
}
if (-not (Test-Path $PeOcRoot)) { throw "未找到 WinPE_OCs：$PeOcRoot。请先安装 WinPE add-on。" }
$Copype = "$AdkRoot\Deployment Tools\amd64\copype.cmd"
$MakeMedia = "$AdkRoot\Deployment Tools\amd64\MakeWinPEMedia.cmd"
Write-Ok "ADK 与 WinPE 插件就绪"

$ScriptDir = $PSScriptRoot
$FilesDir = Join-Path $ScriptDir "winpe-files"
foreach ($f in @("NetInstall.ps1", "startnet.cmd", "diskpart-uefi.txt", "diskpart-bios.txt")) {
    if (-not (Test-Path (Join-Path $FilesDir $f))) { throw "缺少客户端文件: $f" }
}

# ---------- 1. copype ----------
Write-Step "copype 复制 WinPE 工作目录 -> $WorkDir"
if (Test-Path $WorkDir) {
    if (-not $Force) { throw "工作目录已存在: $WorkDir（加 -Force 强制重建）" }
    Remove-Item $WorkDir -Recurse -Force
}
& cmd /c "`"$Copype`" amd64 `"$WorkDir`""
if ($LASTEXITCODE -ne 0) { throw "copype 失败" }
Write-Ok "copype 完成"

$BootWim = "$WorkDir\media\sources\boot.wim"
$MountDir = "$WorkDir\mount"
New-Item -ItemType Directory -Force -Path $MountDir | Out-Null

# ---------- 2. 挂载 boot.wim ----------
Write-Step "挂载 boot.wim"
& dism /Mount-Image /ImageFile:$BootWim /Index:1 /MountDir:$MountDir
if ($LASTEXITCODE -ne 0) { throw "挂载 boot.wim 失败" }

# ---------- 3. 注入可选组件 ----------
Write-Step "注入 WinPE 可选组件"
$LangRoot = "$PeOcRoot\en-us"
$packages = @(
    "WinPE-WMI",          # WMI（Get-Disk 等依赖）
    "WinPE-NetFX",        # .NET（PowerShell 依赖）
    "WinPE-Scripting",    # WSH
    "WinPE-PowerShell",   # PowerShell
    "WinPE-DismCmdlets",  # DISM PowerShell 模块
    "WinPE-StorageWMI",   # 存储 WMI（Get-Disk）
    "WinPE-SecureStartup" # BitLocker 相关（可选但常用）
)
if ($AddWifi -and (Test-Path "$PeOcRoot\WinPE-WiFi-Package.cab")) {
    $packages += "WinPE-WiFi-Package"
    Write-Host "  将加入 Wi-Fi 支持" -ForegroundColor Yellow
}
# 中文字体支持（避免安装界面中文乱码）
if (Test-Path "$PeOcRoot\WinPE-FontSupport-ZH-CN.cab") {
    $packages += "WinPE-FontSupport-ZH-CN"
}
foreach ($pkg in $packages) {
    $cab = "$PeOcRoot\$pkg.cab"
    if (-not (Test-Path $cab)) { Write-Host "  跳过缺失组件: $pkg" -ForegroundColor DarkGray; continue }
    Write-Host "  + $pkg"
    & dism /Image:$MountDir /Add-Package /PackagePath:$cab | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "注入组件失败: $pkg" }
    $langCab = "$LangRoot\${pkg}_en-us.cab"
    if (Test-Path $langCab) {
        & dism /Image:$MountDir /Add-Package /PackagePath:$langCab | Out-Null
    }
}
Write-Ok "组件注入完成"

# ---------- 4. 复制网络安装客户端文件 ----------
Write-Step "复制网络安装客户端文件"
$destDir = "$MountDir\NetInstall"
New-Item -ItemType Directory -Force -Path $destDir | Out-Null
Copy-Item "$FilesDir\*" $destDir -Recurse -Force
# 写入服务端地址
$Server | Set-Content (Join-Path $destDir "server.txt") -Encoding ASCII -NoNewline
Write-Ok "已复制客户端文件，服务端地址: $Server（可在 U 盘/ISO 中修改 X:\NetInstall\server.txt 覆盖）"

# 可选：预置驱动（把 .inf 驱动放到本目录 drivers\，打入 boot.wim 让 WinPE 识别网卡等硬件）
$drvSrc = Join-Path $ScriptDir "drivers"
if ((Test-Path $drvSrc) -and (Get-ChildItem $drvSrc -Recurse -Filter "*.inf" -ErrorAction SilentlyContinue)) {
    Write-Step "注入 drivers\ 驱动到 boot.wim"
    & dism /Image:$MountDir /Add-Driver /Driver:$drvSrc /Recurse
    if ($LASTEXITCODE -ne 0) { Write-Warn "部分驱动注入失败，可检查驱动是否匹配 WinPE 版本" }
    # 同时复制一份到安装包，供将来注入目标系统
    Copy-Item $drvSrc "$destDir\Drivers" -Recurse -Force
    Write-Ok "驱动已注入 boot.wim"
} else {
    Write-Host "  未发现 drivers\，跳过（如目标机网卡在 WinPE 下无法识别，请把驱动放入 drivers\ 后重建）" -ForegroundColor DarkGray
}

# 可选：自定义 WinPE 桌面背景
if ($Wallpaper -and (Test-Path $Wallpaper)) {
    Write-Step "设置 WinPE 背景图"
    Copy-Item $Wallpaper "$MountDir\Windows\System32\winpe.jpg" -Force
    Write-Ok "背景图已设置"
}

# ---------- 5. startnet.cmd 开机自启动 ----------
Write-Step "配置 startnet.cmd 开机自启动"
$startnet = "$MountDir\Windows\System32\startnet.cmd"
$hook = Get-Content (Join-Path $FilesDir "startnet.cmd") -Raw
Add-Content $startnet ("`r`n" + $hook) -Encoding ASCII
Write-Ok "startnet.cmd 已配置"

# ---------- 6. 卸载并提交 ----------
Write-Step "卸载 boot.wim 并提交更改"
& dism /Unmount-Image /MountDir:$MountDir /Commit
if ($LASTEXITCODE -ne 0) { throw "卸载/提交失败" }
Write-Ok "boot.wim 已更新"

# ---------- 7. 生成介质 ----------
if ($Iso) {
    Write-Step "生成 ISO -> $Iso"
    $isoDir = Split-Path $Iso -Parent
    if ($isoDir -and -not (Test-Path $isoDir)) { New-Item -ItemType Directory -Force -Path $isoDir | Out-Null }
    & cmd /c "`"$MakeMedia`" /ISO `"$WorkDir`" `"$Iso`""
    if ($LASTEXITCODE -ne 0) { throw "生成 ISO 失败" }
    Write-Ok "ISO 已生成: $Iso"
}
if ($UsbDrive) {
    $dl = $UsbDrive.TrimEnd(":") + ":"
    Write-Step "制作 U 盘启动盘 -> $dl（将清空该 U 盘！）"
    $yn = Read-Host "确认清空 $dl 并写入 WinPE？输入 YES 继续"
    if ($yn -cne "YES") { throw "已取消 U 盘制作" }
    & cmd /c "`"$MakeMedia`" /UFD `"$WorkDir`" $dl"
    if ($LASTEXITCODE -ne 0) { throw "U 盘制作失败" }
    Write-Ok "U 盘启动盘已写入"

    # ---------- 8. 优盘定制收尾 ----------
    Write-Step "优盘定制：卷标 / NetInstall.ini / BCD"
    # 卷标
    & label "$dl" $Label 2>$null
    # NetInstall.ini（放优盘根目录，改配置无需重建）
    $iniUrl = $Server -replace "^https?://", ""
    $ini = @"
; WinPE 网络安装 - 优盘配置文件（构建时生成，可直接在优盘上修改）
; 优先级：本文件 > server.txt（X:\NetInstall 内）> 开机手动输入

[Server]
Url=$iniUrl

[Boot]
MenuTimeout=$MenuTimeout
DefaultChoice=$DefaultChoice

[Install]
DefaultMode=$DefaultMode
"@
    $ini | Set-Content "$dl\NetInstall.ini" -Encoding ASCII
    Write-Ok "已生成 $dl\NetInstall.ini（服务端 $iniUrl，菜单等待 ${MenuTimeout}s，默认安装模式 $DefaultMode）"
    # BCD：缩短固件启动菜单等待（真正的选择菜单在 startnet.cmd）
    foreach ($bcd in @("$dl\EFI\Microsoft\Boot\BCD", "$dl\Boot\BCD")) {
        if (Test-Path $bcd) {
            & bcdedit /store $bcd /set "{bootmgr}" timeout 3 2>$null | Out-Null
            & bcdedit /store $bcd /set "{bootmgr}" description "Windows 网络安装" 2>$null | Out-Null
        }
    }
    Write-Ok "BCD 已设置（卷标 $Label）"
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " 构建完成！" -ForegroundColor Green
Write-Host " 定制优盘无需重建：直接改优盘根目录 NetInstall.ini"
Write-Host "   - 换服务端：改 [Server] Url="
Write-Host "   - 开机菜单：改 [Boot] MenuTimeout= / DefaultChoice=（1=安装 2=命令行 3=重启 4=关机）"
Write-Host "   - 安装模式：改 [Install] DefaultMode=（0=每次问 1=整盘 2=保留分区）"
Write-Host " 下一步："
Write-Host "  1. 启动服务端: python3 netinstall_server.py --dir ./images"
Write-Host "  2. 放入 .wim 镜像并编辑 images/manifest.json 登记"
Write-Host "  3. 用 U 盘启动目标机器，按菜单完成网络安装"
Write-Host "============================================================" -ForegroundColor Green
