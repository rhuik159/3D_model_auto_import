# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

---

## 언어 및 커뮤니케이션 규칙

- **기본 응답 언어**: 한국어
- **코드 주석**: 한국어
- **커밋 메시지**: 한국어
- **문서화**: 한국어
- **변수명/함수명**: 영어 (코드 표준 준수)

---

## 프로젝트 개요

Xpedition EDM Library에 3D 모델(.step/.stp)을 자동으로 등록하는 파이프라인.
공정기술 공유폴더 → 설계팀 라이브러리 동기화 → Cockpit GUI 자동화까지 단계별로 실행한다.

---

## 주요 명령어

### 파이프라인 실행

```powershell
# 드라이런 (실제 변경 없이 연결성/변경집합 확인)
.\Run-3DModelSync.ps1 -WhatIf

# 전체 실행
.\Run-3DModelSync.ps1

# 1~4단계만 (Cockpit Import 없이 날짜 폴더까지 생성)
.\Run-3DModelSync.ps1 -SkipImport

# robocopy 없이 스캔부터
.\Run-3DModelSync.ps1 -SkipSync

# 스냅샷 무시 후 기준선 재생성
.\Run-3DModelSync.ps1 -ForceFullBaseline

# EDM 등록 검증 포함 (진단용 — 종료코드에 영향 없음, 미등록은 경고만)
.\Run-3DModelSync.ps1 -Verify      # -SkipVerify 로 config 의 verify.enabled 무시

# 기타: -KeepCockpitOpen(Import 후 Cockpit 유지), -ReuseCockpit(떠 있는 Cockpit 재사용),
#       -LogLevel Debug|Info|Warn|Error, -ConfigPath <경로>
```

작업 스케줄러·탐색기 진입점은 `Run-Sync.bat`(인자 그대로 전달, pwsh 우선/없으면 5.1, `-ExecutionPolicy Bypass`)이다. 더블클릭용은 `Run-Sync-Interactive.bat`(끝에 pause). `Run-Sync.bat`에 pause를 넣으면 스케줄러 작업이 시간 제한까지 멈추므로 금지. .bat 주석은 ASCII만 쓴다(콘솔 코드페이지로 읽힘).

### 테스트

```powershell
# Phase A 회귀 테스트 (로컬 더미 폴더, 운영 상태 백업/복원 포함)
.\tools\Invoke-PhaseATests.ps1

# PowerShell 버전을 지정해서 실행
.\tools\Invoke-PhaseATests.ps1 -Engine powershell
```

**양쪽 엔진(pwsh, powershell)에서 모두 통과해야 한다.** 개별 케이스 실행 옵션은 없다(전체 실행만). 기본 테스트 루트는 `C:\Temp\3dtest`(`-TestRoot`로 변경), 픽스처/설정은 `tools\New-TestFixture.ps1`, `tools\Set-TestConfig.ps1`이 만든다.

### BOM 인코딩 수정

```powershell
# 편집기가 BOM 없이 저장한 .ps1 파일을 일괄 수정
.\tools\Fix-Encoding.ps1
```

### 작업 스케줄러 등록

```powershell
.\tools\Register-Task.ps1 -User 'DOMAIN\svc_3dsync'
```

등록 후 작업 스케줄러에서 보안 옵션을 반드시 **"사용자가 로그온할 때만 실행"** 으로 변경한다 (기본값은 세션 0이라 5~6단계 실패).

### JAB 활성화 확인

```powershell
. .\tools\Common.SddHome.ps1
Test-JabEnabled    # Enabled = True 여야 5~6단계가 동작
```

---

## 아키텍처

### 파이프라인 단계

| 단계 | 파일 | 역할 |
|------|------|------|
| 1 | `src\Step1.SyncFromShare.ps1` | robocopy로 공유폴더 → 라이브러리 복사. **최상위 파일만**(`/E` 없음), `/XC /XN /XO`로 **라이브러리에 없는 이름만** 복사 (/MIR 절대 금지). 복사 전 라이브러리 키 집합(`PreSyncKeys`)을 반환 |
| 2 | `src\Step2.ScanAndSnapshot.ps1` | 라이브러리 스캔(`TopDirectoryOnly`) + SHA-256 해시 + 스냅샷 비교 |
| 3 | `src\Step3.MappingFile.ps1` | Mapping.xdm / Alignment.dat 생성 (ASCII+CRLF) |
| 4 | `src\Step4.StageDateFolder.ps1` | New/Modified 파일을 yyyy-MM-dd 폴더로 복사 |
| 5~6 | `src\Step5.Import.ps1` | Cockpit GUI 자동화 - Bulk Import + Import Mapping File |

오케스트레이터: `Run-3DModelSync.ps1` (단계별 함수를 dot-source 후 순서대로 호출)

### 공통 모듈

- `src\Common.Config.ps1` — config.json 로드, 경로 정규화, 접근 검증 (`Import-SyncConfig`)
- `src\Common.Logging.ps1` — `Write-Log`, `Initialize-Log`, 보관 기간 정리
- `src\Common.Io.ps1` — BOM-UTF8 CSV, 260자 경로 회피, SHA-256 해시, 동시 실행 락

