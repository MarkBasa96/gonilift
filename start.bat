@echo off
title Gonilift - close this window to stop it
rem Starts the local Gonilift server and opens it in the browser.
rem Only reachable from this PC (127.0.0.1). Close this window to stop it.
curl -s -o nul http://127.0.0.1:8765/api/songs && (start "" http://127.0.0.1:8765 & exit /b)
cd /d "%~dp0app"
start "" cmd /c "timeout /t 4 >nul & start http://127.0.0.1:8765"
echo Gonilift is running at http://127.0.0.1:8765
echo Close this window to stop it.
"%~dp0.venv\Scripts\python.exe" -m uvicorn server:app --host 127.0.0.1 --port 8765 --log-level warning
