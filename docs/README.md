# Xpedition EDM Library 3D 모델 자동 등록

공정기술팀이 구축한 3D STEP 파일을 설계팀 라이브러리로 동기화하고,
매일 변경분을 추려 Xpedition Import 작업 배치를 자동으로 만들어 준다.

## 전체 흐름

| 단계 | 내용 | 자동화 |
|---|---|---|
| 1 | 공정기술 공유폴더 → 설계팀 라이브러리 동기화 | 자동 |
| 2 | 라이브러리 전체 목록 CSV 출력 | 자동 (1회/일) |
| 3 | Mapping.xdm / Alignment.dat 생성 | 자동 |
| 4 | 업데이트분을 날짜 폴더로 정리 | 자동 |
| 5 | Xpedition 3D Model Import | 수동 |
| 6 | 3D 매핑 파일 Import | 수동 |
| 7 | 2D–3D 모델 alignment | 수동 |

---

## 빠른 시작

```powershell
# 1) 설정 파일 준비
Copy-Item config\config.sample.json config\config.json
notepad config\config.json          # <<SET-ME>> 세 곳을 실제 경로로 교체

# 2) 드라이런 (아무것도 바꾸지 않고 연결성/권한 확인)
.\Run-Sync.bat -WhatIf

# 3) 실제 1회 실행 (최초 실행은 '기준선' 만 만들고 배치는 만들지 않음)
.\Run-Sync.bat

# 4) 작업 스케줄러 등록
.\tools\Register-Task.ps1 -User 'DOMAIN\svc_3dsync'
```

### 실행 방법 3가지
| 방법 | 용도 |
|---|---|
| `Run-Sync.bat` | **작업 스케줄러 등록용.** 멈추지 않고 종료코드를 그대로 반환 |
| `Run-Sync-Interactive.bat` | **더블클릭용.** 결과를 보여주고 창을 유지 |
| `Run-3DModelSync.ps1` | PowerShell 에서 직접 실행 (개발·디버깅) |

`.bat` 래퍼가 하는 일:
- `pwsh.exe` 가 있으면 쓰고, 없으면 `powershell.exe` 로 자동 대체
- `-ExecutionPolicy Bypass` 지정 (서명 안 된 스크립트 차단 방지)
- 배치 파일 위치 기준으로 동작 (스케줄러의 작업 디렉토리는 신뢰 불가)
- PowerShell 종료코드를 그대로 전달

> `Run-Sync.bat` 에는 **의도적으로 `pause` 가 없다.** 스케줄러 실행 중
> 멈추면 작업이 시간 제한까지 매달려 매일 조용히 실패하기 때문이다.
> 더블클릭으로 쓸 때는 `Run-Sync-Interactive.bat` 를 사용한다.

> 드라이런(`-WhatIf`)은 robocopy 를 `/L`(목록만)로 돌리므로 **새 파일이
> 라이브러리에 복사되지 않는다.** 따라서 "오늘 몇 건이 새로 잡힐지"는
> 드라이런으로 알 수 없다. 경로·권한·설정 점검용으로만 쓴다.

---

## 설정 (`config/config.json`)

반드시 채워야 하는 값은 세 개다.

| 키 | 설명 |
|---|---|
| `paths.sourceShare` | 공정기술 공유폴더 (UNC 경로 권장) |
| `paths.designLibrary` | 설계팀 3D 라이브러리 (공유폴더의 전체 미러) |
| `paths.dateFolderRoot` | 날짜별 Import 배치가 쌓일 루트 |

`<<SET-ME>>` 가 남아 있으면 **미설정 키를 전부 한 번에 나열하고** 종료코드 2 로 중단한다.

### 주요 동작 옵션
| 키 | 기본값 | 의미 |
|---|---|---|
| `behavior.firstRunMode` | `BaselineOnly` | 최초 실행은 기준선만 생성. 기존 라이브러리를 통째로 Import 하려면 `TreatAllAsNew` |
| `behavior.failOnZeroFilesFound` | `true` | 원본이 0건이면 중단 (공유폴더 사망 감지) |
| `batch.includeModified` | `true` | 수정된 파일도 배치에 포함 |
| `retention.dateFolderDays` | `0` | 날짜 폴더 자동 삭제 안 함 |
| `mapping.enabled` | `true` | Mapping.xdm / Alignment.dat 생성 |
| `mapping.vendor` | `User` | VND 필드 값 |

