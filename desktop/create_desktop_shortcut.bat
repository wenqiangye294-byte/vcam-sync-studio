@echo off
chcp 65001 >nul
setlocal EnableDelayedExpansion

set "PROJECT_DIR=%~dp0"
if "%PROJECT_DIR:~-1%"=="\" set "PROJECT_DIR=%PROJECT_DIR:~0,-1%"

set "PYTHONW="
if exist "%PROJECT_DIR%\venv\Scripts\pythonw.exe" (
    set "PYTHONW=%PROJECT_DIR%\venv\Scripts\pythonw.exe"
) else (
    for /f "delims=" %%i in ('where pythonw.exe 2^>nul') do (
        if not defined PYTHONW set "PYTHONW=%%i"
    )
)

if not defined PYTHONW (
    echo [错误] 未找到 pythonw.exe，请先安装 Python 3.10+。
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ws = New-Object -ComObject WScript.Shell; " ^
  "$desktop = [Environment]::GetFolderPath('Desktop'); " ^
  "$lnk = $ws.CreateShortcut((Join-Path $desktop '虚拟相机同步工作台.lnk')); " ^
  "$lnk.TargetPath = $env:PYTHONW; " ^
  "$lnk.Arguments = '\"' + (Join-Path $env:PROJECT_DIR 'app_launcher.pyw') + '\"'; " ^
  "$lnk.WorkingDirectory = $env:PROJECT_DIR; " ^
  "$lnk.IconLocation = (Join-Path $env:PROJECT_DIR 'static\app.ico') + ',0'; " ^
  "$lnk.Description = 'VCam Sync Studio - 电脑端虚拟相机同步工作台'; " ^
  "$lnk.Save()"

if errorlevel 1 (
    echo [错误] 创建桌面快捷方式失败。
    pause
    exit /b 1
)

echo [完成] 已在桌面创建 "虚拟相机同步工作台" 快捷方式，双击即可无黑框启动！
pause
