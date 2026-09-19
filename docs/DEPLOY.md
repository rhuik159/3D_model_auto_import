# 운영 배포 가이드

## 1. 가져갈 파일

저장소를 통째로 복사하는 것이 가장 안전하다. 최소 구성만 추리면 아래와 같다.

### 필수 (이게 없으면 동작하지 않음)

```
Run-3DModelSync.ps1          오케스트레이터 (1~6단계)
Run-Sync.bat                 스케줄러용 래퍼  ← 스케줄러는 이 파일을 실행
Run-Sync-Interactive.bat     수동 실행용 (실행 후 일시정지)

src\Common.Io.ps1            공통 - 파일/락
src\Common.Logging.ps1       공통 - 로깅
src\Common.Config.ps1        공통 - 설정 로드/검증
src\Step1.SyncFromShare.ps1  robocopy 동기화
src\Step2.ScanAndSnapshot.ps1  스캔 + SHA-256 스냅샷 비교
src\Step3.MappingFile.ps1    Mapping.xdm / Alignment.dat 생성
src\Step4.StageDateFolder.ps1  날짜 폴더 배치
src\Step5.Import.ps1         5~6단계 Cockpit Import + Cockpit 종료

tools\Common.SddHome.ps1     Xpedition 설치 경로 탐색 (버전 변경 대응)
tools\Jab-Bridge.ps1         JAB P/Invoke 래퍼 (5~6단계 핵심)
tools\Start-Cockpit.ps1      Cockpit 자동 기동

config\config.sample.json    설정 템플릿
```

### 운영 서버에서 새로 만들어야 하는 것

```
config\config.json           ← config.sample.json 을 복사해 경로 수정
```
이 파일은 `.gitignore` 대상이라 저장소에 없다. 서버 IP/공유 경로가 환경마다
다르므로 **반드시 그 서버 기준으로 다시 작성**해야 한다.

`state\`, `logs\`, `output\` 폴더는 첫 실행 시 자동 생성된다.

### 선택 (진단용, 없어도 운영에 지장 없음)

```
tools\Register-Task.ps1            스케줄러 등록 도우미
tools\Inspect-BulkImportDialog.ps1 대화상자 구조 덤프
tools\Get-CockpitTree.ps1          JAB UI 트리 덤프
tools\Inspect-CockpitUI.ps1        UI 탐색
tools\Test-JabRaw.ps1              JAB 저수준 점검
docs\                              문서
```

---

## 2. 스케줄러에 등록할 파일

**`Run-Sync.bat`** 하나만 등록한다. (`Run-3DModelSync.ps1` 을 직접 등록하지 말 것 —
인용부호/ExecutionPolicy 처리를 래퍼가 담당한다.)

```powershell
.\tools\Register-Task.ps1 -User 'DOMAIN\svc_3dsync' -Time '05:00'
```

### ★ 5~6단계 때문에 생긴 제약 ★

**GUI 자동화라 대화형 데스크톱 세션이 반드시 필요하다.**

Cockpit 창을 띄우고 마우스/키보드를 보내는 방식이므로, 세션이 없으면
`Wait-CockpitReady` 단계에서 실패한다(exit 7). 기존 1~4단계만 돌 때는
없던 제약이다.

따라서 작업 스케줄러 설정에서:

| 항목 | 값 | 이유 |
|---|---|---|
| 실행 계정 | 도메인 계정 (SYSTEM 불가) | UNC 공유 접근 |
| 보안 옵션 | **사용자가 로그온할 때만 실행** | GUI 세션 필요 |
| 가장 높은 수준의 권한 | 불필요 | |

`Register-Task.ps1` 은 **"로그온 여부와 관계없이 실행"** 으로 등록한다.
이 설정은 세션 0(비대화형)에서 돌기 때문에 **5~6단계가 실패한다.**
등록 후 작업 스케줄러에서 **"사용자가 로그온할 때만 실행"** 으로 바꿔야 한다.

### 대안: 1~4단계와 5~6단계 분리

무인 운영이 필요하면 이렇게 나눈다.

```
05:00  Run-Sync.bat -SkipImport     ← 로그온 무관, 날짜 폴더까지만
(사람이 로그온한 뒤)  Run-Sync.bat  ← Import 수행
```
`-SkipImport` 는 4단계까지만 하고 종료한다. 스냅샷은 Import 성공 시에만
갱신되므로, 앞 작업이 스냅샷을 소모해버릴 걱정은 없다 — 다만 `-SkipImport`
실행은 **스냅샷을 갱신한다**는 점에 주의(변경분이 이미 배치됐으므로 정상).

---

## 3. 배포 후 점검 순서

```powershell
# 1) 설정 검증 + 연결성 확인 (아무것도 바꾸지 않음)
.\Run-Sync.bat -WhatIf

