@echo off
rem ===========================================================================
rem  DST Engine launcher  (port 8765)
rem
rem  Why this file exists:
rem    deploy/start.sh spawns the server with nohup, which does NOT survive the
rem    calling shell in some environments -> the server dies right after the
rem    health check passes (silent). This script runs the server in the
rem    FOREGROUND of its own console window, so "window open == server alive".
rem
rem  Why the port check below prints the owner PID:
rem    The engine refuses to start when 8765 is already bound (Windows
rem    SO_REUSEADDR allows two listeners on one port -> connections land on a
rem    random one = silent split brain). The old message only said "stop the old
rem    process", which forces the user to go hunt for a PID. Now it shows the
rem    PID + process name and offers to save-and-stop it in one step.
rem ===========================================================================
chcp 65001 >nul
setlocal enabledelayedexpansion
cd /d "%~dp0.."

set "PY=C:\Users\admin\.workbuddy\binaries\python\envs\default\Scripts\python.exe"
set "PORT=8765"

if not exist "%PY%" (
    echo.
    echo [X] Python not found:
    echo     %PY%
    echo     This interpreter is the one that can import lupa.
    echo.
    pause
    exit /b 2
)

rem ---- port probe: find whoever is listening on %PORT% ---------------------
set "OPID="
for /f "tokens=5" %%a in ('netstat -ano ^| findstr ":%PORT%" ^| findstr "LISTENING"') do (
    if not defined OPID set "OPID=%%a"
)

if not defined OPID goto :launch

set "ONAME="
for /f "tokens=1 delims=," %%n in ('tasklist /FI "PID eq !OPID!" /FO CSV /NH 2^>nul') do (
    if not defined ONAME set "ONAME=%%~n"
)
if not defined ONAME set "ONAME=(not found - it may have just exited)"

echo.
echo ==========================================================
echo   Port %PORT% is ALREADY IN USE
echo ==========================================================
echo   PID   : !OPID!
echo   Name  : !ONAME!
echo.
echo   Usually this is a server left running from a previous
echo   session. Two listeners on one port would make your
echo   browser land on a random one, so the engine refuses
echo   to start a second copy.
echo ----------------------------------------------------------
echo   1 = Save the world, stop it, then start fresh  (recommended)
echo   2 = Exit and keep the running server
echo ==========================================================
echo.
choice /c 12 /n /m "  Choose [1/2]: "
if errorlevel 2 goto :bye

echo.
echo   Saving world before stopping ...
"%PY%" -c "import urllib.request as u; u.urlopen('http://127.0.0.1:%PORT%/save', timeout=25)" 2>nul
if errorlevel 1 (
    echo   [i] No live /save response ^(server already dead or hung^) - stopping anyway.
) else (
    echo   [OK] World saved.
)
taskkill /F /PID !OPID! >nul 2>&1
if errorlevel 1 (
    echo   [X] Could not stop PID !OPID!  ^(permission?^)
    echo       Try running this file as Administrator.
    echo.
    pause
    exit /b 3
)
ping -n 3 127.0.0.1 >nul

set "STILL="
for /f "tokens=5" %%a in ('netstat -ano ^| findstr ":%PORT%" ^| findstr "LISTENING"') do (
    if not defined STILL set "STILL=%%a"
)
if defined STILL (
    echo   [X] Port %PORT% STILL has a listener ^(PID !STILL!^).
    echo       Refusing to start a second copy.
    echo.
    pause
    exit /b 4
)
echo   [OK] Port %PORT% is free.

:launch
echo.
echo ==========================================================
echo   DST Engine  -  port %PORT%
echo ==========================================================
echo   Client : http://127.0.0.1:%PORT%/
echo   Status : http://127.0.0.1:%PORT%/healthz
echo.
echo   Keep this window OPEN while playing.
echo   Closing it stops the server.
echo ==========================================================
echo.

"%PY%" -u rt\server.py --port %PORT% --hz 30 --save-file deploy\logs\world-%PORT%.json

echo.
echo Server exited ^(code %errorlevel%^).
echo If it crashed, look at deploy\logs\server-*.log
echo.
pause
exit /b 0

:bye
echo.
echo Kept the running server. Open http://127.0.0.1:%PORT%/
echo.
pause
exit /b 0
