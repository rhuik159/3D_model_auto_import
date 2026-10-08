@echo off
REM Hand the current RDP session over to the console instead of disconnecting it.
REM The session stays Active, so GUI automation (SendInput) keeps working after RDP closes.
REM Run as Administrator from inside the RDP session. Use this instead of closing the RDP window.

net session >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Run this file as Administrator.
    pause
    exit /b 1
)

for /f %%i in ('powershell -NoProfile -Command "(Get-Process -Id $PID).SessionId"') do set SID=%%i
if "%SID%"=="" (
    echo [ERROR] Could not determine the current session id.
    pause
    exit /b 1
)

echo Moving session %SID% to the console. The RDP window will close now.
%windir%\System32\tscon.exe %SID% /dest:console
if errorlevel 1 (
    echo [ERROR] tscon failed with code %errorlevel%.
    pause
    exit /b 1
)
