# 원격 연결 없이(RDP 종료 상태) 실행하기

원격 PC(예: 10.18.25.215)에 RDP 로 접속해 두지 않아도 5~6단계(Cockpit Import)가
동작하도록 하는 설정 메모. 2026-10-06 검증 완료.

---

## 1. 왜 따로 설정이 필요한가

5~6단계는 Java Access Bridge(JAB)로 Cockpit 화면 요소를 찾고, **실제 마우스·키보드 입력**
(SetCursorPos + SendInput, SendKeys)으로 조작한다.

RDP 창을 그냥 닫으면 세션이 **Disconnected** 상태가 되고 다음 문제가 생긴다.

| 증상 | 원인 |
|---|---|
| `HWND 0x0 는 Java 창이 아닙니다` | 디스플레이가 없어 JAB 연결 자체가 실패 |
| `버튼을 눌렀지만 대화상자가 닫히지 않았습니다` | 끊긴 세션에는 입력 데스크톱이 없어 실제 입력이 전달되지 않음 |

끊긴 세션에서 입력을 흉내 내는 방법은 모두 실패했다 (검증 결과).

- **PostMessage 클릭**: Java AWT 가 메시지 좌표가 아니라 실제 커서 위치(GetMessagePos)로
  마우스 진입을 판정하므로 Swing 버튼이 눌리지 않는다.
- **JAB `doAccessibleActions("click")`**: 이 JRE 에서는 성공을 반환하고도 아무 동작을 하지 않는다.

### 해결 방법

1. **가상 디스플레이(IddSampleDriver)** 를 설치해 화면이 없는 상태에서도 디스플레이를 유지한다.
2. RDP 를 끊는 대신 **`tscon` 으로 세션을 콘솔로 넘긴다**. 그러면 세션이 **Active** 상태로 남아
   원격 연결 상태와 똑같이 실제 입력이 동작한다.
3. 2번을 작업 스케줄러로 **자동화**해서 RDP 창을 X 로 닫아도 자동으로 콘솔로 넘어가게 한다.

```
[RDP 접속 중]  --창 닫기-->  [Disconnected]  --(자동 tscon)-->  [Console / Active]
                                                                   ↑
                                               가상 디스플레이가 화면 역할
```

---

## 2. 가상 디스플레이 설치 (IddSampleDriver) — 1회

콘솔 세션을 그려줄 디스플레이 장치가 필요하다. 이 PC 에는 RDP 전용 어댑터
(`Microsoft Remote Display Adapter`) 외에 디스플레이 장치가 없어서 설치했다.

> 실물 모니터가 연결된 PC 나 가상 디스플레이가 있는 VM 이라면 필요 없을 수 있다.
> 확인: `Get-PnpDevice -Class Display | Select Status, FriendlyName`

### 준비 파일 (`IddSampleDriver\`)

```
IddSampleDriver.inf / .dll / .cat   드라이버 (roshkins 포크)
IddSampleDriver.cer                 드라이버 서명 인증서
certmgr.exe, installCert.bat        인증서 설치
Install-VirtualDisplay.ps1          가상 디스플레이 장치 생성 (SetupAPI)
```

### 설치 순서

모든 단계는 **관리자 권한 PowerShell** 에서, **로컬 경로**에서 실행한다.
UNC 경로(`\\...`)에서는 ExecutionPolicy Bypass 가 적용되지 않으므로 먼저 로컬로 복사한다.

```powershell
cd C:\xdm_server\xdm_auto\xdm_3dmap\3D_model_auto_import\IddSampleDriver

# 1) 인증서 설치  →  "CertMgr Succeeded"
.\installCert.bat

# 2) 드라이버 패키지 등록  →  "Driver package added successfully. Published Name: oemNN.inf"
pnputil /add-driver IddSampleDriver.inf /install

# 3) 가상 디스플레이 장치 생성  →  "SUCCESS: Virtual display device created."
powershell -ExecutionPolicy Bypass -File .\Install-VirtualDisplay.ps1
```

### 확인