### GUI 자동화 계층 (5~6단계)

```
Step5.Import.ps1
  ├── tools\Start-Cockpit.ps1   (Cockpit 기동, 자동 로그인 설정)
  ├── tools\Jab-Bridge.ps1      (JAB P/Invoke 래퍼)
  └── tools\Common.SddHome.ps1  (Xpedition 설치 경로 자동 탐색)
```

JAB(Java Access Bridge)로 Swing UI를 직접 제어한다. JAB는 실행 계정별로 활성화해야 한다 (`jabswitch /enable`).

### RDP 없이 무인 실행 구조

RDP 세션이 Disconnected 상태이면 디스플레이가 없어 JAB 연결이 실패한다. 해결 방법은 두 가지를 **함께** 설정해야 한다:

1. **가상 디스플레이(IddSampleDriver)** — 물리 모니터 없이도 디스플레이를 유지
   - 서버에 `Microsoft Remote Display Adapter` 외 디스플레이가 없을 때만 필요
   - 설치: `IddSampleDriver\` 폴더, 상세는 `docs\DEPLOY.md` 2장 (4) 참고
   - **부작용**: DWM이 항상 활성화되어 CPU/GPU 부하 증가. 필요한 경우에만 설치

2. **tscon으로 세션을 콘솔로 전환** — RDP를 닫아도 세션이 Active 상태 유지
   - 수동: `tools\Disconnect-ToConsole.bat` (관리자 권한 실행)
   - 자동: `tools\Move-SessionToConsole.bat`을 "연결 끊을 때" 트리거 작업 스케줄러에 등록
   - 확인: 로그에 `세션 상태: Active(SendInput 클릭)` 가 보여야 정상

```
[RDP 창 닫기] → [Disconnected] --(자동 tscon)--> [Console / Active]
                                                    ↑
                                    가상 디스플레이가 화면 역할
