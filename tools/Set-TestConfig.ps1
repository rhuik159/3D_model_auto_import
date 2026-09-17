[CmdletBinding()]
param([string]$Root = 'C:\Temp\3dtest')
$repo = Split-Path -Parent $PSScriptRoot
$c = Get-Content -Raw (Join-Path $repo 'config\config.sample.json') | ConvertFrom-Json
$c.paths.sourceShare    = Join-Path $Root 'source'
$c.paths.designLibrary  = Join-Path $Root 'library'
$c.paths.dateFolderRoot = Join-Path $Root 'batches'
$json = $c | ConvertTo-Json -Depth 6
[System.IO.File]::WriteAllText((Join-Path $repo 'config\config.json'), $json,
    (New-Object System.Text.UTF8Encoding($false)))
Write-Host "테스트 설정 기록 완료"