### UNC 경로 쓰는 법 (주의)

JSON 은 백슬래시를 이스케이프하므로 **UNC 는 백슬래시 4개**가 필요하다.

| config.json 에 쓴 것 | 실제 해석된 값 | 결과 |
|---|---|---|
| `"\\\\192.168.0.1\\share"` | `\\192.168.0.1\share` | **정상 UNC** |
| `"//192.168.0.1/share"` | `//192.168.0.1/share` | 정상 (이스케이프 불필요) |
| `"\\192.168.0.1\\share"` | `\192.168.0.1\share` | **위험** — 파싱은 되지만 UNC 아님 |
| `"\192.168.0.1\share"` | — | 파싱 오류 |

백슬래시 2개가 가장 위험하다. **오류 없이** 잘못된 경로가 되기 때문이다.
헷갈리면 슬래시(`/`)를 쓰는 편이 안전하다.

> **`dateFolderRoot` 를 `designLibrary` 하위에 둔 경우**
> `scan.excludeFolderNames` 에 그 폴더명을 반드시 넣어야 한다.
> 넣지 않으면 배치로 복사된 파일을 라이브러리 모델로 **중복 인식**한다.

---

## 변경 감지 방식

파일 내용의 **SHA-256 해시**로 판정한다. 타임스탬프만 믿지 않는다.

| 분류 | 조건 | 배치 포함 |
|---|---|---|
| `New` | 스냅샷에 없는 파일 | O |
| `Modified` | 해시가 달라짐 | O |
| `TouchedOnly` | **해시는 같고 타임스탬프/크기만 다름** | X |
| `Deleted` | 원본 공유폴더에서 사라짐 | X (보고만) |
| `Unchanged` | 완전 동일 | X |

`TouchedOnly` 가 중요한 이유: 공유폴더에서 내용 변경 없이 재복사되면
타임스탬프만 바뀌는데, 이를 `Modified` 로 처리하면 재Import 가 불필요한
파일로 날짜 폴더가 가득 찬다.

**성능**: 크기와 타임스탬프가 모두 같으면 이전 해시를 재사용한다.
라이브러리가 커져도 매일 전체를 다시 해싱하지 않는다.

### 최초 실행 (기준선)
스냅샷이 없으면 전체가 "신규"로 보여 첫 배치에 라이브러리 전체가 들어간다.
이를 막기 위해 최초 실행은 **기준선 모드**로 동작한다.
전체 목록 CSV 와 스냅샷만 만들고 **날짜 폴더는 만들지 않는다.**

---

## Mapping.xdm / Alignment.dat

날짜 폴더 안에 step 파일과 **함께** 생성된다. 그날 배치에 들어간
New + Modified 파일만 대상으로 한다.

> **Import 는 누적 방식이다.** 매핑 파일에 없는 부품이라도 이전에 등록된 것은
> 해제되지 않으며, 같은 부품을 다시 Import 하면 덮어쓰면서 업데이트된다.
> 그래서 날짜별로 그날 변경분만 넣으면 되고, 전체 목록을 다시 만들 필요가 없다.

**Mapping.xdm** — 부품당 4줄 + 빈 줄
```
FPT: MAX2003CPE
XDP: MAX2003CPE
VND: User
ALT: 

```

**Alignment.dat** — 부품당 1줄
```
"MAX2003CPE" "MAX2003CPE" User  0 0 0 0 0 0 M
```

- `FPT`(부품번호)와 `XDP`(3D 모델명)는 **둘 다 확장자를 제외한 파일명**
- `VND` 는 `User` 고정 (config 의 `mapping.vendor` 로 변경 가능)
- `ALT` 는 빈 값이며 `ALT: ` 뒤 공백 1개가 유지된다
- 숫자 6개와 단위 `M` 은 고정. 실제 2D–3D 정렬은 7단계에서 수동으로 맞춘다
- 인코딩은 **BOM 없는 ASCII + CRLF**. 제공된 샘플과 바이트 단위로 동일함을 검증했다

> 원본 `CreateMapping_2.vbs` 는 Excel 에서 읽은 값을 ANSI 로 쓴 뒤
> `runvb.bat` 이 `CMD /a /c TYPE` 으로 UNICODE 재변환을 했다. 이는 Excel 경유 시
> 문자가 깨지는 것을 막기 위한 보정으로, 여기서는 Excel 을 거치지 않고
> 파일명에서 직접 생성하므로 그 단계가 필요 없다.

