# WinPE 网络安装 · Windows 版"互联网恢复"（自建版）

macOS 有互联网恢复：开机按组合键，联网直接下载安装系统。Windows 官方没有这个能力——本项目自己搭一套：**WinPE 启动盘/ISO 开机 → 联网 → 从自建服务端拉镜像 → 自动分区释放 → 重启进新系统**。

```
  目标机器（WinPE）                    服务端（任意 Linux/Windows）
 ┌─────────────────┐    HTTP(SMB)    ┌──────────────────────┐
 │ 1. DHCP 获取 IP  │ ────────────► │ netinstall_server.py │
 │ 2. 拉 /api/manifest│              │  ├─ manifest.json   │
 │ 3. 选镜像        │               │  └─ images/*.wim     │
 │ 4. diskpart 分区 │ ────────────► │ (可选) Samba 共享    │
 │ 5. SMB直读/HTTP下载│              │ 供 DISM 直接释放     │
 │ 6. DISM释放+bcdboot│              └──────────────────────┘
 │ 7. 上报+重启     │
 └─────────────────┘
```

## 目录结构

```
winpe-netinstall/
├── server/
│   ├── netinstall_server.py   # 服务端：Python 标准库，无第三方依赖
│   ├── images/                # 镜像库：放 .wim/.esd + manifest.json
│   │   └── manifest.example.json
│   └── samba-example.conf     # Samba 共享示例（SMB 直读方式用）
├── client/
│   ├── Build-WinPE.ps1        # 在 Windows+ADK 上构建 WinPE 启动介质
│   └── winpe-files/
│       ├── NetInstall.ps1     # WinPE 内运行的安装主程序
│       ├── startnet.cmd       # WinPE 开机自启动入口
│       ├── diskpart-uefi.txt  # UEFI 分区模板
│       ├── diskpart-bios.txt  # BIOS 分区模板
│       └── server.txt         # 服务端地址（构建时写入，可现场修改）
└── docs/
    └── ARCHITECTURE.md        # 架构设计文档
```

## 快速开始

### 1. 启动服务端（任意有 Python3 的机器）

```bash
cd server
cp images/manifest.example.json images/manifest.json  # 按实际修改
python3 netinstall_server.py --dir ./images --port 8080
```

把 `.wim` 镜像拷进 `images/`，编辑 `manifest.json` 登记（`id`/`name`/`file`/`size`/`sha256` 必填；`protocol` 选 `smb` 或 `http`）。

> SMB 直读方式：在服务端配好 Samba（见 `samba-example.conf`），客户端无需下载整个镜像，DISM 直接从网络释放，千兆内网约 5–10 分钟装完。

### 2. 构建 WinPE 启动介质（需一台 Windows 10/11 + 安装 ADK 与 WinPE 插件）

```powershell
cd client
.\Build-WinPE.ps1 -Server "192.168.1.10:8080" -Iso "C:\iso\netinstall.iso"
# 或直接制作启动优盘（一键）：
.\Build-WinPE.ps1 -Server "192.168.1.10:8080" -UsbDrive "E:"
# 全定制示例：
.\Build-WinPE.ps1 -Server "192.168.1.10:8080" -UsbDrive "E:" `
  -Label "NETINSTALL" -MenuTimeout 5 -DefaultChoice 1 -DefaultMode 2 `
  -Wallpaper "C:\brand\winpe.jpg" -AddWifi
```

构建机会自动注入网络/PowerShell/DISM/存储/中文字体组件，把安装程序打进 `boot.wim`，
并把 `drivers\` 下的驱动打入 WIM（解决部分机器 WinPE 下网卡不识别）。

#### 优盘定制（无需重建）

制作完成后，优盘根目录会有一个 `NetInstall.ini`，直接用记事本改，插上即生效：

```ini
[Server]
Url=192.168.1.10:8080      ; 换服务端地址，改这里就行

[Boot]
MenuTimeout=10             ; 开机菜单等待秒数，0=直接执行默认项
DefaultChoice=1            ; 1=网络安装 2=WinPE命令行 3=重启 4=关机

[Install]
DefaultMode=0              ; 0=每次询问 1=整盘清空 2=保留分区
```

开机后会先显示启动菜单（安装 / 命令行维护模式 / 重启 / 关机），超时自动执行默认项。

### 3. 在虚拟机里先试（推荐 Hyper-V / VMware）

1. 新建虚拟机（UEFI 固件，内存 ≥ 4GB，空硬盘 ≥ 60GB）
2. 挂载 ISO 或从 U 盘启动，进 WinPE 后自动进入安装程序
3. 输入服务端地址 → 选镜像 → 输入 `YES` 确认 → 等待释放 → 自动重启

### 4. 正式使用

U 盘启动目标机器即可。安装程序会自动识别 UEFI/BIOS、列出服务端镜像清单与磁盘分区布局，全程中文菜单。两种安装模式：**整盘清空**（全新分区）或**保留分区**（只格式化选定的系统分区，D 盘等数据分区保留，UEFI 下复用现有 EFI 分区）。

## 和 macOS 互联网恢复的对比

| | macOS 互联网恢复 | 本方案 |
|---|---|---|
| 服务端 | 苹果官方 | 自建（内网/互联网均可） |
| 镜像来源 | 苹果服务器 | 自己维护的 WIM 库 |
| 驱动 | 内置全 | WinPE 网卡驱动需预置（`client/drivers/`） |
| 适用硬件 | 仅 Mac | 任意 x86 PC |
| 身份/授权 | Apple ID | 自定（当前原型无鉴权，见安全说明） |

## 安全说明（原型阶段）

- 当前服务端无鉴权，**仅限内网/可信网络使用**，不要直接暴露到公网。
- 生产化建议：HTTPS + Token 鉴权（服务端加反向代理即可）、镜像 SHA-256 强校验（客户端已实现）、服务端操作审计。
- 详见 `docs/ARCHITECTURE.md` 的"生产化路线"一节。

## 备选：iVentoy（一句话方案）

如果只是想"局域网内无脑装 ISO"，不用本项目也行：一台机器跑 [iVentoy](https://www.iventoy.com/)，ISO 扔进去，目标机器 PXE 启动直接装。缺点是只能装原版 ISO，做不了本项目的镜像清单管理、部门角色分发和安装上报。
