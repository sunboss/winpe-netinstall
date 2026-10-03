@echo off
rem WinPE 网络安装 - 启动入口
rem 由 Build-WinPE.ps1 复制到 boot.wim 的 Windows\System32\startnet.cmd 末尾
rem WinPE 启动流程：wpeinit -> startnet.cmd -> 本脚本 -> NetInstall.ps1

chcp 65001 >nul
wpeinit

echo.
echo  ============================================================
echo   Windows 网络安装（类 macOS 互联网恢复 · 自建版）
echo  ============================================================
echo.
echo  正在启动安装程序 ...
echo.

powershell -executionpolicy bypass -file X:\NetInstall\NetInstall.ps1

echo.
echo  安装程序已退出。如需重新运行，请执行：
echo    powershell -executionpolicy bypass -file X:\NetInstall\NetInstall.ps1
echo.
cmd
