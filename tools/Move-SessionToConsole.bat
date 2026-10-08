@echo off
REM Action for the scheduled task triggered "On disconnect from user session (remote)".
REM Moves the disconnected session to the console so it stays Active for GUI automation.
REM Task must run as the logged-on user with "Run with highest privileges" (tscon needs admin).

set "LOGDIR=%~dp0..\logs"
if not exist "%LOGDIR%" mkdir "%LOGDIR%"
set "LOG=%LOGDIR%\auto-console.log"

REM Wait ~3 seconds for the RDP connection to finish tearing down.
REM (timeout.exe fails without a console input, so ping is used as a sleep.)
ping -n 4 127.0.0.1 >nul

set "SID="
for /f %%i in ('powershell -NoProfile -NonInteractive -Command "(Get-Process -Id $PID).SessionId"') do set "SID=%%i"
if "%SID%"=="" (
    echo %date% %time% ERROR could not determine session id>> "%LOG%"
    exit /b 1
)

%windir%\System32\tscon.exe %SID% /dest:console
echo %date% %time% session=%SID% tscon exit=%errorlevel%>> "%LOG%"
