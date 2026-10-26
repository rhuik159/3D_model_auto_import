#Requires -Version 5.1
<#
.SYNOPSIS
    Phase A 자동 회귀 테스트. 로컬 더미 폴더(flat 구조)로 전체 시나리오를 검증한다.
.PARAMETER Engine
    테스트할 PowerShell 실행 파일 (pwsh 또는 powershell).
.PARAMETER TestRoot
    테스트용 임시 폴더 루트.
#>
[CmdletBinding()]
param(
    [string]$Engine   = 'pwsh',
    [string]$TestRoot = 'C:\Temp\3dtest'
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$pass = 0; $fail = 0

# ---------------------------------------------------------------------------
# 실제 운영 상태(config.json / snapshot.json)를 백업했다가 끝나면 되돌린다.
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
    # Phase A 는 1~4단계만 검증한다. 픽스처는 가짜 STEP 이라 Cockpit Import 를 돌리면 실패한다.
    if ($ExtraArgs -notcontains '-SkipImport') { $ExtraArgs = @($ExtraArgs) + '-SkipImport' }
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
    $generated = @('_batch_manifest.csv', 'Mapping.xdm', 'Alignment.dat')
    return @(Get-ChildItem $dir -Recurse -File | Where-Object { $generated -notcontains $_.Name })
}

function Get-Changes {
    $f = Get-ChildItem "$repo\output\changes_*.csv" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $f) { return @() }
    return @(Import-Csv $f.FullName)
}

Write-Host "`n=== Phase A 테스트 ($Engine) ===" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# [1] 최초 실행 = BaselineOnly (스냅샷만 생성, 날짜 폴더 없음)
# ---------------------------------------------------------------------------
Write-Host "`n[1] 최초 실행 = 기준선"
Reset-All
$rc = Invoke-Pipeline
Assert-That "종료코드 0 또는 1" ($rc -in @(0,1)) "(실제: $rc)"
Assert-That "날짜 폴더를 만들지 않음" ((Get-BatchFiles).Count -eq 0)
Assert-That "스냅샷 생성됨" (Test-Path "$repo\state\snapshot.json")
if (Test-Path "$repo\state\snapshot.json") {
    $snap = Get-Content -Raw "$repo\state\snapshot.json" | ConvertFrom-Json
    Assert-That "스냅샷에 5개 파일" ($snap.fileCount -eq 5) "(실제: $($snap.fileCount))"
    Assert-That "isBaseline = true" ($snap.isBaseline -eq $true)
}

# ---------------------------------------------------------------------------
# [2] 무변경 재실행
# ---------------------------------------------------------------------------
Write-Host "`n[2] 무변경 재실행"
$rc = Invoke-Pipeline
Assert-That "종료코드 0" ($rc -eq 0) "(실제: $rc)"
Assert-That "변경 0건" ((Get-Changes).Count -eq 0)
Assert-That "날짜 폴더 없음" ((Get-BatchFiles).Count -eq 0)

# ---------------------------------------------------------------------------
# [3-6] 신규3(한글1 포함) / 수정1 / 타임스탬프만1 / 삭제1
# source 는 TopDirectoryOnly 이므로 모든 파일을 source 루트에 직접 배치한다.
#
# ★ 설계 유의사항 ★
# Step1 의 /XC /XN /XO 옵션 때문에 source 를 바꿔도 library 파일은
# 덮어쓰지 않는다. 따라서:
#   - "New": source 에 새로 추가해야 library 에도 새로 복사됨
#   - "Modified": library 파일을 직접 변경해야 해시가 달라짐
#   - "TouchedOnly": library 파일의 mtime 만 변경
#   - "Deleted": source 에서 제거, library 는 그대로 유지
# ---------------------------------------------------------------------------
Write-Host "`n[3-6] 신규3(한글1 포함) / 수정1 / 타임스탬프만1 / 삭제1"
$src = Join-Path $TestRoot 'source'
$lib = Join-Path $TestRoot 'library'

