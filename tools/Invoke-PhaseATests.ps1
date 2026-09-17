<#
.SYNOPSIS
    Phase A 자동 회귀 테스트. 로컬 더미 폴더로 전체 시나리오를 검증한다.
.PARAMETER Engine
    테스트할 PowerShell 실행 파일 (pwsh 또는 powershell).
#>
[CmdletBinding()]
param(
    [string]$Engine = 'pwsh',
    [string]$TestRoot = 'C:\Temp\3dtest'
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$pass = 0; $fail = 0

# ---------------------------------------------------------------------------
# 실제 운영 상태(config.json / snapshot.json)를 백업했다가 끝나면 되돌린다.
# 이게 없으면 테스트가 운영 스냅샷을 더미 데이터로 덮어써서,
# 다음 실제 실행이 '전체 신규' 로 오인하게 된다.
# ---------------------------------------------------------------------------
$backupDir = Join-Path $env:TEMP ("3dsync_backup_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
$preserve = @(
    "$repo\config\config.json",
    "$repo\state\snapshot.json",
    "$repo\state\snapshot.bak.json"
)
foreach ($f in $preserve) {
    if (Test-Path -LiteralPath $f) {
        Copy-Item -LiteralPath $f -Destination (Join-Path $backupDir (Split-Path $f -Leaf)) -Force
    }
}

function Restore-ProductionState {
    foreach ($f in $script:preserve) {
        $name = Split-Path $f -Leaf
        $bak  = Join-Path $script:backupDir $name
        if (Test-Path -LiteralPath $bak) {
            Copy-Item -LiteralPath $bak -Destination $f -Force
        }
        elseif (Test-Path -LiteralPath $f) {
            # 테스트 시작 시 없던 파일이면 테스트가 만든 것이므로 제거
            Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
        }
    }
    Remove-Item -LiteralPath $script:backupDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "`n운영 상태(config/snapshot)를 복원했습니다." -ForegroundColor DarkGray
}

function Assert-That {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) { Write-Host "  [PASS] $Name" -ForegroundColor Green; $script:pass++ }
    else { Write-Host "  [FAIL] $Name $Detail" -ForegroundColor Red; $script:fail++ }
}

function Invoke-Pipeline {
    param([string[]]$ExtraArgs = @())
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command',
                 "& '$repo\Run-3DModelSync.ps1' $($ExtraArgs -join ' ') *>`$null; exit `$LASTEXITCODE")
    $p = Start-Process -FilePath $Engine -ArgumentList $argList -NoNewWindow -Wait -PassThru
    return $p.ExitCode
}

function Reset-All {
    if (Test-Path $TestRoot) { Remove-Item $TestRoot -Recurse -Force }
    Get-ChildItem "$repo\state"  -File -ErrorAction SilentlyContinue | Remove-Item -Force
    Get-ChildItem "$repo\output" -Recurse -File -ErrorAction SilentlyContinue | Remove-Item -Force
    Get-ChildItem "$repo\logs"   -File -ErrorAction SilentlyContinue | Remove-Item -Force
    & $Engine -NoProfile -File "$repo\tools\New-TestFixture.ps1" -Root $TestRoot *>$null
    & $Engine -NoProfile -File "$repo\tools\Set-TestConfig.ps1"  -Root $TestRoot *>$null
}

function Get-BatchFiles {
    $today = Get-Date -Format 'yyyy-MM-dd'
    $dir = Join-Path $TestRoot "batches\$today"
    if (-not (Test-Path $dir)) { return @() }
    # step 파일만 센다 (매니페스트/매핑/alignment 는 생성물이므로 제외)
    $generated = @('_batch_manifest.csv', 'Mapping.xdm', 'Alignment.dat')
    return @(Get-ChildItem $dir -Recurse -File | Where-Object { $generated -notcontains $_.Name })
}

function Get-Changes {
    $f = Get-ChildItem "$repo\output\changes_*.csv" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $f) { return @() }
    return @(Import-Csv $f.FullName)
}

Write-Host "`n=== Phase A 테스트 ($Engine) ===" -ForegroundColor Cyan

# --- 1. 기준선 ---------------------------------------------------------
Write-Host "`n[1] 최초 실행 = 기준선"
Reset-All
$rc = Invoke-Pipeline
Assert-That "종료코드 0 또는 1" ($rc -in @(0,1)) "(실제: $rc)"
Assert-That "날짜 폴더를 만들지 않음" ((Get-BatchFiles).Count -eq 0)
Assert-That "스냅샷 생성됨" (Test-Path "$repo\state\snapshot.json")
$snap = Get-Content -Raw "$repo\state\snapshot.json" | ConvertFrom-Json
Assert-That "스냅샷에 5개 파일" ($snap.fileCount -eq 5) "(실제: $($snap.fileCount))"
Assert-That "isBaseline = true" ($snap.isBaseline -eq $true)

