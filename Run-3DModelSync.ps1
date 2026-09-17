<#
.SYNOPSIS
    Xpedition EDM Library 3D 모델 자동 등록 파이프라인 (1~4단계).

.DESCRIPTION
    1. 공정기술 공유폴더 -> 설계팀 라이브러리 동기화 (robocopy, /MIR 미사용)
    2. 라이브러리 전체 목록 CSV 출력 + SHA-256 스냅샷 비교
    3. 업데이트분에 대한 매핑 파일 생성 (★포맷 미확정 - 스텁)
    4. 업데이트분을 yyyy-MM-dd 폴더로 복사 (Import 작업 배치)

    5~6단계(Xpedition Import)는 수동. docs\README.md 참조.

.PARAMETER ConfigPath
    설정 파일 경로. 기본값: .\config\config.json

.PARAMETER WhatIf
    드라이런. 복사/스냅샷 기록/폴더 생성을 하지 않고 수행 예정 내용만 출력한다.
    스캔은 실제로 수행하며 CSV 는 output\dryrun\ 에 기록된다.
    실제 공유폴더를 대상으로 첫 테스트할 때 반드시 사용할 것.

.PARAMETER SkipSync
    1단계(robocopy)를 건너뛰고 라이브러리 스캔만 수행한다.

.PARAMETER ForceFullBaseline
    스냅샷을 무시하고 전체를 다시 해싱해 기준선을 새로 만든다.
    날짜 폴더는 생성하지 않는다.

.EXAMPLE
    .\Run-3DModelSync.ps1 -WhatIf
    실제 공유폴더 대상 무해 점검 (연결성/권한/변경집합 확인)

.NOTES
    종료코드:
      0  성공 (변경 없음 포함)
      1  경고와 함께 완료 (일부 파일 읽기 실패 등)
      2  설정 오류 / config 없음
      3  원본·대상 접근 불가 또는 robocopy 실패 (exit >= 8)
      4  스캔/해시 실패
      5  스냅샷 손상 또는 배치 생성 실패
      6  다른 실행이 진행 중 (락 보유)
      10 예상치 못한 예외
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath,
    [switch]$SkipSync,
    [switch]$ForceFullBaseline,
    [ValidateSet('Debug', 'Info', 'Warn', 'Error')][string]$LogLevel = 'Info'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = $PSScriptRoot
. (Join-Path $RepoRoot 'src\Common.Io.ps1')
. (Join-Path $RepoRoot 'src\Common.Logging.ps1')
. (Join-Path $RepoRoot 'src\Common.Config.ps1')
. (Join-Path $RepoRoot 'src\Step1.SyncFromShare.ps1')
. (Join-Path $RepoRoot 'src\Step2.ScanAndSnapshot.ps1')
. (Join-Path $RepoRoot 'src\Step3.MappingFile.ps1')
. (Join-Path $RepoRoot 'src\Step4.StageDateFolder.ps1')

if (-not $ConfigPath) { $ConfigPath = Join-Path $RepoRoot 'config\config.json' }

$lockStream = $null
$lockPath   = $null
$exitCode   = 0
$startTime  = Get-Date
# ★ 주의 ★ 드라이런 여부는 $WhatIfPreference 로 '읽기만' 해야 한다.
#   여기서 $PSCmdlet.ShouldProcess() 를 호출해 판정하면 확인 상태를 소비해버려
#   -WhatIf 없이 실행해도 하위 단계의 ShouldProcess 가 false 를 반환한다
#   (= 4단계가 조용히 건너뛰어짐).
$isDryRun   = [bool]$WhatIfPreference

