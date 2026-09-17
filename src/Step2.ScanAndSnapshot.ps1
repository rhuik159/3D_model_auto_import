# Step2.ScanAndSnapshot.ps1 - 라이브러리 스캔, 해시, 스냅샷 비교

Set-StrictMode -Version Latest

<#
.SYNOPSIS
    설계팀 라이브러리를 스캔해 파일 목록을 만든다 (해시는 이후 단계에서).
.DESCRIPTION
    - EnumerateFiles: 스트리밍이라 대용량에서 메모리 부담이 적고
      5.1 의 Get-ChildItem -Recurse 보다 긴 경로에 강하다.
    - 파일별 try/catch: 잠긴 파일 하나가 전체 실행을 중단시키면 안 된다.
#>
function Get-LibraryFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string[]]$IncludeExtensions,
        [string[]]$ExcludeFolderNames = @()
    )

    $extSet = @{}
    foreach ($e in $IncludeExtensions) { $extSet[$e.ToLowerInvariant()] = $true }

    $excludeSet = @{}
    foreach ($x in $ExcludeFolderNames) { $excludeSet[$x.ToLowerInvariant()] = $true }

    $rootFull   = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    $rootPrefix = $rootFull + '\'
    $results    = New-Object System.Collections.Generic.List[object]
    $skipped    = 0

    try {
        $enum = [System.IO.Directory]::EnumerateFiles(
            $rootFull, '*', [System.IO.SearchOption]::AllDirectories)
    }
    catch {
        throw "라이브러리 폴더를 열거할 수 없습니다: $rootFull`n  $($_.Exception.Message)"
    }

    foreach ($full in $enum) {
        try {
            $ext = [System.IO.Path]::GetExtension($full).ToLowerInvariant()
            if (-not $extSet.ContainsKey($ext)) { continue }

            $rel = $full.Substring($rootPrefix.Length)

            # 제외 폴더 검사 (마지막 요소는 파일명이므로 제외)
            $parts = $rel.Split('\')
            $excluded = $false
            for ($i = 0; $i -lt $parts.Length - 1; $i++) {
                if ($excludeSet.ContainsKey($parts[$i].ToLowerInvariant())) {
                    $excluded = $true
                    break
                }
            }
            if ($excluded) { continue }

            # 260자 초과 대비 확장 접두사
            $access = ConvertTo-ExtendedPath $full
            $fi = New-Object System.IO.FileInfo($access)

            $category = if ($parts.Length -gt 1) { $parts[0] } else { '(root)' }

            $results.Add([pscustomobject]@{
                RelativePath     = $rel
                Key              = ConvertTo-SnapshotKey $rel
                FullPath         = $full
                AccessPath       = $access
                FileName         = [System.IO.Path]::GetFileName($full)
                PartNumber       = [System.IO.Path]::GetFileNameWithoutExtension($full)
                Category         = $category
                Extension        = $ext
                SizeBytes        = $fi.Length
                LastWriteTimeUtc = $fi.LastWriteTimeUtc.ToString('o')
                Sha256           = $null
            })
        }
        catch {
            $skipped++
            Write-Log "파일 접근 실패(건너뜀): $full - $($_.Exception.Message)" -Level Warn -Step 'Step2'
        }
    }

    if ($skipped -gt 0) {
        Write-Log "접근 실패로 건너뛴 파일: $skipped 건" -Level Warn -Step 'Step2'
    }
    return $results
}

<#
.SYNOPSIS
    스냅샷의 mtime 값을 비교 가능한 ISO 8601 문자열로 정규화한다.
.DESCRIPTION
    ★ 함정 ★
    ConvertFrom-Json 은 ISO 8601 문자열을 [DateTime] 으로 자동 변환한다.
    그대로 [string] 캐스팅하면 로캘 형식('09/16/2026 06:01:48')이 되어
    밀리초가 날아가고, 원본 'o' 포맷과 절대 일치하지 않는다.
    그 결과 매 실행마다 전체 파일이 TouchedOnly 로 오분류된다.
