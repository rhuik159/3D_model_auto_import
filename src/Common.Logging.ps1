# Common.Logging.ps1 - 파일 로깅 및 보관 기간 정리

Set-StrictMode -Version Latest

$script:LogPath  = $null
$script:LogLevel = 'Info'
$script:WarnCount = 0

$script:LevelRank = @{ 'Debug' = 0; 'Info' = 1; 'Warn' = 2; 'Error' = 3 }

function Initialize-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LogDir,
        [ValidateSet('Debug', 'Info', 'Warn', 'Error')][string]$Level = 'Info'
    )
    # -WhatIf 중에도 로그는 남겨야 하므로 디렉토리 생성을 억제하지 않는다
    if (-not (Test-Path -LiteralPath $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir -Force -WhatIf:$false | Out-Null
    }
    $script:LogPath   = Join-Path $LogDir ("sync_{0}.log" -f (Get-Date -Format 'yyyy-MM-dd'))
    $script:LogLevel  = $Level
    $script:WarnCount = 0
    return $script:LogPath
}

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Message,
        [ValidateSet('Debug', 'Info', 'Warn', 'Error')][string]$Level = 'Info',
        [string]$Step = ''
    )

    if ($script:LevelRank[$Level] -lt $script:LevelRank[$script:LogLevel]) { return }
    if ($Level -eq 'Warn') { $script:WarnCount++ }

    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
    $tag   = if ($Step) { "[$Step]" } else { '' }
    $line  = '{0} [{1,-5}] {2} {3}' -f $stamp, $Level, $tag, $Message

    switch ($Level) {
        'Error' { Write-Host $line -ForegroundColor Red }
        'Warn'  { Write-Host $line -ForegroundColor Yellow }
        'Debug' { Write-Host $line -ForegroundColor DarkGray }
        default { Write-Host $line }
    }

    if ($script:LogPath) {
        # 한글 경로/파일명이 로그에 들어가므로 UTF-8 로 append
        $enc = New-Object System.Text.UTF8Encoding($true)
        $sw  = New-Object System.IO.StreamWriter($script:LogPath, $true, $enc)
        try { $sw.WriteLine($line) } finally { $sw.Dispose() }
    }
}

function Get-LogWarningCount { return $script:WarnCount }

function Write-LogBanner {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Text)
    $bar = '=' * 70
    Write-Log $bar
    Write-Log $Text
    Write-Log $bar
}

<#
.SYNOPSIS
    보관 기간이 지난 로그/CSV 정리. 실패해도 파이프라인을 중단하지 않는다.
#>
function Remove-AgedFiles {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$Filter,
        [Parameter(Mandatory)][int]$Days
    )

    if ($Days -le 0) { return }        # 0 = 정리 안 함
    if (-not (Test-Path -LiteralPath $Directory)) { return }

    $cutoff = (Get-Date).AddDays(-$Days)
    Get-ChildItem -LiteralPath $Directory -Filter $Filter -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        ForEach-Object {
            if ($PSCmdlet.ShouldProcess($_.FullName, '삭제')) {
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                Write-Log "보관기간 초과 삭제: $($_.Name)" -Level Debug -Step 'Cleanup'
            }
            else {
                Write-Log "[WHATIF] would 삭제 $($_.FullName)" -Level Info -Step 'Cleanup'
            }
        }
}
