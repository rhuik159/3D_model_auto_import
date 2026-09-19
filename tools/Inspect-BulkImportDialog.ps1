#Requires -Version 5.1
<#
.SYNOPSIS
    Bulk Import 대화상자를 열고 JAB 트리를 덤프한다.
    대화상자의 텍스트 필드 / 버튼 이름을 확인하는 진단 도구.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'Jab-Bridge.ps1')

Write-Host "JAB 초기화..." -ForegroundColor Cyan
$conn = Initialize-Jab
Write-Host "vmId=$($conn.VmId)  ok" -ForegroundColor Green

# ---------------------------------------------------------------- 메뉴 열기
# 서브메뉴 탐색 전략:
#   각 단계에서 팝업/서브메뉴가 실제로 나타난 뒤 그 안에서 다음 항목을 탐색한다.
#   루트 전체를 탐색하면 비활성 항목과 충돌할 수 있다.

function Wait-MenuItemVisible {
    param([string]$Name, [int]$TimeoutMs = 3000)
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        [Jab.Win32]::PumpMessages(20)
        # role 을 menu 계열로 한정 (frame/dialog 등 제외)
        foreach ($role in @('menu','menu item','check box menu item','radio button menu item')) {
            $el = Find-JabElement -Name $Name -Role $role -MaxDepth 10
            if ($el -and $el.States -match 'visible') { return $el }
        }
        Start-Sleep -Milliseconds 150
    }
    return $null
}

Write-Host "`n[1] Tools 클릭" -ForegroundColor Yellow
$tools = Find-JabElement -Name 'Tools' -Role 'menu' -MaxDepth 6
Write-Host "    ac=0x$($tools.Ac.ToString('X'))  states=$($tools.States)"
Invoke-JabAction -Ac $tools.Ac
Start-Sleep -Milliseconds 600
[Jab.Win32]::PumpMessages(30)

Write-Host "[2] Library 대기 + 클릭" -ForegroundColor Yellow
$lib = Wait-MenuItemVisible -Name 'Library' -TimeoutMs 3000
if (-not $lib) { throw "Library 메뉴 항목이 나타나지 않았습니다." }
Write-Host "    ac=0x$($lib.Ac.ToString('X'))  states=$($lib.States)"
Invoke-JabAction -Ac $lib.Ac
Start-Sleep -Milliseconds 600
[Jab.Win32]::PumpMessages(30)

Write-Host "[3] '3D Models' 대기 + 클릭" -ForegroundColor Yellow
$m3d = Wait-MenuItemVisible -Name '3D Models' -TimeoutMs 3000
if (-not $m3d) { throw "'3D Models' 메뉴 항목이 나타나지 않았습니다." }
Write-Host "    ac=0x$($m3d.Ac.ToString('X'))  states=$($m3d.States)"
Invoke-JabAction -Ac $m3d.Ac
Start-Sleep -Milliseconds 600
[Jab.Win32]::PumpMessages(30)

Write-Host "[4] 'Bulk Import' 대기 + 클릭" -ForegroundColor Yellow
$bi = Wait-MenuItemVisible -Name 'Bulk Import' -TimeoutMs 3000
if (-not $bi) { throw "'Bulk Import' 항목이 나타나지 않았습니다." }
Write-Host "    ac=0x$($bi.Ac.ToString('X'))  states=$($bi.States)"
Invoke-JabAction -Ac $bi.Ac
Start-Sleep -Milliseconds 800
[Jab.Win32]::PumpMessages(50)

# ---------------------------------------------------------------- 대화상자 탐색
Write-Host "`n대화상자 대기 (최대 10초)..." -ForegroundColor Cyan
$deadline = (Get-Date).AddSeconds(10)
$dlgAc    = 0L
while ((Get-Date) -lt $deadline) {
    [Jab.Win32]::PumpMessages(30)
    foreach ($role in @('dialog','file chooser','option pane')) {
        $el = Find-JabElement -Role $role -MaxDepth 5
        if ($el) { $dlgAc = $el.Ac; Write-Host "발견: role=$role  name='$($el.Name)'" -ForegroundColor Green; break }
    }
    if ($dlgAc -ne 0) { break }
    Start-Sleep -Milliseconds 300
}

if ($dlgAc -eq 0) {
    Write-Host "대화상자 미발견 - 루트 전체 덤프" -ForegroundColor Yellow
    $dlgAc = $conn.RootAc
}

# ---------------------------------------------------------------- 트리 덤프
Write-Host "`n=== 대화상자 내부 트리 ===" -ForegroundColor Yellow

function Dump {
    param([long]$Ac, [int]$Depth, [string]$Indent = '')
    if ($Depth -gt 10) { return }
    $info = Get-JabContextInfo -Ac $Ac
    if ($null -eq $info) { return }
    $line = "{0}[{1}]" -f $Indent, $info.role_en_US
    if ($info.name)        { $line += "  '$($info.name)'" }
    if ($info.states_en_US){ $line += "  ({$($info.states_en_US)})" }
    if ($info.accessibleAction) {
        $acts = Get-JabActions -Ac $Ac
        $line += "  ACT:[$($acts -join ',')]"
    }
    Write-Host $line

    $children = Get-JabChildren -Ac $Ac
    foreach ($ch in $children) {
        Dump -Ac $ch -Depth ($Depth+1) -Indent ($Indent+'  ')
        Release-JabObject -Ac $ch
    }
}

Dump -Ac $dlgAc -Depth 0
Release-JabObject -Ac $conn.RootAc
