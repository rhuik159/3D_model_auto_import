<#
.SYNOPSIS
    프로젝트의 모든 .ps1/.psm1 을 UTF-8 BOM 으로 재기록한다.
.DESCRIPTION
    ★ 중요 ★
    Windows PowerShell 5.1 은 BOM 없는 .ps1 을 ANSI(949) 로 해석한다.
    한글 주석/문자열이 들어간 스크립트를 BOM 없이 저장하면 5.1 에서
    문자가 깨지고 중괄호 짝이 어긋나 파서 오류가 발생한다.
    (PS 7 은 BOM 없어도 UTF-8 로 읽으므로 증상이 안 보인다 - 함정)

    편집기가 BOM 없이 저장했다면 이 스크립트를 실행할 것.
#>
[CmdletBinding()]
param([string]$Root = (Split-Path -Parent $PSScriptRoot))

$withBom    = New-Object System.Text.UTF8Encoding($true)
$withoutBom = New-Object System.Text.UTF8Encoding($false)

Get-ChildItem -LiteralPath $Root -Recurse -Include *.ps1, *.psm1 -ErrorAction SilentlyContinue |
    ForEach-Object {
        $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
        $hasBom = $bytes.Length -ge 3 -and
                  $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
        if (-not $hasBom) {
            $text = [System.IO.File]::ReadAllText($_.FullName, $withoutBom)
            [System.IO.File]::WriteAllText($_.FullName, $text, $withBom)
            Write-Host "  BOM 추가: $($_.FullName.Substring($Root.Length + 1))"
        }
    }
Write-Host "완료."