### 매핑에서 제외되는 경우 (경고 후 계속 진행)
ASCII 파일이라 담을 수 없거나 형식을 깨뜨리는 항목은 **조용히 넘어가지 않고**
로그에 경고를 남긴 뒤 제외한다. step 파일 자체는 배치 폴더에 그대로 복사된다.

| 사유 | 처리 |
|---|---|
| 파일명에 한글 등 **비ASCII** 문자 | 제외 + 경고. 영문으로 변경하거나 수동 등록 |
| 파일명에 큰따옴표 `"` | 제외 (Alignment.dat 의 구분자와 충돌) |
| 부품명 **중복** (다른 폴더에 동명 파일) | 첫 건만 등록하고 나머지 제외 + 경고 |

제외가 발생하면 종료코드 1(경고와 함께 완료)로 끝난다.

---

## 삭제 정책 (중요)

**공유폴더에서 파일이 지워져도 설계팀 라이브러리에서는 지우지 않는다.**

- robocopy `/MIR` 를 쓰지 않는다. 공유폴더의 대량 삭제 사고를
  설계팀 폴더로 전파시키는 것이 바로 그 플래그다.
- 이미 EDM 에 등록된 모델의 원본이 사라지지 않는다.
- 삭제는 `changes_*.csv` 와 로그에 `Deleted` 로 **보고만** 한다.

---

## 하루에 여러 번 실행할 경우 (누적)

같은 날 두 번 이상 실행해도 **이전 실행 결과가 사라지지 않는다.**
오전에 만든 매핑을 오후 실행이 덮어써 버리면, 오전에 등록한 부품이
매핑에서 빠져 Xpedition 에 등록되지 않기 때문이다.

| 파일 | 동작 |
|---|---|
| `Mapping.xdm` | **누적** — 기존 항목을 읽어 이어붙인다 |
| `Alignment.dat` | **누적** — 위와 동일 |
| `_batch_manifest.csv` | **누적** — `RunTime` 으로 회차 구분 |
| `changes_*.csv` | **누적** — `RunTime` 으로 회차 구분 |
| `filelist_*.csv` | **덮어쓰기** — '현재 전체 상태' 스냅샷이므로 누적하면 중복 |
| 날짜 폴더의 step 파일 | 같은 이름은 덮어쓰기, 새 파일은 추가 |

**같은 부품이 여러 회차에 걸쳐 변경되어도 매핑에는 1건만 남는다.**
FPT/XDP 가 동일한 파일명이라 두 번 기록해도 내용이 같기 때문이다.
단 `changes_*.csv` 에는 회차별로 모두 기록되므로 이력 추적은 가능하다.

예시 — 오전에 2건, 오후에 1건 추가 + 1건 수정한 경우:

```
Mapping.xdm          AM-001, AM-002, PM-001        (3건)

changes_*.csv
  RunTime              ChangeType  FileName
  2026-09-16 09:00:10  New         AM-001.step
  2026-09-16 09:00:10  New         AM-002.step
  2026-09-16 14:30:11  Modified    AM-001.step     ← 이력은 남음
  2026-09-16 14:30:11  New         PM-001.step
```

---

## 출력물

```
output/
  filelist_yyyy-MM-dd.csv    # 전체 목록 (2단계)
  changes_yyyy-MM-dd.csv     # 변경 리포트 (하루 여러 번 실행 시 누적)
  dryrun/                    # -WhatIf 실행 결과

<dateFolderRoot>/yyyy-MM-dd/
  <원본 하위구조 그대로>/*.step   # Import 대상 파일
  Mapping.xdm                     # 3D 매핑 파일
  Alignment.dat                   # alignment 파일
  _batch_manifest.csv             # 이 배치의 내역

logs/
  sync_yyyy-MM-dd.log        # 파이프라인 로그
  robocopy_yyyy-MM-dd.log    # robocopy 자체 로그
```

### CSV 를 Excel 로 열 때
- UTF-8 BOM 으로 기록하므로 **한글이 깨지지 않는다.**
- 다만 `1-2`, `3E5` 같은 품번은 Excel 이 날짜/지수로 자동 변환한다.
  정확히 보려면 **데이터 → 텍스트/CSV에서 가져오기** 로 열고
  해당 열을 '텍스트'로 지정한다.

