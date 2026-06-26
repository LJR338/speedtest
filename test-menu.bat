@echo off
chcp 65001 >nul
cd /d "%~dp0"
PowerShell -NoProfile -ExecutionPolicy Bypass -File "%~dp0test-menu.ps1" -FeedHistory
