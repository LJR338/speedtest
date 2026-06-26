@echo off
cd /d "%~dp0"
powershell -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0start-sub.ps1"
