@echo off
setlocal EnableExtensions
chcp 65001 >nul
cd /d "%~dp0"
title 虚拟相机同步工作台 - VCam Sync Studio

echo ==========================================================
echo   虚拟相机同步工作台 (VCam Sync Studio) - 一键启动
echo ==========================================================

if not exist "main.py" goto :no_main
if not exist "app_launcher.pyw" goto :no_main

set "PY_CMD="
set "PYW_CMD="
python --version >nul 2>&1
if not errorlevel 1 (
    set "PY_CMD=python"
    for /f "delims=" %%i in ('where pythonw.exe 2^>nul') do (
        if not defined PYW_CMD set "PYW_CMD=%%i"
    )
)
if not defined PY_CMD (
    py -3 --version >nul 2>&1
    if not errorlevel 1 set "PY_CMD=py -3"
)
if not defined PY_CMD goto :no_python

%PY_CMD% -c "import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)" >nul 2>&1
if errorlevel 1 goto :old_python

set "VENV_PY=venv\Scripts\python.exe"
set "VENV_PYW=venv\Scripts\pythonw.exe"

if exist "%VENV_PY%" (
    "%VENV_PY%" -c "import fastapi, uvicorn, websockets, PIL, pydantic, importlib.metadata as m; m.version('python-multipart')" >nul 2>&1
    if not errorlevel 1 (
        echo [1/2] 虚拟环境依赖已就绪，正在启动桌面 App...
        start "" "%VENV_PYW%" "%~dp0app_launcher.pyw"
        exit /b 0
    )
)

%PY_CMD% -c "import fastapi, uvicorn, websockets, PIL, pydantic, importlib.metadata as m; m.version('python-multipart')" >nul 2>&1
if not errorlevel 1 (
    echo [1/2] 系统 Python 依赖已就绪，直接启动桌面 App...
    if defined PYW_CMD (
        start "" "%PYW_CMD%" "%~dp0app_launcher.pyw"
    ) else (
        %PY_CMD% run_local.py
    )
    exit /b 0
)

if not exist "%VENV_PY%" (
    echo [1/3] 正在创建 Python 虚拟环境...
    %PY_CMD% -m venv venv
    if errorlevel 1 goto :venv_fail
)

echo [2/3] 正在安装依赖包，请稍候...
"%VENV_PY%" -m pip install -r requirements.txt -i https://pypi.tuna.tsinghua.edu.cn/simple
if errorlevel 1 (
    echo [提示] 清华镜像安装失败，正在尝试官方 PyPI 源...
    "%VENV_PY%" -m pip install -r requirements.txt
    if errorlevel 1 goto :pip_fail
)

echo [3/3] 正在启动桌面 App 窗口...
if exist "%VENV_PYW%" (
    start "" "%VENV_PYW%" "%~dp0app_launcher.pyw"
    exit /b 0
)
"%VENV_PY%" run_local.py
exit /b 0

:no_main
echo [错误] 找不到 main.py 或 app_launcher.pyw！
pause
exit /b 1

:no_python
echo [错误] 未检测到 Python 3.10+，请先安装 Python 并勾选 Add python.exe to PATH。
pause
exit /b 1

:old_python
echo [错误] 当前 Python 版本低于 3.10，请升级后重试。
%PY_CMD% --version
pause
exit /b 1

:venv_fail
echo [错误] 创建虚拟环境失败。
pause
exit /b 1

:pip_fail
echo [错误] 依赖安装失败，请检查网络连接。
pause
exit /b 1
