#Requires -Version 5.1
<#
.SYNOPSIS
    설계팀 라이브러리의 STEP 파일이 EDM 서버에 등록돼 있는지 대조한다 (읽기 전용).

.DESCRIPTION
    라이브러리 폴더의 STEP 파일명과 EDM 의 Model3D/3DModel/UserModel 을 대조해
    누락·중복·고아 항목을 CSV 로 보고한다.

    ★ 읽기 전용 ★
      서버에 아무것도 쓰지 않는다. 누락이 나와도 재Import 는 하지 않는다.
      재Import 는 CSV 를 보고 수동으로 판단한다.

    파이프라인과 독립적으로 동작한다. 스냅샷을 읽지도 쓰지도 않으므로
    파이프라인이 도는 중에 실행해도 서로 간섭하지 않는다.

.PARAMETER LoginConfig
    app-auto-login 설정 이름. 기본 api_conf_lib.
    운영은 서버 IP 만 다르고 설정 이름은 같게 쓰는 것을 권장한다.
    (`app-auto-login -list` 로 확인)

.PARAMETER ConfigPath
    config.json 경로. 라이브러리 경로를 여기서 읽는다. 기본 ..\config\config.json

.PARAMETER LibraryRoot
    라이브러리 경로를 직접 지정한다. 주면 ConfigPath 보다 우선한다.

.PARAMETER OutCsv
    결과 CSV 경로. 기본 ..\output\edm_verify_<날짜시각>.csv

.PARAMETER Rebuild
    .class 가 최신이어도 다시 컴파일한다.

.EXAMPLE
    .\Test-EdmRegistration.ps1
    config.json 의 라이브러리를 api_conf_lib 로 대조

.EXAMPLE
    .\Test-EdmRegistration.ps1 -LoginConfig api_conf_prod
    운영 서버 설정으로 대조

.NOTES
    종료코드:
      0  전부 정상 등록
      1  미등록 있음 (또는 조회 0건)
      2  사용법/설정 오류
      3  라이브러리 접근 불가
      4  접속 또는 조회 실패
      5  컴파일 실패 / JDK 없음
#>
[CmdletBinding()]
param(
    [string]$LoginConfig = 'api_conf_lib',
    [string]$ConfigPath  = '',
    [string]$LibraryRoot = '',
    [string]$OutCsv      = '',
    [switch]$Rebuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'Common.SddHome.ps1')

function Write-Step {
    param([string]$Message, [string]$Level = 'Info')
    $color = switch ($Level) {
        'Warn'  { 'Yellow' }
        'Error' { 'Red' }
        'Ok'    { 'Green' }
        default { 'Gray' }
    }
    Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $Message) -ForegroundColor $color
}

# ------------------------------------------------------------ 라이브러리 경로
if (-not $LibraryRoot) {
    if (-not $ConfigPath) { $ConfigPath = Join-Path $RepoRoot 'config\config.json' }
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        Write-Step "설정 파일이 없습니다: $ConfigPath" -Level Error
        Write-Step "  -LibraryRoot 로 직접 지정하거나 config.json 을 만드세요." -Level Error
        exit 2
    }
    try {
        $raw = [System.IO.File]::ReadAllText($ConfigPath, [System.Text.Encoding]::UTF8)
        $cfg = $raw | ConvertFrom-Json
        $LibraryRoot = $cfg.paths.designLibrary
    }
    catch {
        Write-Step "config.json 파싱 실패: $($_.Exception.Message)" -Level Error
        exit 2
    }
}
if (-not $LibraryRoot) {
    Write-Step "라이브러리 경로를 결정하지 못했습니다." -Level Error
    exit 2
}

if (-not $OutCsv) {
    $stamp  = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    $OutCsv = Join-Path $RepoRoot ("output\edm_verify_{0}.csv" -f $stamp)
}

# ------------------------------------------------------------------ classpath
# 설치 경로는 툴 버전이 올라가면 바뀐다. Common.SddHome.ps1 이 찾아준다.
try { $SddHome = Get-SddHome }
catch {
    Write-Step "Xpedition 설치 경로를 찾지 못했습니다: $($_.Exception.Message)" -Level Error
    Write-Step "  환경변수 XPEDITION_SDD_HOME 으로 지정할 수 있습니다." -Level Error
    exit 2
}