```powershell
Get-PnpDevice -Class Display | Select-Object Status, FriendlyName
```
`IddSampleDriver Virtual Display` 가 `OK` 상태로 보이면 완료.

### 설치 중 겪은 문제

| 증상 | 조치 |
|---|---|
| `CertMgr Failed` / `Access is denied` | 관리자 권한 PowerShell 에서 실행 |
| `pnputil /add-device` 가 지원되지 않음 | Windows 버전에 따라 없다. `Install-VirtualDisplay.ps1` 로 장치를 만든다 |
| `devcon` 을 찾을 수 없음 | 기본 설치에 없다. 위와 동일 |
| ps1 실행 시 구문 오류 | 한글이 든 ps1 이 BOM 없이 저장되면 깨진다. 설치 스크립트는 영문만 사용 |
| UNC 경로에서 실행 정책 오류 | 로컬 경로로 복사한 뒤 실행 |

제거: 장치 관리자 → 디스플레이 어댑터 → `IddSampleDriver Virtual Display` → 디바이스 제거.

---

## 3. 세션을 콘솔로 넘기기

### 3-1. 수동: `tools\Disconnect-ToConsole.bat`

RDP 접속 중에 이 파일을 **관리자 권한으로 실행**하면 RDP 창이 닫히고 세션이 콘솔로 넘어간다.
(내부적으로 `tscon <현재 세션 ID> /dest:console` 실행)

3-2 의 자동 작업을 등록했다면 필요 없다. 자동 작업이 동작하지 않을 때의 대안으로 쓴다.

### 3-2. 자동: 작업 스케줄러 등록 — 1회

RDP 연결이 끊기면 자동으로 `tools\Move-SessionToConsole.bat` 가 실행되어 세션을 콘솔로 넘긴다.
결과는 `logs\auto-console.log` 에 남는다.

원격 PC 에서 **작업 스케줄러 → 작업 만들기**:

| 탭 | 설정 |
|---|---|
| **일반** | 이름: `3DModel-AutoConsole`<br>사용자: `AD001\m3nz95` (파이프라인을 실행하는 계정)<br>**"사용자가 로그온할 때만 실행"** 선택<br>**"가장 높은 수준의 권한으로 실행"** 체크 |
| **트리거** | 작업 시작: **"사용자 세션에서 연결을 끊을 때"**<br>특정 사용자: `AD001\m3nz95`<br>**"원격 컴퓨터에서 연결"** 선택 |
| **동작** | 프로그램 시작:<br>`C:\xdm_server\xdm_auto\xdm_3dmap\3D_model_auto_import\tools\Move-SessionToConsole.bat` |
| **조건** | "AC 전원이 있는 경우에만 작업 시작" 체크 해제 |
| **설정** | "이미 실행 중이면 새 인스턴스 시작 안 함" (기본값) |

> **주의**
> - "사용자가 로그온할 때만 실행" 이어야 한다. "로그온 여부에 관계없이 실행" 은 작업이
>   사용자 세션 밖에서 돌아 세션을 넘길 수 없다.
> - "가장 높은 수준의 권한" 이 없으면 tscon 이 권한 부족으로 실패한다.

#### 동작 확인

1. RDP 창을 **X 로 닫는다**.
2. 잠시 후 다시 접속해 `logs\auto-console.log` 확인:
   ```
   2026-10-06 ... session=2 tscon exit=0
   ```
3. 끊긴 상태에서 파이프라인을 실행하면 로그에 다음이 보여야 한다:
   ```
   세션 상태: Active(SendInput 클릭)
   ```
   `Disconnected(PostMessage 클릭)` 로 나오면 콘솔로 넘어가지 않은 것이다.

---

## 4. 파이프라인 스케줄러 설정 확인

파이프라인 작업(`Run-Sync.bat`, [DEPLOY.md](DEPLOY.md) 참고)도
**"사용자가 로그온할 때만 실행"** 이어야 한다. 그래야 Cockpit 이 사용자 세션(콘솔)에서 뜬다.

---

