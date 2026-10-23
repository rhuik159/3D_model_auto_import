# 운영 서버 배포 가이드

---

## 1. 배포할 파일

저장소를 통째로 복사하는 것이 가장 안전하다. 최소 구성만 추리면 아래와 같다.

### 필수

```
Run-3DModelSync.ps1               오케스트레이터 (1~6단계)
Run-Sync.bat                      작업 스케줄러용 래퍼  ← 스케줄러는 이 파일을 실행
Run-Sync-Interactive.bat          수동 실행용 (실행 후 일시정지)

src\Common.Io.ps1
src\Common.Logging.ps1
src\Common.Config.ps1
src\Step1.SyncFromShare.ps1
src\Step2.ScanAndSnapshot.ps1
src\Step3.MappingFile.ps1
src\Step4.StageDateFolder.ps1
src\Step5.Import.ps1

tools\Common.SddHome.ps1          Xpedition 설치 경로 자동 탐색
tools\Jab-Bridge.ps1              JAB P/Invoke 래퍼 (5~6단계 핵심)
tools\Start-Cockpit.ps1           Cockpit 자동 기동

config\config.sample.json
```

### 서버에서 직접 만들어야 하는 것

```
config\config.json   ← config.sample.json 을 복사해 경로 수정
```

`.gitignore` 대상이라 저장소에 없다. 서버 IP/공유 경로가 환경마다 다르므로
**반드시 그 서버 기준으로 다시 작성**해야 한다. `<<SET-ME>>` 가 남아 있으면
파이프라인이 시작 직후 오류를 내고 멈춘다(fail-fast).

`state\`, `logs\`, `output\` 폴더는 첫 실행 시 자동 생성된다.

### RDP 없이 운영하려면 추가 필요

```
IddSampleDriver\                  가상 디스플레이 드라이버 (1회 설치)
tools\Move-SessionToConsole.bat   자동 콘솔 전환 (스케줄러 등록)
tools\Disconnect-ToConsole.bat    수동 콘솔 전환
```

→ 상세는 [UNATTENDED-RDP.md](UNATTENDED-RDP.md) 참고.

### 선택 (진단용, 없어도 운영에 지장 없음)

```
tools\Register-Task.ps1
tools\Inspect-BulkImportDialog.ps1
tools\Get-CockpitTree.ps1
tools\Inspect-CockpitUI.ps1
tools\Test-JabRaw.ps1
docs\
```

---

## 2. 최초 설치 체크리스트

아래를 순서대로 완료해야 파이프라인이 무인 실행된다.

### (1) 실행 계정 결정

| 항목 | 요구사항 |
|------|----------|
| 계정 종류 | 도메인 계정 — SYSTEM/LocalService 는 UNC 공유에 접근 불가 |
| 권장 | 전용 서비스 계정 (예: `DOMAIN\svc_3dsync`) — 개인 계정은 암호 변경·퇴사 시 중단됨 |
| UNC 공유 권한 | 원본 공유폴더 읽기 + 라이브러리 폴더 쓰기 |
| Cockpit 프로필 | Cockpit 에 로그인 설정이 있어야 함 (`app-auto-login.exe -list` 로 확인) |

### (2) Cockpit 자동 로그인 설정

무인 실행을 위해 `app-auto-login.exe` 로 대화상자 없이 Cockpit 이 기동되도록 설정해야 한다.
설정이 없으면 `Start-Cockpit.ps1` 이 `로그인 설정 '3d_model_import' 이 없습니다` 로 실패한다.

```powershell
# 실행 계정으로 로그온한 상태에서:
$auto = "$SddHome\common\win64\bin\app-auto-login.exe"
& $auto -list          # 현재 저장된 설정 목록 확인

# 없으면 -ds -dslicense -dsprodlib 옵션으로 만든다
# (정확한 파라미터는 Xpedition Overview 가이드 p.96, p.107 참조)
```

`config.json` 의 기본 설정 이름은 `3d_model_import` 이다.
다른 이름을 써야 한다면 `Start-Cockpit.ps1 -ConfigName` 에 해당 이름을 지정한다.

### (3) JAB 활성화 — 계정별, 빼먹기 가장 쉬운 항목

**Java Access Bridge(JAB) 는 계정마다 개별적으로 활성화해야 한다.**
개발 PC 에서 켰다고 운영 서버 계정에 자동으로 켜져 있지 않다.
활성화되지 않으면 5~6단계가 `HWND 0x... 는 Java 창이 아닙니다` 로 실패한다.

#### 사전 조건

**파이프라인을 실제로 실행할 계정으로 그 서버에 로그온한 상태**에서 진행한다.
(서비스 계정이라면 `runas` 또는 해당 계정으로 직접 RDP 접속)

#### 활성화 여부 확인

저장소 루트에서 **PowerShell** 을 연 뒤:

```powershell
# 저장소 루트로 이동 (예시 — 실제 경로로 변경)
cd C:\xdm_server\xdm_auto\xdm_3dmap\3D_model_auto_import

