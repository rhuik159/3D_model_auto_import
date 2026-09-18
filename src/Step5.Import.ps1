#Requires -Version 5.1
<#
.SYNOPSIS
    Cockpit GUI 자동화 - 3D 모델 Bulk Import 및 매핑 파일 Import.

.DESCRIPTION
    Step4 가 스테이징한 날짜 폴더를 Cockpit 에 Import 한다.
    JAB(Java Access Bridge) P/Invoke 로 Cockpit Swing UI 를 직접 제어한다.

    동작 순서:
      1. Cockpit 기동 (또는 재사용)
      2. Tools > Library > 3D Models > Bulk Import 클릭
         → 파일 선택 대화상자에 스테이지 폴더 경로 입력 → OK
         → 진행바 사라질 때까지 대기
      3. Tools > Library > 3D Models > Import Mapping File 클릭
         → 파일 선택 대화상자에 Mapping.xdm 경로 입력 → OK
         → 완료 대기

.PARAMETER ConfigPath
    설정 파일 경로. 기본값: .\config\config.json

.PARAMETER DateFolder
    특정 날짜 폴더 이름(yyyy-MM-dd). 생략하면 가장 최근 폴더를 사용.

.PARAMETER DryRun
    메뉴를 찾는 단계까지만 수행하고 실제 클릭/Import 를 하지 않는다.

.PARAMETER Reuse
    이미 떠 있는 Cockpit 이 있으면 재사용한다.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = '',
    [string]$StageRoot  = '',   # 생략하면 config.json 의 dateFolderRoot 사용
    [string]$DateFolder = '',
    [switch]$DryRun,
    [switch]$Reuse
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot  = Split-Path $PSScriptRoot -Parent
$ScriptDir = $PSScriptRoot

. (Join-Path $ScriptDir 'Common.Logging.ps1')
. (Join-Path $ScriptDir 'Common.Config.ps1')
. (Join-Path $RepoRoot  'tools\Jab-Bridge.ps1')

# ---------------------------------------------------------------- 설정 로드
if (-not $ConfigPath) { $ConfigPath = Join-Path $RepoRoot 'config\config.json' }
$cfg = Import-SyncConfig -ConfigPath $ConfigPath -RepoRoot $RepoRoot -SkipReachabilityCheck
$stageRoot = if ($StageRoot) { $StageRoot } else { $cfg.paths.dateFolderRoot }

# 날짜 폴더 결정
if ($DateFolder) {
    $datePath = Join-Path $stageRoot $DateFolder
} else {
    $latest = Get-ChildItem -LiteralPath $stageRoot -Directory -ErrorAction SilentlyContinue |
              Sort-Object Name -Descending | Select-Object -First 1
    if (-not $latest) { throw "날짜 폴더가 없습니다: $stageRoot" }
    $datePath = $latest.FullName
}
if (-not (Test-Path -LiteralPath $datePath)) {
    throw "날짜 폴더를 찾을 수 없습니다: $datePath"
}

$mappingFile = Join-Path $datePath 'Mapping.xdm'
if (-not (Test-Path -LiteralPath $mappingFile)) {
    throw "Mapping.xdm 를 찾을 수 없습니다: $mappingFile"
}

Write-Log "Step5 Import 시작"
Write-Log "  날짜 폴더 : $datePath"
Write-Log "  매핑 파일 : $mappingFile"
if ($DryRun) { Write-Log "  [DRY RUN] 실제 클릭 없음" -Level Warn }

# ================================================================ 헬퍼

function Click-MenuPath {
    <#
    .SYNOPSIS
        메뉴 경로를 순서대로 열어서 마지막 항목을 클릭한다.
        예: Click-MenuPath 'Tools','Library','3D Models','Bulk Import'
    .NOTES
        각 단계마다 루트부터 재탐색한다. 서브메뉴가 열린 뒤 새 노드가
        루트 하위에 추가되기 때문이다.
    #>
    param([string[]]$Path)
    foreach ($step in $Path) {
        $el = Find-JabElement -Name $step -MaxDepth 8
        if (-not $el) { throw "메뉴/항목을 찾을 수 없습니다: '$step'" }
        Write-Log "  클릭: '$step'" -Level Info
        if (-not $DryRun) {
            Invoke-JabAction -Ac $el.Ac -ActionName '누르기'
            Start-Sleep -Milliseconds 400
        }
    }
}

