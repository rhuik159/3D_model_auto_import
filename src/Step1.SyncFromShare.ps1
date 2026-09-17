# Step1.SyncFromShare.ps1 - 공정기술 공유폴더 -> 설계팀 라이브러리 동기화

Set-StrictMode -Version Latest

<#
.SYNOPSIS
    robocopy 종료코드를 사람이 읽을 수 있는 설명으로 변환한다.
.DESCRIPTION
    robocopy 종료코드는 비트마스크다:
      1  = 파일 복사됨
      2  = 대상에 추가 파일/폴더 존재
      4  = 불일치 파일/폴더 존재
      8  = 일부 파일 복사 실패
      16 = 치명적 오류
    0~7 은 성공/정보, 8 이상이 실패.
#>
function Get-RobocopyCodeText {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Code)

    if ($Code -eq 0) { return '변경 없음 (동기화 상태 일치)' }
    if ($Code -eq 16) { return '치명적 오류 - 원본/대상에 접근 불가' }

    $parts = @()
    if ($Code -band 1)  { $parts += '파일 복사됨' }
    if ($Code -band 2)  { $parts += '대상에 추가 파일 존재' }
    if ($Code -band 4)  { $parts += '불일치 파일 존재' }
    if ($Code -band 8)  { $parts += '일부 파일 복사 실패' }
    if ($parts.Count -eq 0) { $parts += "알 수 없는 코드 $Code" }
    return ($parts -join ', ')
}

<#
.SYNOPSIS
    robocopy 로 공유폴더를 라이브러리에 동기화한다.
.DESCRIPTION
    ★ /MIR 를 절대 쓰지 않는다 ★
    공유폴더에서 파일이 삭제되어도 라이브러리에서는 지우지 않는다는 것이
    확정된 요구사항이다. /MIR 는 공유폴더의 대량 삭제 사고를 그대로
    설계팀 폴더로 전파시키는 바로 그 플래그다.
.OUTPUTS
    [pscustomobject] @{ ExitCode; Success; Description }
#>
function Invoke-Step1Sync {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$RobocopyLogPath
    )

    $src = $Config.paths.sourceShare
    $dst = $Config.paths.designLibrary

    Write-Log "동기화 시작: $src -> $dst" -Level Info -Step 'Step1'

    $rcArgs = @($src, $dst)
    foreach ($ext in $Config.scan.includeExtensions) {
        $rcArgs += ('*' + $ext)     # .step -> *.step
    }

    $rcArgs += @(
        '/E'                                        # 하위폴더 포함 (/MIR 아님)
        '/Z'                                        # 재시작 가능 모드 - 네트워크 끊김 대비
        '/COPY:DAT'                                 # 타임스탬프 보존 (변경감지 정확도)
        '/DCOPY:T'
        "/R:$($Config.robocopy.retryCount)"
        "/W:$($Config.robocopy.retryWaitSeconds)"
        "/MT:$($Config.robocopy.threads)"
        '/NP'                                       # 진행률 제외 (로그 비대화 방지)
        '/NDL'                                      # 디렉토리 목록 제외
        '/XJ'                                       # junction 제외 - 무한 재귀 방지
        "/LOG+:$RobocopyLogPath"                    # robocopy 자체 로그는 별도 파일
    )

    if (-not $PSCmdlet.ShouldProcess("$src -> $dst", 'robocopy 동기화')) {
        $rcArgs += '/L'    # 목록만 출력, 복사하지 않음
        Write-Log "[WHATIF] would robocopy 동기화 $src -> $dst (/L 모드로 실행)" -Level Info -Step 'Step1'
    }

    $global:LASTEXITCODE = 0
    & robocopy.exe @rcArgs | Out-Null
    $rc = $LASTEXITCODE
    $global:LASTEXITCODE = 0    # 후속 판정 오염 방지

    $desc = Get-RobocopyCodeText $rc

    # ★ 함정 ★ robocopy 는 정상 복사 시에도 1 을 반환한다.
    #   if ($rc -ne 0) { fail } 로 쓰면 복사가 성공할 때마다 실패로 오판한다.
    if ($rc -ge 8) {
        Write-Log "robocopy 실패 (exit $rc): $desc" -Level Error -Step 'Step1'
        return [pscustomobject]@{ ExitCode = $rc; Success = $false; Description = $desc }
    }

    Write-Log "robocopy 정상 (exit $rc): $desc" -Level Info -Step 'Step1'
    return [pscustomobject]@{ ExitCode = $rc; Success = $true; Description = $desc }
}