# Common.SddHome.ps1 를 현재 세션에 로드 (점 공백 경로 형태)
. .\tools\Common.SddHome.ps1

# JAB 활성화 여부 확인
Test-JabEnabled
```

정상 활성화 상태의 출력 예시:
```
Enabled        : True
PropertiesPath : C:\Users\svc_3dsync\.accessibility.properties
JabSwitchPath  : C:\MentorGraphics\EEVX.2.14.1\SDD_HOME\common\win64\jre\default\bin\jabswitch.exe
Detail         : AccessBridge 등록됨
```

미활성화 상태의 출력 예시:
```
Enabled        : False
PropertiesPath : C:\Users\svc_3dsync\.accessibility.properties
JabSwitchPath  : C:\MentorGraphics\EEVX.2.14.1\SDD_HOME\common\win64\jre\default\bin\jabswitch.exe
Detail         : C:\Users\svc_3dsync\.accessibility.properties 가 없습니다 (jabswitch 미실행)
```

#### 활성화 실행

`Enabled = False` 이면 `JabSwitchPath` 에 표시된 경로의 jabswitch 를 실행한다.

```powershell
# JabSwitchPath 값을 그대로 사용 (Get-SddHome 이 경로를 자동으로 찾아줌)
$jab = (Test-JabEnabled).JabSwitchPath
& $jab /enable
```

성공 시 메시지가 출력되고 아래 파일이 생성된다:
```
C:\Users\<계정명>\.accessibility.properties
```

파일 내용 확인 (선택):
```powershell
Get-Content "$env:USERPROFILE\.accessibility.properties"
# → assistive_technologies=... 줄에 AccessBridge 가 포함돼 있으면 정상
```

#### 활성화 후 Cockpit 재기동 필수

JVM 이 기동할 때 `.accessibility.properties` 를 읽으므로,
**이미 떠 있는 Cockpit 이 있으면 완전히 종료한 뒤 다시 띄워야** 적용된다.

```powershell
# 남아 있는 Cockpit 프로세스 강제 종료
Get-Process xDMLibraryClient, javaw -ErrorAction SilentlyContinue | Stop-Process -Force
```

#### 최종 확인

활성화 + Cockpit 재기동 후 다시 확인:
```powershell
Test-JabEnabled
# Enabled = True 이면 완료
```

#### 다른 계정으로 실행해야 할 때

현재 로그온 계정이 아닌 서비스 계정에 활성화해야 한다면:
```powershell
# 예: DOMAIN\svc_3dsync 계정에 활성화
# JabSwitchPath 전체 경로를 큰따옴표로 감싸야 한다
runas /user:DOMAIN\svc_3dsync `
    "cmd /c ""C:\MentorGraphics\EEVX.2.14.1\SDD_HOME\common\win64\jre\default\bin\jabswitch.exe"" /enable"
```
실행 후 암호를 입력하면 별도 cmd 창이 잠깐 뜨고 닫힌다.
그 계정으로 로그온해서 `Test-JabEnabled` 로 결과를 확인한다.

---

### (4) 가상 디스플레이 설치 (RDP 없이 운영할 경우에만)

RDP 창을 닫은 상태(Disconnected)에서는 디스플레이가 없어 JAB 연결이 실패한다
(`HWND 0x0 는 Java 창이 아닙니다`).
서버에 **실물 모니터가 없고 RDP 없이 운영**해야 하는 경우에만 이 단계가 필요하다.

#### 먼저 확인: 이미 디스플레이가 있는지

```powershell
Get-PnpDevice -Class Display | Select-Object Status, FriendlyName
```

`IddSampleDriver Virtual Display` 또는 실물 모니터 항목이 `OK` 상태로 있으면
이 단계는 건너뛴다.

`Microsoft Remote Display Adapter` 만 보인다면 가상 디스플레이를 설치해야 한다.

