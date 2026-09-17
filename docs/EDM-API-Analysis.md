# EDM Library API 자동화 가능성 분석 (2026-09-17)

5~6단계(3D Model Import / Mapping·Alignment Import)를 자동화할 수 있는지
공식 매뉴얼과 실제 설치본을 함께 조사한 결과다.

조사 대상
- 매뉴얼: `edm_lib_api_gd_vx.2.14.pdf` (135p, Rev 11, 2023)
- 설치본: `C:\MentorGraphics\EEVX.2.14.1\SDD_HOME\dms`
- 샘플: `OI_API_EXAMPLES_OF_CONNECTIONS_INTO_EDM_2510\ConnectExamples`

---

## 결론 요약

| 항목 | 공식 API 로 자동화 | 근거 |
|---|---|---|
| 3D 모델(.stp) 등록 | **문서화된 방법 없음** | 매뉴얼 135p 전체에 STEP/3D import API 0건 |
| Mapping·Alignment Import | **문서화된 방법 없음** | 매뉴얼에 FPT/XDP/alignment 0건 |
| EDM 접속·인증 | **가능 (공식 지원)** | OI API batch 인증 (p.32-33) |
| 라이브러리 캐시 갱신 | **가능 (CLI 존재)** | `LibraryCacheClient.bat -dmsloginconfig` |

**즉 "접속과 조회는 공식 자동화 가능, 3D import 는 공식 경로 없음"** 이다.
다만 설치본 분석에서 우회 가능성의 실마리를 찾았다 (아래 3항).

---

## 1. 매뉴얼 조사 결과 — 3D 관련 API 부재

전수 검색 결과 다음 문자열이 135페이지에서 **0건**이다.

    STEP  .stp  Cax  CaxIpc  alignment  FPT  XDP  MCAD  transform  4001

`3D` 는 p.60 라이선스 역할표의 `xdm3dmanager` (3D Model Manager) 한 곳뿐이다.
3D 모델 관리가 **별도 라이선스 역할로 존재**한다는 사실은 확인되지만,
그 기능을 호출하는 API 는 이 문서 범위 밖이다.

매뉴얼이 명시한 제약 (자동화 설계 시 중요)

- p.7 — "You cannot use this library to create, edit, or delete object classes."
  → 3D 매핑용 클래스가 DB 에 없으면 API 로 만들 수 없다.
- p.8 — "An XML import does not create missing catalogs, characteristics, or classes."
- p.7 — "Do not use any non-public, non-documented internal classes."
  → **아래 3항의 내부 클래스 활용은 Siemens 가 명시적으로 비권장하는 영역이다.**

---

## 2. 접속·인증 — 공식 지원 (여기까지는 안전)

샘플의 두 패턴 모두 매뉴얼에서 확인된다.

**(a) 저장된 로그인 설정 사용** (p.32-33) — 무인 배치에 적합

```java
OIAuthenticate auth = OIAuthenticateFactory.createBatchAuthenticate("api_conf");
OIObjectManagerFactory omf = auth.login("OI Example");
```

로그인 설정은 **EDM Batch Login application** 으로 미리 만들어 둔다 (p.19).
비밀번호를 코드에 두지 않아도 되므로 이 방식이 권장된다.

**(b) 자격증명 직접 지정** (p.33, p.48-49)

```java
OILoginData d = OIAuthenticateFactory.createLoginData("api_conf");
d.setServer(server); d.setUsername(user); d.setPassword(pass);
```

**라이선스 역할** (p.49-50, p.60) — 3D 작업 시 주의
`xdm3dmanager`(3D Model Manager)는 구 스킴 역할이며 신 스킴에서
`xedmlibrarian_c`(코드 `5689`, Librarian)에 흡수되었다.
3D 관련 자동화에는 Librarian 급 라이선스가 필요할 가능성이 높다.

    d.setLicenseRoleCodes("5689");

**환경 변수** (p.8): `SDD_HOME`, `DBEDIR`(=`%SDD_HOME%\dms`), `WDIR`

---

## 3. 설치본 분석 — 매뉴얼에 없는 3D 내부 구조

