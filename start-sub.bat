@echo off
echo ============================================
echo  这是后台脚本，日常使用请双击「启动优选IP.bat」
echo  继续执行: 启动订阅后台
echo ============================================
cd /d "%~dp0"
powershell -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0start-sub.ps1"
