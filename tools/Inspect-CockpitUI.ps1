#Requires -Version 5.1
<#
.SYNOPSIS
    EDM Library Cockpit 창의 UI Automation 트리를 덤프한다.

.DESCRIPTION
    GUI 자동화가 가능한지 판단하기 위한 탐색 도구다.
    Cockpit 은 Java Swing 앱이므로 UIA 노출이 제한적일 수 있다.
    메뉴 항목이 이름으로 잡히면 UIA 방식이 가능하고,
    아무것도 안 잡히면 좌표 기반으로 가야 한다.

.PARAMETER ProcessId
    대상 Cockpit 프로세스 ID. 생략하면 창이 있는 첫 번째 것을 쓴다.

.PARAMETER MaxDepth
    트리 탐색 깊이. 기본 4. 너무 깊으면 느리다.

.PARAMETER Filter
    이 문자열이 Name/ControlType 에 포함된 요소만 출력한다.

.EXAMPLE
    .\Inspect-CockpitUI.ps1
    최상위 구조 덤프

.EXAMPLE
    .\Inspect-CockpitUI.ps1 -Filter Tools
    Tools 메뉴 관련 요소만
#>
[CmdletBinding()]
param(
    [int]$ProcessId = 0,
    [int]$MaxDepth = 4,
    [string]$Filter
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

# ------------------------------------------------------------ 대상 창 찾기
if ($ProcessId -eq 0) {
    $proc = @(Get-Process -Name 'xDMLibraryClient' -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 })
    if ($proc.Count -eq 0) {
        throw "창이 있는 Cockpit 프로세스를 찾을 수 없습니다."
    }
    if ($proc.Count -gt 1) {
        Write-Host "창이 있는 Cockpit 이 $($proc.Count) 개입니다:" -ForegroundColor Yellow
        $proc | ForEach-Object { Write-Host "  PID $($_.Id)  '$($_.MainWindowTitle)'" }
        Write-Host "  첫 번째(PID $($proc[0].Id))를 사용합니다. -ProcessId 로 지정 가능." -ForegroundColor Yellow
    }
    $target = $proc[0]
}
else {
    $target = Get-Process -Id $ProcessId
}

Write-Host "대상: PID $($target.Id) / '$($target.MainWindowTitle)'" -ForegroundColor Green
Write-Host ""

$root = [System.Windows.Automation.AutomationElement]::FromHandle($target.MainWindowHandle)
if ($null -eq $root) {
    throw "창 핸들에서 AutomationElement 를 얻지 못했습니다."
}

# --------------------------------------------------------------- 트리 덤프
$script:hitCount = 0

function Show-Element {
    param(
        [System.Windows.Automation.AutomationElement]$Element,
        [int]$Depth,
        [string]$Indent = ''
    )

    if ($Depth -gt $MaxDepth) {
        return
    }

    try {
        $name = $Element.Current.Name
        $type = $Element.Current.ControlType.ProgrammaticName -replace 'ControlType\.', ''
        $autoId = $Element.Current.AutomationId
        $class = $Element.Current.ClassName
    }
    catch {
        return
    }

    $line = "{0}{1}" -f $Indent, $type
    if ($name) { $line += "  '$name'" }
    if ($autoId) { $line += "  [id=$autoId]" }
    if ($class) { $line += "  {$class}" }

    $show = $true
    if ($Filter) {
        $show = ($name -like "*$Filter*") -or ($type -like "*$Filter*") -or ($class -like "*$Filter*")
    }
    if ($show) {
        $script:hitCount++
        Write-Host $line
    }

    # 자식 탐색
    try {
        $children = $Element.FindAll(
            [System.Windows.Automation.TreeScope]::Children,
            [System.Windows.Automation.Condition]::TrueCondition)
        foreach ($child in $children) {
            Show-Element -Element $child -Depth ($Depth + 1) -Indent ($Indent + '  ')
        }
    }
    catch {
        # 접근 불가한 하위는 건너뛴다
    }
}

Write-Host "=== UI Automation 트리 (깊이 $MaxDepth) ===" -ForegroundColor Cyan
Show-Element -Element $root -Depth 0

Write-Host ""
Write-Host "총 $($script:hitCount) 개 요소" -ForegroundColor Cyan

if ($script:hitCount -le 1) {
    Write-Host ""
    Write-Host "요소가 거의 잡히지 않았습니다." -ForegroundColor Yellow
    Write-Host "Java Swing 앱은 기본적으로 UIA 를 노출하지 않습니다." -ForegroundColor Yellow
    Write-Host "Java Access Bridge 활성화가 필요할 수 있습니다:" -ForegroundColor Yellow
    Write-Host "  %JAVA_HOME%\bin\jabswitch -enable" -ForegroundColor Yellow
}
