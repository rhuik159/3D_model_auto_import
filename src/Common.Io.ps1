# Common.Io.ps1 - CSV/BOM 출력, 긴 경로 처리, 동시 실행 락
# PowerShell 5.1 / 7.x 양쪽에서 동일하게 동작해야 함.

Set-StrictMode -Version Latest

<#
.SYNOPSIS
    UTF-8 BOM 포함 CSV 기록. Excel 한글 깨짐 방지.
.DESCRIPTION
    Export-Csv -Encoding 은 이식 불가:
      - PS 5.1 'UTF8'    -> BOM 있음
      - PS 7   'UTF8'    -> BOM 없음  (Excel에서 한글 깨짐)
      - PS 7   'utf8BOM' -> 정상
      - PS 5.1 'utf8BOM' -> ValidateSet 오류
    따라서 메모리에서 CSV로 변환한 뒤 바이트를 직접 기록한다.
#>
function Write-CsvUtf8Bom {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$InputObject,
        [Parameter(Mandatory)][string]$Path,
        [Parameter()][string[]]$HeaderIfEmpty
    )

    # -WhatIf 중에도 CSV 는 실제로 기록한다 (드라이런 결과를 검토해야 하므로).
    # 따라서 디렉토리 생성에 -WhatIf:$false 를 명시해 억제되지 않게 한다.
    # (억제되면 StreamWriter 가 '경로를 찾을 수 없음' 으로 실패한다)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force -WhatIf:$false | Out-Null
    }

    if ($InputObject.Count -gt 0) {
        $lines = $InputObject | ConvertTo-Csv -NoTypeInformation
    }
    elseif ($HeaderIfEmpty) {
        # 행이 없어도 헤더는 남긴다 (baseline 실행의 빈 변경 리포트 등)
        $lines = @(($HeaderIfEmpty | ForEach-Object { '"' + $_ + '"' }) -join ',')
    }
    else {
        $lines = @()
    }

    $enc = New-Object System.Text.UTF8Encoding($true)   # $true = BOM 기록
    $sw  = New-Object System.IO.StreamWriter($Path, $false, $enc)
    try {
        foreach ($line in $lines) { $sw.WriteLine($line) }
    }
    finally {
        $sw.Dispose()   # 누락 시 0바이트 파일이 남음
    }
}

<#
.SYNOPSIS
    260자 제한 회피용 확장 경로 접두사 부여.
.DESCRIPTION
    UNC는 선행 백슬래시 2개를 '\\?\UNC\' 로 치환해야 한다 (단순히 앞에 붙이면 안 됨).
#>
function ConvertTo-ExtendedPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if ($Path.StartsWith('\\?\')) { return $Path }

    # 상대경로면 확장 접두사를 쓸 수 없으므로 절대경로로 먼저 정규화
    if (-not [System.IO.Path]::IsPathRooted($Path)) { return $Path }

    # UNC 는 선행 '\\' 를 '\\?\UNC\' 로 '치환' 해야 한다 (앞에 붙이는 게 아님)
    if ($Path.StartsWith('\\')) {
        return '\\?\UNC\' + $Path.Substring(2)
    }
    return '\\?\' + $Path
}

<#
.SYNOPSIS
    상대 경로를 스냅샷 키로 정규화. 구분자 '/' 통일 + 대문자화.
.DESCRIPTION
    Windows는 대소문자를 구분하지 않으므로, 대소문자만 바뀐 이름이
    삭제+신규로 오분류되면 안 된다.
#>
function ConvertTo-SnapshotKey {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RelativePath)
    return $RelativePath.Replace('\', '/').Trim('/').ToUpperInvariant()
}

<#
.SYNOPSIS
    동시 실행 방지 락 획득. 핸들을 열어둔 채 반환한다.
.DESCRIPTION
    "파일이 존재하나" 확인 방식은 경합이 발생하므로,
    FileShare::None 으로 열어 OS가 배타성을 강제하게 한다.
    stale 락(기록된 PID가 죽음)은 회수한다.
.OUTPUTS
    성공 시 [System.IO.FileStream], 이미 실행 중이면 $null
#>
<#
.SYNOPSIS
    파일 해시를 계산한다 (.NET 직접 호출).
.DESCRIPTION
    Get-FileHash 를 쓰지 않는 이유:
    Microsoft.PowerShell.Utility 모듈이 자동 로드되지 않는 환경
    (제한된 모듈 경로, 일부 서비스 계정 세션 등)에서는 5.1 에서
    'Get-FileHash 용어가 인식되지 않습니다' 로 실패한다.
    파일별 catch 에 걸려 조용히 누락되면 변경 감지가 통째로 무력해지므로
    외부 cmdlet 의존성을 제거한다.
#>
function Get-FileSha {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Algorithm = 'SHA256'
    )

    $algo = [System.Security.Cryptography.HashAlgorithm]::Create($Algorithm)
    if (-not $algo) { throw "지원하지 않는 해시 알고리즘입니다: $Algorithm" }
    try {
        $stream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite)
        try {
            $bytes = $algo.ComputeHash($stream)
        }
        finally {
            $stream.Dispose()
        }
        return [System.BitConverter]::ToString($bytes).Replace('-', '')
    }
    finally {
        $algo.Dispose()
    }
}

function Get-RunLock {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LockPath)

    $dir = Split-Path -Parent $LockPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        try {
            $fs = [System.IO.File]::Open(
                $LockPath,
                [System.IO.FileMode]::Create,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::None)

            $bytes = [System.Text.Encoding]::UTF8.GetBytes(
                "PID=$PID`nStarted=$((Get-Date).ToString('o'))`n")
            $fs.Write($bytes, 0, $bytes.Length)
            $fs.Flush()
            return $fs
        }
        catch [System.IO.IOException] {
            # 잠겨 있음 - 보유 프로세스가 살아있는지 확인
            $holderPid = $null
            try {
                $txt = [System.IO.File]::ReadAllText($LockPath)
                if ($txt -match 'PID=(\d+)') { $holderPid = [int]$Matches[1] }
            } catch { }

            if ($holderPid) {
                $alive = Get-Process -Id $holderPid -ErrorAction SilentlyContinue
                if ($alive) { return $null }   # 정상적으로 실행 중
            }

            # stale 로 판단되면 한 번 회수 시도
            if ($attempt -eq 0) {
                Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
                continue
            }
            return $null
        }
    }
    return $null
}

function Remove-RunLock {
    [CmdletBinding()]
    param(
        [Parameter()]$LockStream,
        [Parameter(Mandatory)][string]$LockPath
    )
    if ($LockStream) {
        try { $LockStream.Dispose() } catch { }
    }
    Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
}