function Wait-Element {
    <#
    .SYNOPSIS
        조건에 맞는 JAB 요소가 나타날 때까지 기다린다.
    #>
    param(
        [string]$Name = '',
        [string]$Role = '',
        [int]$TimeoutMs = 15000
    )
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        [Jab.Win32]::PumpMessages(20)
        $el = Find-JabElement -Name $Name -Role $Role -MaxDepth 10
        if ($el) { return $el }
        Start-Sleep -Milliseconds 300
    }
    throw "요소(name='$Name' role='$Role')가 ${TimeoutMs}ms 안에 나타나지 않았습니다."
}

function Wait-ElementGone {
    <#
    .SYNOPSIS
        조건에 맞는 JAB 요소가 사라질 때까지 기다린다 (Import 완료 판정).
    #>
    param(
        [string]$Role = 'progress bar',
        [int]$TimeoutMs = 300000
    )
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        [Jab.Win32]::PumpMessages(20)
        $el = Find-JabElement -Role $Role -MaxDepth 8
        if (-not $el) { return }
        Start-Sleep -Milliseconds 1000
    }
    Write-Log "경고: ${TimeoutMs}ms 안에 진행바가 사라지지 않았습니다." -Level Warn
}

function Do-FileDialog {
    <#
    .SYNOPSIS
        파일 선택 대화상자에 경로를 입력하고 OK/Open 버튼을 클릭한다.
    #>
    param([string]$Path)

    # 텍스트 필드 대기 (파일명 입력란)
    $tf = Wait-Element -Role 'text' -TimeoutMs 15000
    Write-Log "    텍스트 필드 발견" -Level Info
    $null = [Jab.Bridge]::requestFocus($script:JabVmId, $tf.Ac)
    [Jab.Win32]::PumpMessages(10)
    $null = [Jab.Bridge]::setTextContents($script:JabVmId, $tf.Ac, $Path)
    [Jab.Win32]::PumpMessages(10)

    # OK / Open / 열기 버튼 탐색 (대화상자별 라벨이 다름)
    $okBtn = $null
    foreach ($label in @('OK','Open','열기','확인')) {
        $okBtn = Find-JabElement -Name $label -Role 'push button' -MaxDepth 10
        if ($okBtn) { break }
    }
    if (-not $okBtn) { throw "OK/Open 버튼을 찾지 못했습니다." }

    Write-Log "    OK 버튼 클릭 ('$($okBtn.Name)')" -Level Info
    Invoke-JabAction -Ac $okBtn.Ac -ActionName '누르기'
    [Jab.Win32]::PumpMessages(30)
}

# ================================================================ 메인

# 1) Cockpit 기동
Write-Log "Cockpit 기동 중..." -Level Info
$cockpitScript = Join-Path $RepoRoot 'tools\Start-Cockpit.ps1'
$cockpit = & $cockpitScript -Reuse:$Reuse
Write-Log "Cockpit PID $($cockpit.Process.Id) 준비됨" -Level Info

# 2) JAB 초기화
Write-Log "JAB 초기화 중..." -Level Info
$conn = Initialize-Jab -Hwnd ([IntPtr]$cockpit.MainWindowHandle)
Write-Log "JAB 연결 완료 (vmId=$($conn.VmId))" -Level Info

# ---------------------------------------------------------------- A) Bulk Import
Write-Log "=== A) Bulk Import ===" -Level Info
Write-Log "  경로: $datePath" -Level Info

Click-MenuPath -Path @('Tools','Library','3D Models','Bulk Import')

if (-not $DryRun) {
    Start-Sleep -Milliseconds 800
    Do-FileDialog -Path $datePath
    Write-Log "  Import 완료 대기..." -Level Info
    Wait-ElementGone -Role 'progress bar' -TimeoutMs 300000
    Write-Log "  Bulk Import 완료" -Level Info
}

# ---------------------------------------------------------------- B) Import Mapping File
Write-Log "=== B) Import Mapping File ===" -Level Info
Write-Log "  파일: $mappingFile" -Level Info

Start-Sleep -Milliseconds 500
[Jab.Win32]::PumpMessages(30)

Click-MenuPath -Path @('Tools','Library','3D Models','Import Mapping File')

if (-not $DryRun) {
    Start-Sleep -Milliseconds 800
    Do-FileDialog -Path $mappingFile
    Write-Log "  완료 대기..." -Level Info
    Wait-ElementGone -Role 'progress bar' -TimeoutMs 60000
    Write-Log "  Import Mapping File 완료" -Level Info
}

Release-JabObject -Ac $conn.RootAc
Write-Log "Step5 완료" -Level Info