매뉴얼에는 없지만 설치본에 실제로 존재하는 것들이다.
**전부 비문서화 내부 API 이므로 Siemens 지원 대상이 아니다** (p.7 참조).

### 3-1. `com.mentor.dms.m3dl.alignment.jar` — 우리가 만드는 파일의 원본 구현

    com/mentor/dms/m3dl/alignment/
      data/         Part, PartAlignment, PartDefaultModel, PartVerification, Vector3, AlignmentType
      fileIO/input/  AlignmentFileReader, PartAlignmentReader, PartVerificationReader
      fileIO/output/ PartAlignmentWriter, PartVerificationWriter, PartsWriter
      library/       DfoManager, PartsFromDMS      <- DB 접근
      mapping/emptymapping/ EmptyMappingGenerator, ModelMappingDataConverter
      transfer/      Model3D
      files/mapping/ XDMapping.xdm (676KB), XDVendorCodes.dat

즉 **Mapping.xdm 과 Alignment.dat 를 읽고 쓰는 공식 구현체가 이 jar 안에 있다.**

### 3-2. Model3D 데이터 모델 (실제 필드)

`transfer/Model3D.class` 에서 추출한 필드다.

    name, manufacturer, seriesName, seriesPath, subseriesName,
    alignment, verification, isDefault, isUser

우리 파이프라인의 `VND: User` 는 `isUser` 플래그에 대응한다.

### 3-3. DB 저장 구조 (가장 중요한 발견)

`library/PartsFromDMS.class` 에서 DFO 쿼리 경로가 확인된다.

    055lst_id.055compid.001model_list.001model_ref.295model_catalog
                                                  .295subseries

**3D 모델이 EDM DB 의 일반 오브젝트(`model_list` / `model_ref`)로 저장된다**는 뜻이다.
전용 바이너리 저장소가 아니라 일반 클래스라면, 매뉴얼의 OI API
(`createObject` / `set` / `makePermanent`, p.55·57)로 조작할 수 있는 여지가 있다.
→ **다음 단계에서 실증이 필요한 지점.**

### 3-4. 번들 레퍼런스 파일

- `XDMapping.xdm` (19,996줄 / FPT 3,330건) — Siemens 정품 매핑 파일
- `XDVendorCodes.dat` — vendor 코드 정의. **399행에 `User  User  USER DEFINED PARTS`**
  → 현재 파이프라인의 `VND: User` 는 정식 등록된 유효값이다.

**형식 차이 주의** — 정품 XDMapping.xdm 은 우리 출력과 구조가 다르다.

    Version: 7                                   <- 버전 헤더 있음
    FPT: MAX2003
    FPH: Controllers\Power\Batteries             <- 계층 경로
    XDP: MAX2003CPE MAX2003CPE_MAX2003ACPE T F F <- 플래그 3개
    XDP1: ...edp                                 <- 참조 파일
    XDP2: ...edp

현재 우리 출력은 `FPT:` / `XDP:` / `VND:` / `ALT:` 4줄 구조다.
샘플과 바이트 일치를 검증했으므로 우리 용도에는 맞지만,
**정품 파일과는 다른 프로파일**이라는 점을 알고 있어야 한다.

### 3-5. 배치 배치 위치

`files/XRConfig.cfg` 가 매핑 파일의 기대 위치를 알려준다.

    XRMapLocation = %CLRoot%\PartDB\Mapping
    XRMapName     = XDMapping.xdm
    PartDBRoot    = %CLRoot%\PartDB
    UserDBRoot    = %CLRoot%\PartDB\User

---

## 4. CaxIpc API — 3D 기능 없음 (확인 완료)

샘플의 `DMS_CaxIpc(clientId, 4001, hostname)` 는 `dmsapi.jar` 에 실재하지만
매뉴얼에는 전혀 없다. 클래스에서 추출한 **전체 메서드 목록에
3D·매핑·alignment·STEP 관련은 하나도 없다.**

있는 것: `initConnection` `quitConnection` `getVersionInfo` `initClass`
`get_login_user` `get_logged_users_list` `getPartsByCharacteristics`
`executePathQuery` `putXmlBlob` `putXmlObject` `putXmlSearch`
`getProductionLibrary` `setProductionLibrary` `shutdownDMS`