#>
function ConvertTo-IsoUtcString {
    [CmdletBinding()]
    param([Parameter()]$Value)

    if ($null -eq $Value) { return '' }
    if ($Value -is [datetime]) {
        return $Value.ToUniversalTime().ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    }

    $text = [string]$Value
    $parsed = [datetime]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::RoundtripKind
    if ([datetime]::TryParse($text, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
        return $parsed.ToUniversalTime().ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    return $text
}

function Read-Snapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $raw  = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        $json = $raw | ConvertFrom-Json

        # PS 5.1 의 ConvertFrom-Json 에는 -AsHashtable 이 없으므로 수동 변환 (O(1) 조회용)
        $map = @{}
        if ($json.PSObject.Properties.Name -contains 'files' -and $json.files) {
            foreach ($p in $json.files.PSObject.Properties) {
                $map[$p.Name] = $p.Value
            }
        }
        return [pscustomobject]@{
            SchemaVersion = $json.schemaVersion
            CreatedUtc    = $json.createdUtc
            SourceRoot    = $json.sourceRoot
            IsBaseline    = $json.isBaseline
            Files         = $map
        }
    }
    catch {
        Write-Log "스냅샷 읽기 실패: $Path - $($_.Exception.Message)" -Level Warn -Step 'Step2'
        return $null
    }
}

<#
.SYNOPSIS
    스냅샷을 원자적으로 기록한다.
.DESCRIPTION
    현재본을 .bak 으로 회전 -> 임시파일 기록 -> Move-Item -Force 로 교체.
    쓰기 도중 죽어도 잘린 스냅샷이 남지 않는다.
#>
function Write-Snapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Files,
        [switch]$IsBaseline
    )

    $map = [ordered]@{}
    foreach ($f in $Files) {
        $map[$f.Key] = [ordered]@{
            h = $f.Sha256
            s = $f.SizeBytes
            m = $f.LastWriteTimeUtc
        }
    }

    $doc = [ordered]@{
        schemaVersion = 1
        createdUtc    = (Get-Date).ToUniversalTime().ToString('o')
        sourceRoot    = $SourceRoot
        fileCount     = $Files.Count
        isBaseline    = [bool]$IsBaseline
        files         = $map
    }

    # -Depth 명시 필수: PS 5.1 기본값은 2 라서 files 내용이 조용히 잘린다.
    $json = $doc | ConvertTo-Json -Depth 5 -Compress

    $dir  = Split-Path -Parent $Path
    $base = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $bak  = Join-Path $dir ($base + '.bak.json')
    $tmp  = "$Path.tmp"

    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tmp, $json, $enc)

    if (Test-Path -LiteralPath $Path) {
        Move-Item -LiteralPath $Path -Destination $bak -Force
    }
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

<#
.SYNOPSIS
    현재 스캔 결과를 직전 스냅샷과 비교해 변경을 분류한다.
.DESCRIPTION
    해시 최적화: size 와 mtime 이 모두 같으면 이전 해시를 재사용한다.
    분류:
      New          - 스냅샷에 없음                -> 배치 포함
      Modified     - 해시 상이                     -> 배치 포함
      TouchedOnly  - 해시 동일, mtime/size 만 다름 -> 보고만, 배치 제외
      Deleted      - 스냅샷에 있으나 현재 없음     -> 보고만, 삭제 안 함
      Unchanged    - 완전 동일                     -> CSV 제외
