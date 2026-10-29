@echo off
rem Windows Optimizer launcher (ASCII only on purpose)
set "WINOPT_DIR=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath $env:WINOPT_DIR | Unblock-File -ErrorAction SilentlyContinue" >nul 2>&1
start "" powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0WinOptimizer.ps1"