→ CaxIpc 는 **조회·XML 입출력용 범용 IPC** 이며 3D import 전용 경로가 아니다.
당초 "3D 는 CaxIpc 관할일 것"이라는 추정은 **틀렸다.**

**포트 주의**: 샘플은 `4001` 을 쓰지만 이 PC 의 실제 설정은 `4000` 이다.

    DFConnector.properties: DMS_IPCPORT 4000

---

## 5. 커맨드라인 도구

`SDD_HOME\dms\bin` 의 배치 도구들이다.

| 도구 | 용도 |
|---|---|
| `LibraryCacheClient.bat` | 라이브러리 캐시 갱신. **`-dmsloginconfig` 로 무인 인증 지원** |
| `xml-console.bat` | XML 임포트/익스포트. 구문은 **Administrators 가이드** 참조 |
| `CapitalLibraryImporter.bat` | Capital 라이브러리 임포트 |
| `dbomloader.bat` `compsync.bat` `batchadmin.exe` | 기타 배치 |

`LibraryCacheClient.bat -help` 실증 결과 (`update_cache_wg`):

    -library <production library>  -wgtarget <LMC file>
    -dmsloginconfig <login config name>  [-full] [-remove] [-verbose] ...

3D import 도구는 아니지만, **`-dmsloginconfig` 라는 무인 인증 규약이
실제로 동작한다**는 증거다. 3D 쪽에 같은 규약의 도구가 있을 가능성.

`3DModelPreviewMigrator.jar` 도 존재하나 프리뷰 마이그레이션 용도로 보이며 미검증.

---

## 6. 권고 — 다음 단계

**우선순위 1: DB 클래스 실사 (가장 확실)**
OI API 로 접속해 `OIClassManager.getAllClasses()` (p.39) 를 덤프하면
3-3 의 `model_list` / `model_ref` 가 어떤 클래스·특성으로 노출되는지
실제로 확인할 수 있다. 일반 클래스라면 공식 OI API 로 자동화 가능성이 열린다.
번들 예제 `SimpleConnectionWithLoginConfig.java` 를 그대로 쓰면 된다.

    C:\MentorGraphics\EEVX.2.14.1\SDD_HOME\dms\examples\OI_API\

**우선순위 2: Administrators 가이드 확보**
매뉴얼이 p.8/128/133 에서 세 번 가리키는 `xml-console` 구문이 거기 있다.
3-3 이 사실이라면 XML import 로 매핑 등록이 가능할 수 있다.

**우선순위 3: Javadoc (KB MG582249)**
Support Center 에서 다운로드. 매뉴얼에 없는 시그니처가 있을 수 있다 (p.7).

**우선순위 4: Cockpit 저널·로그 확인**
GUI 에서 3D import 를 한 번 수행하고 로그를 보면 내부 호출이 드러날 수 있다.

    %SDD_HOME%\dms\java\config\dmsdesktop_log4j.properties

**현실적 판단**
공식 문서 범위에서 5~6단계 완전 자동화는 **현재 불가**다.
3-1~3-3 의 내부 클래스를 쓰면 기술적으로는 가능해 보이나,
매뉴얼 p.7 이 비문서화 내부 클래스 사용을 명시적으로 금지하며
버전 업 시 깨질 수 있다. 업무 도구로는 권하지 않는다.

**당장 이득이 되는 자동화**는 따로 있다.
- 접속·조회는 공식 API 로 가능하므로, **Import 완료 여부 검증**을 자동화할 수 있다.
  (배치 폴더의 부품이 실제로 DB 에 등록됐는지 OI API 로 조회)
- `LibraryCacheClient.bat -dmsloginconfig` 로 **캐시 갱신 자동화**는 지금 바로 가능하다.

---

# 【추가 조사 2026-09-17 오후】 Cockpit 화면 + 플러그인 역해석

Cockpit 캡처(`D:\xdm_server\xdm_auto\xdm_3dmap\*.jpg`)와
3D 플러그인 `com.mentor.dms.m3dl.jar` (2.2MB) 를 추가 조사한 결과다.
**앞의 "공식 경로 없음" 결론은 유지되지만, 실제 구현 경로가 훨씬 구체적으로 드러났다.**

