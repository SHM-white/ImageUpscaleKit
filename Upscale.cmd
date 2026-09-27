@echo off
cd /d "%~dp0"
if "%~1"=="" (echo Drag an image or folder onto this file.& pause & exit /b 1)
pwsh.exe -NoProfile -File "%~dp0Upscale.ps1" -InputPath "%~1"
pause
