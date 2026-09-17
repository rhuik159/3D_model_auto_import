# Step3.MappingFile.ps1 - Xpedition 3D 매핑 / alignment 파일 생성

Set-StrictMode -Version Latest

<#
.SYNOPSIS
    ASCII + CRLF 로 텍스트 파일을 기록한다 (BOM 없음).
.DESCRIPTION
    Xpedition 이 읽는 Mapping.xdm / Alignment.dat 는 BOM 없는 ASCII + CRLF 다.
    (샘플 파일을 바이트 단위로 확인함)

    참고: 원본 VBScript(CreateMapping_2.vbs)는 Excel 에서 읽은 값을
    ANSI 로 쓴 뒤 runvb.bat 이 'CMD /a /c TYPE' 으로 UNICODE 재변환을 했다.
    이는 Excel 경유 시 비ASCII 문자가 깨지는 것을 막기 위한 보정으로 보인다.
    여기서는 Excel 을 거치지 않고 파일명에서 직접 생성하므로 그 단계가 불필요하다.
    (사용자 확인: "그냥 ascii로 한번에 변환해도 될 것 같아")

    PowerShell 의 Out-File/Set-Content 는 버전별 기본 인코딩/개행이 달라
    신뢰할 수 없으므로 바이트를 직접 기록한다.
#>
function Write-AsciiCrlfFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines,
        [Parameter(Mandatory)][string]$Path
    )

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force -WhatIf:$false | Out-Null
    }

    # 각 줄 뒤에 CRLF. 마지막 줄에도 붙인다 (샘플과 동일).
    $sb = New-Object System.Text.StringBuilder
    foreach ($line in $Lines) { [void]$sb.Append($line); [void]$sb.Append("`r`n") }

    # ASCII 인코더: 표현 불가 문자는 '?' 로 치환된다.
    # 사전에 Test-AsciiSafe 로 걸러내므로 여기까지 오면 안 된다.
    $enc = New-Object System.Text.ASCIIEncoding
    [System.IO.File]::WriteAllText($Path, $sb.ToString(), $enc)
}

<#
.SYNOPSIS
    문자열이 ASCII 로 안전하게 표현 가능한지 검사한다.
.DESCRIPTION
    Mapping.xdm / Alignment.dat 는 ASCII 파일이므로 한글 파일명은 담을 수 없다.
    조용히 '?' 로 깨뜨리면 Xpedition 이 잘못된 부품번호를 등록하게 되므로
    미리 걸러내 경고하고 제외한다.
#>
function Test-AsciiSafe {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    foreach ($ch in $Text.ToCharArray()) {
        if ([int]$ch -gt 127) { return $false }
    }
    return $true
}

<#
.SYNOPSIS
    기존 Mapping.xdm 에서 이미 기록된 항목을 읽어온다 (누적 실행용).
.DESCRIPTION
    하루에 스크립트가 여러 번 실행되면 같은 날짜 폴더에 결과가 '누적' 되어야 한다.
    덮어쓰면 오전 실행분이 사라져, 그 부품들은 step 파일만 폴더에 남고
    매핑에서 빠져 Xpedition 에 등록되지 않는다.

    파일이 없거나 읽을 수 없으면 빈 목록을 반환한다 (첫 실행으로 간주).
.OUTPUTS
    [object[]] @{ Fpt; Xdp } 형태의 기존 항목들