$plugins = Join-Path $SddHome 'dms\java\DMSBrowser\plugins'
$dmsJava = Join-Path $SddHome 'dms\java'
$jars = @(
    (Join-Path $plugins 'com.mentor.datafusion.dfo.is3.jar')
    (Join-Path $plugins 'com.mentor.datafusion.dfo.jar')
    (Join-Path $plugins 'com.mentor.datafusion.dfodeps.jar')
    (Join-Path $plugins 'com.mentor.datafusion.oi.jar')
    (Join-Path $plugins 'com.mentor.datafusion.utils.jar')
    (Join-Path $dmsJava 'dmsapi.jar')
    (Join-Path $dmsJava 'logkit-1.2.2.jar')
    (Join-Path $dmsJava 'avalon-framework-4.2.0.jar')
)
$missing = @($jars | Where-Object { -not (Test-Path -LiteralPath $_) })
if ($missing.Count -gt 0) {
    Write-Step "필요한 jar 를 찾지 못했습니다 (SDD_HOME=$SddHome):" -Level Error
    $missing | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
    exit 2
}

$srcDir  = Join-Path $PSScriptRoot 'edmverify'
$srcFile = Join-Path $srcDir 'EdmVerify.java'
$clsFile = Join-Path $srcDir 'EdmVerify.class'
$cp      = ($jars + $srcDir) -join ';'

# --------------------------------------------------------------------- 컴파일
$needBuild = $Rebuild -or (-not (Test-Path -LiteralPath $clsFile))
if (-not $needBuild) {
    $srcTime = (Get-Item -LiteralPath $srcFile).LastWriteTimeUtc
    $clsTime = (Get-Item -LiteralPath $clsFile).LastWriteTimeUtc
    if ($srcTime -gt $clsTime) { $needBuild = $true }
}

if ($needBuild) {
    Write-Step "컴파일 중..."
    # EDM 런타임이 Java 17 이므로 --release 17 로 맞춘다.
    $javac = 'javac'
    $jdkJavac = Join-Path $SddHome 'common\win64\jre\default\bin\javac.exe'
    if (Test-Path -LiteralPath $jdkJavac) { $javac = $jdkJavac }

    $buildOut = & $javac --release 17 -encoding UTF-8 -cp $cp -d $srcDir $srcFile 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-Step "컴파일 실패:" -Level Error
        Write-Host $buildOut -ForegroundColor Red
        Write-Step "  JDK 가 없으면 javac 가 아니라 JRE 만 설치된 것입니다." -Level Error
        Write-Step "  이미 빌드된 .class 를 다른 장비에서 복사해 와도 됩니다." -Level Error
        exit 5
    }
    Write-Step "  컴파일 완료" -Level Ok
}

# ----------------------------------------------------------------------- 실행
$java = 'java'
$jreJava = Join-Path $SddHome 'common\win64\jre\default\bin\java.exe'
if (Test-Path -LiteralPath $jreJava) { $java = $jreJava }

Write-Step "대조 시작"
Write-Step "  로그인 설정 : $LoginConfig"
Write-Step "  라이브러리  : $LibraryRoot"
Write-Step "  출력        : $OutCsv"
Write-Host ''

& $java -cp $cp EdmVerify $LoginConfig $LibraryRoot $OutCsv
$rc = $LASTEXITCODE

Write-Host ''
switch ($rc) {
    0 { Write-Step "전부 정상 등록되어 있습니다." -Level Ok }
    1 { Write-Step "미등록 항목이 있습니다. CSV 를 확인하세요: $OutCsv" -Level Warn }
    2 { Write-Step "사용법 또는 설정 오류입니다." -Level Error }
    3 { Write-Step "라이브러리 폴더에 접근하지 못했습니다: $LibraryRoot" -Level Error }
    4 { Write-Step "EDM 접속 또는 조회에 실패했습니다. 로그인 설정을 확인하세요." -Level Error }
    default { Write-Step "예상치 못한 종료코드: $rc" -Level Error }
}

if (Test-Path -LiteralPath $OutCsv) {
    Write-Step "CSV: $OutCsv"
}
exit $rc
