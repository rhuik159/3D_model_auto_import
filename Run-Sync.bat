@echo off
REM ============================================================================
REM  3D Model Auto Import - launcher
REM  (Comments are ASCII on purpose: a .bat is read with the console codepage,
REM   so non-ASCII text here breaks depending on the machine's locale.)
REM
REM  Purpose
REM    - Entry point for Windows Task Scheduler (avoids quoting mistakes)
REM    - Double-clickable from Explorer
REM    - Bypasses ExecutionPolicy so an unsigned .ps1 always runs
REM
REM  Usage
REM    Run-Sync.bat              normal run
REM    Run-Sync.bat -WhatIf      dry run, changes nothing
REM    Run-Sync.bat -SkipSync    skip robocopy, scan only
REM
REM  Exit codes are passed through from the PowerShell script:
REM    0=OK  1=warning  2=config error  3=unreachable  4=scan failed
REM    5=batch failed  6=already running  10=exception
REM ============================================================================

setlocal

REM Anchor to this file's folder. Task Scheduler's working directory
REM is not reliable, so never depend on the current directory.
set "SCRIPT_DIR=%~dp0"
set "PS_SCRIPT=%SCRIPT_DIR%Run-3DModelSync.ps1"

if not exist "%PS_SCRIPT%" (
    echo [ERROR] Script not found: "%PS_SCRIPT%"
    exit /b 2
)

REM Prefer PowerShell 7 when present, otherwise Windows PowerShell 5.1.
REM The pipeline is verified on both, so either is fine.
set "PS_EXE=powershell.exe"
where pwsh.exe >nul 2>&1 && set "PS_EXE=pwsh.exe"

"%PS_EXE%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%PS_SCRIPT%" %*
set "RC=%ERRORLEVEL%"

echo(
echo(Exit code = %RC%

REM NOTE: deliberately no "pause" here.
REM Auto-detecting a double-click is unreliable, and a stray pause under Task
REM Scheduler would hang the job until its time limit -- a silent daily
REM failure. Never blocking is the safe default.
REM For double-click use, Run-Sync-Interactive.bat wraps this and pauses.

exit /b %RC%
