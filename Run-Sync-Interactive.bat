@echo off
REM ============================================================================
REM  3D Model Auto Import - double-click launcher
REM
REM  Same as Run-Sync.bat but keeps the window open so you can read the result.
REM  Use this one from Explorer; use Run-Sync.bat for Task Scheduler.
REM
REM  Tip: to preview without changing anything, run from a prompt:
REM         Run-Sync.bat -WhatIf
REM ============================================================================

setlocal

call "%~dp0Run-Sync.bat" %*
set "RC=%ERRORLEVEL%"

echo(
if "%RC%"=="0" echo(Completed successfully.
if "%RC%"=="1" echo(Completed with warnings - check the log in logs\.
if %RC% GEQ 2  echo(FAILED - see logs\ for details.
echo(

pause
exit /b %RC%
