#Requires -Version 5.1
<#
.SYNOPSIS
    Cockpit GUI 자동화 - 3D 모델 Bulk Import 및 매핑 파일 Import (5~6단계).

.DESCRIPTION
    Step4 가 스테이징한 날짜 폴더를 Cockpit 에 Import 한다.
    JAB(Java Access Bridge) P/Invoke 로 Cockpit Swing UI 를 직접 제어한다.

    동작 순서:
      1. Cockpit 기동 (또는 재사용)
      2. Tools > Library > 3D Models > Bulk Import
         → 폴더 선택 대화상자에 날짜 폴더 경로 입력 → Open
         → 결과 창의 Close 가 활성화될 때까지 대기 (= 완료)
      3. Tools > Library > 3D Models > Import Mapping File
         → 전용 폼에 Mapping.xdm 경로 입력 → Import
         → 결과 창의 OK 가 활성화될 때까지 대기 (= 완료)

    이 파일은 두 가지로 쓸 수 있다:
      - dot-source 해서 Invoke-Step5Import / Stop-Cockpit 함수를 사용
        (Run-3DModelSync.ps1 이 이 방식을 쓴다)
      - 단독 실행 (아래 param 으로 직접 구동)

.PARAMETER ConfigPath
    설정 파일 경로. 기본값: .\config\config.json

.PARAMETER DateFolder
    특정 날짜 폴더 이름(yyyy-MM-dd). 생략하면 가장 최근 폴더를 사용.

.PARAMETER DryRun
    메뉴 도달 여부만 확인하고 실제 Import 는 하지 않는다.

.PARAMETER Reuse
    이미 떠 있는 Cockpit 이 있으면 재사용한다.

.PARAMETER CloseCockpit
    작업이 끝나면 Cockpit 을 종료한다.

.PARAMETER BulkTimeoutMinutes
    Bulk Import 완료 대기 시간(분). 생략(0)하면 파일 수와 config 의 import 섹션으로 계산.

.PARAMETER MappingTimeoutMinutes
    Import Mapping File 완료 대기 시간(분). 생략(0)하면 자동 계산.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = '',
    [string]$StageRoot  = '',   # 생략하면 config.json 의 dateFolderRoot 사용
    [string]$DateFolder = '',
    [switch]$DryRun,
    [switch]$Reuse,
    [switch]$CloseCockpit,
    [int]$BulkTimeoutMinutes    = 0,
    [int]$MappingTimeoutMinutes = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Step5Root = Split-Path $PSScriptRoot -Parent

. (Join-Path $PSScriptRoot 'Common.Logging.ps1')
. (Join-Path $PSScriptRoot 'Common.Config.ps1')
. (Join-Path $Step5Root  'tools\Jab-Bridge.ps1')

# ================================================================ 함수

function Stop-Cockpit {
    <#
    .SYNOPSIS
        Cockpit 을 종료한다.

    .DESCRIPTION
        먼저 창 닫기(WM_CLOSE)로 정상 종료를 시도하고, 시간 안에 끝나지 않으면
        프로세스를 강제 종료한다. Import 직후 바로 죽이면 마무리 작업이 잘릴 수
        있으므로 기본적으로 정상 종료를 먼저 시도한다.

    .PARAMETER ProcessId
        종료할 Cockpit 프로세스 ID. 생략하면 떠 있는 xDMLibraryClient 전부.

    .PARAMETER TimeoutSeconds
        정상 종료를 기다릴 시간. 초과하면 강제 종료한다.
    #>
    param(
        [int]$ProcessId = 0,
        [int]$TimeoutSeconds = 30
    )

    # if/else 의 결과를 그대로 받으면 원소가 1개일 때 PowerShell 이 풀어버려서
    # StrictMode 에서 .Count 접근이 예외가 된다. 식 전체를 @() 로 감싸야 한다.
    $targets = @(
        if ($ProcessId -gt 0) {
            Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
        } else {
            Get-Process -Name 'xDMLibraryClient' -ErrorAction SilentlyContinue
        }
    )
    if ($targets.Count -eq 0) {
        Write-Log "종료할 Cockpit 프로세스가 없습니다." -Level Info
        return $true
    }

    foreach ($p in $targets) {
        Write-Log "Cockpit 종료 시도 (PID $($p.Id))..." -Level Info
        try { $null = $p.CloseMainWindow() } catch { }
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 700
        $alive = @($targets | ForEach-Object {
            Get-Process -Id $_.Id -ErrorAction SilentlyContinue
        } | Where-Object { $_ })
        if ($alive.Count -eq 0) {
            Write-Log "Cockpit 정상 종료됨" -Level Info
            return $true
        }
    }

    # 정상 종료가 안 되면(변경사항 확인 대화상자 등) 강제 종료한다.
    $remain = @($targets | ForEach-Object {
        Get-Process -Id $_.Id -ErrorAction SilentlyContinue
    } | Where-Object { $_ })
    foreach ($p in $remain) {
        Write-Log "정상 종료에 실패해 강제 종료합니다 (PID $($p.Id))" -Level Warn
        try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch {
            Write-Log "  강제 종료 실패: $($_.Exception.Message)" -Level Error
            return $false
        }
    }
    Start-Sleep -Milliseconds 500
    return $true
}