## 5. 운영상 제약

| 항목 | 내용 | 대책 |
|---|---|---|
| **재부팅** | 재부팅 후에는 로그온된 사용자가 없어 5~6단계가 실패한다 | 자동 로그온(Sysinternals Autologon 등) 설정. 비밀번호가 PC 에 저장되므로 도메인 보안 정책 확인 필요 |
| **화면 잠금 / 화면 보호기** | 콘솔 세션이 잠기면 실제 입력이 막혀 실패한다 | 화면 보호기·자동 잠금 해제. GPO 로 강제되면 IT 예외 요청 |
| **콘솔 보안** | 콘솔 세션은 잠기지 않은 상태라 PC 앞에 물리적으로 접근하면 화면을 쓸 수 있다 | 서버실/VM 이면 대개 문제없음 |
| **RDP 재접속** | 다시 접속하면 세션이 RDP 로 돌아온다. 닫으면 자동 작업이 다시 콘솔로 넘긴다 | 별도 조치 불필요 |
| **로그오프** | 로그오프하면 세션 자체가 없어진다 | 로그오프 대신 창 닫기 |

---

## 6. 문제 해결 (로그 메시지별)

| 로그 | 원인 / 조치 |
|---|---|
| `세션 상태: Disconnected(PostMessage 클릭)` 후 `대화상자가 닫히지 않았습니다` | 세션이 콘솔로 넘어가지 않음. `logs\auto-console.log` 확인, 3-2 작업의 권한·트리거 설정 점검, 또는 `Disconnect-ToConsole.bat` 로 수동 전환 |
| `HWND 0x0 는 Java 창이 아닙니다` | 디스플레이 없음. 2장 가상 디스플레이 설치 확인 |
| `Cockpit 메인 창을 찾지 못했습니다` | 이전 실행에서 남은 Cockpit 프로세스 의심. 아래 명령으로 정리 후 재실행 |
| `새 xDMLibraryClient 프로세스 2 개:` (Warn) | 정상. Cockpit 은 창 없는 보조 프로세스를 함께 띄운다. 창이 있는 쪽을 자동 선택함 |
| `Cockpit 이 준비되지 않았습니다 (메뉴 바가 나타나지 않음)` | 기동 대화상자(License Selector 등)를 넘기지 못함. 바로 앞의 `기동 대화상자 처리 실패(재시도): ...` 메시지 확인 |
| `결과 창을 닫지 못했습니다` | 결과 창 버튼 클릭 실패. 세션 상태 줄 확인 |

남은 Cockpit 프로세스 정리:
```powershell
Get-Process xDMLibraryClient, javaw -ErrorAction SilentlyContinue | Stop-Process -Force
```

---

## 7. 관련 코드 변경 (2026-10-06)

| 파일 | 변경 |
|---|---|
| `tools\Start-Cockpit.ps1` | 새 xDMLibraryClient 중 **Cockpit 창을 가진 프로세스**를 EnumWindows 로 골라 반환 (창 없는 보조 프로세스를 잡던 문제 수정). 경고는 `Diag` 로 반환 |
| `src\Step5.Import.ps1` | Start-Cockpit 의 `Diag` 를 로그에 기록. 메인 창 탐색에 대기 시간(`-WaitMs`) 부여 |
| `tools\Jab-Bridge.ps1` | `IsSessionActive()`(WTS 세션 상태), `Invoke-JabPress`(Active 면 실제 클릭, 끊김이면 JAB 액션→PostMessage 순 시도 후 결과 검증), 메인 창은 전체 창 열거·대화상자는 보이는 창만 탐색, 닫힘 판정을 "보이지 않음" 기준으로 복원, 실패 원인 로그 기록 |
| `tools\Disconnect-ToConsole.bat` | 신규. 수동 콘솔 전환 |
| `tools\Move-SessionToConsole.bat` | 신규. 자동 콘솔 전환 (스케줄러 동작) |
| `IddSampleDriver\` | 신규. 가상 디스플레이 드라이버와 설치 스크립트 |
