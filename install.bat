@echo off
rem Gonilift one-click installer: double-click this file.
rem All the work is in tools\install.ps1 (readable, safe to run again).
title Gonilift installer
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\install.ps1" %*
echo.
pause
