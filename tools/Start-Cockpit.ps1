#Requires -Version 5.1
<#
.SYNOPSIS
    EDM Library Cockpit 을 자동 로그인 설정으로 기동한다.

.DESCRIPTION
    5~6단계(3D Model Bulk Import / Import Mapping File)를 GUI 자동화하기 위한
    1단계다. 로그인 대화상자 없이 Cockpit 을 띄우고 창 핸들을 돌려준다.

    ★ 무인 실행 조건 ★
      로그인 설정이 -ds -dslicense -dsprodlib 로 만들어져 있어야
      대화상자가 뜨지 않는다 (Overview 가이드 p.96, p.107).
      설정이 그렇지 않으면 창이 떠도 로그인 단계에서 멈춘다.
      이 경우 -Recreate 스위치로 설정을 다시 만들 수 있다.

.PARAMETER ConfigName
    사용할 자동 로그인 설정 이름. 기본값 3d_model_import

.PARAMETER TimeoutSeconds
    창이 뜰 때까지 기다릴 최대 시간. 기본 120초.
    Cockpit 은 초기 기동에 시간이 걸린다 (플러그인 로드 + 서버 접속).

.PARAMETER Reuse
    이미 떠 있는 Cockpit 이 있으면 새로 띄우지 않고 그것을 돌려준다.

.EXAMPLE
    .\Start-Cockpit.ps1
    3d_model_import 설정으로 새 Cockpit 기동

.EXAMPLE
    .\Start-Cockpit.ps1 -Reuse
    이미 떠 있으면 재사용

.NOTES
    반환: PSCustomObject (Process, MainWindowHandle, MainWindowTitle, Reused)
    실패 시 예외를 던진다.
#>
[CmdletBinding()]
param(
    [string]$ConfigName = '3d_model_import',
    [int]$TimeoutSeconds = 120,
    [switch]$Reuse
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# 설치 경로는 툴 버전이 올라가면 바뀐다(EEVX.2.14.1 → EEVX.2.15 등).
# Common.SddHome.ps1 이 환경변수 → 최신 버전 순으로 찾아준다.
. (Join-Path $PSScriptRoot 'Common.SddHome.ps1')
$SddHome = Get-SddHome
$DmsBin = Join-Path $SddHome 'dms\bin'
$Launcher = Join-Path $DmsBin 'dmsdesktop.bat'
$AutoLogin = Join-Path $SddHome 'common\win64\bin\app-auto-login.exe'

function Write-Step {
    param([string]$Message, [string]$Level = 'Info')
    $color = switch ($Level) {
        'Warn' { 'Yellow' }
        'Error' { 'Red' }
        'Ok' { 'Green' }
        default { 'Gray' }
    }
    Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $Message) -ForegroundColor $color
    if ($Level -eq 'Warn') { $script:Diag.Add($Message) }
}
# 호출자(Step5)가 파이프라인 로그에 남기도록 경고 메시지를 모아 반환한다.
$script:Diag = New-Object System.Collections.Generic.List[string]

# Process.MainWindowHandle 은 RDP 가 끊긴 세션에서 0 으로 보이므로 EnumWindows 로 직접 창 제목을 읽는다.
if (-not ('CockpitWin' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class CockpitWin {
    private delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr h, StringBuilder sb, int max);
    public static string[] Titles(uint targetPid) {
        var list = new List<string>();
        EnumWindows((h, l) => {
            uint pid; GetWindowThreadProcessId(h, out pid);
            if (pid == targetPid) {
                var sb = new StringBuilder(512);
                GetWindowText(h, sb, 512);
                if (sb.Length > 0) list.Add(sb.ToString());
            }
            return true;
        }, IntPtr.Zero);
        return list.ToArray();
    }
}
'@
}

function Test-CockpitWindow {
    param([int]$ProcessId)
    @([CockpitWin]::Titles([uint32]$ProcessId) | Where-Object { $_ -like '*Xpedition EDM Library Cockpit*' }).Count -gt 0
}

# ---------------------------------------------------------------- 사전 점검
if (-not (Test-Path -LiteralPath $Launcher)) {
    throw "Cockpit 실행 스크립트를 찾을 수 없습니다: $Launcher"
}

