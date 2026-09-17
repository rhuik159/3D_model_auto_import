<#
.SYNOPSIS
    3D 모델 자동 등록 파이프라인을 Windows 작업 스케줄러에 등록한다.

.DESCRIPTION
    ★★ 가장 중요한 주의사항 ★★
    SYSTEM 계정으로 실행하면 UNC 공유폴더에 접근할 수 없다.
    SYSTEM 은 네트워크에서 '컴퓨터 계정' 으로 인증되는데, 공유 권한은
    거의 항상 사용자 계정에 부여되어 있기 때문이다.

    증상: 수동으로 실행하면 완벽히 동작하는데 스케줄러로만 실패.

    따라서 공유폴더 읽기 + 라이브러리 쓰기 권한이 있는 도메인 계정으로
    등록해야 한다. 개인 계정은 암호 변경/퇴사 시 중단되므로 전용
    서비스 계정(예: DOMAIN\svc_3dsync)을 권장한다.

.PARAMETER User
    작업을 실행할 도메인 계정. 예: 'DOMAIN\svc_3dsync'
    생략하면 대화형으로 입력받는다.

.PARAMETER Time
    매일 실행 시각. 기본 05:00 (업무 시작 전).

.PARAMETER TaskName
    작업 이름. 기본 '3D_Model_Auto_Import'

.PARAMETER UsePwsh
    (더 이상 사용하지 않음) 실행 파일 선택은 Run-Sync.bat 이 담당한다.
    pwsh.exe 가 있으면 그것을, 없으면 powershell.exe 를 자동으로 쓴다.

.EXAMPLE
    .\Register-Task.ps1 -User 'DOMAIN\svc_3dsync'

.NOTES
    등록 후 확인:
      Start-ScheduledTask -TaskName '3D_Model_Auto_Import'
      (Get-ScheduledTaskInfo -TaskName '3D_Model_Auto_Import').LastTaskResult
    LastTaskResult 에 파이프라인 종료코드가 그대로 노출된다.
      0=성공  1=경고  2=설정오류  3=접근불가/동기화실패
      4=스캔실패  5=배치실패  6=중복실행  10=예외
#>
[CmdletBinding()]
param(
    [string]$User,
    [string]$Time = '05:00',
    [string]$TaskName = '3D_Model_Auto_Import',
    [switch]$UsePwsh
)

$ErrorActionPreference = 'Stop'
$repo   = Split-Path -Parent $PSScriptRoot
# 스케줄러는 .bat 래퍼를 실행한다.
# PowerShell 을 직접 등록할 때 생기는 인용부호 실수를 피할 수 있고,
# 실행 파일 선택(pwsh/powershell)과 ExecutionPolicy 처리를 래퍼가 담당한다.
$script = Join-Path $repo 'Run-Sync.bat'

if (-not (Test-Path -LiteralPath $script)) {
    throw "파이프라인 스크립트를 찾을 수 없습니다: $script"
}

if (-not $User) {
    Write-Host ""
    Write-Host "작업을 실행할 계정을 입력하세요 (예: DOMAIN\svc_3dsync)." -ForegroundColor Yellow
    Write-Host "※ SYSTEM/LocalService 는 UNC 공유에 접근할 수 없으므로 사용 불가." -ForegroundColor Yellow
    $User = Read-Host "실행 계정"
}
if ([string]::IsNullOrWhiteSpace($User)) { throw "실행 계정은 필수입니다." }

if ($User -match '^(SYSTEM|NT AUTHORITY\\SYSTEM|LOCAL SERVICE|NETWORK SERVICE)$') {
    throw ("'$User' 로는 등록할 수 없습니다.`n" +
           "  이 계정들은 UNC 공유폴더에 접근할 수 없어 동기화가 반드시 실패합니다.`n" +
           "  공유 권한이 있는 도메인 계정을 사용하세요.")
}

$action = New-ScheduledTaskAction -Execute $script -WorkingDirectory $repo

$trigger = New-ScheduledTaskTrigger -Daily -At $Time

$settings = New-ScheduledTaskSettingsSet `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Hours 4) `
    -StartWhenAvailable `
    -DontStopIfGoingOnBatteries `
    -AllowStartIfOnBatteries

Write-Host ""
Write-Host "작업 스케줄러 등록 내용" -ForegroundColor Cyan
Write-Host "  작업 이름 : $TaskName"
Write-Host "  실행 계정 : $User"
Write-Host "  실행 시각 : 매일 $Time"
Write-Host "  실행 파일 : $script"
Write-Host ""
Write-Host "계정 암호를 입력하세요 ('로그온 여부와 관계없이 실행' 에 필요)." -ForegroundColor Yellow
$cred = Get-Credential -UserName $User -Message "작업 실행 계정 암호"

Register-ScheduledTask -TaskName $TaskName `
    -Action $action -Trigger $trigger -Settings $settings `
    -User $cred.UserName `
    -Password $cred.GetNetworkCredential().Password `
    -RunLevel Limited -Force | Out-Null

Write-Host ""
Write-Host "등록 완료: $TaskName" -ForegroundColor Green
Write-Host ""
Write-Host "다음 단계 (권장 순서):" -ForegroundColor Cyan
Write-Host "  1) 서비스 계정으로 드라이런이 통과하는지 먼저 확인했는지 점검"
Write-Host "  2) Start-ScheduledTask -TaskName '$TaskName'"
Write-Host "  3) (Get-ScheduledTaskInfo -TaskName '$TaskName').LastTaskResult  # 0 또는 1 이면 정상"
Write-Host "  4) logs\ 폴더의 당일 로그 확인"
Write-Host ""
Write-Host "※ 계정 암호가 만료되면 작업이 조용히 실패합니다." -ForegroundColor Yellow
Write-Host "  만료 없는 서비스 계정 또는 gMSA 사용을 권장합니다." -ForegroundColor Yellow
