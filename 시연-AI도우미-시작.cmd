@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo Eugene Rings AI helper: starting on http://localhost:8000 (Claude Code login, no API key)
powershell -NoProfile -ExecutionPolicy Bypass -File "server\local-helper.ps1" -Open
pause