---

## 종료코드

| 코드 | 의미 | 대응 |
|---|---|---|
| 0 | 성공 (변경 없음 포함) | — |
| 1 | 경고와 함께 완료 | 로그의 `[Warn ]` 확인 |
| 2 | 설정 오류 | `config.json` 경로 확인 |
| 3 | 원본·대상 접근 불가 / 동기화 실패 | 공유폴더 연결, 실행 계정 권한 |
| 4 | 스캔·해시 실패 | 로그 확인 |
| 5 | 스냅샷 손상 / 배치 실패 | `state\snapshot.bak.json` 확인 |
| 6 | 다른 실행이 진행 중 | 정상 동작. 대응 불필요 |
| 10 | 예상치 못한 예외 | 로그의 스택트레이스 확인 |

작업 스케줄러의 `LastTaskResult` 에 그대로 노출된다.

---

## 작업 스케줄러 — 반드시 읽을 것

### SYSTEM 계정으로 실행하면 UNC 공유에 접근할 수 없다

SYSTEM 은 네트워크에서 *컴퓨터 계정*으로 인증되는데, 공유 권한은
거의 항상 사용자 계정에 부여되어 있다.

> **증상**: 수동으로 실행하면 완벽히 동작하는데 스케줄러로만 실패한다.

체크리스트:
- [ ] 공유 읽기 + 라이브러리 쓰기 권한이 있는 **도메인 계정**으로 등록
- [ ] 개인 계정 대신 **전용 서비스 계정** (암호 변경·퇴사에 영향받지 않도록)
- [ ] **"사용자의 로그온 여부에 관계없이 실행"** 선택
      (해당 계정에 *배치 작업으로 로그온* 권한 필요)
- [ ] **"암호를 저장하지 않음" 체크 해제**
      (체크하면 네트워크 자격증명 없는 토큰이 되어 UNC 실패가 재발)
- [ ] config 에 **UNC 경로를 직접** 기입.
      매핑 드라이브(`Z:\`)는 대화형 세션 전용이라 스케줄러에 존재하지 않음
- [ ] 계정 암호 만료 시 작업이 조용히 실패 → 만료 없는 계정 또는 gMSA 권장

가동 전 마지막 점검은 **서비스 계정으로 드라이런**을 돌려보는 것이다.
본인 계정으로만 테스트하면 이 문제를 발견할 수 없다.

---

## 개발 시 주의사항

### 한글이 들어간 .ps1 은 반드시 UTF-8 **BOM** 으로 저장할 것

Windows PowerShell 5.1 은 BOM 없는 `.ps1` 을 ANSI(949)로 해석한다.
한글 주석이 깨지면서 중괄호 짝이 어긋나 **파서 오류**가 난다.
PS 7 은 BOM 없이도 UTF-8 로 읽기 때문에 증상이 보이지 않는 것이 함정이다.

편집기가 BOM 없이 저장했다면:
```powershell
.\tools\Fix-Encoding.ps1
```

### 회귀 테스트
```powershell
.\tools\Invoke-PhaseATests.ps1 -Engine pwsh        # PowerShell 7
.\tools\Invoke-PhaseATests.ps1 -Engine powershell  # Windows PowerShell 5.1
```
로컬 더미 폴더(`C:\Temp\3dtest`)로 45개 항목을 검증한다.
테스트는 운영 `config.json` / `snapshot.json` 을 백업했다가 끝나면 복원하므로,
실제 운영 상태를 건드리지 않는다.
**양쪽 엔진 모두에서 통과해야 한다.**

---

## 5~6단계 수동 절차

파이프라인이 끝나면 로그 마지막에 배치 폴더 경로가 출력된다.

1. 해당 날짜 폴더를 연다 (`_batch_manifest.csv` 로 내역 확인 가능)
2. Xpedition 에서 **3D Model Import** 실행 → 이 폴더의 STEP 파일 지정
3. 같은 폴더의 `Mapping.xdm` / `Alignment.dat` Import
4. 2D–3D alignment 확인

이전 날짜 폴더를 다시 Import 해도 무방하다. 누적 방식이라 기존 등록이
풀리지 않고, 같은 부품은 덮어쓰기로 갱신된다.

자동화 가능 여부는 `docs/FOLLOWUP-Xpedition-Automation.md` 참조.
