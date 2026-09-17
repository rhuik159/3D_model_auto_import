<#
.SYNOPSIS
    Phase A 로컬 더미 테스트용 폴더/파일 생성.
#>
[CmdletBinding()]
param([string]$Root = 'C:\Temp\3dtest')

$ErrorActionPreference = 'Stop'

if (Test-Path -LiteralPath $Root) { Remove-Item -LiteralPath $Root -Recurse -Force }

$src = Join-Path $Root 'source'
foreach ($d in @('Capacitor', 'Resistor', 'Connector')) {
    New-Item -ItemType Directory -Path (Join-Path $src $d) -Force | Out-Null
}
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

New-StepFile (Join-Path $src 'Capacitor\CAP-0402-10uF.step')  '#1=CARTESIAN_POINT((0.,0.,0.));'
New-StepFile (Join-Path $src 'Capacitor\부품_커패시터_001.step') '#1=CARTESIAN_POINT((1.,0.,0.));'
New-StepFile (Join-Path $src 'Resistor\RES-0603-10K.stp')      '#1=CARTESIAN_POINT((2.,0.,0.));'
New-StepFile (Join-Path $src 'Resistor\R[bracket]-TEST.step')  '#1=CARTESIAN_POINT((3.,0.,0.));'
New-StepFile (Join-Path $src 'Connector\CONN-USB-C.step')      '#1=CARTESIAN_POINT((4.,0.,0.));'

# 무시되어야 할 비대상 확장자
[System.IO.File]::WriteAllText((Join-Path $src 'Connector\readme.txt'), 'not a step file')

Write-Host "테스트 픽스처 생성 완료: $Root"
Get-ChildItem -LiteralPath $src -Recurse -File | ForEach-Object {
    Write-Host ("  " + $_.FullName.Substring($src.Length + 1))
}