# --- 2. 무변경 재실행 ---------------------------------------------------
Write-Host "`n[2] 무변경 재실행"
$rc = Invoke-Pipeline
Assert-That "변경 0건" ((Get-Changes).Count -eq 0)
Assert-That "날짜 폴더 없음" ((Get-BatchFiles).Count -eq 0)

# --- 3~6. 신규/수정/터치/삭제 -------------------------------------------
Write-Host "`n[3-6] 신규3(한글1 포함) / 수정1 / 타임스탬프만1 / 삭제1"
$src = Join-Path $TestRoot 'source'
Set-Content "$src\Capacitor\NEW-A.step"  "ISO-10303-21;`nDATA;`n#1=A;`nENDSEC;"
Set-Content "$src\Connector\NEW-B.step"  "ISO-10303-21;`nDATA;`n#1=B;`nENDSEC;"
# 한글 파일명: 배치에는 복사되지만 ASCII 파일인 Mapping.xdm 에는 담을 수 없다.
# 조용히 깨지지 않고 경고와 함께 제외되는지 검증하기 위한 케이스.
Set-Content "$src\Capacitor\한글부품_001.step" "ISO-10303-21;`nDATA;`n#1=K;`nENDSEC;"
Set-Content "$src\Resistor\RES-0603-10K.stp" "ISO-10303-21;`nDATA;`n#1=CHANGED;`nENDSEC;"
(Get-Item "$src\Connector\CONN-USB-C.step").LastWriteTimeUtc = [datetime]'2027-01-01T00:00:00Z'
Remove-Item "$src\Capacitor\부품_커패시터_001.step"

$rc = Invoke-Pipeline
$ch = Get-Changes
$byType = @{}
foreach ($t in @('New','Modified','TouchedOnly','Deleted')) {
    $byType[$t] = @($ch | Where-Object { $_.ChangeType -eq $t }).Count
}
Assert-That "New = 3"         ($byType.New -eq 3)         "(실제: $($byType.New))"
Assert-That "Modified = 1"    ($byType.Modified -eq 1)    "(실제: $($byType.Modified))"
Assert-That "TouchedOnly = 1" ($byType.TouchedOnly -eq 1) "(실제: $($byType.TouchedOnly))"
Assert-That "Deleted = 1"     ($byType.Deleted -eq 1)     "(실제: $($byType.Deleted))"

$batch = Get-BatchFiles
Assert-That "배치에 4건 (New3+Modified1)" ($batch.Count -eq 4) "(실제: $($batch.Count))"
Assert-That "TouchedOnly 는 배치 제외" (-not ($batch.Name -contains 'CONN-USB-C.step'))
Assert-That "하위 폴더 구조 보존" (@($batch | Where-Object { $_.FullName -match 'Capacitor|Connector|Resistor' }).Count -eq $batch.Count)

# ★ 핵심 안전요건 ★
$deletedInLib = Join-Path $TestRoot 'library\Capacitor\부품_커패시터_001.step'
Assert-That "삭제된 파일이 라이브러리에 유지됨 (핵심)" (Test-Path -LiteralPath $deletedInLib)

# --- 7. 인코딩 / 특수문자 ------------------------------------------------
Write-Host "`n[7] CSV 인코딩 / 한글 / 대괄호"
$listCsv = Get-ChildItem "$repo\output\filelist_*.csv" | Select-Object -First 1
$bytes = [System.IO.File]::ReadAllBytes($listCsv.FullName)
Assert-That "UTF-8 BOM 존재" ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
$rows = Import-Csv $listCsv.FullName
Assert-That "대괄호 파일명 스캔됨" (@($rows | Where-Object { $_.FileName -like '*bracket*' }).Count -eq 1)
Assert-That "한글 파일명 보존" (@($rows | Where-Object { $_.FileName -match '커패시터' }).Count -ge 1)

# --- 8. Mapping.xdm / Alignment.dat 포맷 --------------------------------
Write-Host "`n[8] Mapping.xdm / Alignment.dat"
$today2   = Get-Date -Format 'yyyy-MM-dd'
$batchDir = Join-Path $TestRoot "batches\$today2"
$mapFile  = Join-Path $batchDir 'Mapping.xdm'
$alnFile  = Join-Path $batchDir 'Alignment.dat'

Assert-That "Mapping.xdm 이 날짜 폴더에 생성됨"   (Test-Path -LiteralPath $mapFile)
Assert-That "Alignment.dat 이 날짜 폴더에 생성됨" (Test-Path -LiteralPath $alnFile)

