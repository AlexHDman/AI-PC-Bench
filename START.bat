@echo off
chcp 65001 >nul
setlocal
set "PYTHONUTF8=1"
set "PYTHONIOENCODING=utf-8"
title EXPC AI Benchmark Portable

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Start-Benchmark.ps1"

set "EXIT_CODE=%ERRORLEVEL%"

echo.
powershell.exe -NoLogo -NoProfile -Command "$utf8=[System.Text.UTF8Encoding]::new($false); [Console]::InputEncoding=$utf8; [Console]::OutputEncoding=$utf8; [void](Read-Host 'Нажмите Enter для выхода')"

exit /b %EXIT_CODE%