# 2) Import 제외하고 4단계까지
.\Run-Sync.bat -SkipImport

# 3) 전체 (Cockpit 이 뜨고 닫히는 것을 눈으로 확인)
.\Run-Sync.bat

# 4) 스케줄러 등록 후
Start-ScheduledTask -TaskName '3D_Model_Auto_Import'
(Get-ScheduledTaskInfo -TaskName '3D_Model_Auto_Import').LastTaskResult
```

### 종료 코드

| 코드 | 의미 |
|---|---|
| 0 | 성공 |
| 1 | 경고와 함께 완료 (정상으로 취급) |
| 2 | 설정 오류 |
| 3 | 공유 접근 불가 / robocopy 실패 |
| 4 | 스캔 실패 |
| 5 | 배치 실패 |
| 6 | 중복 실행 |
| **7** | **Cockpit Import 실패 (5~6단계)** |
| 10 | 예외 |

**exit 7 은 스냅샷을 갱신하지 않는다.** 원인 조치 후 다시 실행하면 같은
변경분을 그대로 재처리하므로 유실이 없다.

---

## 4. 운영 환경에서 먼저 확인할 것

### 디스플레이 배율
JAB 은 배율이 적용되지 않은 좌표를 준다. 코드가 창 크기로 배율을 **실측해
보정**하므로 100%/125%/150% 어디서든 따라가도록 만들었지만, 검증은
**125% 환경에서만** 했다. 운영 PC 배율이 다르면 3-(3) 전체 실행으로 한 번
확인할 것.

모니터마다 배율이 다른 혼합 환경은 미검증이다(구형 `SetProcessDPIAware` 사용).

### Cockpit 기동 관문
아래 창들이 설정에 따라 뜰 수 있고, 모두 자동 처리하도록 되어 있다.
- `License Selector` → Librarian 선택 후 OK
- `Production library selection` → Next
- `Setup M3DL Connection` → EDM Server only 선택 후 OK

서버 설정이 바뀌어 **다른 관문 창**이 추가되면 거기서 멈춘다. 그때는
`tools\Inspect-BulkImportDialog.ps1` 로 창 구조를 덤프해 핸들러를 추가해야 한다.

### 계정
- SYSTEM/LocalService 로는 UNC 공유에 접근할 수 없다.
- 개인 계정은 암호 변경/퇴사 시 중단되므로 전용 서비스 계정 권장.
- Cockpit 프로필에 있어야 한다.
  `app-auto-login.exe -list` 로 확인.

---

## 5. 툴(Xpedition) 버전이 바뀌면

**코드를 고칠 필요가 없다.** 설치 경로는 `tools\Common.SddHome.ps1` 이
실행할 때마다 찾는다. 예전에는 `C:\MentorGraphics\EEVX.2.14.1` 이
세 파일에 하드코딩돼 있었다.

### 탐색 순서
1. 환경변수 `XPEDITION_SDD_HOME`
2. 환경변수 `SDD_HOME`
3. `C:\MentorGraphics\EEVX.*` 중 **가장 최신 버전**
4. `D:\MentorGraphics\EEVX.*`

버전은 문자열이 아니라 숫자로 비교한다(`EEVX.2.9 < EEVX.2.14.1`).

### 후보 검증
폴더가 있다고 바로 쓰지 않고, 아래 파일이 **둘 다** 있어야 채택한다.
```
common\win64\jre\default\bin\windowsaccessbridge-64.dll   (JAB)
dms\bin\dmsdesktop.bat                                    (Cockpit 기동)
```

이 검증이 없으면 실제로 깨진다. 개발 PC 에는 `EEVX.2.14` 와 `EEVX.2.14.1`
이 둘 다 있는데 환경변수 `SDD_HOME` 은 **두 파일이 모두 없는 `EEVX.2.14`**
를 가리키고 있었다. 검증 없이 환경변수를 믿었다면 멀쩡히 돌던 자동화가
버전 업그레이드도 아닌 상황에서 깨졌을 것이다.

### 확인 방법
```powershell
. .\tools\Common.SddHome.ps1
Get-SddHome -Verbose      # 어떤 경로를 왜 골랐는지 출력
Get-JabDllPath
```

### 특정 버전으로 고정하고 싶을 때
여러 버전이 깔려 있는데 최신이 아닌 것을 써야 한다면 환경변수로 지정한다.
```powershell
[Environment]::SetEnvironmentVariable(
    'XPEDITION_SDD_HOME',
    'C:\MentorGraphics\EEVX.2.14.1\SDD_HOME',
    'Machine')
