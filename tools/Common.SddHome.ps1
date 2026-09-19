#Requires -Version 5.1
<#
.SYNOPSIS
    Xpedition 설치 경로(SDD_HOME) 탐색.

.DESCRIPTION
    툴 버전이 올라가면 설치 폴더가 바뀐다(예: EEVX.2.14.1 → EEVX.2.15).
    경로를 코드에 박아두면 그때마다 여러 스크립트를 고쳐야 하므로
    이 파일 하나에서만 결정한다.

    Jab-Bridge.ps1 과 Start-Cockpit.ps1 이 dot-source 해서 쓴다.
#>

function Get-SddHome {
    <#
    .SYNOPSIS
        Xpedition 설치 경로(SDD_HOME)를 찾는다.

    .DESCRIPTION
        순서대로 찾는다:
          1. 환경변수 XPEDITION_SDD_HOME  (운영에서 명시적으로 고정하고 싶을 때)
          2. 환경변수 SDD_HOME            (Xpedition 설치 시 설정되기도 함)
          3. C:\MentorGraphics\EEVX.* 중 가장 최신 버전
          4. D:\MentorGraphics\EEVX.*

        3~4번은 버전 문자열을 숫자로 파싱해 정렬하므로
        EEVX.2.9 < EEVX.2.14.1 을 올바르게 판단한다(문자열 정렬이면 반대가 된다).

        ★ 후보는 반드시 '쓸 수 있는지' 검증한다 ★
        폴더만 있다고 되는 게 아니다. 실제로 이 PC 에는 EEVX.2.14 와
        EEVX.2.14.1 이 둘 다 있는데 환경변수 SDD_HOME 은 JAB DLL 도
        dmsdesktop.bat 도 없는 EEVX.2.14 를 가리키고 있었다.
        그대로 믿으면 멀쩡한 설정이 깨지므로 필요한 파일이 있는지 확인한다.

    .PARAMETER SearchRoots
        탐색할 루트 폴더. 기본 C:\MentorGraphics, D:\MentorGraphics

    .PARAMETER SkipValidation
        검증 없이 첫 후보를 그대로 쓴다(진단용).

    .OUTPUTS
        SDD_HOME 전체 경로. 못 찾으면 예외.
    #>
    param(
        [string[]]$SearchRoots = @('C:\MentorGraphics', 'D:\MentorGraphics'),
        [switch]$SkipValidation
    )

    # 이 파이프라인이 실제로 쓰는 파일들. 하나라도 없으면 후보에서 제외한다.
    $required = @(
        'common\win64\jre\default\bin\windowsaccessbridge-64.dll',  # JAB
        'dms\bin\dmsdesktop.bat'                                    # Cockpit 기동
    )
    function Test-SddUsable {
        param([string]$Path)
        if (-not (Test-Path -LiteralPath $Path)) { return $false }
        if ($SkipValidation) { return $true }
        foreach ($r in $required) {
            if (-not (Test-Path -LiteralPath (Join-Path $Path $r))) { return $false }
        }
        return $true
    }

    foreach ($envName in @('XPEDITION_SDD_HOME', 'SDD_HOME')) {
        $v = [Environment]::GetEnvironmentVariable($envName)
        if (-not $v) { continue }
        if (Test-SddUsable -Path $v) {
            Write-Verbose "SDD_HOME (환경변수 ${envName}): $v"
            return $v
        }
        Write-Verbose "환경변수 ${envName} 은 필요한 파일이 없어 건너뜁니다: $v"
    }

    $candidates = @()
    foreach ($root in $SearchRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $dirs = @(Get-ChildItem -LiteralPath $root -Directory -Filter 'EEVX.*' -ErrorAction SilentlyContinue)
        foreach ($d in $dirs) {
            $sdd = Join-Path $d.FullName 'SDD_HOME'
            if (-not (Test-SddUsable -Path $sdd)) { continue }
            # 'EEVX.2.14.1' → [2,14,1] 로 파싱해 숫자 정렬
            $parts = @($d.Name -replace '^EEVX\.', '' -split '\.')
            $nums = @()
            foreach ($p in $parts) {
                $n = 0
                [void][int]::TryParse($p, [ref]$n)
                $nums += $n
            }
            while ($nums.Count -lt 4) { $nums += 0 }
            $candidates += [PSCustomObject]@{
                Path = $sdd
                Key  = ($nums[0] * 1000000 + $nums[1] * 10000 + $nums[2] * 100 + $nums[3])
                Name = $d.Name
            }
        }
    }

    if ($candidates.Count -gt 0) {
        $best = @($candidates | Sort-Object Key -Descending)[0]
        Write-Verbose "SDD_HOME (자동 탐색, $($best.Name)): $($best.Path)"
        return $best.Path
    }

    throw ("사용 가능한 Xpedition 설치(SDD_HOME)를 찾지 못했습니다.`n" +
           "  확인한 위치: $($SearchRoots -join ', ')`n" +
           "  필요한 파일: $($required -join ', ')`n" +
           "  다른 위치에 설치했다면 환경변수 XPEDITION_SDD_HOME 을 설정하세요.")
}

function Get-JabDllPath {
    <#
    .SYNOPSIS
        windowsaccessbridge-64.dll 의 전체 경로를 돌려준다.
    #>
    param([string]$SddHome = '')
    if (-not $SddHome) { $SddHome = Get-SddHome }
    $dll = Join-Path $SddHome 'common\win64\jre\default\bin\windowsaccessbridge-64.dll'
    if (-not (Test-Path -LiteralPath $dll)) {
        throw ("JAB DLL 을 찾지 못했습니다: $dll`n" +
               "  Xpedition 설치가 온전한지, JRE 경로가 바뀌지 않았는지 확인하세요.")
    }
    return $dll
}
