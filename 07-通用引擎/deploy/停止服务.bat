@echo off
rem ===========================================================================
rem  DST Engine stopper  (port 8765)
rem
rem  Finds the listener by PORT, not by deploy/logs/server.pid.
rem  Why: the pid file goes stale as soon as the server is started some other
rem  way (background task, manual python, crash). Stopping "the PID I remember"
rem  then either fails or kills the wrong thing. The port is the only fact.
rem
rem  Saves the world first: taskkill /F is a hard kill and the periodic autosave
rem  is every 30 s, so killing first would drop up to 30 s of progress.
rem ===========================================================================
chcp 65001 >nul
setlocal enabledelayedexpansion
cd /d "%~dp0.."

set "PY=C:\Users\admin\.workbuddy\binaries\python\envs\default\Scripts\python.exe"
set "PORT=8765"

set "PIDS="
for /f "tokens=5" %%a in ('netstat -ano ^| findstr ":%PORT%" ^| findstr "LISTENING"') do (
    echo !PIDS! | findstr /C:"%%a" >nul || set "PIDS=!PIDS! %%a"
)

if not defined PIDS (
    echo.
    echo   Nothing is listening on port %PORT% - already stopped.
    echo.
    pause
    exit /b 0
)

echo.
echo   Listener^(s^) on port %PORT%:!PIDS!
echo.
echo   Saving world first ...
if exist "%PY%" (
    "%PY%" -c "import urllib.request as u; u.urlopen('http://127.0.0.1:%PORT%/save', timeout=25)" 2>nul
    if errorlevel 1 (
        echo   [i] No response from /save - stopping anyway.
    ) else (
        echo   [OK] World saved.
    )
) else (
    echo   [i] Python not found, skipping save.
)

for %%p in (!PIDS!) do (
    echo   Stopping PID %%p ...
    taskkill /F /PID %%p >nul 2>&1
    if errorlevel 1 (
        echo     [X] Failed - permission? Try "Run as Administrator".
    ) else (
        echo     [OK] Stopped.
    )
)

ping -n 3 127.0.0.1 >nul
set "LEFT="
for /f "tokens=5" %%a in ('netstat -ano ^| findstr ":%PORT%" ^| findstr "LISTENING"') do set "LEFT=1"

if defined LEFT (
    echo.
    echo   [X] Port %PORT% still has a listener. Check with:
    echo       netstat -ano ^| findstr :%PORT%
    echo.
    pause
    exit /b 1
)

echo.
echo   [OK] Port %PORT% is free.
echo.
pause
exit /b 0