# New: source 에 신규 파일 추가 (library 에 없는 파일이므로 Step1 이 복사)
Set-Content "$src\NEW-A.step"        "ISO-10303-21;`nDATA;`n#1=A;`nENDSEC;"
Set-Content "$src\NEW-B.step"        "ISO-10303-21;`nDATA;`n#1=B;`nENDSEC;"
# 한글 파일명: 배치에는 복사되지만 ASCII 전용 Mapping.xdm 에는 담을 수 없다.
# 경고와 함께 제외되는지 검증하는 케이스.
Set-Content "$src\한글부품_001.step" "ISO-10303-21;`nDATA;`n#1=K;`nENDSEC;"

# Modified: library 의 파일 내용을 직접 변경 → 해시가 달라져 Modified 로 분류됨
# (Step1 의 /XC /XN /XO 가 있으므로 source 변경은 library 에 전파되지 않는다)
Set-Content "$lib\RES-0603-10K.stp"  "ISO-10303-21;`nDATA;`n#1=CHANGED;`nENDSEC;"

# TouchedOnly: library 파일의 mtime 만 변경 (내용/해시 동일)
(Get-Item "$lib\CONN-USB-C.step").LastWriteTimeUtc = [datetime]'2027-01-01T00:00:00Z'

# Deleted: source 에서 제거 (library 에는 유지되어야 함)
Remove-Item "$src\부품_커패시터_001.step"

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
# includeModified 기본값 false → New 3건만 배치에 포함
Assert-That "배치에 3건 (New 3, Modified 는 기본 제외)" ($batch.Count -eq 3) "(실제: $($batch.Count))"
Assert-That "TouchedOnly 는 배치 제외" (-not ($batch.Name -contains 'CONN-USB-C.step'))
Assert-That "Modified 는 기본 배치 제외" (-not ($batch.Name -contains 'RES-0603-10K.stp'))

# ★ 핵심 안전요건: 원본에서 삭제된 파일이 라이브러리에 유지되어야 한다
$deletedInLib = Join-Path $TestRoot 'library\부품_커패시터_001.step'
Assert-That "삭제된 파일이 라이브러리에 유지됨 (핵심)" (Test-Path -LiteralPath $deletedInLib)

# ---------------------------------------------------------------------------
# [7] CSV 인코딩 / 한글 / 대괄호
# ---------------------------------------------------------------------------
Write-Host "`n[7] CSV 인코딩 / 한글 / 대괄호"
$listCsv = Get-ChildItem "$repo\output\filelist_*.csv" | Select-Object -First 1
$bytes = [System.IO.File]::ReadAllBytes($listCsv.FullName)
Assert-That "filelist UTF-8 BOM 존재" ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
$rows = Import-Csv $listCsv.FullName
Assert-That "대괄호 파일명 스캔됨" (@($rows | Where-Object { $_.FileName -like '*bracket*' }).Count -eq 1)
Assert-That "한글 파일명 보존" (@($rows | Where-Object { $_.FileName -match '커패시터' }).Count -ge 1)