```
(스케줄러 계정에도 보이도록 `Machine` 범위로 설정할 것)

### 설치 위치가 아예 다를 때
`C:` / `D:` 의 `MentorGraphics` 가 아니면 자동 탐색이 못 찾는다.
위 환경변수를 쓰거나, `Get-SddHome -SearchRoots` 기본값을 수정한다.

---

## 6. 실패했을 때 로그 보는 법

### 로그 위치

| 파일 | 내용 |
|---|---|
| `logs\sync_YYYY-MM-DD.log` | **여기부터 본다.** 파이프라인 전체 진행/실패 |
| `logs\robocopy_YYYY-MM-DD.log` | 1단계 파일 복사 상세 |
| `%TEMP%\%USERNAME%\expedition\2011.1\EExDMLibraryClient_*.log` | **Cockpit 자체 로그.** 5~6단계 실패 시 |
| `output\changes_YYYY-MM-DD.csv` | 그날 감지된 변경 목록 (누적) |
| `output\filelist_YYYY-MM-DD.csv` | 라이브러리 전체 현황 |

로그는 날짜별로 쌓이고 `retention.logDays`(기본 90일) 지나면 자동 삭제된다.

### 1단계: 종료 코드 확인

스케줄러로 돌렸다면:
```powershell
(Get-ScheduledTaskInfo -TaskName '3D_Model_Auto_Import').LastTaskResult
```
`0`/`1` 은 정상. 나머지는 3장의 표 참조. **`7` 이면 Cockpit Import 실패.**

### 2단계: 파이프라인 로그에서 [Error] 찾기

```powershell
Select-String -Path logs\sync_*.log -Pattern '\[Error\]' | Select-Object -Last 5
```

실패 메시지는 어느 단계에서 멈췄는지 그대로 알려준다:
```
[Error] [Step5] Cockpit Import 실패: 메뉴 항목 'Library' 을 선택하지 못했습니다.
[Error] [Step5] Cockpit Import 실패: 확인 버튼을 눌렀지만 대화상자가 닫히지 않았습니다.
[Error] [Step5] Cockpit Import 실패: Cockpit 이 준비되지 않았습니다 (메뉴 바가 나타나지 않음).
```

경고만 보려면 `-Pattern '\[Warn'`.

### 3단계: 증상별로 볼 곳

| 증상 | 원인 후보 | 확인 |
|---|---|---|
| `[Step1]` 접근 불가 (exit 3) | 공유 권한/네트워크 | `Test-Path` 로 UNC 확인, 계정 권한 |
| `Cockpit 이 준비되지 않았습니다` | 서버 접속 실패, 관문 창 추가됨 | **Cockpit 로그**, 화면에 낯선 창이 떴는지 |
| `메뉴 항목 ... 선택하지 못했습니다` | 메뉴 구성 변경, 배율 문제 | 4장 배율 항목, 메뉴 이름이 바뀌었는지 |
| `대화상자가 닫히지 않았습니다` | 버튼 라벨 변경, 좌표 어긋남 | 아래 대화상자 덤프 |
| 창이 아예 안 뜸 | GUI 세션 없음 | 2장 - 스케줄러가 세션 0 에서 돌고 있는지 |

### Cockpit 자체 오류

파이프라인 로그에 "대화상자: 'Error'" 가 찍혔다면 Cockpit 쪽 문제다.
이때는 Cockpit 로그를 본다.
```powershell
$log = "$env:TEMP\$env:USERNAME\expedition\2011.1\EExDMLibraryClient_$env:USERNAME.log"
Select-String -Path $log -Pattern 'ERROR|Exception|Caused by' | Select-Object -Last 20
```

실제 사례: `Could not get DMSInstance reference object` — 서버 세션 문제였고
자동화로는 해결 불가. 서버/라이선스 설정을 봐야 했다.

### 낯선 대화상자에서 멈출 때

서버 설정이 바뀌면 새 관문 창이 생길 수 있다. 구조를 덤프해 확인한다.
```powershell
.\tools\Inspect-BulkImportDialog.ps1
```
창 제목, 버튼 이름, 좌표가 출력된다. 이걸 보고
`Jab-Bridge.ps1` 의 `Dismiss-CockpitStartupDialog` 에 핸들러를 추가한다.

### 실패해도 데이터는 안전하다

**Import 실패(exit 7) 시 스냅샷을 갱신하지 않는다.** 원인을 고치고 다시
실행하면 같은 변경분을 그대로 재처리하므로 누락이 없다.

반대로 말하면, 실패를 방치하면 그 파일은 계속 미처리 상태로 남는다.
`logs\` 의 `[Error]` 를 주기적으로 확인할 것.