#### 설치 준비

모든 작업은 **관리자 권한 PowerShell** 에서 진행한다.
`IddSampleDriver\` 폴더가 UNC 경로(`\\서버\공유\...`)에 있으면
**먼저 로컬 경로로 복사한 뒤** 그 경로에서 실행한다.
(UNC 경로에서는 ExecutionPolicy Bypass 가 적용되지 않아 스크립트가 실행 거부됨)

```powershell
# 로컬로 복사 후 이동 (예시 경로)
cd C:\xdm_server\xdm_auto\xdm_3dmap\3D_model_auto_import\IddSampleDriver
```

#### 설치 순서

**1단계: 드라이버 서명 인증서 설치**

```powershell
.\installCert.bat
```

성공 출력:
```
CertMgr Succeeded
```

실패 시(`CertMgr Failed` / `Access is denied`): 관리자 권한인지 다시 확인한다.

---

**2단계: 드라이버 패키지 등록**

```powershell
pnputil /add-driver IddSampleDriver.inf /install
```

성공 출력 (숫자 NN 은 환경마다 다름):
```
Microsoft PnP Utility

Adding driver package:  IddSampleDriver.inf
Driver package added successfully.
Published Name:         oem12.inf
...
```

---

**3단계: 가상 디스플레이 장치 생성**

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-VirtualDisplay.ps1
```

성공 출력:
```
SUCCESS: Virtual display device created.

=== Display devices ===
Status FriendlyName
------ ------------
OK     IddSampleDriver Virtual Display
OK     Microsoft Remote Display Adapter
```

`FAILED (error code: N)` 가 나오면 1·2단계가 정상 완료됐는지 다시 확인한다.

---

**4단계: 설치 결과 확인**

```powershell
Get-PnpDevice -Class Display | Select-Object Status, FriendlyName
```

`IddSampleDriver Virtual Display` 가 `OK` 이면 완료.

#### 설치 후 필수 작업

가상 디스플레이만으로는 부족하다. RDP 를 닫을 때 세션이 **Active 상태로 유지**되도록
콘솔 전환 자동화도 함께 설정해야 한다.
→ [UNATTENDED-RDP.md](UNATTENDED-RDP.md) 3장 참고.

#### 제거 방법

가상 디스플레이가 불필요해졌거나 서버 부하를 줄이고 싶을 때 아래 순서로 제거한다.
제거 전에 tscon 콘솔 전환 자동화([UNATTENDED-RDP.md](UNATTENDED-RDP.md) 3장)가
동작하는지 확인한다. 디스플레이가 없어지면 5~6단계가 다시 실패하기 때문이다.

모든 단계는 **관리자 권한 PowerShell** 에서 실행한다.

**1단계: 가상 디스플레이 장치 제거**

```powershell
$dev = Get-PnpDevice -Class Display | Where-Object { $_.FriendlyName -like '*IddSample*' }
$dev | Disable-PnpDevice -Confirm:$false
$dev | Remove-PnpDevice -Confirm:$false
```

또는 장치 관리자 → 디스플레이 어댑터 → `IddSampleDriver Virtual Display` → 마우스 오른쪽 → **디바이스 제거**.

---

**2단계: 드라이버 패키지 제거**

```powershell
# 설치 시 출력된 oem 이름 확인 (IddSample 줄 위아래를 같이 본다)
pnputil /enum-drivers | Select-String -Context 2 'IddSample'

# 확인한 이름으로 제거 (숫자 NN 은 환경마다 다름)
pnputil /delete-driver oem12.inf /uninstall
```

---

**3단계: 드라이버 서명 인증서 제거 (선택)**

```powershell
# 인증서 확인
Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Subject -like '*Idd*' }
Get-ChildItem Cert:\LocalMachine\TrustedPublisher | Where-Object { $_.Subject -like '*Idd*' }

# Thumbprint 로 삭제 (위 명령에서 확인한 값으로 교체)
Get-Item "Cert:\LocalMachine\Root\<Thumbprint>" | Remove-Item
Get-Item "Cert:\LocalMachine\TrustedPublisher\<Thumbprint>" | Remove-Item
```

---

**4단계: 제거 확인**

```powershell
Get-PnpDevice -Class Display | Select-Object Status, FriendlyName
```

`IddSampleDriver Virtual Display` 항목이 사라지면 완료.

---

## 3. 작업 스케줄러 등록

