@echo off
cd /d "%~dp0"
where pwsh.exe >nul 2>nul || (echo PowerShell 7 ^(pwsh^) is required.& pause & exit /b 1)
pwsh.exe -NoProfile -STA -File "%~dp0GUI.ps1"