## 7. Cockpit 메뉴 구조 (캡처 확인)

    Tools > Library > 3D Models >
        Bulk Import                       <- 5단계 (모델 등록)
        Setup Connection
        Import Mapping File               <- 6단계 (매핑+alignment)
        Load 3D Models from Central Library

    Tools > Library > Associate All Mappings with Components   <- 별도 메뉴

### Setup Connection 다이얼로그
- Select 3D Models source: (•) **EDM Server only** / ( ) External M3DL Library
- M3DL Root path: `\10.102.69.191\sdd_home\M3DL`

→ 3D 모델 저장소가 **EDM 서버와 별개인 M3DL 공유 경로**에 있다.
   현재 파이프라인이 다루는 `\137.202.176.98\...\designLibrary` 와는 다른 저장소다.

### Import Mapping File 다이얼로그 (6단계)
안내문: *"This function imports mapping and alignment file."*

| 입력 | 값 |
|---|---|
| Mapping file | (우리 `Mapping.xdm`) |
| Alignment file | (우리 `Alignment.dat`) — *"found or selected"* → 같은 폴더면 자동 탐지 |
| Default alignment | (•) Automatic / ( ) Model's origin |
| Import to library | `SMC` |

**입력이 4개뿐이다.** 자동화 관점에서 매우 단순한 인터페이스다.
현재 파이프라인이 두 파일을 같은 날짜 폴더에 나란히 생성하므로
alignment 자동 탐지 조건을 이미 충족한다.

## 8. 3D 기능의 실제 위치 — 플러그인

3D 기능은 `dms\java` 가 아니라 **DMSBrowser 플러그인**에 있다.

    SDD_HOME\dms\java\DMSBrowser\plugins\
        com.mentor.dms.m3dl.jar            2,234,503  <- 본체
        com.mentor.dms.m3dl.alignment.jar    205,088
        com.mentor.dms.m3dl.migration.jar     26,761

앞서 `DmsLibraryGUI.jar` 에서 3D 클래스를 찾지 못한 이유다.

### 8-1. Bulk Import 경로

    com/mentor/dms/m3dl/bulkimport/
        M3DLBulkImportEntryPoint      <- 진입점 (GUI 의존)
        BulkImportProcessOutputHandler
        BulkImportResult / ModelImportResult
        gui/BulkImportDialog, BulkImportWorker, NativeFormatModelImporter

`M3DLBulkImportEntryPoint` 는 `JFileChooser` / `Workbench` 에 묶여 있어
**그대로는 헤드리스 호출 불가**다. 핵심 메서드는 `executeBulkImport`.

라이선스 체크가 내장돼 있다: `checkLicenseRole`, `checkRequiredLicensesForAction`,
`is3DPluginAvailable`. 실패 시 *"This operation cannot be performed due to
missing 3D Plugin component."*

### 8-2. Mapping Import 경로 — **GUI 비의존**

    com/mentor/dms/m3dl/importer/steps/files/FileMappingImportStep

이 클래스가 실제 매핑 임포트 로직이며 **GUI 의존성이 없다.**
추출된 메서드가 우리 파일 형식과 정확히 대응한다.

    getFpt()  getXdp()  getXdp2()  getVendor()  getCellName()  getModelName()
    getAlternateCells()          <- ALT: 필드
    useZeroAlignment             <- Default alignment 옵션
    createOrGetModel3D()  createAssociation()  addAssociation()
    parseMappingFile()  readMappingFile()  parseParams()

→ **우리가 생성하는 `FPT:` / `XDP:` / `VND:` / `ALT:` 4필드가
   파서가 실제로 읽는 필드와 일치한다.** (3-4 의 형식 차이 우려 해소)

## 9. 커맨드라인 실행파일 발견 ★

`ACGExecutor` 가 외부 프로세스를 호출한다는 단서를 따라가 실물을 찾았다.

    SDD_HOME\common3D\win64\bin\
        3DLT.exe                  421,824
        SatToXt.exe               197,424
        XD3DFileInterop.exe     2,324,504
    SDD_HOME\common3D\win64\lib\
        BulkImportWorker.exe      457,240   ★
        FacetsToJT.exe             74,176
        WaitDialogWrapper.exe     588,824

