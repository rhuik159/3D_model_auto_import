# Step4.StageDateFolder.ps1 - 업데이트 파일을 날짜 폴더로 정리

Set-StrictMode -Version Latest

<#
.SYNOPSIS
    New / Modified 파일을 yyyy-MM-dd 폴더에 복사한다 (Import 작업 배치).
.DESCRIPTION
    - 복사이지 이동이 아니다. 설계팀 라이브러리는 공유폴더의 전체 미러로 유지된다.
    - TouchedOnly / Deleted / Unchanged 는 제외한다.
      특히 TouchedOnly(내용 동일, 타임스탬프만 변경)를 넣으면
      재Import 가 불필요한 파일로 배치가 가득 찬다.
    - 하위 폴더 구조를 보존한다. 평탄화하면 카테고리가 다른 동명 부품이
      서로 덮어쓴다.
    - 변경이 없으면 폴더 자체를 만들지 않는다.
.OUTPUTS
    [pscustomobject] @{ BatchPath; StagedCount; Skipped }
#>
function Invoke-Step4Stage {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Changes,
        [Parameter(Mandatory)][string]$LibraryRoot
    )

    # 배치 대상은 New 와 Modified 뿐.
    # (TouchedOnly/Deleted/Unchanged 는 제외 - 재Import 가 불필요하거나 불가능)
    # Set-StrictMode 하에서는 없는 속성 접근이 예외이므로 존재 여부를 먼저 확인한다.
    $stageTypes = @('New')
    $includeModified = $true
    if ($Config.PSObject.Properties.Name -contains 'batch' -and
        $Config.batch.PSObject.Properties.Name -contains 'includeModified') {
        $includeModified = [bool]$Config.batch.includeModified
    }
    if ($includeModified) { $stageTypes += 'Modified' }

    $toStage = @($Changes | Where-Object { $stageTypes -contains $_.ChangeType })

    if ($toStage.Count -eq 0) {
        Write-Log "변경 없음 - 날짜 폴더를 생성하지 않습니다." -Level Info -Step 'Step4'
        return [pscustomobject]@{ BatchPath = $null; StagedCount = 0; Skipped = 0 }
    }

    $folderName = (Get-Date).ToString('yyyy-MM-dd')
    $batchPath  = Join-Path $Config.paths.dateFolderRoot $folderName

    if (-not $PSCmdlet.ShouldProcess($batchPath, "$($toStage.Count) 개 파일 배치")) {
        Write-Log "[WHATIF] would 날짜 폴더 생성 $batchPath ($($toStage.Count) 건 복사 예정)" -Level Info -Step 'Step4'
        foreach ($c in $toStage) {
            Write-Log "[WHATIF]   would 복사 $($c.RelativePath)" -Level Debug -Step 'Step4'
        }
        return [pscustomobject]@{ BatchPath = $batchPath; StagedCount = 0; Skipped = 0 }
    }

    if (Test-Path -LiteralPath $batchPath) {
        Write-Log "같은 날짜 폴더가 이미 존재합니다 - 재배치합니다: $batchPath" -Level Info -Step 'Step4'
    }
    else {
        New-Item -ItemType Directory -Path $batchPath -Force | Out-Null
    }

    $staged  = 0
    $skipped = 0

    foreach ($c in $toStage) {
        try {
            $srcFull = Join-Path $LibraryRoot $c.RelativePath
            $dstFull = Join-Path $batchPath   $c.RelativePath

            $dstDir = Split-Path -Parent $dstFull
            if ($dstDir -and -not (Test-Path -LiteralPath $dstDir)) {
                New-Item -ItemType Directory -Path $dstDir -Force | Out-Null
            }

            Copy-Item -LiteralPath (ConvertTo-ExtendedPath $srcFull) `
                      -Destination (ConvertTo-ExtendedPath $dstFull) -Force -ErrorAction Stop

            $c.StagedToDateFolder = 'True'
            $staged++
        }
        catch {
            $skipped++
            $c.Notes = "배치 복사 실패: $($_.Exception.Message)"
            Write-Log "배치 복사 실패: $($c.RelativePath) - $($_.Exception.Message)" -Level Warn -Step 'Step4'
        }
    }

    # 배치 폴더를 자기설명적으로 만든다 - Import 담당자가 폴더 하나만 보면 되도록.
    # 하루 여러 번 실행되면 누적한다 (덮어쓰면 오전 실행분 내역이 사라진다).
    $manifest = Join-Path $batchPath '_batch_manifest.csv'
    Export-ChangesCsv -Changes $toStage -Path $manifest

    Write-Log "배치 완료: $batchPath (복사 $staged 건, 실패 $skipped 건)" -Level Info -Step 'Step4'
    return [pscustomobject]@{ BatchPath = $batchPath; StagedCount = $staged; Skipped = $skipped }
}