if ((Test-Path -LiteralPath $mapFile) -and (Test-Path -LiteralPath $alnFile)) {
    $mapBytes = [System.IO.File]::ReadAllBytes($mapFile)
    $alnBytes = [System.IO.File]::ReadAllBytes($alnFile)

    # BOM 이 없어야 한다 (Xpedition 이 읽는 형식)
    $mapHasBom = $mapBytes.Length -ge 3 -and $mapBytes[0] -eq 0xEF -and $mapBytes[1] -eq 0xBB -and $mapBytes[2] -eq 0xBF
    Assert-That "Mapping.xdm BOM 없음" (-not $mapHasBom)

    # 전부 ASCII 범위여야 한다
    Assert-That "Mapping.xdm 전체 ASCII"   (@($mapBytes | Where-Object { $_ -gt 127 }).Count -eq 0)
    Assert-That "Alignment.dat 전체 ASCII" (@($alnBytes | Where-Object { $_ -gt 127 }).Count -eq 0)

    $mapText = [System.Text.Encoding]::ASCII.GetString($mapBytes)
    $alnText = [System.Text.Encoding]::ASCII.GetString($alnBytes)

    Assert-That "CRLF 개행 사용" ($mapText.Contains("`r`n"))
    Assert-That "LF 단독 개행 없음" (-not ($mapText -replace "`r`n", '').Contains("`n"))

    # 배치에 들어간 3건 중 ASCII 파일명만 매핑에 포함 (한글 파일명은 제외됨)
    $fptCount = ([regex]::Matches($mapText, '(?m)^FPT: ')).Count
    $xdpCount = ([regex]::Matches($mapText, '(?m)^XDP: ')).Count
    $vndCount = ([regex]::Matches($mapText, '(?m)^VND: User')).Count
    # .NET multiline 에서 '$' 는 \r 앞에서 매칭되므로 후행 공백 검사에 \r? 가 필요하다
    $altCount = ([regex]::Matches($mapText, "(?m)^ALT: \r?$")).Count
    Assert-That "FPT 3건" ($fptCount -eq 3) "(실제: $fptCount)"
    Assert-That "FPT/XDP/VND/ALT 줄 수 일치" ($fptCount -eq $xdpCount -and $xdpCount -eq $vndCount -and $vndCount -eq $altCount)
    Assert-That "'ALT: ' 뒤 공백 유지" ($altCount -eq 3) "(실제: $altCount)"

    # FPT 와 XDP 가 동일해야 한다 (사용자 확정: 둘 다 파일명)
    $fpts = [regex]::Matches($mapText, '(?m)^FPT: (.+)$') | ForEach-Object { $_.Groups[1].Value }
    $xdps = [regex]::Matches($mapText, '(?m)^XDP: (.+)$') | ForEach-Object { $_.Groups[1].Value }
    Assert-That "FPT 와 XDP 동일" (-not (Compare-Object $fpts $xdps))
    Assert-That "확장자가 제거됨" (@($fpts | Where-Object { $_ -match '\.(step|stp)$' }).Count -eq 0)

    # Alignment 각 줄 형식
    $alnLines = @($alnText -split "`r`n" | Where-Object { $_ -ne '' })
    Assert-That "Alignment 3줄" ($alnLines.Count -eq 3) "(실제: $($alnLines.Count))"
    $okFormat = @($alnLines | Where-Object { $_ -match '^"[^"]+" "[^"]+" User  0 0 0 0 0 0 M$' }).Count
    Assert-That "Alignment 줄 형식 (User 뒤 공백2, 0x6, M)" ($okFormat -eq $alnLines.Count) "(일치: $okFormat/$($alnLines.Count))"

    # 한글 파일명은 ASCII 파일에 담을 수 없으므로 제외되어야 한다
    Assert-That "비ASCII 파일명은 매핑에서 제외됨" (-not ($mapText -match '\?\?\?'))
}

# --- 9. 하루 2회 실행 시 누적 --------------------------------------------
Write-Host "`n[9] 하루 2회 실행 = 결과 누적"

# 현재까지: New 3 + Modified 1 이 배치/매핑에 반영된 상태.
# 여기서 한 번 더 실행하면 오전분이 사라지지 않고 누적되어야 한다.
$mapBefore = @([regex]::Matches(
    [IO.File]::ReadAllText($mapFile, [Text.Encoding]::ASCII), '(?m)^FPT: ')).Count
$csvPath    = (Get-ChildItem "$repo\output\changes_*.csv" | Select-Object -First 1).FullName
$csvBefore  = @(Import-Csv $csvPath).Count

Set-Content "$src\Connector\SECOND-RUN.step" "ISO-10303-21;`nDATA;`n#1=S;`nENDSEC;"
$rc = Invoke-Pipeline