**`Run-Sync.bat` 하나만 등록한다.** `Run-3DModelSync.ps1` 을 직접 등록하지 말 것
(인용부호/ExecutionPolicy 처리를 래퍼가 담당).

```powershell
.\tools\Register-Task.ps1 -User 'DOMAIN\svc_3dsync' -Time '05:00'
```

### 스케줄러 보안 옵션 — 중요

`Register-Task.ps1` 은 **"로그온 여부와 관계없이 실행"** 으로 등록한다.
이 상태에서는 5~6단계가 세션 0(비대화형)에서 돌아 **Import 가 실패한다.**
등록 후 작업 스케줄러에서 반드시 아래로 변경해야 한다.

| 항목 | 설정값 |
|------|--------|
| 보안 옵션 | **사용자가 로그온할 때만 실행** |
| 가장 높은 수준의 권한 | 불필요 |

### 1~4단계와 5~6단계를 분리하고 싶을 때

```
05:00  Run-Sync.bat -SkipImport   ← 로그온 무관, 날짜 폴더까지만
(로그온 후)  Run-Sync.bat         ← Import 수행
```

`-SkipImport` 는 4단계까지 완료 후 **스냅샷을 갱신한다** (변경분이 이미 배치됐으므로 정상).

---

## 4. 배포 후 점검 순서

```powershell
# 1) 설정 검증 + 연결성 확인 (아무것도 바꾸지 않음)
.\Run-Sync.bat -WhatIf

# 2) Import 없이 4단계까지만
.\Run-Sync.bat -SkipImport

# 3) 전체 실행 (Cockpit 이 뜨고 닫히는 것을 눈으로 확인)
.\Run-Sync.bat

# 4) 스케줄러 등록 후 동작 확인
Start-ScheduledTask -TaskName '3D_Model_Auto_Import'
(Get-ScheduledTaskInfo -TaskName '3D_Model_Auto_Import').LastTaskResult
```

---

## 5. Xpedition 버전이 올라가면

**코드를 고칠 필요 없다.** `tools\Common.SddHome.ps1` 이 실행 시마다 경로를 자동 탐색한다.

탐색 순서:
1. 환경변수 `XPEDITION_SDD_HOME`
2. 환경변수 `SDD_HOME`
3. `C:\MentorGraphics\EEVX.*` 중 가장 최신 버전 (숫자 비교, `EEVX.2.9 < EEVX.2.14.1`)
4. `D:\MentorGraphics\EEVX.*`

후보는 아래 두 파일이 **둘 다** 있어야 채택된다.
```
common\win64\jre\default\bin\windowsaccessbridge-64.dll   (JAB)
dms\bin\dmsdesktop.bat                                    (Cockpit 기동)
```

현재 선택된 경로 확인:
```powershell
. .\tools\Common.SddHome.ps1
Get-SddHome -Verbose    # 어떤 경로를 왜 골랐는지 출력
Get-JabDllPath
```

특정 버전으로 고정할 때:
```powershell
[Environment]::SetEnvironmentVariable(
    'XPEDITION_SDD_HOME',
    'C:\MentorGraphics\EEVX.2.14.1\SDD_HOME',
    'Machine')           # 스케줄러 계정에도 보이도록 Machine 범위
```

---

## 6. 종료코드

| 코드 | 의미 |
|------|------|
| 0 | 성공 (변경 없음 포함) |
| 1 | 경고와 함께 완료 (정상으로 취급) |
| 2 | 설정 오류 / config.json 없음 또는 `<<SET-ME>>` 미설정 |
| 3 | 공유폴더 접근 불가 / robocopy 실패 |
| 4 | 스캔/해시 실패 |
| 5 | 배치 생성 실패 |
| 6 | 다른 인스턴스 실행 중 (락 보유) |
| **7** | **Cockpit Import 실패 (5~6단계)** — 스냅샷 미갱신 |
| 10 | 예상치 못한 예외 |

**exit 7 은 스냅샷을 갱신하지 않는다.** 원인을 고친 뒤 다시 실행하면
같은 변경분이 그대로 재처리되므로 유실이 없다.

---

## 7. 실패 시 로그 확인

### 로그 위치