Write-Step "로그인 설정 '$ConfigName' 확인 중..."
$listOut = & $AutoLogin -list 2>&1 | Out-String
$configLine = ($listOut -split "`n") | Where-Object { $_ -match "^\s*$([regex]::Escape($ConfigName))\s" }
if (-not $configLine) {
    Write-Step "설정 목록:" -Level Warn
    Write-Host $listOut
    throw "로그인 설정 '$ConfigName' 이 없습니다. app-auto-login 으로 먼저 만드세요."
}
Write-Step ("  " + ($configLine -replace '\s+', ' ').Trim()) -Level Ok

# ------------------------------------------------------- 기존 인스턴스 확인
$existing = @(Get-Process -Name 'xDMLibraryClient' -ErrorAction SilentlyContinue |
    Where-Object { Test-CockpitWindow -ProcessId $_.Id })

if ($existing.Count -gt 0) {
    if ($Reuse) {
        $p = $existing[0]
        Write-Step "이미 떠 있는 Cockpit 을 재사용합니다 (PID $($p.Id))" -Level Ok
        return [PSCustomObject]@{
            Process          = $p
            MainWindowHandle = $p.MainWindowHandle
            MainWindowTitle  = $p.MainWindowTitle
            Reused           = $true
            Diag             = @($script:Diag)
        }
    }
    Write-Step "이미 $($existing.Count) 개의 Cockpit 이 떠 있습니다. 새로 하나 더 띄웁니다." -Level Warn
    Write-Step "  (기존 것을 쓰려면 -Reuse 를 붙이세요)" -Level Warn
}

$before = @(Get-Process -Name 'xDMLibraryClient' -ErrorAction SilentlyContinue |
    ForEach-Object { $_.Id })

# ------------------------------------------------------------------- 기동
# dmsdesktop.bat 은 내부에서 start 로 javaw 를 띄우고 즉시 반환한다.
# 따라서 이 프로세스의 종료를 기다리는 것은 의미가 없고,
# 새로 생긴 xDMLibraryClient 프로세스를 폴링해야 한다.
Write-Step "Cockpit 기동: dmsdesktop.bat -configname $ConfigName"
$null = Start-Process -FilePath 'cmd.exe' `
    -ArgumentList '/c', "`"$Launcher`"", '-configname', $ConfigName `
    -WorkingDirectory $DmsBin -WindowStyle Hidden -PassThru

# --------------------------------------------------------------- 창 대기
Write-Step "창이 뜨기를 기다립니다 (최대 ${TimeoutSeconds}초)..."
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$target = $null

# 새 xDMLibraryClient 가 둘 이상 생길 수 있다(창 없는 프로세스가 먼저 잡혀 실패한 적 있음).
# Cockpit 메인 창을 실제로 가진 프로세스를 고른다.
$now = @()
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 1000
    $now = @(Get-Process -Name 'xDMLibraryClient' -ErrorAction SilentlyContinue |
        Where-Object { $before -notcontains $_.Id })
    $withWin = @($now | Where-Object { Test-CockpitWindow -ProcessId $_.Id })
    if ($withWin.Count -gt 0) {
        $target = $withWin[0]
        break
    }
}

if ($now.Count -gt 1 -or -not $target) {
    Write-Step "새 xDMLibraryClient 프로세스 $($now.Count) 개:" -Level Warn
    foreach ($p in $now) {
        $titles = @([CockpitWin]::Titles([uint32]$p.Id)) -join ' | '
        $parent = (Get-CimInstance Win32_Process -Filter "ProcessId=$($p.Id)" -ErrorAction SilentlyContinue).ParentProcessId
        Write-Step "  PID $($p.Id) (부모 $parent, 시작 $($p.StartTime.ToString('HH:mm:ss'))) 창: $titles" -Level Warn
    }
}

if (-not $target) {
    throw ("Cockpit 창이 나타나지 않았습니다 (${TimeoutSeconds}초). 남아 있는 xDMLibraryClient/javaw 프로세스를 정리한 뒤 다시 실행하세요.`n  " +
           ($script:Diag -join "`n  "))
}

$target.Refresh()
Write-Step "기동 완료: PID $($target.Id) / 창: $(@([CockpitWin]::Titles([uint32]$target.Id)) -join ' | ')" -Level Ok

[PSCustomObject]@{
    Process          = $target
    MainWindowHandle = $target.MainWindowHandle
    MainWindowTitle  = $target.MainWindowTitle
    Reused           = $false
    Diag             = @($script:Diag)
}