$mapText2  = [IO.File]::ReadAllText($mapFile, [Text.Encoding]::ASCII)
$mapAfter  = @([regex]::Matches($mapText2, '(?m)^FPT: ')).Count
$alnAfter  = @([IO.File]::ReadAllLines($alnFile, [Text.Encoding]::ASCII) |
                Where-Object { $_ -ne '' }).Count
$csvAfter  = @(Import-Csv $csvPath)

Assert-That "Mapping.xdm 누적 (이전 $mapBefore -> $($mapBefore+1))" ($mapAfter -eq $mapBefore + 1) "(실제: $mapAfter)"
Assert-That "이전 실행분이 남아있음" ($mapText2 -match 'NEW-A')
Assert-That "이번 실행분이 추가됨"   ($mapText2 -match 'SECOND-RUN')
Assert-That "Alignment.dat 도 같은 건수" ($alnAfter -eq $mapAfter) "(실제: $alnAfter)"
Assert-That "changes CSV 누적" ($csvAfter.Count -gt $csvBefore) "(이전 $csvBefore -> 현재 $($csvAfter.Count))"
Assert-That "RunTime 컬럼 존재" ($csvAfter[0].PSObject.Properties.Name -contains 'RunTime')
Assert-That "RunTime 이 2종류 이상" (@($csvAfter | Select-Object -ExpandProperty RunTime -Unique).Count -ge 2)

# 같은 부품을 다시 변경해도 매핑 항목은 1건만 유지되어야 한다 (사용자 확정)
Set-Content "$src\Connector\SECOND-RUN.step" "ISO-10303-21;`nDATA;`n#1=S-CHANGED;`nENDSEC;"
$rc = Invoke-Pipeline
$mapText3 = [IO.File]::ReadAllText($mapFile, [Text.Encoding]::ASCII)
$dupCount = @([regex]::Matches($mapText3, '(?m)^FPT: SECOND-RUN\r?$')).Count
Assert-That "같은 부품 재변경해도 매핑은 1건" ($dupCount -eq 1) "(실제: $dupCount)"

# filelist 는 현재 상태 스냅샷이므로 누적하지 않는다
$listRows = @(Import-Csv (Get-ChildItem "$repo\output\filelist_*.csv" | Select-Object -First 1).FullName)
$libCount = @(Get-ChildItem (Join-Path $TestRoot 'library') -Recurse -File -Include *.step, *.stp |
              Where-Object { $_.FullName -notmatch '\\dateFolderRoot\\' }).Count
Assert-That "filelist 는 덮어쓰기 (중복 없음)" ($listRows.Count -eq $libCount) "(CSV $($listRows.Count) vs 실제 $libCount)"

# --- 12. 원본 0건 감지 ---------------------------------------------------
Write-Host "`n[12] 원본 빈 폴더 = 중단 (스냅샷 보호)"
# 원본 공유폴더가 비어 보이는 상황(권한 상실 등)을 재현한다.
$snapBefore = (Get-FileHash "$repo\state\snapshot.json").Hash
$srcBak = Join-Path $TestRoot 'source_bak'
Move-Item (Join-Path $TestRoot 'source') $srcBak
New-Item -ItemType Directory -Path (Join-Path $TestRoot 'source') | Out-Null
$rc = Invoke-Pipeline
Assert-That "종료코드 3" ($rc -eq 3) "(실제: $rc)"
Assert-That "스냅샷 미변경" ((Get-FileHash "$repo\state\snapshot.json").Hash -eq $snapBefore)
Remove-Item (Join-Path $TestRoot 'source') -Recurse -Force
Move-Item $srcBak (Join-Path $TestRoot 'source')

# --- 13. 미설정 config ---------------------------------------------------
Write-Host "`n[13] <<SET-ME>> 미설정 감지"
Copy-Item "$repo\config\config.json" "$repo\config\config.bak.json" -Force
$c = Get-Content -Raw "$repo\config\config.json" | ConvertFrom-Json
$c.paths.sourceShare = '<<SET-ME>>'
[System.IO.File]::WriteAllText("$repo\config\config.json", ($c | ConvertTo-Json -Depth 6),
    (New-Object System.Text.UTF8Encoding($false)))
$rc = Invoke-Pipeline
Assert-That "종료코드 2" ($rc -eq 2) "(실제: $rc)"
Move-Item "$repo\config\config.bak.json" "$repo\config\config.json" -Force

# --- 결과 ---------------------------------------------------------------
Restore-ProductionState

Write-Host "`n=== 결과: $pass PASS / $fail FAIL ===" -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
if ($fail -gt 0) { exit 1 }