# ---------------------------------------------------------------------------
# [8] Mapping.xdm / Alignment.dat 포맷
# ---------------------------------------------------------------------------
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

    $mapHasBom = $mapBytes.Length -ge 3 -and $mapBytes[0] -eq 0xEF -and $mapBytes[1] -eq 0xBB -and $mapBytes[2] -eq 0xBF
    Assert-That "Mapping.xdm BOM 없음" (-not $mapHasBom)
    Assert-That "Mapping.xdm 전체 ASCII"   (@($mapBytes | Where-Object { $_ -gt 127 }).Count -eq 0)
    Assert-That "Alignment.dat 전체 ASCII" (@($alnBytes | Where-Object { $_ -gt 127 }).Count -eq 0)

    $mapText = [System.Text.Encoding]::ASCII.GetString($mapBytes)
    $alnText = [System.Text.Encoding]::ASCII.GetString($alnBytes)

    Assert-That "CRLF 개행 사용" ($mapText.Contains("`r`n"))
    Assert-That "LF 단독 개행 없음" (-not ($mapText -replace "`r`n", '').Contains("`n"))

    # New 3건 + Modified 1건이 매핑 대상. 단 한글부품_001 은 ASCII 아니므로 제외.
    # → ASCII 파일: NEW-A, NEW-B (New), RES-0603-10K (Modified) = FPT 3건
    # (includeModified=false 는 배치 복사 여부이고, 매핑은 New+Modified 모두 포함)
    $fptCount = ([regex]::Matches($mapText, '(?m)^FPT: ')).Count
    $xdpCount = ([regex]::Matches($mapText, '(?m)^XDP: ')).Count
    $vndCount = ([regex]::Matches($mapText, '(?m)^VND: User')).Count
    $altCount = ([regex]::Matches($mapText, "(?m)^ALT: \r?$")).Count
    Assert-That "FPT 3건 (New 2 + Modified 1, 한글 제외)" ($fptCount -eq 3) "(실제: $fptCount)"
    Assert-That "FPT/XDP/VND/ALT 줄 수 일치" ($fptCount -eq $xdpCount -and $xdpCount -eq $vndCount -and $vndCount -eq $altCount)
    Assert-That "'ALT: ' 뒤 공백 유지" ($altCount -eq 3) "(실제: $altCount)"

    $fpts = [regex]::Matches($mapText, '(?m)^FPT: (.+)$') | ForEach-Object { $_.Groups[1].Value }
    $xdps = [regex]::Matches($mapText, '(?m)^XDP: (.+)$') | ForEach-Object { $_.Groups[1].Value }
    Assert-That "FPT 와 XDP 동일" (-not (Compare-Object $fpts $xdps))
    Assert-That "확장자가 제거됨" (@($fpts | Where-Object { $_ -match '\.(step|stp)$' }).Count -eq 0)

    $alnLines = @($alnText -split "`r`n" | Where-Object { $_ -ne '' })
    Assert-That "Alignment 3줄 (FPT 와 일치)" ($alnLines.Count -eq 3) "(실제: $($alnLines.Count))"
    $okFormat = @($alnLines | Where-Object { $_ -match '^"[^"]+" "[^"]+" User  0 0 0 0 0 0 M$' }).Count
    Assert-That "Alignment 줄 형식 (User 뒤 공백2, 0x6, M)" ($okFormat -eq $alnLines.Count) "(일치: $okFormat/$($alnLines.Count))"

    Assert-That "비ASCII 파일명은 매핑에서 제외됨" (-not ($mapText -match '\?\?\?'))
}

# ---------------------------------------------------------------------------
# [9] 하루 2회 실행 시 누적
# ---------------------------------------------------------------------------
Write-Host "`n[9] 하루 2회 실행 = 결과 누적"

$mapBefore = @([regex]::Matches(
    [IO.File]::ReadAllText($mapFile, [Text.Encoding]::ASCII), '(?m)^FPT: ')).Count
$csvPath   = (Get-ChildItem "$repo\output\changes_*.csv" | Select-Object -First 1).FullName
$csvBefore = @(Import-Csv $csvPath).Count

Set-Content "$src\SECOND-RUN.step" "ISO-10303-21;`nDATA;`n#1=S;`nENDSEC;"
$rc = Invoke-Pipeline

$mapText2 = [IO.File]::ReadAllText($mapFile, [Text.Encoding]::ASCII)
$mapAfter = @([regex]::Matches($mapText2, '(?m)^FPT: ')).Count
$alnAfter = @([IO.File]::ReadAllLines($alnFile, [Text.Encoding]::ASCII) |
               Where-Object { $_ -ne '' }).Count
$csvAfter = @(Import-Csv $csvPath)

