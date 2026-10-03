# 架构设计

## 1. 设计目标

复刻 macOS 互联网恢复的核心体验——**裸机开机、联网、选系统、自动装完**——但服务端完全自建，适配 Windows 生态（硬件多样、需自维护驱动与镜像）。

非目标：替代 WDS/MDT/SCCM 等成熟企业方案；本项目定位是轻量、可魔改、能快速验证的原型。

## 2. 组件

### 2.1 服务端 `server/netinstall_server.py`

Python 3 标准库实现，无第三方依赖，方便丢到任何机器上跑。

| 接口 | 说明 |
|---|---|
| `GET /` | 状态页：镜像列表 + 快速开始 |
| `GET /api/manifest` | 镜像清单 JSON；服务端按请求 Host 自动补全 `http_url` |
| `GET /files/<name>` | 镜像下载；支持 `Range` 断点续传（BITS 依赖）；防目录穿越 |
| `POST /api/report` | 客户端上报安装结果，追加写入 `images/reports.log` |

`manifest.json` 字段：`id` / `name` / `file` / `size` / `sha256` / `index`（WIM 卷索引）/ `protocol`（`smb`\|`http`）/ `smb_share` / `description`。

### 2.2 客户端 WinPE

- **构建**：`client/Build-WinPE.ps1` 在 Windows+ADK 上执行，`copype` → 挂载 `boot.wim` → 注入组件（WMI/NetFX/Scripting/PowerShell/DismCmdlets/StorageWMI/SecureStartup/中文字体，可选 WiFi）→ 复制 `winpe-files/` → 改写 `startnet.cmd` → 生成 ISO/U 盘。
- **运行**：`NetInstall.ps1` 全流程：
  1. 检查 WinPE 环境 → `wpeutil InitializeNetwork`
  2. 读取 `server.txt`（可现场改）→ 3 次重试连通性
  3. 拉清单 → 数字菜单选镜像
  4. 枚举磁盘 → **显示分区布局**（序号/大小/盘符/类型/卷标）
  5. 选择安装模式 → 按模式二次确认（输入 `YES`）：
     - **整盘清空**：`diskpart` 按模板重建（UEFI：EFI 100MB + MSR 16MB + Windows；BIOS：单分区+active）
     - **保留分区**：只格式化选定的一个数据分区（EFI/MSR/恢复分区不可选），UEFI 下复用现有 EFI 分区写引导
  6. 读注册表 `PEFirmwareType` 判定 UEFI/BIOS
  7. 取镜像：
     - `smb`：`net use Z:` 挂载共享，DISM 直接从网络路径释放（不占本地空间）
     - `http`：BITS 下载（断点续传）→ `Get-FileHash` SHA-256 校验 → 释放 → 删除临时文件
  7. `dism /Apply-Image` → `bcdboot` 写引导 → 可选 `X:\NetInstall\Drivers` 驱动注入
  8. `POST /api/report` 上报 → `wpeutil reboot`

### 2.3 镜像获取方式对比

| 方式 | 优点 | 缺点 | 适用 |
|---|---|---|---|
| SMB 直读 | 不占客户端空间；速度最快 | 需同局域网+共享配置 | 内网批量装机 |
| HTTP 下载 | 可跨互联网；实现简单 | 需本地暂存（WIM 通常 4–8GB） | 分支机构/互联网 |

## 3. 网络需求

- 客户端 DHCP（WinPE 默认）；静态 IP 场景可在 WinPE 命令行先用 `netsh` 配置。
- 端口：HTTP 服务端口（默认 8080）、SMB 445（SMB 方式）。
- WinPE 网卡驱动：Intel/Realtek 主流网卡 WinPE 自带；小众网卡把 `.inf` 驱动放入 `client/drivers/`，构建时自动打入启动介质，安装时注入目标系统。

## 4. 与部门角色的结合（呼应镜像治理方案）

`manifest.json` 即"可安装基线目录"：财务/研发/前台各维护自己的 WIM 条目，客户端按需选择。更进一步可扩展清单字段 `role`，结合客户端机器资产编号自动推荐镜像——原型暂用手动选择。

## 5. 生产化路线（TODO）

1. **鉴权**：Nginx 反向代理 + Token（`Authorization` 头），客户端 `server.txt` 扩展为 `地址|token`。
2. **HTTPS**：内网 CA 或 Let's Encrypt，WinPE 需导入根证书（构建时注入）。
3. **unattend.xml**：DISM 释放后写入应答文件，实现 OOBE 全自动（跳过隐私设置页、预建本地管理员）。
4. **多播**：大批量并发时用 MDT/WDS 多播替代 HTTP 单播。
5. **审计**：`reports.log` 接入现有运维平台；服务端记录每次下载的 IP/镜像/耗时。
6. **Wi-Fi 安装**：构建加 `-AddWifi`，客户端增加 SSID/密码输入（需 WinPE-WiFi-Package，ADK 版本 ≥ 对应要求）。