### ACGExecutor 가 조립하는 CLI 파라미터 (상수 추출)

    -library <name>        LIBRARY_PARAMETER
    -importLibrary         IMPORT_LIB_PARAMETER
    -addManufacturerPart   ADD_MFG_PART_PARAMETER
    -handshk=<token>       buildHandshake / HandshakeGenerator

`BulkImportWorker.exe` 바이너리에서도 `-handshk=` 문자열이 확인된다.

환경 변수: `ACG_DIR`, `ACG_EXECUTABLE`, `SDD_HOME`, `M3DLRoot`(`M3DLROOT_ENV_VAR`)

### M3DLConst 의 CL 상수

    _M3DL_CL_import_    getM3DLImportCLPath()   getImportM3DLRootPath()
    _M3DL_CL_align_     getM3DLAlignCLPath()    getAlignM3DLRootPath()
    ALIGNMENT_FILE_NAME = XDAlignment.dat

"CL" = Command Line. **import 와 align 각각에 커맨드라인 경로 개념이 존재한다.**
다만 `_M3DL_CL_import_` 자체는 실행파일명이 아니라 작업 디렉토리 접두사로 보인다
(`getImportM3DLRootPath` 와 짝을 이룸). 실행파일 실체는 미확정.

**주의**: `-handshk` 는 GUI 가 생성한 핸드셰이크 토큰을 워커에 전달하는 구조로 보인다.
즉 `BulkImportWorker.exe` 를 **단독 실행하려면 이 토큰을 만들어야 하며,
이는 문서화되지 않은 내부 규약이다.** 단순 CLI 호출로 끝나지 않을 가능성이 높다.

## 10. 수정된 결론

| 단계 | 자동화 | 근거 |
|---|---|---|
| 5 Bulk Import | 어려움 | 진입점이 GUI 의존, 워커는 handshk 토큰 필요 |
| 6 Mapping Import | **가능성 있음** | `FileMappingImportStep` 이 GUI 비의존 |

**6단계가 5단계보다 자동화하기 쉽다.** 매핑 임포트 로직이 GUI 와 분리돼 있고
입력이 파일 2개 + 옵션 2개뿐이기 때문이다.

다만 둘 다 **비문서화 내부 클래스**이며 매뉴얼 p.7 이 사용을 금지한다.
버전 업 시 깨질 수 있으므로 업무 도구로는 여전히 권하지 않는다.

## 11. 다음 검증 (우선순위 수정)

1. ~~`BulkImportWorker.exe` 단독 실행 시도~~ — **실증 완료(2026-09-17): 실패.**
   `-?` 로 호출 시 stdout/stderr 아무 출력 없이 `exit 1`.
   usage 를 제공하지 않으며, handshk 토큰 없이는 단독 기동하지 않는 것으로 보인다.
   → 5단계를 exe 직접 호출로 자동화하는 경로는 **사실상 막혔다.**
2. **Cockpit 로그 확보** — GUI 에서 Import 를 1회 수행하고 로그를 보면
   실제 호출되는 명령줄이 그대로 드러난다. **가장 확실한 방법.**
   `%SDD_HOME%\dms\java\config\dmsdesktop_log4j.properties` 에서 레벨 조정.
3. OI API 로 `model_list` / `model_ref` 클래스 실사 (기존 우선순위 1)
4. Administrators 가이드의 `xml-console` 구문

## 12. 로그인 설정 `api_conf` — 확인 실패

사용자가 생성했다고 한 `api_conf` 를 다음에서 찾지 못했다.

    %APPDATA%\Mentor Graphics\        (비어 있음)
    %LOCALAPPDATA%\MentorGraphics\    (ces.ini 등만 존재)
    %USERPROFILE% 하위 *api_conf*     (0건)
    SDD_HOME\dms\config\login\        (log4j 설정만)

EDM 로그인 설정은 **서버측 또는 암호화된 저장소**에 보관되는 것으로 보인다.
실제 동작 확인은 파일 탐색이 아니라 **접속 테스트로 해야 한다** (아래).