```

상세 설정: `docs\UNATTENDED-RDP.md` 참고.

### 진단 도구

| 파일 | 용도 |
|------|------|
| `tools\Inspect-BulkImportDialog.ps1` | 현재 열린 대화상자 제목·버튼·좌표 덤프 |
| `tools\Get-CockpitTree.ps1` | JAB 접근성 트리 전체 출력 |
| `tools\Inspect-CockpitUI.ps1` | Cockpit UI 요소 탐색 |
| `tools\Test-JabRaw.ps1` | JAB DLL 직접 호출 테스트 |
| `tools\Test-EdmRegistration.ps1` | EDM 서버 등록 검증 (읽기 전용) |

### 설정

- `config\config.sample.json` — 템플릿 (버전 관리됨)
- `config\config.json` — 실제 설정 (.gitignore로 제외)
- `<<SET-ME>>` 센티널이 남아 있으면 실행 시 fail-fast로 중단된다.
- 상대경로는 CWD가 아닌 **리포지토리 루트** 기준으로 정규화된다 (작업 스케줄러 대응).

---

## 핵심 설계 원칙 및 함정

### 스냅샷 보호

Import가 실패하면 스냅샷을 갱신하지 않는다. 갱신하면 그날 변경분이 '기존'으로 흡수되어 다음 실행에서 누락된다. 종료코드 7이 반환된 경우 원인 조치 후 재실행하면 같은 변경분을 다시 처리한다.

### robocopy 종료코드

`exit >= 8`만 실패다. 정상 복사 시에도 1을 반환하므로 `if ($rc -ne 0)` 판정은 금지. (`Invoke-Step1Sync`의 `$rc -ge 8` 판정)

### 원본 쪽 수정은 전파되지 않음

`/XC /XN /XO` 때문에 공유폴더에서 같은 이름으로 내용만 바뀐 파일은 (원본이 더 최신이어도) 라이브러리로 복사되지 않는다. 따라서 `Modified`는 라이브러리 쪽 파일이 바뀐 경우에만 생긴다. 이 동작을 바꾸려면 Step1 옵션과 Step2 분류를 함께 손봐야 한다.

`/XN`을 빼면 원본이 더 최신인 같은 이름의 파일이 라이브러리 파일을 덮어쓴다(robocopy Newer 분류). 세 옵션이 모두 있어야 덮어쓰기가 막힌다.

### 최초 실행 판정 (`behavior.firstRunMode`)

스냅샷이 없으면 최초 실행으로 본다. 값은 `BaselineOnly` | `TreatAllAsNew`.
- `BaselineOnly`: 해시·스냅샷만 만들고 날짜 폴더/Import는 하지 않는다.
- `TreatAllAsNew`: Step1이 복사 **전에** 찍은 `PreSyncKeys`에 없던 파일(=이번에 새로 복사된 파일)만 `New`로 강제한다. 기존 파일은 이미 Import된 것으로 보고 `TouchedOnly` 유지. `-SkipSync`로 `PreSyncKeys`가 없으면 전체가 `New`가 된다.
- 스냅샷 없이 비교할 때는 원본 폴더를 `{key→size}` 맵(`Get-SourceFileMap`)으로만 읽어 크기가 다르면 `New`, 같거나 원본에 없으면 `TouchedOnly`로 본다 (UNC 원본 해시 생략).

### 변경 분류

`New` / `Modified`만 날짜 폴더에 넣는다. `TouchedOnly`(해시 동일, mtime만 변경)를 포함하면 재Import 불필요 파일로 배치가 가득 찬다. `Deleted`는 보고만 하고 파일을 삭제하지 않는다(`/MIR` 미사용 설계).

### CSV 누적 기록

`changes_yyyy-MM-dd.csv`는 하루에 여러 번 실행 시 누적된다. `RunTime` 컬럼으로 회차를 구분한다. 덮어쓰는 곳은 `filelist_*.csv`뿐이다.

### Mapping.xdm 누적

날짜 폴더 안에 이미 파일이 있으면 기존 항목을 이어받은 뒤 신규를 추가한다. 덮어쓰면 오전 실행분의 부품이 매핑에서 사라진다.

### mtime 비교

`ConvertFrom-Json`이 ISO 8601을 `[DateTime]`으로 자동 변환하므로 `ConvertTo-IsoUtcString`으로 반드시 정규화한 뒤 비교한다. 그렇지 않으면 매 실행마다 전체 파일이 `TouchedOnly`로 오분류된다. (`Compare-WithSnapshot` 내부, 양쪽 모두 정규화)

### PS 5.1 호환성

- `Get-FileHash` 대신 .NET `HashAlgorithm.ComputeHash` 직접 호출
- `Export-Csv -Encoding utf8BOM` 미지원 → `StreamWriter` + BOM 바이트 직접 기록
- `ConvertFrom-Json -AsHashtable` 미지원 → `PSObject.Properties` 수동 변환
- `ConvertTo-Json -Depth` 기본값 2라서 파일 내용이 조용히 잘림 → `-Depth 5` 필수
- `$x = try { return ... } finally { ... }` 구조 금지 — 5.1에서 return이 `$x`에 할당되지 않고 함수를 빠져나간다. 정리(Dispose)는 각 return 앞에서 직접 호출
- 해시는 `HashAlgorithm` 인스턴스를 루프 밖에서 한 번 만들어 재사용(`-AlgoInstance`) — 파일마다 생성하면 수만 건에서 GC로 급격히 느려진다

### PowerShell 5.1 파일 인코딩

`.ps1` 파일은 UTF-8 **BOM 필수**다. BOM이 없으면 한글 주석이 깨진다.
`.gitattributes`에서 `* -text`로 줄바꿈 자동변환을 비활성화해두었다 (`core.autocrlf=true` 전역 설정 우선 방지).

### UNC 경로

JSON에서 백슬래시는 4개(`\\\\`) 필요. 260자 초과 경로는 `ConvertTo-ExtendedPath`로 `\\?\UNC\` 접두사를 붙인다.

### JAB 주의사항 (5~6단계)

- `doAccessibleActions` 성공 반환이 실제 클릭을 보장하지 않음 → Win32 좌표 클릭 사용
- JAB 핸들 해제 후 접근 시 예외가 아닌 0/False 반환 → "미지원"으로 오판 주의
- 액션 이름은 JRE 로캘 의존 (한국어 JRE: `'누르기'`) → 하드코딩 금지
- 다중 모니터 좌표 클릭 시 `SetProcessDPIAware` 없으면 클릭이 다른 화면으로 날아감
- `MainWindowHandle`은 기동 대화상자(License Selector, Production Library, M3DL)가 뜨면 그쪽을 가리킴 → 제목으로 직접 탐색 필요
- 팝업 메뉴 하위 항목은 JAB rect가 없음 → 화면 실측 좌표 사용
- 세션 상태(`IsSessionActive()`)가 Active일 때만 SendInput 클릭이 동작한다. Disconnected면 PostMessage를 시도하지만 Java AWT에서는 실패한다.

### 작업 스케줄러

SYSTEM 계정은 UNC 공유에 접근 불가. 반드시 공유폴더 읽기 + 라이브러리 쓰기 권한이 있는 도메인 계정으로 등록해야 한다.

---

## 종료코드

| 코드 | 의미 |
|------|------|
| 0 | 성공 (변경 없음 포함) |
| 1 | 경고와 함께 완료 (일부 파일 실패 등) |
| 2 | 설정 오류 / config 없음 |
| 3 | 원본·대상 접근 불가 또는 robocopy 실패 |
| 4 | 스캔/해시 실패 |
| 5 | 스냅샷 손상 또는 배치 생성 실패 |
| 6 | 다른 실행이 진행 중 (락 보유) |
| 7 | Cockpit Import 실패 (스냅샷 미갱신 → 재실행 시 재처리) |
| 10 | 예상치 못한 예외 |