#>
function Read-ExistingMappingEntries {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $result = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $Path)) { return $result }

    try {
        $lines = [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::ASCII)
    }
    catch {
        Write-Log "기존 매핑 파일을 읽을 수 없습니다(새로 만듭니다): $Path - $($_.Exception.Message)" `
            -Level Warn -Step 'Step3'
        return $result
    }

    # FPT/XDP 쌍을 순서대로 수집. 레코드는 4줄 + 빈 줄 구조지만
    # 손상된 파일에도 관대하도록 FPT 를 만날 때마다 새 레코드로 처리한다.
    $fpt = $null
    foreach ($line in $lines) {
        if ($line -match '^FPT:\s*(.*)$') {
            $fpt = $Matches[1].Trim()
        }
        elseif ($line -match '^XDP:\s*(.*)$' -and $fpt) {
            $result.Add([pscustomobject]@{ Fpt = $fpt; Xdp = $Matches[1].Trim() })
            $fpt = $null
        }
    }
    return $result
}

<#
.SYNOPSIS
    변경된 3D 파일로부터 Mapping.xdm 과 Alignment.dat 를 생성한다.

.DESCRIPTION
    두 파일 모두 날짜 폴더(배치 폴더)에 step 파일과 함께 생성된다.

    [Mapping.xdm] 부품당 4줄 + 빈 줄 1개
        FPT: <부품번호>
        XDP: <3D 모델명>
        VND: User
        ALT:
        (빈 줄)
      - 'ALT:' 뒤에는 값이 비어도 공백 1개가 유지된다 (샘플과 동일)
      - 마지막 레코드 뒤에도 빈 줄이 있다

    [Alignment.dat] 부품당 1줄
        "<부품번호>" "<3D 모델명>" User  0 0 0 0 0 0 M
      - User 뒤 공백 2개 (샘플 바이트 확인)
      - 숫자 6개는 회전/오프셋, M 은 단위. 모두 고정값.
        실제 2D-3D 정렬은 7단계에서 수동으로 맞춘다.

    FPT/XDP 는 둘 다 확장자를 제외한 파일명을 사용한다 (사용자 확정).

.PARAMETER ChangedFiles
    그날 배치에 포함된 파일 (New + Modified). 각 항목은 PartNumber 속성을 가진다.

.PARAMETER OutputDirectory
    날짜 폴더 경로. 이 안에 Mapping.xdm / Alignment.dat 를 만든다.

.OUTPUTS
    [pscustomobject] @{ MappingPath; AlignmentPath; Count; Skipped }
    생성하지 않았으면 $null.
#>
function New-3DMappingFile {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ChangedFiles,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [string]$MappingFileName   = 'Mapping.xdm',
        [string]$AlignmentFileName = 'Alignment.dat',
        [string]$Vendor            = 'User',
        [switch]$Enabled
    )

    if (-not $Enabled) {
        Write-Log "3단계 건너뜀 (config: mapping.enabled=false)" -Level Info -Step 'Step3'
        return $null
    }

    if ($ChangedFiles.Count -eq 0) {
        Write-Log "매핑 대상 파일이 없습니다." -Level Info -Step 'Step3'
        return $null
    }

    $mappingPath   = Join-Path $OutputDirectory $MappingFileName
    $alignmentPath = Join-Path $OutputDirectory $AlignmentFileName

    # --- 기존 항목 이어받기 (하루 여러 번 실행 시 누적) ----------------------
    # 덮어쓰면 오전 실행분이 사라져 해당 부품이 매핑에서 빠진다.
    $entries = New-Object System.Collections.Generic.List[object]
    $skipped = 0
    $seen    = @{}

    $existing = Read-ExistingMappingEntries -Path $mappingPath
    foreach ($e in $existing) {
        $k = $e.Fpt.ToUpperInvariant()
        if (-not $seen.ContainsKey($k)) {
            $seen[$k] = '(기존 매핑 파일)'
            $entries.Add($e)
        }
    }
    $carried = $entries.Count
    if ($carried -gt 0) {
        Write-Log "기존 매핑 파일에서 $carried 건을 이어받습니다 (누적 실행)." -Level Info -Step 'Step3'
    }

    $added = 0

    foreach ($f in $ChangedFiles) {
        $name = $f.PartNumber        # 확장자를 제외한 파일명

        if ([string]::IsNullOrWhiteSpace($name)) {
            $skipped++
            Write-Log "부품명이 비어 있어 제외: $($f.FileName)" -Level Warn -Step 'Step3'
            continue
        }

        # ASCII 파일이므로 한글 등 비ASCII 파일명은 담을 수 없다.
        # 조용히 '?' 로 깨뜨리면 잘못된 부품번호가 등록되므로 제외하고 경고한다.
        if (-not (Test-AsciiSafe $name)) {
            $skipped++
            Write-Log ("비ASCII 문자가 포함되어 매핑에서 제외: $($f.FileName)`n" +
                       "  Mapping.xdm / Alignment.dat 는 ASCII 파일이라 한글 파일명을 담을 수 없습니다.`n" +
                       "  해당 모델은 파일명을 영문으로 변경하거나 수동으로 등록하세요.") -Level Warn -Step 'Step3'
            continue
        }

        # 큰따옴표는 Alignment.dat 의 구분자이므로 포함될 수 없다.
        if ($name.Contains('"')) {
            $skipped++
            Write-Log "파일명에 큰따옴표가 있어 제외: $($f.FileName)" -Level Warn -Step 'Step3'
            continue
        }

        # 같은 부품명은 한 번만 기록한다 (사용자 확정).
        # FPT/XDP 가 동일한 파일명이라 두 번 넣어도 내용이 같고,
        # 오전에 등록한 부품이 오후에 수정되어도 항목은 하나면 충분하다.
        $dupKey = $name.ToUpperInvariant()
        if ($seen.ContainsKey($dupKey)) {
            if ($seen[$dupKey] -eq '(기존 매핑 파일)') {
                # 이전 실행에서 이미 기록됨 - 정상적인 누적 상황이므로 경고가 아니다
                Write-Log "이미 매핑에 있음(건너뜀): $name" -Level Debug -Step 'Step3'
            }
            else {
                $skipped++
                Write-Log ("부품명 중복으로 제외: $($f.RelativePath)`n" +
                           "  이미 등록됨: $($seen[$dupKey])") -Level Warn -Step 'Step3'
            }
            continue
        }
        $seen[$dupKey] = $f.RelativePath

        # FPT / XDP 모두 확장자를 제외한 파일명 (사용자 확정)
        $entries.Add([pscustomobject]@{ Fpt = $name; Xdp = $name })
        $added++
    }

    if ($entries.Count -eq 0) {
        Write-Log "유효한 매핑 대상이 없습니다. 파일을 생성하지 않습니다." -Level Warn -Step 'Step3'
        return $null
    }

    if (-not $PSCmdlet.ShouldProcess($OutputDirectory, "매핑/alignment 파일 생성 ($($entries.Count) 건)")) {
        Write-Log "[WHATIF] would 생성 $mappingPath ($($entries.Count) 건)" -Level Info -Step 'Step3'
        Write-Log "[WHATIF] would 생성 $alignmentPath ($($entries.Count) 건)" -Level Info -Step 'Step3'
        return $null
    }

    # --- Mapping.xdm ---------------------------------------------------------
    $mapLines = New-Object System.Collections.Generic.List[string]
    foreach ($e in $entries) {
        $mapLines.Add("FPT: $($e.Fpt)")
        $mapLines.Add("XDP: $($e.Xdp)")
        $mapLines.Add("VND: $Vendor")
        $mapLines.Add('ALT: ')      # 값이 비어도 뒤 공백 1개 유지 (샘플과 동일)
        $mapLines.Add('')           # 레코드 구분 빈 줄 (마지막 뒤에도 있음)
    }
    Write-AsciiCrlfFile -Lines @($mapLines.ToArray()) -Path $mappingPath

    # --- Alignment.dat -------------------------------------------------------
    # 형식: "FPT" "XDP" User  0 0 0 0 0 0 M   (User 뒤 공백 2개)
    $alignLines = New-Object System.Collections.Generic.List[string]
    foreach ($e in $entries) {
        $alignLines.Add(('"{0}" "{1}" {2}  0 0 0 0 0 0 M' -f @($e.Fpt, $e.Xdp, $Vendor)))
    }
    Write-AsciiCrlfFile -Lines @($alignLines.ToArray()) -Path $alignmentPath

    $msg = if ($carried -gt 0) {
        "매핑 파일 갱신: 총 $($entries.Count) 건 (기존 $carried + 신규 $added)"
    } else {
        "매핑 파일 생성: $($entries.Count) 건"
    }
    if ($skipped -gt 0) { $msg += " / 제외 $skipped 건 - 위 경고 참조" }
    Write-Log $msg -Level Info -Step 'Step3'
    Write-Log "  $mappingPath"   -Level Info -Step 'Step3'
    Write-Log "  $alignmentPath" -Level Info -Step 'Step3'

    return [pscustomobject]@{
        MappingPath   = $mappingPath
        AlignmentPath = $alignmentPath
        Count         = $entries.Count
        Carried       = $carried
        Added         = $added
        Skipped       = $skipped
    }
}
