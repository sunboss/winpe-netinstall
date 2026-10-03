#Requires -RunAsAdministrator
<#
.SYNOPSIS
  WinPE 网络安装主程序（类 macOS 互联网恢复 · 自建版客户端）
.DESCRIPTION
  在 WinPE 中运行：从服务端拉取镜像清单 -> 选择镜像 -> 分区 ->
  获取镜像（SMB 直读 / HTTP 下载）-> DISM 释放 -> bcdboot 写引导 -> 重启
  由 startnet.cmd 在 WinPE 启动后自动调用，也可手动执行。
#>
$ErrorActionPreference = "Stop"
$ScriptDir = $PSScriptRoot
$ServerFile = Join-Path $ScriptDir "server.txt"

function Write-Step([string]$msg) {
    Write-Host ""
    Write-Host "==> $msg" -ForegroundColor Cyan
}
function Write-Ok([string]$msg)   { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Write-Warn([string]$msg) { Write-Host "  [!!] $msg" -ForegroundColor Yellow }
function Write-Err([string]$msg)  { Write-Host "  [XX] $msg" -ForegroundColor Red }

function Read-Choice([string]$prompt, [int]$min, [int]$max, [int]$default) {
    while ($true) {
        $raw = Read-Host "$prompt [$default]"
        if ([string]::IsNullOrWhiteSpace($raw)) { return $default }
        $n = 0
        if ([int]::TryParse($raw, [ref]$n) -and $n -ge $min -and $n -le $max) { return $n }
        Write-Warn "请输入 $min - $max 之间的数字"
    }
}

# GPT 分区类型 GUID（用于识别 EFI/MSR/恢复分区）
$GuidEfi = "{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}"
$GuidMsr = "{e3c9e316-0b5c-4db8-817d-f92df00215ae}"
$GuidRecovery = "{de94bba4-06d1-4d40-a16a-bfd50179d6ac}"

function Show-DiskLayout([int]$diskNum) {
    Write-Host ""
    Write-Host ("  磁盘 {0} 当前分区布局：" -f $diskNum) -ForegroundColor Yellow
    try {
        $parts = @(Get-Partition -DiskNumber $diskNum -ErrorAction Stop | Sort-Object PartitionNumber)
    } catch {
        Write-Warn "无法读取分区信息: $_"
        return @()
    }
    if ($parts.Count -eq 0) {
        Write-Host "  （无分区：空盘或未初始化）" -ForegroundColor DarkGray
        return $parts
    }
    Write-Host ("  {0,-6}{1,-12}{2,-8}{3,-14}{4}" -f "序号", "大小", "盘符", "类型", "卷标")
    foreach ($p in $parts) {
        $size = "{0:N1} GB" -f ($p.Size / 1GB)
        $letters = (($p.DriveLetter | ForEach-Object { "$_:" }) -join ",")
        $type = switch ($p.GptType) {
            $GuidEfi      { "EFI系统分区"; break }
            $GuidMsr      { "MSR保留分区"; break }
            $GuidRecovery { "恢复分区"; break }
            default       { if ($p.IsActive) { "活动分区" } else { "数据分区" } }
        }
        $label = ""
        try {
            $vol = Get-Volume -Partition $p -ErrorAction SilentlyContinue
            if ($vol) { $label = $vol.FileSystemLabel }
        } catch {}
        Write-Host ("  {0,-6}{1,-12}{2,-8}{3,-14}{4}" -f $p.PartitionNumber, $size, $letters, $type, $label)
    }
    return $parts
}

function Set-DriveLetter([int]$diskNum, [int]$partNum, [string]$letter) {
    # 先释放被占用的目标盘符
    Get-Partition -ErrorAction SilentlyContinue |
        Where-Object { $_.DriveLetter -eq $letter } |
        ForEach-Object { $_ | Remove-PartitionAccessPath -AccessPath ($letter + ":") }
    $p = Get-Partition -DiskNumber $diskNum -PartitionNumber $partNum -ErrorAction Stop
    if ($p.DriveLetter) {
        $p | Remove-PartitionAccessPath -AccessPath ($p.DriveLetter + ":")
        $p = Get-Partition -DiskNumber $diskNum -PartitionNumber $partNum -ErrorAction Stop
    }
    $p | Add-PartitionAccessPath -AccessPath ($letter + ":")
}

# ---------- 1. 环境检查 ----------
Write-Step "环境检查"
if (-not (Test-Path "$env:SystemRoot\System32\wpeutil.exe")) {
    Write-Err "未检测到 WinPE 环境，请用本项目的 WinPE 启动盘启动后再运行。"
    exit 1
}
Write-Ok "WinPE 环境确认"

# ---------- 2. 网络初始化 ----------
Write-Step "初始化网络（DHCP）"
try { wpeutil InitializeNetwork 2>$null | Out-Null } catch {}
Start-Sleep -Seconds 3
$nic = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
       Where-Object { $_.Status -eq "Up" } | Select-Object -First 1
if ($nic) {
    $ip = (Get-NetIPAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
           Where-Object { $_.IPAddress -notlike "169.254.*" } | Select-Object -First 1).IPAddress
    Write-Ok ("网卡 {0} 已连接，IP: {1}" -f $nic.Name, ($ip ? $ip : "获取中"))
} else {
    Write-Warn "未发现已连接的网卡，请检查网线 / Wi-Fi（Wi-Fi 需构建时加入 WinPE-WiFi-Package）"
}

# ---------- 3. 服务端地址 ----------
$server = $null
if (Test-Path $ServerFile) {
    $server = (Get-Content $ServerFile -Raw).Trim()
}
if ([string]::IsNullOrWhiteSpace($server) -or $server -like "*192.168.1.10*") {
    Write-Host ""
    Write-Host "  当前预设服务端: $server" -ForegroundColor DarkGray
    $input = Read-Host "  输入服务端地址 (IP:端口，直接回车使用预设)"
    if (-not [string]::IsNullOrWhiteSpace($input)) { $server = $input.Trim() }
}
if ($server -notmatch ":\d+$") { $server = "$server`:8080" }
$base = "http://$server"
Write-Step "连接服务端 $base"
$netOk = $false
for ($i = 1; $i -le 3; $i++) {
    try {
        $null = Invoke-RestMethod "$base/api/manifest" -TimeoutSec 8
        $netOk = $true; break
    } catch {
        Write-Warn "第 $i 次连接失败，3 秒后重试..."
        Start-Sleep -Seconds 3
    }
}
if (-not $netOk) {
    Write-Err "无法连接服务端 $base，请检查网络与服务端状态后重试。"
    exit 1
}
Write-Ok "服务端连接正常"

# ---------- 4. 拉取镜像清单 ----------
Write-Step "获取镜像清单"
$manifest = Invoke-RestMethod "$base/api/manifest" -TimeoutSec 15
$images = @($manifest.images)
if ($images.Count -eq 0) {
    Write-Err "服务端暂无可用镜像，请先在服务端 images 目录放入 .wim 并编辑 manifest.json"
    exit 1
}
Write-Host ""
for ($i = 0; $i -lt $images.Count; $i++) {
    $img = $images[$i]
    $sizeGB = if ($img.size) { "{0:N2} GB" -f ($img.size / 1GB) } else { "未知" }
    Write-Host ("  [{0}] {1}  ({2}, {3})" -f ($i + 1), $img.name, $sizeGB, $img.protocol)
    if ($img.description) { Write-Host ("       {0}" -f $img.description) -ForegroundColor DarkGray }
}
$choice = Read-Choice "选择要安装的镜像" 1 $images.Count 1
$img = $images[$choice - 1]
Write-Ok ("已选择: {0}" -f $img.name)

# ---------- 6. 选择目标磁盘 ----------
Write-Step "选择目标磁盘"
$disks = @()
try {
    $disks = Get-Disk | Sort-Object Number
} catch {}
if ($disks.Count -gt 0) {
    Write-Host ""
    foreach ($d in $disks) {
        $sizeGB = "{0:N0} GB" -f ($d.Size / 1GB)
        $tag = if ($d.BusType -eq "USB") { "[U 盘]" } else { "" }
        Write-Host ("  [{0}] 磁盘 {1}  {2}  {3}  {4} {5}" -f $d.Number, $d.Number, $d.FriendlyName, $sizeGB, $d.PartitionStyle, $tag)
    }
    $diskNum = Read-Choice "选择目标磁盘编号" 0 99 0
} else {
    Write-Warn "无法枚举磁盘，默认使用磁盘 0"
    $diskNum = 0
}

# ---------- 6b. 显示分区布局 ----------
$parts = Show-DiskLayout $diskNum

# ---------- 6c. 选择安装模式 ----------
Write-Host ""
Write-Host "  安装模式："
Write-Host "  [1] 整盘清空安装：删除所选磁盘的全部的分區，全新分区安装"
Write-Host "  [2] 保留分区安装：只格式化一个选定分区，其他分区数据保留"
$installMode = Read-Choice "选择安装模式" 1 2 1

Write-Host ""
if ($installMode -eq 1) {
    Write-Warn "警告：整盘安装将删除磁盘 $diskNum 上的全部分区和数据！"
} else {
    Write-Warn "警告：保留安装将格式化你选定的系统分区（该分区数据丢失），其他分区不受影响。"
}
$confirm = Read-Host '确认继续请输入 YES（区分大小写）'
if ($confirm -cne "YES") {
    Write-Host "已取消。"
    exit 0
}

# ---------- 7. 固件类型 ----------
$fwType = 2  # 默认 UEFI
try {
    $fwType = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control").PEFirmwareType
} catch {}
$isUefi = ($fwType -eq 2)
Write-Step ("固件类型: " + ($isUefi ? "UEFI" : "传统 BIOS"))

# ---------- 8. 准备目标分区 ----------
if ($installMode -eq 1) {
    # --- 模式1：整盘清空，diskpart 按模板重建 ---
    $tplName = if ($isUefi) { "diskpart-uefi.txt" } else { "diskpart-bios.txt" }
    $tplPath = Join-Path $ScriptDir $tplName
    $tplContent = Get-Content $tplPath -Raw
    $tplContent = $tplContent -replace "select disk 0", "select disk $diskNum"
    $tmpTpl = Join-Path $env:TEMP "diskpart-run.txt"
    $tplContent | Set-Content $tmpTpl -Encoding ASCII
    Write-Step "正在分区（diskpart 整盘重建）..."
    diskpart /s $tmpTpl | Out-Null
    if (-not (Test-Path "W:\")) {
        Write-Err "分区失败：未找到 W: 盘，请检查 diskpart 输出后重试。"
        exit 1
    }
    Write-Ok "分区完成（系统盘 W:，EFI 分区 S:）"
} else {
    # --- 模式2：保留其他分区，只格式化选定分区 ---
    Write-Step "保留分区安装：选择系统目标分区"
    $candidates = @($parts | Where-Object {
        $_.GptType -notin @($GuidEfi, $GuidMsr, $GuidRecovery)
    })
    if ($candidates.Count -eq 0) {
        Write-Err "该磁盘上没有可用的数据分区，请改用整盘安装。"
        exit 1
    }
    Write-Host ""
    Write-Host "  可选分区（序号对应上表，EFI/MSR/恢复分区已排除）："
    foreach ($c in $candidates) {
        $size = "{0:N1} GB" -f ($c.Size / 1GB)
        Write-Host ("  [{0}] 分区 {0}  {1}" -f $c.PartitionNumber, $size)
    }
    $partNum = Read-Choice "输入分区序号" 1 999 $candidates[0].PartitionNumber
    $target = $candidates | Where-Object { $_.PartitionNumber -eq $partNum } | Select-Object -First 1
    if (-not $target) {
        Write-Err "无效的分区序号。"
        exit 1
    }
    $tSize = "{0:N1} GB" -f ($target.Size / 1GB)
    if ($target.Size -lt 40GB) {
        Write-Warn "该分区仅 $tSize，Windows 建议至少 64GB，空间不足可能安装失败"
    }
    Write-Step ("正在格式化分区 {0}（{1}）为 NTFS..." -f $partNum, $tSize)
    try {
        Format-Volume -Partition $target -FileSystem NTFS -NewFileSystemLabel "Windows" -Confirm:$false -Force -ErrorAction Stop | Out-Null
    } catch {
        Write-Err "格式化失败: $_"
        exit 1
    }
    Set-DriveLetter $diskNum $partNum "W"
    if (-not (Test-Path "W:\")) {
        Write-Err "盘符分配失败。"
        exit 1
    }
    if ($isUefi) {
        $efi = $parts | Where-Object { $_.GptType -eq $GuidEfi } | Select-Object -First 1
        if (-not $efi) {
            Write-Err "UEFI 模式下未找到 EFI 系统分区，无法写入引导，请改用整盘安装。"
            exit 1
        }
        Set-DriveLetter $diskNum $efi.PartitionNumber "S"
        Write-Ok ("复用现有 EFI 系统分区（分区 {0}）" -f $efi.PartitionNumber)
    } else {
        try { Set-Partition -DiskNumber $diskNum -PartitionNumber $partNum -IsActive $true -ErrorAction Stop } catch {}
    }
    Write-Ok "目标分区就绪（W:），其他分区数据保留"
}

# ---------- 9. 获取镜像文件 ----------
$wimPath = $null
$downloaded = $null
$proto = ($img.protocol ?? "smb").ToLower()

if ($proto -eq "smb") {
    Write-Step "通过 SMB 直读镜像（无需下载）"
    $share = $img.smb_share
    if ([string]::IsNullOrWhiteSpace($share)) {
        Write-Err "清单中未配置 smb_share，无法使用 SMB 方式。"
        exit 1
    }
    # 先断开可能存在的旧连接
    net use Z: /delete 2>$null | Out-Null
    $netArgs = @("use", "Z:", $share)
    if ($img.smb_user) { $netArgs += @("/user:$($img.smb_user)", $img.smb_pass) }
    & net @netArgs | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Err "SMB 共享连接失败: $share（检查服务端 Samba/共享配置与网络）"
        exit 1
    }
    $wimPath = "Z:\$($img.file)"
    if (-not (Test-Path $wimPath)) {
        Write-Err "共享中未找到镜像文件: $wimPath"
        exit 1
    }
    Write-Ok "已挂载 $share"
} else {
    Write-Step "通过 HTTP 下载镜像（BITS 断点续传）"
    $url = $img.http_url
    if ([string]::IsNullOrWhiteSpace($url)) {
        Write-Err "清单中未提供 http_url，无法下载。"
        exit 1
    }
    $destDir = "W:\_netinstall"
    New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    $dest = Join-Path $destDir $img.file
    Write-Host "  下载: $url"
    Write-Host "  保存: $dest"
    $dlOk = $false
    try {
        Import-Module BitsTransfer -ErrorAction Stop
        Start-BitsTransfer -Source $url -Destination $dest -Description "下载系统镜像" -ErrorAction Stop
        $dlOk = $true
    } catch {
        Write-Warn "BITS 不可用，改用备用下载器: $_"
    }
    if (-not $dlOk) {
        try {
            if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
                & curl.exe -L -C - --retry 3 -o $dest $url
                if ($LASTEXITCODE -ne 0) { throw "curl 下载失败" }
            } else {
                Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
            }
            $dlOk = $true
        } catch {
            Write-Err "镜像下载失败: $_"
            exit 1
        }
    }
    # SHA-256 校验
    if ($img.sha256 -and $img.sha256 -notlike "*请替换*") {
        Write-Step "校验镜像 SHA-256..."
        $hash = (Get-FileHash $dest -Algorithm SHA256).Hash
        if ($hash -ne $img.sha256.ToUpper()) {
            Write-Err "校验失败！文件可能损坏或被篡改，已终止安装。"
            exit 1
        }
        Write-Ok "校验通过"
    } else {
        Write-Warn "清单未提供 SHA-256，跳过校验"
    }
    $wimPath = $dest
    $downloaded = $dest
}

# ---------- 10. DISM 释放镜像 ----------
Write-Step ("正在释放镜像到 W:（索引 {0}），请耐心等待..." -f $img.index)
$idx = if ($img.index) { $img.index } else { 1 }
& dism /Apply-Image /ImageFile:$wimPath /Index:$idx /ApplyDir:W:\
if ($LASTEXITCODE -ne 0) {
    Write-Err "DISM 释放失败，请检查镜像文件与索引号。"
    exit 1
}
Write-Ok "镜像释放完成"

# ---------- 11. 写入引导 ----------
Write-Step "写入系统引导（bcdboot）"
if ($isUefi) {
    & W:\Windows\System32\bcdboot W:\Windows /s S: /f UEFI
} else {
    & W:\Windows\System32\bcdboot W:\Windows /s W: /f BIOS
}
if ($LASTEXITCODE -ne 0) {
    Write-Err "bcdboot 写入引导失败。"
    exit 1
}
Write-Ok "引导写入完成"

# ---------- 12. 可选：注入驱动 ----------
$drvDir = "X:\NetInstall\Drivers"
if (Test-Path $drvDir) {
    Write-Step "检测到驱动目录，正在注入驱动..."
    & dism /Image:W:\ /Add-Driver /Driver:$drvDir /Recurse
    Write-Ok "驱动注入完成（详见 DISM 输出）"
} else {
    Write-Host "  未发现 X:\NetInstall\Drivers，跳过驱动注入" -ForegroundColor DarkGray
}

# ---------- 13. 清理与上报 ----------
if ($downloaded -and (Test-Path $downloaded)) {
    Remove-Item $downloaded -Force
    Write-Ok "已清理下载的临时镜像文件"
}
if ($proto -eq "smb") {
    net use Z: /delete 2>$null | Out-Null
}
try {
    $report = @{
        event        = "install_completed"
        image_id     = $img.id
        disk         = $diskNum
        install_mode = ($installMode -eq 1 ? "full_wipe" : "keep_partitions")
        firmware     = ($isUefi ? "UEFI" : "BIOS")
        computer     = $env:COMPUTERNAME
    } | ConvertTo-Json -Compress
    Invoke-RestMethod -Method Post -Uri "$base/api/report" `
        -Body $report -ContentType "application/json" -TimeoutSec 10 | Out-Null
    Write-Ok "已向服务端上报安装结果"
} catch {
    Write-Warn "上报服务端失败（不影响安装）: $_"
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  安装完成！10 秒后自动重启进入新系统" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Start-Sleep -Seconds 10
wpeutil reboot
