#Requires -Version 5.1
<#
.SYNOPSIS
    Phase A 로컬 더미 테스트용 폴더/파일 생성.

.DESCRIPTION
    Step1 은 TopDirectoryOnly 로 복사하므로 source 루트 바로 아래에 파일을 둔다.
    library 도 flat 구조(하위폴더 없음)로 유지해야 파이프라인과 일치한다.
#>
[CmdletBinding()]
param([string]$Root = 'C:\Temp\3dtest')

$ErrorActionPreference = 'Stop'

if (Test-Path -LiteralPath $Root) { Remove-Item -LiteralPath $Root -Recurse -Force }

$src = Join-Path $Root 'source'
New-Item -ItemType Directory -Path $src      -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $Root 'library') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $Root 'batches') -Force | Out-Null

function New-StepFile {
    param([string]$Path, [string]$Body)
    $content = @"
ISO-10303-21;
HEADER;
FILE_DESCRIPTION((''),'2;1');
FILE_NAME('$(Split-Path $Path -Leaf)','2026-09-16T00:00:00',(''),(''),'','','');
ENDSEC;
DATA;
$Body
ENDSEC;
END-ISO-10303-21;
"@
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $content, $enc)
}

# 모두 source 루트 바로 아래 (TopDirectoryOnly 설계)
New-StepFile (Join-Path $src 'CAP-0402-10uF.step')      '#1=CARTESIAN_POINT((0.,0.,0.));'
New-StepFile (Join-Path $src '부품_커패시터_001.step')  '#1=CARTESIAN_POINT((1.,0.,0.));'
New-StepFile (Join-Path $src 'RES-0603-10K.stp')        '#1=CARTESIAN_POINT((2.,0.,0.));'
New-StepFile (Join-Path $src 'R[bracket]-TEST.step')    '#1=CARTESIAN_POINT((3.,0.,0.));'
New-StepFile (Join-Path $src 'CONN-USB-C.step')         '#1=CARTESIAN_POINT((4.,0.,0.));'

# 무시되어야 할 비대상 확장자
[System.IO.File]::WriteAllText((Join-Path $src 'readme.txt'), 'not a step file')

Write-Host "테스트 픽스처 생성 완료: $Root"
Get-ChildItem -LiteralPath $src -File | ForEach-Object {
    Write-Host ("  " + $_.Name)
}