Assert-That "Mapping.xdm 누적 (이전 $mapBefore -> $($mapBefore+1))" ($mapAfter -eq $mapBefore + 1) "(실제: $mapAfter)"
Assert-That "이전 실행분이 남아있음" ($mapText2 -match 'NEW-A')
Assert-That "이번 실행분이 추가됨"   ($mapText2 -match 'SECOND-RUN')
Assert-That "Alignment.dat 도 같은 건수" ($alnAfter -eq $mapAfter) "(실제: $alnAfter)"
Assert-That "changes CSV 누적" ($csvAfter.Count -gt $csvBefore) "(이전 $csvBefore -> 현재 $($csvAfter.Count))"
Assert-That "RunTime 컬럼 존재" ($csvAfter[0].PSObject.Properties.Name -contains 'RunTime')
Assert-That "RunTime 이 2종류 이상" (@($csvAfter | Select-Object -ExpandProperty RunTime -Unique).Count -ge 2)

# 같은 부품 재변경 → 매핑 항목은 1건만 유지
Set-Content "$src\SECOND-RUN.step" "ISO-10303-21;`nDATA;`n#1=S-CHANGED;`nENDSEC;"
$rc = Invoke-Pipeline
$mapText3 = [IO.File]::ReadAllText($mapFile, [Text.Encoding]::ASCII)
$dupCount = @([regex]::Matches($mapText3, '(?m)^FPT: SECOND-RUN\r?$')).Count
Assert-That "같은 부품 재변경해도 매핑은 1건" ($dupCount -eq 1) "(실제: $dupCount)"

# filelist 는 현재 라이브러리 스냅샷 → 누적하지 않음
$listRows = @(Import-Csv (Get-ChildItem "$repo\output\filelist_*.csv" | Select-Object -First 1).FullName)
$libCount = @(Get-ChildItem (Join-Path $TestRoot 'library\*') -File -Include *.step, *.stp).Count
Assert-That "filelist 는 덮어쓰기 (중복 없음)" ($listRows.Count -eq $libCount) "(CSV $($listRows.Count) vs 실제 $libCount)"

# ---------------------------------------------------------------------------
# [10] -WhatIf 드라이런: 실제 변경 없음
# ---------------------------------------------------------------------------
Write-Host "`n[10] -WhatIf 드라이런"
# 새 파일을 원본에 추가한 뒤 드라이런 → 라이브러리에 복사되지 않아야 한다
Set-Content "$src\WHATIF-TEST.step" "ISO-10303-21;`nDATA;`n#1=W;`nENDSEC;"
$snapHashBefore = (Get-FileHash "$repo\state\snapshot.json").Hash
$rc = Invoke-Pipeline @('-WhatIf')
Assert-That "종료코드 0 또는 1" ($rc -in @(0,1)) "(실제: $rc)"
$libHasWhatif = Test-Path (Join-Path $TestRoot 'library\WHATIF-TEST.step')
Assert-That "라이브러리에 복사 안 됨" (-not $libHasWhatif)
Assert-That "스냅샷 미변경" ((Get-FileHash "$repo\state\snapshot.json").Hash -eq $snapHashBefore)
Remove-Item "$src\WHATIF-TEST.step"

# ---------------------------------------------------------------------------
# [11] TreatAllAsNew: 최초 실행 시 PreSyncKeys 기준 분류
# ---------------------------------------------------------------------------
Write-Host "`n[11] TreatAllAsNew 최초 실행"
Reset-All
# config 의 firstRunMode 를 TreatAllAsNew 로 변경
$cfgPath = "$repo\config\config.json"
$cfgObj  = Get-Content -Raw $cfgPath | ConvertFrom-Json
$cfgObj.behavior.firstRunMode = 'TreatAllAsNew'
[System.IO.File]::WriteAllText($cfgPath, ($cfgObj | ConvertTo-Json -Depth 6),
    (New-Object System.Text.UTF8Encoding($false)))

# 미리 라이브러리에 한 파일을 직접 넣어둔다 (이미 import된 것처럼 시뮬레이션)
$preExisting = Join-Path $TestRoot 'library\CAP-0402-10uF.step'
Copy-Item (Join-Path $TestRoot 'source\CAP-0402-10uF.step') $preExisting -Force

