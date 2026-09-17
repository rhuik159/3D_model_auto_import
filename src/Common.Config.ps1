# Common.Config.ps1 - 설정 로드 및 fail-fast 검증

Set-StrictMode -Version Latest

$script:SENTINEL = '<<SET-ME>>'

<#
.SYNOPSIS
    config.json 을 읽고 검증한 뒤 정규화된 절대경로를 담아 반환한다.
.DESCRIPTION
    검증 실패는 전부 throw. 호출자가 종료코드 2로 변환한다.
    미설정 키는 하나씩이 아니라 '전부 한 번에' 나열한다.
#>
function Import-SyncConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$RepoRoot,
        [switch]$SkipReachabilityCheck
    )

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "설정 파일이 없습니다: $ConfigPath`n" +
              "  config\config.sample.json 을 config\config.json 으로 복사한 뒤 경로를 채우세요."
    }

    try {
        $raw = [System.IO.File]::ReadAllText($ConfigPath, [System.Text.Encoding]::UTF8)
        $cfg = $raw | ConvertFrom-Json
    }
    catch {
        throw "설정 파일 JSON 파싱 실패: $ConfigPath`n  $($_.Exception.Message)"
    }

    if ($cfg.schemaVersion -ne 1) {
        throw "지원하지 않는 schemaVersion 입니다: $($cfg.schemaVersion) (필요: 1)"
    }

    # --- 미설정 센티널 일괄 검출 -------------------------------------------
    $unset = @()
    foreach ($key in @('sourceShare', 'designLibrary', 'dateFolderRoot')) {
        if ($cfg.paths.$key -eq $script:SENTINEL -or
            [string]::IsNullOrWhiteSpace($cfg.paths.$key)) {
            $unset += "paths.$key"
        }
    }
    if ($unset.Count -gt 0) {
        throw ("다음 설정값이 아직 채워지지 않았습니다 ($ConfigPath):`n" +
               (($unset | ForEach-Object { "  - $_" }) -join "`n"))
    }

    # --- 경로 정규화: 상대경로는 '리포지토리 루트' 기준 ----------------------
    # 작업 스케줄러는 임의의 CWD 로 실행하므로 CWD 기준으로 풀면 조용히 깨진다.
    foreach ($key in @('sourceShare','designLibrary','dateFolderRoot','stateDir','logDir','outputDir')) {
        $v = $cfg.paths.$key
        if ([string]::IsNullOrWhiteSpace($v)) { continue }
        if (-not [System.IO.Path]::IsPathRooted($v)) {
            $cfg.paths.$key = [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $v))
        }
        else {
            $cfg.paths.$key = $v.TrimEnd('\')
        }
    }

    if (-not $SkipReachabilityCheck) {
        Test-ConfigPathAccess -Config $cfg
    }

    # --- 값 범위 검증 -------------------------------------------------------
    if (-not $cfg.scan.includeExtensions -or $cfg.scan.includeExtensions.Count -eq 0) {
        throw "scan.includeExtensions 가 비어 있습니다. 최소 하나의 확장자가 필요합니다."
    }
    if ($cfg.behavior.firstRunMode -notin @('BaselineOnly', 'TreatAllAsNew')) {
        throw "behavior.firstRunMode 값이 잘못되었습니다: '$($cfg.behavior.firstRunMode)' (BaselineOnly | TreatAllAsNew)"
    }
    if ($cfg.robocopy.threads -lt 1 -or $cfg.robocopy.threads -gt 128) {
        throw "robocopy.threads 는 1~128 범위여야 합니다 (현재: $($cfg.robocopy.threads))"
    }

    return $cfg
}

<#
.SYNOPSIS
    원본 읽기 / 대상 쓰기 권한을 '실제로' 확인한다.
.DESCRIPTION
    Test-Path 만으로는 부족하다. 열거 권한이 없어도 UNC 경로는 $true 를 반환한다.
    또한 작업 스케줄러가 SYSTEM 으로 실행될 때의 UNC 접근 실패를
    robocopy 내부가 아니라 여기서 명확한 메시지로 드러내야 한다.
#>
function Test-ConfigPathAccess {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)

    $src = $Config.paths.sourceShare

    if (-not (Test-Path -LiteralPath $src)) {
        throw ("원본 공유폴더에 접근할 수 없습니다: $src`n" +
               "  - 경로/서버명이 맞는지 확인하세요.`n" +
               "  - 작업 스케줄러로 실행 중이라면: SYSTEM 계정은 UNC 공유에 접근할 수 없습니다.`n" +
               "    공유 권한이 있는 도메인 계정으로 작업을 등록해야 합니다.")
    }
    try {
        Get-ChildItem -LiteralPath $src -Force -ErrorAction Stop | Select-Object -First 1 | Out-Null
    }
    catch {
        throw ("원본 공유폴더를 열거할 수 없습니다(권한 문제로 추정): $src`n  $($_.Exception.Message)")
    }

    foreach ($key in @('designLibrary', 'dateFolderRoot')) {
        $dir = $Config.paths.$key
        if (-not (Test-Path -LiteralPath $dir)) {
            try { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
            catch { throw "대상 폴더를 생성할 수 없습니다 (paths.$key): $dir`n  $($_.Exception.Message)" }
        }
        # 임시 파일 생성/삭제로 실제 쓰기 권한 확인
        $probe = Join-Path $dir (".writeprobe_{0}.tmp" -f [guid]::NewGuid().ToString('N'))
        try {
            [System.IO.File]::WriteAllText($probe, 'probe')
            # -WhatIf 중에도 반드시 지운다. Remove-Item 이 억제되면 프로브 파일이
            # 사용자 폴더에 그대로 쌓이므로 .NET API 로 직접 삭제한다.
            [System.IO.File]::Delete($probe)
        }
        catch {
            throw ("대상 폴더에 쓰기 권한이 없습니다 (paths.$key): $dir`n" +
                   "  실행 계정을 확인하세요.`n  $($_.Exception.Message)")
        }
    }
}

function Initialize-WorkDirectories {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)
    foreach ($key in @('stateDir', 'logDir', 'outputDir')) {
        $dir = $Config.paths.$key
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force -WhatIf:$false | Out-Null
        }
    }
}
