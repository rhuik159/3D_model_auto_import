#Requires -Version 5.1
<#
.SYNOPSIS
    JAB 를 사용해 Cockpit Swing UI 트리를 덤프한다.

.DESCRIPTION
    Jab-Bridge.ps1 을 dot-source 로 로드하고, 루트부터 깊이 우선으로
    모든 컴포넌트를 출력한다. Inspect-CockpitUI.ps1 의 UIA 버전과 달리
    Java Swing 내부 구조가 그대로 노출된다.

.PARAMETER MaxDepth
    최대 탐색 깊이. 기본 8. 트리가 깊으면 느려진다.

.PARAMETER Filter
    이 문자열이 Name / Role / States 에 포함된 노드만 출력한다.

.PARAMETER ShowActions
    액션이 있는 컴포넌트의 액션 목록도 함께 출력한다.

.PARAMETER OutFile
    지정하면 결과를 파일에도 저장한다 (UTF-8 BOM).

.EXAMPLE
    .\Get-CockpitTree.ps1
    전체 트리 덤프

.EXAMPLE
    .\Get-CockpitTree.ps1 -Filter "Tools" -ShowActions
    Tools 관련 항목과 액션 목록

.EXAMPLE
    .\Get-CockpitTree.ps1 -MaxDepth 12 -OutFile cockpit-tree.txt
    깊이 12까지 덤프해서 파일 저장
#>
[CmdletBinding()]
param(
    [int]$MaxDepth    = 8,
    [string]$Filter   = '',
    [switch]$ShowActions,
    [string]$OutFile  = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- 로드
$bridgePath = Join-Path $PSScriptRoot 'Jab-Bridge.ps1'
if (-not (Test-Path -LiteralPath $bridgePath)) {
    throw "Jab-Bridge.ps1 를 찾을 수 없습니다: $bridgePath"
}
. $bridgePath

# ---------------------------------------------------------------- 초기화
Write-Host "JAB 초기화 중..." -ForegroundColor Cyan
$conn = Initialize-Jab
Write-Host ("연결 완료  vmId=$($conn.VmId)  ac=0x{0:X}" -f $conn.RootAc) -ForegroundColor Green
Write-Host ("JRE  : $($conn.VersionInfo.VMversion)") -ForegroundColor DarkGray
Write-Host ("DLL  : $($conn.VersionInfo.bridgeWinDLLVersion)") -ForegroundColor DarkGray
Write-Host ""

# ---------------------------------------------------------------- 출력 버퍼
$lines = [System.Collections.Generic.List[string]]::new()
$script:hitCount = 0

function Add-Line {
    param([string]$text, [System.ConsoleColor]$color = 'Gray')
    $lines.Add($text)
    Write-Host $text -ForegroundColor $color
}

# ---------------------------------------------------------------- 트리 덤프
function Dump-Node {
    param(
        [long]$Ac,
        [int]$Depth,
        [string]$Indent = ''
    )

    if ($Depth -gt $MaxDepth) {
        if ($Filter -eq '') {
            Add-Line ("{0}  [이하 생략 - MaxDepth={1}]" -f $Indent, $MaxDepth) 'DarkGray'
        }
        return
    }

    $info = Get-JabContextInfo -Ac $Ac
    if ($null -eq $info) { return }

    # 표시 여부 판단
    $show = $true
    if ($Filter -ne '') {
        $show = ($info.name -like "*$Filter*") -or
                ($info.role_en_US -like "*$Filter*") -or
                ($info.states_en_US -like "*$Filter*")
    }

    if ($show) {
        $script:hitCount++

        # 기본 라인
        $line = "{0}[{1}]" -f $Indent, $info.role_en_US
        if ($info.name)        { $line += "  '$($info.name)'" }
        if ($info.states_en_US){ $line += "  ({$($info.states_en_US)})" }
        $line += "  ch=$($info.childrenCount)"
        if ($info.accessibleAction) { $line += "  *ACT*" }

        $color = switch ($info.role_en_US) {
            { $_ -match 'menu'    } { 'Yellow'  }
            { $_ -match 'button'  } { 'Cyan'    }
            { $_ -match 'text'    } { 'White'   }
            { $_ -match 'tree'    } { 'Green'   }
            { $_ -match 'table'   } { 'Green'   }
            { $_ -match 'dialog'  } { 'Magenta' }
            default                 { 'Gray'    }
        }
        Add-Line $line $color

        # 액션 목록
        if ($ShowActions -and $info.accessibleAction) {
            $acts = Get-JabActions -Ac $Ac
            if ($acts.Count -gt 0) {
                Add-Line ("{0}    actions: {1}" -f $Indent, ($acts -join ', ')) 'DarkCyan'
            }
        }
    }

    # 자식 탐색
    if ($info.childrenCount -gt 0) {
        $children = Get-JabChildren -Ac $Ac
        foreach ($child in $children) {
            Dump-Node -Ac $child -Depth ($Depth + 1) -Indent ($Indent + '  ')
            Release-JabObject -Ac $child
        }
    }
}

Add-Line "=== Cockpit JAB UI 트리 (깊이 $MaxDepth) ===" 'Cyan'
Add-Line ""

try {
    Dump-Node -Ac $conn.RootAc -Depth 0
}
finally {
    Release-JabObject -Ac $conn.RootAc
}

Add-Line ""
Add-Line "총 $($script:hitCount) 개 노드$(if ($Filter) { " (필터: '$Filter')" })" 'Cyan'

# ---------------------------------------------------------------- 파일 출력
if ($OutFile -ne '') {
    $utf8bom = New-Object System.Text.UTF8Encoding($true)
    $absPath = if ([System.IO.Path]::IsPathRooted($OutFile)) {
        $OutFile
    } else {
        Join-Path (Get-Location).Path $OutFile
    }
    [System.IO.File]::WriteAllLines($absPath, $lines.ToArray(), $utf8bom)
    Write-Host "파일 저장: $OutFile" -ForegroundColor Green
}