try {
    # ---------------------------------------------------------------- 설정
    try {
        $cfg = Import-SyncConfig -ConfigPath $ConfigPath -RepoRoot $RepoRoot
    }
    catch {
        Write-Host "[설정 오류] $($_.Exception.Message)" -ForegroundColor Red
        exit 2
    }

    Initialize-WorkDirectories -Config $cfg
    $logFile = Initialize-Log -LogDir $cfg.paths.logDir -Level $LogLevel

    Write-LogBanner "3D 모델 자동 등록 파이프라인 시작"
    Write-Log "설정 파일   : $ConfigPath"
    Write-Log "PowerShell  : $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
    Write-Log "실행 계정   : $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
    Write-Log "원본 공유   : $($cfg.paths.sourceShare)"
    Write-Log "라이브러리  : $($cfg.paths.designLibrary)"
    Write-Log "배치 루트   : $($cfg.paths.dateFolderRoot)"
    if ($isDryRun) { Write-Log "*** 드라이런 모드 (-WhatIf) - 변경을 적용하지 않습니다 ***" -Level Warn }

    # ------------------------------------------------------------------ 락
    # 드라이런도 락을 잡는다 (실제 실행과 경합하면 안 됨)
    $lockPath   = Join-Path $cfg.paths.stateDir 'run.lock'
    $lockStream = Get-RunLock -LockPath $lockPath
    if (-not $lockStream) {
        Write-Log "다른 실행이 진행 중입니다. 종료합니다. (락: $lockPath)" -Level Error
        exit 6
    }

    Remove-AgedFiles -Directory $cfg.paths.logDir    -Filter '*.log' -Days $cfg.retention.logDays
    Remove-AgedFiles -Directory $cfg.paths.outputDir -Filter '*.csv' -Days $cfg.retention.outputCsvDays

    # -------------------------------------------------------------- 1단계
    if ($SkipSync) {
        Write-Log "1단계 건너뜀 (-SkipSync)" -Level Info -Step 'Step1'
    }
    else {
        $rcLog = Join-Path $cfg.paths.logDir ("robocopy_{0}.log" -f (Get-Date -Format 'yyyy-MM-dd'))
        $sync  = Invoke-Step1Sync -Config $cfg -RobocopyLogPath $rcLog
        if (-not $sync.Success) {
            Write-Log "동기화 실패로 중단합니다. 스냅샷은 갱신되지 않습니다." -Level Error
            exit 3
        }
    }

    # -------------------------------------------------------------- 2단계
    # 스냅샷 존재 여부를 '스캔 전에' 기록해 둔다.
    # 최초 구축(스냅샷 없음)과 접근 이상(스냅샷 있는데 0건)을 구분하는 기준이다.
    $snapshotExistsAtStart = Test-Path -LiteralPath (Join-Path $cfg.paths.stateDir 'snapshot.json')

    Write-Log "라이브러리 스캔 시작..." -Level Info -Step 'Step2'
    $files = @(Get-LibraryFiles -Root $cfg.paths.designLibrary `
                                -IncludeExtensions $cfg.scan.includeExtensions `
                                -ExcludeFolderNames $cfg.scan.excludeFolderNames)
    Write-Log "스캔 완료: $($files.Count) 개 파일" -Level Info -Step 'Step2'

    # 라이브러리가 비어 있어도 그 자체로는 중단하지 않는다.
    # 최초 구축 시점에는 라이브러리가 당연히 비어 있고(동기화 전),
    # 드라이런에서는 robocopy 가 /L 로 돌아 실제 복사가 없기 때문이다.
    # '공유폴더 사망' 판정은 원본 기준으로 아래에서 수행한다.
    if ($files.Count -eq 0) {
        if ($snapshotExistsAtStart) {
            # 스냅샷에는 파일이 있었는데 지금 0건이면 접근 이상으로 본다.
            Write-Log ("라이브러리에서 파일을 하나도 찾지 못했습니다. 접근 문제로 의심됩니다.`n" +
                       "  스냅샷을 보호하기 위해 아무 변경 없이 중단합니다.") -Level Error -Step 'Step2'
            exit 3
        }
        Write-Log "라이브러리가 비어 있습니다 (최초 구축 또는 드라이런)." -Level Warn -Step 'Step2'
    }

    $snapPath = Join-Path $cfg.paths.stateDir 'snapshot.json'
    $bakPath  = Join-Path $cfg.paths.stateDir 'snapshot.bak.json'
    $snapshot = $null
    $isFirstRun = $false

    if ($ForceFullBaseline) {
        Write-Log "-ForceFullBaseline: 스냅샷을 무시하고 기준선을 다시 만듭니다." -Level Warn -Step 'Step2'
        $isFirstRun = $true
    }
    else {
        $snapshot = Read-Snapshot -Path $snapPath
        if (-not $snapshot -and (Test-Path -LiteralPath $bakPath)) {
            Write-Log "스냅샷을 읽을 수 없어 백업(.bak)에서 복구를 시도합니다." -Level Warn -Step 'Step2'
            $snapshot = Read-Snapshot -Path $bakPath
            if ($snapshot) {
                Write-Log "백업 스냅샷으로 복구했습니다." -Level Warn -Step 'Step2'
                $exitCode = 1
            }
        }
        if (-not $snapshot) {
            $isFirstRun = $true
            if ($files.Count -gt 0) {
                Write-Log "사용 가능한 스냅샷이 없습니다. 기준선 생성 모드로 진행합니다." -Level Warn -Step 'Step2'
            }
        }
        elseif ($snapshot.SourceRoot -and
                $snapshot.SourceRoot -ne $cfg.paths.designLibrary) {
            # 라이브러리 경로만 바뀐 경우 (서버 IP/호스트명 변경, 공유 재구성 등).
            #
            # ★ 스냅샷을 버리면 안 된다 ★
            #   스냅샷의 키는 라이브러리 루트 기준 '상대경로' 이므로 루트가 바뀌어도
            #   그대로 유효하다. 여기서 기준선을 다시 만들면 아직 날짜폴더로 배치되지
            #   않은 파일까지 전부 '기존' 으로 흡수되어 영영 Import 되지 않는다.
            #   (실제로 발생: IP 변경일에 올라온 모델이 조용히 누락됨)
            #
            #   '전체가 삭제됨으로 오보고된다' 는 걱정은 근거가 없다. 삭제 판정은
            #   $sourceKeys - 즉 원본 공유폴더의 키 - 를 기준으로 하며 SourceRoot 와
            #   무관하다. 루트 표기만 갱신하고 비교는 정상 진행한다.
            Write-Log ("스냅샷의 라이브러리 경로가 현재 설정과 다릅니다. 경로 표기만 갱신하고`n" +
                       "  기존 스냅샷으로 변경 비교를 계속합니다 (미처리 파일 보호).`n" +
                       "  스냅샷: $($snapshot.SourceRoot)`n  현재  : $($cfg.paths.designLibrary)") -Level Warn -Step 'Step2'
            $snapshot.SourceRoot = $cfg.paths.designLibrary
            $exitCode = 1
        }
    }

    # 최초 실행 동작 결정
    $treatAllAsNew = $cfg.behavior.firstRunMode -eq 'TreatAllAsNew'
    $baselineOnly  = $isFirstRun -and -not $treatAllAsNew

    # 삭제 판정을 위해 원본 공유폴더의 키 집합을 구한다.
    # /MIR 를 쓰지 않으므로 라이브러리만 봐서는 삭제를 감지할 수 없다.
    $sourceKeys = $null
    if (-not $SkipSync) {
        try {
            $srcFiles = @(Get-LibraryFiles -Root $cfg.paths.sourceShare `
                                           -IncludeExtensions $cfg.scan.includeExtensions `
                                           -ExcludeFolderNames $cfg.scan.excludeFolderNames)
            $sourceKeys = @{}
            foreach ($sf in $srcFiles) { $sourceKeys[$sf.Key] = $true }
            Write-Log "원본 공유폴더 파일 수: $($srcFiles.Count) (삭제 감지 기준)" -Level Info -Step 'Step2'

            # 공유폴더 사망 감지기.
            # 원본이 0건이면 스냅샷의 모든 파일이 '삭제됨' 으로 보고된다.
            # 마운트는 됐는데 권한 상실 등으로 빈 폴더로 읽히는 상황이 전형적이므로
            # 아무것도 바꾸지 않고 중단한다.
            if ($srcFiles.Count -eq 0 -and $cfg.behavior.failOnZeroFilesFound) {
                Write-Log ("원본 공유폴더에서 대상 파일을 하나도 찾지 못했습니다: $($cfg.paths.sourceShare)`n" +
                           "  공유폴더 접근 문제로 의심됩니다. 스냅샷을 보호하기 위해 변경 없이 중단합니다.`n" +
                           "  의도된 상태라면 config 의 behavior.failOnZeroFilesFound 를 false 로 두세요.") -Level Error -Step 'Step2'
                exit 3
            }
        }
        catch {
            Write-Log "원본 공유폴더 열거 실패 - 삭제 감지를 건너뜁니다: $($_.Exception.Message)" -Level Warn -Step 'Step2'
            $sourceKeys = $null
        }
    }

    $changes = @(Compare-WithSnapshot -CurrentFiles $files -Snapshot $snapshot `
                                      -HashAlgorithm $cfg.behavior.hashAlgorithm `
                                      -MaxFileSizeMB $cfg.scan.maxFileSizeMB `
                                      -ForceRehash:$ForceFullBaseline `
                                      -SourceKeys $sourceKeys)

    $counts = @{}
    foreach ($t in @('New', 'Modified', 'TouchedOnly', 'Deleted')) {
        $counts[$t] = @($changes | Where-Object { $_.ChangeType -eq $t }).Count
    }

    # CSV 출력 (드라이런은 별도 폴더에)
    $outDir = if ($isDryRun) { Join-Path $cfg.paths.outputDir 'dryrun' } else { $cfg.paths.outputDir }
    $today  = Get-Date -Format 'yyyy-MM-dd'

    # filelist 는 '현재 전체 상태' 의 스냅샷이므로 매번 덮어쓴다 (누적하면 중복).
    Export-InventoryCsv -Files $files -Changes $changes -Path (Join-Path $outDir "filelist_$today.csv")

    # changes 는 하루 여러 번 실행 시 '누적' 한다. RunTime 컬럼으로 회차를 구분한다.
    # 배치 결과(StagedToDateFolder)를 반영해야 하므로 4단계 뒤에 한 번만 기록한다.
    $changesCsvPath = Join-Path $outDir "changes_$today.csv"
    $runTime = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

    if ($baselineOnly) {
        # 기준선 실행에서는 변경 리포트에 아무것도 추가하지 않는다
        # (전체가 New 로 기록되면 오해 소지). 파일이 없으면 헤더만 만든다.
        if (-not (Test-Path -LiteralPath $changesCsvPath)) {
            Export-ChangesCsv -Changes @() -Path $changesCsvPath -RunTime $runTime -Replace
        }
    }

    # ------------------------------------------------------ 3·4단계 or 기준선
    if ($baselineOnly) {
        Write-LogBanner ("기준선 생성 완료 - $($files.Count) 개 파일을 등록했습니다.`n" +
                         "  Import 배치를 만들지 않았습니다. 다음 실행부터 변경분을 추적합니다.`n" +
                         "  (기존 라이브러리 전체를 한 번에 Import 하려면 config 의`n" +
                         "   behavior.firstRunMode 를 'TreatAllAsNew' 로 바꾸고 다시 실행하세요.)")
    }
    else {
        Write-Log "변경 요약 - 신규 $($counts.New), 수정 $($counts.Modified), 타임스탬프만 $($counts.TouchedOnly), 삭제 $($counts.Deleted)" -Level Info

        $stageable = @($changes | Where-Object { $_.ChangeType -in @('New', 'Modified') })

        # 4단계를 먼저 수행해 StagedToDateFolder 가 매니페스트에 반영되도록 한다
        $batch = Invoke-Step4Stage -Config $cfg -Changes $changes -LibraryRoot $cfg.paths.designLibrary

        # 3단계 - Mapping.xdm / Alignment.dat 를 '날짜 폴더 안에' step 파일과 함께 생성.
        # 4단계 뒤에 실행하는 이유: 날짜 폴더가 먼저 만들어져 있어야 한다.
        if ($batch.BatchPath) {
            $map = New-3DMappingFile -ChangedFiles $stageable `
                                     -OutputDirectory $batch.BatchPath `
                                     -MappingFileName $cfg.mapping.mappingFileName `
                                     -AlignmentFileName $cfg.mapping.alignmentFileName `
                                     -Vendor $cfg.mapping.vendor `
                                     -Enabled:$cfg.mapping.enabled
            if ($map -and $map.Skipped -gt 0) { $exitCode = 1 }
        }

        if ($batch.Skipped -gt 0) { $exitCode = 1 }

        # 변경 리포트 기록 (이번 실행분을 기존 내용 뒤에 누적).
        # 배치 결과가 StagedToDateFolder 에 반영된 뒤이므로 여기서 한 번만 쓴다.
        Export-ChangesCsv -Changes $changes -Path $changesCsvPath -RunTime $runTime

        if ($batch.BatchPath -and $batch.StagedCount -gt 0) {
            Write-LogBanner ("Import 대상 배치 폴더:`n  $($batch.BatchPath)`n" +
                             "  ($($batch.StagedCount) 개 파일 - Xpedition 에서 수동 Import 하세요)")
        }
    }

    # ------------------------------------------------------------ 스냅샷 기록
    # 성공했을 때만 갱신한다. 실패 후 갱신하면 그날 변경분이 영원히 누락된다.
    if ($isDryRun) {
        Write-Log "[WHATIF] would 스냅샷 기록 $snapPath ($($files.Count) 건)" -Level Info -Step 'Step2'
    }
    else {
        Write-Snapshot -Path $snapPath -SourceRoot $cfg.paths.designLibrary `
                       -Files $files -IsBaseline:$baselineOnly
        Write-Log "스냅샷 기록 완료: $snapPath" -Level Info -Step 'Step2'
    }

    $warnCount = Get-LogWarningCount
    if ($warnCount -gt 0 -and $exitCode -eq 0) { $exitCode = 1 }

    $elapsed = (Get-Date) - $startTime
    Write-LogBanner ("완료 - 소요 {0:mm\:ss}, 경고 {1} 건, 종료코드 {2}" -f $elapsed, $warnCount, $exitCode)
}
catch {
    if ($script:LogPath) {
        Write-Log "예상치 못한 오류: $($_.Exception.Message)" -Level Error
        Write-Log $_.ScriptStackTrace -Level Debug
    }
    else {
        Write-Host "[오류] $($_.Exception.Message)" -ForegroundColor Red
    }
    $exitCode = 10
}
finally {
    if ($lockPath) { Remove-RunLock -LockStream $lockStream -LockPath $lockPath }
}

exit $exitCode
