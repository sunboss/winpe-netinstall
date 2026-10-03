# drivers\（可选）

把目标机器的驱动（.inf 格式，含子目录）放到这里，
`Build-WinPE.ps1` 构建时会自动用 DISM 打入 `boot.wim`。

最常见需求：**网卡驱动**（WinPE 下不认网卡就无法联网安装）。
去主板/网卡官网下载对应 Windows 版本的驱动，解压后把含 .inf 的文件夹拷进来即可。

> 注意：构建机会在 Windows 上运行 DISM /Add-Driver /Recurse，本目录只是驱动源。