#>
function Compare-WithSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$CurrentFiles,
        [Parameter()]$Snapshot,
        [Parameter(Mandatory)][string]$HashAlgorithm,
        [int]$MaxFileSizeMB = 0,
        [switch]$ForceRehash,
        # 원본 공유폴더의 키 집합(hashtable). 삭제 판정 기준.
        [Parameter()]$SourceKeys
    )

    $prev = if ($Snapshot) { $Snapshot.Files } else { @{} }
    $changes  = New-Object System.Collections.Generic.List[object]
    $reused     = 0
    $hashed     = 0
    $hashFailed = 0
    $seenKeys = @{}

    foreach ($f in $CurrentFiles) {
        $seenKeys[$f.Key] = $true
        $old = if ($prev.ContainsKey($f.Key)) { $prev[$f.Key] } else { $null }

        # mtime 은 양쪽 모두 정규화해서 비교한다 (ConvertTo-IsoUtcString 주석 참조)
        $sizeMatch = $old -and ([int64]$old.s -eq [int64]$f.SizeBytes)
        $timeMatch = $old -and
                     ((ConvertTo-IsoUtcString $old.m) -eq (ConvertTo-IsoUtcString $f.LastWriteTimeUtc))

        if ($old -and $sizeMatch -and $timeMatch -and -not $ForceRehash) {
            # 내용이 바뀌지 않았다고 보고 이전 해시 재사용 (핵심 성능 최적화)
            $f.Sha256 = $old.h
            $reused++
            continue    # Unchanged
        }

        if ($MaxFileSizeMB -gt 0 -and $f.SizeBytes -gt ($MaxFileSizeMB * 1MB)) {
            $mb = [math]::Round($f.SizeBytes / 1MB, 1)
            Write-Log "크기 초과로 해시 생략: $($f.RelativePath) ($mb MB)" -Level Warn -Step 'Step2'
            $f.Sha256 = 'SKIPPED-TOO-LARGE'
        }
        else {
            try {
                $f.Sha256 = Get-FileSha -Path $f.AccessPath -Algorithm $HashAlgorithm
                $hashed++
            }
            catch {
                # 해시 실패 파일을 조용히 빠뜨리면 변경 감지가 무력해진다.
                # 건너뛰되 반드시 경고로 남기고 집계한다.
                $hashFailed++
                Write-Log "해시 계산 실패(건너뜀): $($f.RelativePath) - $($_.Exception.Message)" -Level Warn -Step 'Step2'
                continue
            }
        }

        if (-not $old) {
            $changes.Add((New-ChangeRecord -File $f -ChangeType 'New'))
        }
        elseif ($old.h -ne $f.Sha256) {
            $changes.Add((New-ChangeRecord -File $f -ChangeType 'Modified' -Previous $old))
        }
        else {
            # 해시는 같은데 타임스탬프/크기만 다름.
            # 이걸 Modified 로 잡으면 재Import 가 불필요한 파일이 배치를 가득 채운다.
            $changes.Add((New-ChangeRecord -File $f -ChangeType 'TouchedOnly' -Previous $old))
        }
    }

    # ------------------------------------------------------------------
    # 삭제 감지 (보고만 - 라이브러리에서는 절대 지우지 않는다)
    #
    # ★ 중요 ★ 삭제 판정 기준은 '원본 공유폴더' 다.
    #   /MIR 를 쓰지 않으므로 공유폴더에서 지워진 파일도 라이브러리에는
    #   그대로 남는다. 따라서 라이브러리만 보면 삭제를 영원히 감지할 수 없다.
    #   $SourceKeys 가 주어지면 그것을 기준으로, 없으면 (원본 접근 불가 등)
    #   삭제 판정을 건너뛴다 - 오탐으로 대량 삭제를 보고하는 것보다 안전하다.
    # ------------------------------------------------------------------
    if ($null -eq $SourceKeys) {
        Write-Log "원본 파일 목록이 없어 삭제 감지를 건너뜁니다." -Level Debug -Step 'Step2'
        return $changes
    }

    foreach ($key in $prev.Keys) {
        if (-not $SourceKeys.ContainsKey($key)) {
            $old = $prev[$key]
            $changes.Add([pscustomobject]@{
                ChangeType               = 'Deleted'
                RelativePath             = $key
                FileName                 = Split-Path $key -Leaf
                PartNumber               = [System.IO.Path]::GetFileNameWithoutExtension($key)
                Category                 = ($key -split '/')[0]
                SizeBytes                = $old.s
                LastWriteTimeUtc         = ''
                Sha256                   = ''
                PreviousSha256           = $old.h
                PreviousLastWriteTimeUtc = $old.m
                StagedToDateFolder       = 'False'
                Notes                    = '원본에서 삭제됨 - 라이브러리에는 유지'
            })
        }
    }

    Write-Log "해시: 신규계산 $hashed 건, 이전값 재사용 $reused 건" -Level Info -Step 'Step2'
    if ($hashFailed -gt 0) {
        Write-Log "해시 실패로 변경 판정에서 누락된 파일: $hashFailed 건 (위 경고 참조)" -Level Warn -Step 'Step2'
    }
    return $changes
}

function New-ChangeRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$File,
        [Parameter(Mandatory)][string]$ChangeType,
        [Parameter()]$Previous
    )
    [pscustomobject]@{
        ChangeType               = $ChangeType
        RelativePath             = $File.RelativePath
        FileName                 = $File.FileName
        PartNumber               = $File.PartNumber
        Category                 = $File.Category
        SizeBytes                = $File.SizeBytes
        LastWriteTimeUtc         = $File.LastWriteTimeUtc
        Sha256                   = $File.Sha256
        PreviousSha256           = if ($Previous) { $Previous.h } else { '' }
        PreviousLastWriteTimeUtc = if ($Previous) { $Previous.m } else { '' }
        StagedToDateFolder       = 'False'
        Notes                    = ''
    }
}

