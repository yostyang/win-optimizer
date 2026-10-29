@echo off
rem Debug launcher: keeps the console open so errors are visible
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -NoExit -File "%~dp0WinOptimizer.ps1"