function Get-ImportTimeouts {
    <#
    .SYNOPSIS
        날짜 폴더의 파일 수에 비례해 Bulk Import / Mapping File 완료 대기 시간을 계산한다.

    .DESCRIPTION
        고정 10분이면 파일이 많을 때(200개 이상) Import 도중 시간 초과가 나고,
        finally 의 Stop-Cockpit 이 진행 중인 Cockpit 을 강제 종료해 버린다(실제로 겪음).

        대기 시간 = max(최소분, 파일 수 × 파일당 초) 를 최대분으로 자른다.
        값은 config 의 import 섹션에서 읽고, 섹션/키가 없으면 기본값을 쓴다
        (import 섹션이 없는 기존 운영 config 도 그대로 동작해야 한다).

        파일 수는 날짜 폴더 전체 기준이다. 같은 날 여러 번 실행하면 폴더가 누적되고
        Bulk Import 는 폴더 전체를 다시 읽기 때문이다.

    .OUTPUTS
        PSCustomObject { FileCount, BulkTimeoutMs, MappingTimeoutMs }
    #>
    param(
        [Parameter(Mandatory)][string]$DatePath,
        [Parameter(Mandatory)]$Config
    )

    # 실측: 10분에 약 70개(≈8.6초/개) → 여유를 두고 15초/개.
    # 최대값 합계(150+30분)는 작업 스케줄러 실행 제한(4시간, Register-Task.ps1) 안에 들어와야 한다.
    $defaults = [ordered]@{
        bulkTimeoutMinMinutes    = 10
        bulkSecondsPerFile       = 15
        bulkTimeoutMaxMinutes    = 150
        mappingTimeoutMinMinutes = 5
        mappingSecondsPerFile    = 3
        mappingTimeoutMaxMinutes = 30
    }
    # StrictMode 에서 없는 속성을 읽으면 예외가 나므로 PSObject.Properties 로 확인한다.
    $section = $null
    if ($Config.PSObject.Properties['import']) { $section = $Config.import }
    $s = @{}
    foreach ($k in $defaults.Keys) {
        $s[$k] = if ($section -and $section.PSObject.Properties[$k]) { [double]$section.$k } else { $defaults[$k] }
    }

    $extSet = @{}
    foreach ($e in $Config.scan.includeExtensions) { $extSet[$e.ToLowerInvariant()] = $true }
    $count = @([System.IO.Directory]::EnumerateFiles($DatePath, '*', [System.IO.SearchOption]::AllDirectories) |
               Where-Object { $extSet.ContainsKey([System.IO.Path]::GetExtension($_).ToLowerInvariant()) }).Count

    $calc = {
        param([double]$minMin, [double]$secPerFile, [double]$maxMin)
        $sec = [Math]::Max($minMin * 60, $count * $secPerFile)
        $sec = [Math]::Min($sec, $maxMin * 60)
        return [int]($sec * 1000)
    }

    return [PSCustomObject]@{
        FileCount        = $count
        BulkTimeoutMs    = (& $calc $s.bulkTimeoutMinMinutes $s.bulkSecondsPerFile $s.bulkTimeoutMaxMinutes)
        MappingTimeoutMs = (& $calc $s.mappingTimeoutMinMinutes $s.mappingSecondsPerFile $s.mappingTimeoutMaxMinutes)
    }
}