function Export-InventoryCsv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Files,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Changes,
        [Parameter(Mandatory)][string]$Path
    )

    $statusByKey = @{}
    foreach ($c in $Changes) {
        if ($c.ChangeType -ne 'Deleted') {
            $statusByKey[(ConvertTo-SnapshotKey $c.RelativePath)] = $c.ChangeType
        }
    }

    $rows = foreach ($f in $Files) {
        [pscustomobject]@{
            RelativePath     = $f.RelativePath
            FileName         = $f.FileName
            PartNumber       = $f.PartNumber
            Category         = $f.Category
            Extension        = $f.Extension
            SizeBytes        = $f.SizeBytes
            LastWriteTimeUtc = $f.LastWriteTimeUtc
            Sha256           = $f.Sha256
            Status           = if ($statusByKey.ContainsKey($f.Key)) { $statusByKey[$f.Key] } else { 'Unchanged' }
        }
    }

    Write-CsvUtf8Bom -InputObject @($rows) -Path $Path -HeaderIfEmpty @(
        'RelativePath', 'FileName', 'PartNumber', 'Category', 'Extension',
        'SizeBytes', 'LastWriteTimeUtc', 'Sha256', 'Status')
}

<#
.SYNOPSIS
    변경 리포트 CSV 를 기록한다.
.DESCRIPTION
    하루에 여러 번 실행될 수 있으므로 기본은 '누적' 이다.
    RunTime 컬럼으로 어느 회차에 잡힌 변경인지 구분할 수 있다.

    -Replace 를 주면 덮어쓴다. 같은 실행 안에서 배치 결과
    (StagedToDateFolder)를 반영해 다시 쓸 때 사용한다.
#>
function Export-ChangesCsv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Changes,
        [Parameter(Mandatory)][string]$Path,
        [string]$RunTime,
        [switch]$Replace
    )

    $header = @(
        'RunTime', 'ChangeType', 'RelativePath', 'FileName', 'PartNumber', 'Category',
        'SizeBytes', 'LastWriteTimeUtc', 'Sha256', 'PreviousSha256',
        'PreviousLastWriteTimeUtc', 'StagedToDateFolder', 'Notes')

    if (-not $RunTime) { $RunTime = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }

    # RunTime 을 맨 앞에 붙인 행으로 변환.
    # @() 필수: 1건이면 배열이 아닌 단일 객체가 되어 이후 연결/카운트가 깨진다.
    $rows = @(foreach ($c in $Changes) {
        $o = [ordered]@{ RunTime = $RunTime }
        foreach ($col in $header[1..($header.Count - 1)]) { $o[$col] = $c.$col }
        [pscustomobject]$o
    })

    if (-not $Replace) {
        # 기존 파일의 행을 앞에 이어붙인다 (누적).
        # @() 로 감싸는 이유: 행이 1개면 배열이 아닌 단일 객체가 반환되어
        # StrictMode 하에서 .Count 접근이 실패한다.
        $prev = @(Read-CsvRowsSafe -Path $Path -Header $header)
        if ($prev.Count -gt 0) {
            $rows = @($prev) + @($rows)
        }
    }

    Write-CsvUtf8Bom -InputObject @($rows) -Path $Path -HeaderIfEmpty $header
}

<#
.SYNOPSIS
    기존 CSV 를 읽어 지정한 헤더 구조의 행으로 돌려준다.
.DESCRIPTION
    파일이 없거나 손상되었으면 빈 배열을 반환한다 (누적 실패로 전체를 멈추지 않는다).
    구 버전 CSV 에 RunTime 컬럼이 없을 수 있으므로 없는 컬럼은 빈 값으로 채운다.
#>
function Read-CsvRowsSafe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$Header
    )

    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    try {
        $imported = @(Import-Csv -LiteralPath $Path)
    }
    catch {
        Write-Log "기존 CSV 를 읽을 수 없어 누적을 건너뜁니다: $Path - $($_.Exception.Message)" `
            -Level Warn -Step 'Step2'
        return @()
    }

    $out = foreach ($r in $imported) {
        $o = [ordered]@{}
        foreach ($col in $Header) {
            $o[$col] = if ($r.PSObject.Properties.Name -contains $col) { $r.$col } else { '' }
        }
        [pscustomobject]$o
    }
    return @($out)
}