| 파일 | 내용 |
|------|------|
| `logs\sync_YYYY-MM-DD.log` | **여기부터 본다.** 파이프라인 전체 진행/실패 |
| `logs\robocopy_YYYY-MM-DD.log` | 1단계 파일 복사 상세 |
| `output\changes_YYYY-MM-DD.csv` | 그날 감지된 변경 목록 (누적) |
| `output\filelist_YYYY-MM-DD.csv` | 라이브러리 전체 현황 |
| `%TEMP%\%USERNAME%\expedition\2011.1\EExDMLibraryClient_*.log` | Cockpit 자체 로그. 5~6단계 실패 시 추가 확인 |

### 오류 메시지 검색

```powershell
# 오류만 추출
Select-String -Path logs\sync_*.log -Pattern '\[Error\]' | Select-Object -Last 5

# 경고 포함
Select-String -Path logs\sync_*.log -Pattern '\[Warn\]|\[Error\]' | Select-Object -Last 20
```

### 증상별 원인

| 증상 | 원인 | 조치 |
|------|------|------|
| `HWND 0x... 는 Java 창이 아닙니다` | **JAB 미활성화** | 2장 (3) — `Test-JabEnabled` 확인 후 `jabswitch /enable` |
| `로그인 설정 '...' 이 없습니다` | Cockpit 자동 로그인 미설정 | 2장 (2) — `app-auto-login.exe -list` 확인 |
| `[Step1]` 접근 불가 (exit 3) | 공유 권한 / 네트워크 | `Test-Path \\server\share` 로 UNC 확인, 계정 권한 |
| `Cockpit 이 준비되지 않았습니다 (메뉴 바가 나타나지 않음)` | 서버 접속 실패, 새 관문 창 출현 | Cockpit 로그 확인, 낯선 창 점검 |
| `메뉴 항목 '...' 을 선택하지 못했습니다` | 메뉴 구성 변경, 배율 문제 | 아래 대화상자 덤프 |
| `대화상자가 닫히지 않았습니다` | 버튼 라벨 변경, 좌표 어긋남 | 아래 대화상자 덤프 |
| 창이 아예 안 뜸 | GUI 세션 없음 (세션 0) | 3장 — 스케줄러 "사용자가 로그온할 때만 실행" 확인 |
| `세션 상태: Disconnected` 후 `대화상자가 닫히지 않았습니다` | RDP 끊긴 세션 | [UNATTENDED-RDP.md](UNATTENDED-RDP.md) 참고 |

### Cockpit 자체 오류 확인

```powershell
$log = "$env:TEMP\$env:USERNAME\expedition\2011.1\EExDMLibraryClient_$env:USERNAME.log"
Select-String -Path $log -Pattern 'ERROR|Exception|Caused by' | Select-Object -Last 20
```

### 낯선 대화상자에서 멈출 때

서버 설정이 바뀌면 처음 보는 관문 창이 생길 수 있다.
```powershell
.\tools\Inspect-BulkImportDialog.ps1   # 창 제목·버튼·좌표 덤프
```
출력 내용을 보고 `Jab-Bridge.ps1` 의 `Dismiss-CockpitStartupDialog` 에 핸들러를 추가한다.

현재 자동 처리되는 관문 창:
- `License Selector` → Librarian 선택 후 OK
- `Production library selection` → Next
- `Setup M3DL Connection` → EDM Server only 선택 후 OK
- Cockpit `Error` 창 → OK (서버 접속 오류 등)

### 남은 Cockpit 프로세스 정리

```powershell
Get-Process xDMLibraryClient, javaw -ErrorAction SilentlyContinue | Stop-Process -Force
```

---

## 8. 운영 환경 확인 사항

### 디스플레이 배율

JAB 는 배율 미적용 좌표를 반환한다. 코드가 창 크기로 배율을 **실측 보정**하므로
100%/125%/150% 모두 동작하도록 설계되어 있으나, **검증은 125% 환경에서만** 수행했다.
운영 PC 배율이 다르면 전체 실행으로 한 번 육안 확인할 것.

모니터마다 배율이 다른 혼합 환경은 미검증이다 (구형 `SetProcessDPIAware` 사용).

### 화면 잠금·화면 보호기

콘솔 세션이 잠기면 실제 입력이 막혀 5~6단계가 실패한다.
GPO 로 자동 잠금이 강제된다면 IT 에 예외를 요청해야 한다.

### 재부팅 후 자동 로그온

재부팅 후 로그온된 사용자가 없으면 5~6단계가 실패한다.
무인 운영이 필요하면 Sysinternals Autologon 등으로 자동 로그온을 설정한다.
(비밀번호가 PC 에 저장되므로 도메인 보안 정책 확인 필요)
