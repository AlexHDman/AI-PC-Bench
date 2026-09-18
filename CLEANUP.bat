@echo off
chcp 65001 >nul
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Cleanup-Benchmark.ps1"
exit /b %ERRORLEVEL%
