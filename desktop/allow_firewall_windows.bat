@echo off
chcp 65001 >nul
echo ==========================================================
echo   放行 Windows 防火墙局域网端口 (TCP 18760 / UDP 18766)
echo   让同一 Wi-Fi 下的 iPhone 顺利扫码并同步文件
echo ==========================================================

net session >nul 2>&1
if errorlevel 1 (
    echo [提示] 正在请求管理员权限以添加防火墙规则...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b 0
)

netsh advfirewall firewall delete rule name="VCam Sync Studio TCP 18760" >nul 2>&1
netsh advfirewall firewall delete rule name="VCam Sync Studio UDP 18766" >nul 2>&1

netsh advfirewall firewall add rule name="VCam Sync Studio TCP 18760" dir=in action=allow protocol=TCP localport=18760 profile=private,domain
netsh advfirewall firewall add rule name="VCam Sync Studio UDP 18766" dir=in action=allow protocol=UDP localport=18766 profile=private,domain

if errorlevel 1 (
    echo [失败] 添加防火墙规则失败，请手动检查 Windows Defender 防火墙。
) else (
    echo [完成] 已放行专用/域网络 TCP 18760 与 UDP 18766 端口！
)
pause
