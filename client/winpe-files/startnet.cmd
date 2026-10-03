@echo off
rem ============================================================
rem WinPE 网络安装 - 启动入口（含开机菜单）
rem 由 Build-WinPE.ps1 追加到 boot.wim 的 Windows\System32\startnet.cmd 末尾
rem 启动流程：wpeinit -> startnet.cmd -> 本菜单 -> NetInstall.ps1
rem 定制：优盘根目录 NetInstall.ini（MenuTimeout / DefaultChoice）
rem ============================================================

chcp 65001 >nul
wpeinit

rem ---- 定位优盘（NetInstall.ini 所在盘）----
set USBDRV=
for %%L in (D E F G H I J K L M N O P Q R S T U V W Y Z) do (
    if exist "%%L:\NetInstall.ini" set USBDRV=%%L:
)

rem ---- 读开机菜单配置（默认值）----
set MENU_TIMEOUT=10
set DEFAULT_CHOICE=1
if defined USBDRV (
    for /f "tokens=2 delims==" %%a in ('findstr /b /c:"MenuTimeout=" "%USBDRV%\NetInstall.ini" 2^>nul') do set MENU_TIMEOUT=%%a
    for /f "tokens=2 delims==" %%a in ('findstr /b /c:"DefaultChoice=" "%USBDRV%\NetInstall.ini" 2^>nul') do set DEFAULT_CHOICE=%%a
)

echo.
echo  ============================================================
echo   Windows 网络安装（类 macOS 互联网恢复 · 自建版）
echo  ============================================================
echo.
echo   [1] 网络安装 Windows（推荐）
echo   [2] WinPE 命令行（维护模式）
echo   [3] 重启
echo   [4] 关机
echo.
if "%MENU_TIMEOUT%"=="0" goto :auto
choice /c 1234 /n /t %MENU_TIMEOUT% /d %DEFAULT_CHOICE% /m "请选择 [%MENU_TIMEOUT% 秒后自动执行 %DEFAULT_CHOICE%]: "
if errorlevel 4 goto :shutdown
if errorlevel 3 goto :reboot
if errorlevel 2 goto :shell
goto :install

:auto
if "%DEFAULT_CHOICE%"=="4" goto :shutdown
if "%DEFAULT_CHOICE%"=="3" goto :reboot
if "%DEFAULT_CHOICE%"=="2" goto :shell
goto :install

:install
echo.
echo  正在启动网络安装程序 ...
echo.
if defined USBDRV (
    powershell -executionpolicy bypass -file X:\NetInstall\NetInstall.ps1 -UsbDrive "%USBDRV%"
) else (
    powershell -executionpolicy bypass -file X:\NetInstall\NetInstall.ps1
)
echo.
echo  安装程序已退出。如需重新运行，请执行：
echo    powershell -executionpolicy bypass -file X:\NetInstall\NetInstall.ps1
echo.
goto :shell

:reboot
wpeutil reboot

:shutdown
wpeutil shutdown

:shell
cmd
