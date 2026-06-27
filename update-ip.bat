@echo off
echo ============================================
echo  这是后台脚本，日常使用请双击「启动优选IP.bat」
echo  继续执行: 更新优选 (update-hosts-asian)
echo ============================================
cd /d "%~dp0"
PowerShell -NoProfile -ExecutionPolicy Bypass -File "%~dp0update-hosts-asian.ps1"
pause