$rc = Invoke-Pipeline
Assert-That "종료코드 0 또는 1" ($rc -in @(0,1)) "(실제: $rc)"
$ch11 = Get-Changes
# CAP-0402-10uF 는 robocopy 전부터 라이브러리에 있었으므로 TouchedOnly 여야 한다
$preTouched = @($ch11 | Where-Object { $_.FileName -eq 'CAP-0402-10uF.step' -and $_.ChangeType -eq 'TouchedOnly' }).Count
Assert-That "PreSyncKeys 파일은 TouchedOnly" ($preTouched -eq 1) "(실제: $preTouched)"
# 나머지 파일은 New
$newCount11 = @($ch11 | Where-Object { $_.ChangeType -eq 'New' }).Count
Assert-That "새로 복사된 파일은 New" ($newCount11 -ge 1) "(실제: $newCount11)"

# ---------------------------------------------------------------------------
# [12] 원본 빈 폴더 = 중단 (스냅샷 보호)
# ---------------------------------------------------------------------------
Write-Host "`n[12] 원본 빈 폴더 = 중단 (스냅샷 보호)"
Reset-All
# 기준선 먼저 생성
Invoke-Pipeline | Out-Null
$snapBefore = (Get-FileHash "$repo\state\snapshot.json").Hash

$srcBak = Join-Path $TestRoot 'source_bak'
Move-Item (Join-Path $TestRoot 'source') $srcBak
New-Item -ItemType Directory -Path (Join-Path $TestRoot 'source') | Out-Null
$rc = Invoke-Pipeline
Assert-That "종료코드 3" ($rc -eq 3) "(실제: $rc)"
Assert-That "스냅샷 미변경" ((Get-FileHash "$repo\state\snapshot.json").Hash -eq $snapBefore)
Remove-Item (Join-Path $TestRoot 'source') -Recurse -Force
Move-Item $srcBak (Join-Path $TestRoot 'source')

# ---------------------------------------------------------------------------
# [13] <<SET-ME>> 미설정 감지
# ---------------------------------------------------------------------------
Write-Host "`n[13] <<SET-ME>> 미설정 감지"
Reset-All
$cfgPath2 = "$repo\config\config.json"
Copy-Item $cfgPath2 "$repo\config\config.bak.json" -Force
$c = Get-Content -Raw $cfgPath2 | ConvertFrom-Json
$c.paths.sourceShare = '<<SET-ME>>'
[System.IO.File]::WriteAllText($cfgPath2, ($c | ConvertTo-Json -Depth 6),
    (New-Object System.Text.UTF8Encoding($false)))
$rc = Invoke-Pipeline
Assert-That "종료코드 2" ($rc -eq 2) "(실제: $rc)"
Move-Item "$repo\config\config.bak.json" $cfgPath2 -Force

# ---------------------------------------------------------------------------
# [14] -SkipSync: 스냅샷 없이 재실행 (스캔만)
# ---------------------------------------------------------------------------
Write-Host "`n[14] -SkipSync 단독 실행"
Reset-All
# 기준선 생성 후 스냅샷 삭제 → SkipSync 로 스캔만
Invoke-Pipeline | Out-Null
Remove-Item "$repo\state\snapshot.json" -Force -ErrorAction SilentlyContinue
$rc = Invoke-Pipeline @('-SkipSync', '-SkipImport')
Assert-That "종료코드 0 또는 1" ($rc -in @(0,1)) "(실제: $rc)"
Assert-That "스냅샷 재생성됨" (Test-Path "$repo\state\snapshot.json")

# ---------------------------------------------------------------------------
# 결과
# ---------------------------------------------------------------------------
Restore-ProductionState

Write-Host "`n=== 결과: $pass PASS / $fail FAIL ===" -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
if ($fail -gt 0) { exit 1 }