function Invoke-Step5Import {
    <#
    .SYNOPSIS
        날짜 폴더 하나를 Cockpit 에 Import 한다 (Bulk Import + Mapping File).

    .OUTPUTS
        PSCustomObject { Success, DatePath, MappingFile, CockpitPid, DryRun, Message }
    #>
    param(
        [Parameter(Mandatory)][string]$DatePath,
        [string]$MappingFileName = 'Mapping.xdm',
        [switch]$DryRun,
        [switch]$Reuse,
        [switch]$CloseCockpit,
        [int]$BulkTimeoutMs    = 600000,
        [int]$MappingTimeoutMs = 300000
    )

    if (-not (Test-Path -LiteralPath $DatePath)) {
        throw "날짜 폴더를 찾을 수 없습니다: $DatePath"
    }
    $mappingFile = Join-Path $DatePath $MappingFileName
    if (-not (Test-Path -LiteralPath $mappingFile)) {
        throw "$MappingFileName 를 찾을 수 없습니다: $mappingFile"
    }

    Write-Log "  날짜 폴더 : $DatePath" -Level Info -Step 'Step5'
    Write-Log "  매핑 파일 : $mappingFile" -Level Info -Step 'Step5'
    Write-Log ("  완료 대기 한도: Bulk {0:N0}분 / Mapping {1:N0}분" -f ($BulkTimeoutMs / 60000), ($MappingTimeoutMs / 60000)) -Level Info -Step 'Step5'
    if ($DryRun) { Write-Log "  [DRY RUN] 실제 Import 없음" -Level Warn -Step 'Step5' }

    $cockpitPid = 0
    try {
        # 1) Cockpit 기동
        Write-Log "Cockpit 기동 중..." -Level Info -Step 'Step5'
        $cockpitScript = Join-Path $Step5Root 'tools\Start-Cockpit.ps1'
        $cockpit = & $cockpitScript -Reuse:$Reuse
        $cockpitPid = $cockpit.Process.Id
        foreach ($d in @($cockpit.Diag)) { Write-Log $d -Level Warn -Step 'Step5' }
        Write-Log "Cockpit PID $cockpitPid 준비됨" -Level Info -Step 'Step5'

        # 2) JAB 초기화.
        #    Get-CockpitMainWindow 가 Jab.Win32 를 쓰므로 먼저 한 번 올려 둔다.
        Write-Log "JAB 초기화 중..." -Level Info -Step 'Step5'
        $conn = Initialize-Jab
        Write-Log "JAB 연결 완료 (vmId=$($conn.VmId))" -Level Info -Step 'Step5'

        # 이전 실행의 결과 창이 남아 있으면 닫는다.
        # 떠 있으면 Process.MainWindowHandle 이 그쪽을 가리켜 메뉴 바를 못 찾는다.
        # 이 시점엔 기동 대화상자(License Selector 등)가 떠 있을 수 있으므로
        # 제목으로 걸러야 한다. 안 거르면 그걸 결과 창으로 잡고 10분간 멈춘다.
        $tmpMain = Get-CockpitMainWindow -ProcessId $cockpitPid -WaitMs 60000
        if ($tmpMain -ne [IntPtr]::Zero) {
            if (Close-JabResultDialog -ProcessId $cockpitPid -MainHwnd $tmpMain -AppearMs 1500 `
                                      -TitlePatterns @('*finished*', 'Importing Mapping File')) {
                Write-Log "  이전 실행의 결과 창을 닫았습니다." -Level Warn -Step 'Step5'
            }
        }

        # MainWindowHandle 은 대화상자가 뜨면 그쪽을 가리키므로 제목으로 직접 찾는다.
        $hwnd = Get-CockpitMainWindow -ProcessId $cockpitPid -WaitMs 60000
        if ($hwnd -eq [IntPtr]::Zero) { throw "Cockpit 메인 창을 찾지 못했습니다." }
        Write-Log "  메인 창 = 0x$($hwnd.ToString('X'))" -Level Info -Step 'Step5'

        $conn = Initialize-Jab -Hwnd $hwnd

        # 창이 떴다고 바로 쓸 수 있는 게 아니다. 서버 접속이 끝나기 전에는
        # 메뉴 바가 아예 없어서 메뉴 탐색이 실패한다. 준비될 때까지 기다린다.
        # License Selector / Production library selection 이 뜨면 여기서 넘긴다.
        # (설정에 따라 안 뜰 수도 있다)
        Write-Log "  Cockpit 준비 대기..." -Level Info -Step 'Step5'
        if (-not (Wait-CockpitReady -VmId $conn.VmId -RootAc $conn.RootAc -TimeoutMs 180000 `
                                    -ProcessId $cockpitPid -MainHwnd $hwnd)) {
            throw "Cockpit 이 준비되지 않았습니다 (메뉴 바가 나타나지 않음). 서버 접속을 확인하세요."
        }
        # 관문 대화상자를 넘기는 동안 Cockpit 이 메인 창을 다시 만들기도 한다.
        # 처음 잡은 핸들이 죽어 있을 수 있으므로 제목으로 다시 찾는다.
        $hwnd = Get-CockpitMainWindow -ProcessId $cockpitPid -WaitMs 30000
        if ($hwnd -eq [IntPtr]::Zero) { throw "준비 후 Cockpit 메인 창을 찾지 못했습니다." }
        Write-Log "  메인 창(갱신) = 0x$($hwnd.ToString('X'))" -Level Info -Step 'Step5'

        # 스플래시에서 본 화면으로 넘어가며 루트 AC 도 바뀌었으므로 다시 잡는다.
        $conn = Initialize-Jab -Hwnd $hwnd
        Write-Log "  Cockpit 준비 완료" -Level Info -Step 'Step5'

        # 메뉴 좌표가 흔들리지 않도록 창 위치/크기를 고정한다.
        # (최대화 상태에서는 실행마다 위치가 달라져 클릭이 빗나간 사례가 있었다)
        [Jab.Win32]::MoveWindow($hwnd, 0, 0, 1600, 1000, $true) | Out-Null
        Start-Sleep -Milliseconds 500

        if ($DryRun) {
            foreach ($leaf in @('Bulk Import','Import Mapping File')) {
                Write-Log "[DRY RUN] 메뉴 확인: Tools > Library > 3D Models > $leaf" -Level Info -Step 'Step5'
                $ok = Invoke-JabMenuPath -Path @('Tools','Library','3D Models',$leaf) `
                                         -Hwnd $hwnd -NoInvoke
                if (-not $ok) { throw "'$leaf' 메뉴에 도달하지 못했습니다." }
                Write-Log "  도달 확인" -Level Info -Step 'Step5'
            }
            Write-Log "[DRY RUN] 완료 - 실제 Import 는 수행하지 않았습니다." -Level Warn -Step 'Step5'
            return [PSCustomObject]@{
                Success = $true; DatePath = $DatePath; MappingFile = $mappingFile
                CockpitPid = $cockpitPid; DryRun = $true; Message = 'DryRun'
            }
        }

        # ------------------------------------------------------ A) Bulk Import
        Write-Log "=== A) Bulk Import ===" -Level Info -Step 'Step5'
        Write-Log "  경로: $DatePath" -Level Info -Step 'Step5'

        Invoke-JabMenuPath -Path @('Tools','Library','3D Models','Bulk Import') -Hwnd $hwnd | Out-Null

        $dlg = Wait-JabDialog -MainHwnd $hwnd -ProcessId $cockpitPid -TimeoutMs 20000
        if ($null -eq $dlg) { throw "Bulk Import 대화상자가 나타나지 않았습니다." }
        Write-Log "  대화상자: '$($dlg.Title)'" -Level Info -Step 'Step5'

        # 폴더 선택창 대신 'Setup M3DL Connection' 이 먼저 뜨는 경우가 있다
        # (연결이 아직 설정되지 않은 세션). 넘기고 본 대화상자를 다시 기다린다.
        if ($dlg.Title -like '*M3DL*') {
            Write-Log "  M3DL 연결 설정 창 처리 중..." -Level Info -Step 'Step5'
            $null = Dismiss-CockpitStartupDialog -ProcessId $cockpitPid -MainHwnd $hwnd
            Start-Sleep -Milliseconds 1000
            $dlg = Wait-JabDialog -MainHwnd $hwnd -ProcessId $cockpitPid -TimeoutMs 20000
            if ($null -eq $dlg) { throw "M3DL 설정 후 Bulk Import 대화상자가 나타나지 않았습니다." }
            Write-Log "  대화상자: '$($dlg.Title)'" -Level Info -Step 'Step5'
        }

        # UNC 경로를 그대로 넣어도 Cockpit 이 수락한다 (확인 완료).
        Do-JabFileDialog -Dialog $dlg -Path $DatePath | Out-Null
        Write-Log "  경로 입력 및 확인 완료" -Level Info -Step 'Step5'

        # 결과 창('Bulk Import in progress...' → '... finished').
        # 버튼이 활성화되는 시점이 곧 완료 시점이다.
        Write-Log "  Import 완료 대기..." -Level Info -Step 'Step5'
        if (-not (Close-JabResultDialog -ProcessId $cockpitPid -MainHwnd $hwnd -WaitFinishMs $BulkTimeoutMs)) {
            throw "Bulk Import 결과 창이 나타나지 않았습니다. Import 가 시작되지 않았을 수 있습니다."
        }
        Write-Log "  Bulk Import 완료" -Level Info -Step 'Step5'

        # ---------------------------------------------- B) Import Mapping File
        Write-Log "=== B) Import Mapping File ===" -Level Info -Step 'Step5'
        Write-Log "  파일: $mappingFile" -Level Info -Step 'Step5'

        Start-Sleep -Milliseconds 800
        [Jab.Win32]::PumpMessages(30)

        Invoke-JabMenuPath -Path @('Tools','Library','3D Models','Import Mapping File') -Hwnd $hwnd | Out-Null

        $dlg2 = Wait-JabDialog -MainHwnd $hwnd -ProcessId $cockpitPid -TimeoutMs 20000
        if ($null -eq $dlg2) { throw "Import Mapping File 대화상자가 나타나지 않았습니다." }
        Write-Log "  대화상자: '$($dlg2.Title)'" -Level Info -Step 'Step5'

        # 이쪽은 JFileChooser 가 아니라 전용 폼이라 별도 핸들러를 쓴다.
        Do-JabMappingDialog -Dialog $dlg2 -MappingPath $mappingFile | Out-Null
        Write-Log "  매핑 파일 입력 및 Import 완료" -Level Info -Step 'Step5'

        Write-Log "  완료 대기..." -Level Info -Step 'Step5'
        if (-not (Close-JabResultDialog -ProcessId $cockpitPid -MainHwnd $hwnd -WaitFinishMs $MappingTimeoutMs)) {
            throw "Import Mapping File 결과 창이 나타나지 않았습니다."
        }
        Write-Log "  Import Mapping File 완료" -Level Info -Step 'Step5'

        Release-JabObject -Ac $conn.RootAc

        return [PSCustomObject]@{
            Success = $true; DatePath = $DatePath; MappingFile = $mappingFile
            CockpitPid = $cockpitPid; DryRun = $false; Message = 'OK'
        }
    }
    finally {
        # 성공/실패와 무관하게 요청받았으면 Cockpit 을 닫는다.
        # 실패 시에도 닫아야 다음 실행이 깨끗한 상태에서 시작한다.
        #
        # 여기서 예외가 나면 원래 실패 원인을 덮어써 버린다(실제로 겪음).
        # 정리 작업은 절대 밖으로 예외를 던지지 않는다.
        if ($CloseCockpit) {
            try { $null = Stop-Cockpit -ProcessId $cockpitPid }
            catch {
                Write-Log "Cockpit 종료 중 오류(무시): $($_.Exception.Message)" -Level Warn -Step 'Step5'
            }
        }
    }
}

# ================================================================ 단독 실행
# dot-source 될 때는 아래를 실행하지 않는다.
# $MyInvocation.InvocationName 이 '.' 이면 dot-source 다.
if ($MyInvocation.InvocationName -ne '.') {

    if (-not $ConfigPath) { $ConfigPath = Join-Path $Step5Root 'config\config.json' }
    $cfg = Import-SyncConfig -ConfigPath $ConfigPath -RepoRoot $Step5Root -SkipReachabilityCheck
    $stageRoot = if ($StageRoot) { $StageRoot } else { $cfg.paths.dateFolderRoot }

    if ($DateFolder) {
        $datePath = Join-Path $stageRoot $DateFolder
    } else {
        # yyyy-MM-dd 이름만 대상. reimport_* 폴더는 이름순으로 뒤에 와서 잘못 선택된다.
        $latest = Get-ChildItem -LiteralPath $stageRoot -Directory -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}$' } |
                  Sort-Object Name -Descending | Select-Object -First 1
        if (-not $latest) { throw "날짜 폴더가 없습니다: $stageRoot" }
        $datePath = $latest.FullName
    }

    Write-Log "Step5 Import 시작"
    $to = Get-ImportTimeouts -DatePath $datePath -Config $cfg
    $bulkMs    = if ($BulkTimeoutMinutes    -gt 0) { $BulkTimeoutMinutes    * 60000 } else { $to.BulkTimeoutMs }
    $mappingMs = if ($MappingTimeoutMinutes -gt 0) { $MappingTimeoutMinutes * 60000 } else { $to.MappingTimeoutMs }
    Write-Log "  날짜 폴더 파일 수: $($to.FileCount)" -Level Info -Step 'Step5'
    $r = Invoke-Step5Import -DatePath $datePath `
                            -MappingFileName $cfg.mapping.mappingFileName `
                            -DryRun:$DryRun -Reuse:$Reuse -CloseCockpit:$CloseCockpit `
                            -BulkTimeoutMs $bulkMs -MappingTimeoutMs $mappingMs
    Write-Log "Step5 완료" -Level Info
    $r
}
