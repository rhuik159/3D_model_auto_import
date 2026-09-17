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

---

# 【추가 조사 2026-09-17 15시】 app-auto-login 실증 + Overview 매뉴얼

`edm_lib_overview_gd.pdf` (303p) 조사와 `app-auto-login` 실행 결과다.
**12항의 "api_conf 확인 실패"는 해결되었다.**

## 13. app-auto-login — 로그인 설정 관리 도구

    C:\MentorGraphics\EEVX.2.14.1\SDD_HOME\common\win64\bin\app-auto-login.exe

Linux 는 `setup-auto-login.sh` (`<SDD_HOME>/idm/login/bin`), 기능 동일 (p.105).

**역할은 설정의 생성/갱신/목록/삭제이며, 인증 도구가 아니다** (p.105, p.107).
저장된 정보를 소비 측 애플리케이션이 사용해 접속한다 (p.104).

### 구문 (실행 확인)

    app-auto-login -configname <NAME> -user <USER> [-pass <PW> | -passenc <PW>]
                   -server <URL> -prodlib <LIBS> -license <ROLES>
                   [-ds] [-dslicense] [-dsprodlib]
    app-auto-login -list [<NAME>]
    app-auto-login -delete <NAME>
    app-auto-login -help

| 옵션 | 의미 |
|---|---|
| `-ds` `-dslicense` `-dsprodlib` | 대화상자 억제. **무인 로그인의 정식 조건** (p.96, p.107) |
| `-passenc` | `<SDD_HOME>\dms\bin\passwdenc.bat` 로 만든 암호문 (p.106) |
| `-license` | 신규 스킴은 **하나만** 지정 가능 (상호 superset) (p.106) |

신규 역할: `xedmnameduser` `xedmengineer` `xedmlibrarian` `xedmdeveloper`
구 스킴에는 `xdm3dmanager` 가 있으며 자동 매핑된다 (p.106).

### 자격증명 저장 위치

매뉴얼의 유일한 서술 (p.102):

> "saves information to the **local system only for the system account
>  you are currently using**"

**구체적 경로는 매뉴얼도 침묵한다.** 12항에서 파일을 찾지 못한 것이 정상이다.
`%APPDATA%` / `%LOCALAPPDATA%` / `SDD_HOME\dms\config\login` 모두 해당 없음.
→ **검증은 파일 탐색이 아니라 `app-auto-login -list` 로 해야 한다.**

## 14. api_conf 실증 결과 ★

`app-auto-login -list` 출력:

| ConfigName | User | ProdLib | Licenses | EDM Server |
|---|---|---|---|---|
| **api_conf** | admin | [nolimits] | **xedmdeveloper_c** | 10.102.69.191:31000 |
| library_export | admin | [nolimits] | xedmlibrarian_c | 10.252.173.212:31000 |
| mb-export | admin | [nolimits] | xedmlibrarian_c | 10.102.69.191:31000 |
| update_cache | admin | [nolimits] | xedmlibrarian_c | localhost:31000 |
| xml_console | admin | [nolimits] | xedmlibrarian_c | 10.102.69.191:31000 |

**배치 로그인 자체는 성공이 실증되었다.** `~\.DMSBrowser10.2.14.1\setup-auto-login.log`:

    2026.09.17 14:21:23 LoginUtil: Start iS3 batch login process.
    2026.09.17 14:21:31 IS3LoginUtil: Using URL for connection : http://10.102.69.191:31000
    2026.09.17 14:21:31 ClientGIOPConnection to 137.202.176.98:32519

### ★ 라이선스 불일치 — 3D 작업 차단 가능성

`api_conf` 만 `xedmdeveloper_c` 이고 나머지는 전부 `xedmlibrarian_c` 다.
Overview p.28 Table 1 (EDM Library Licenses):

> "**Librarian** / Librarian 200 / **3D Model Manager** — Gives edit rights for
>  all library object classes, plus the right to edit Request objects and enter
>  mapping information on a Component object. **Enables you to launch and use
>  the 3D Model Manager window.**"

**3D Model Manager 는 Librarian 라이선스에 속한다.**
API 가이드 p.60 (`xdm3dmanager` → `xedmlibrarian_c` 흡수)과도 일치한다.

→ 현재 `api_conf`(developer) 로는 3D 기능 권한이 없을 가능성이 높다.
   실제로 임포트 시각에 경고가 3회 기록되었다 (dmsBrowser.log):

    14:28:09 / 14:41:48 / 14:45:22
    com.mentor.dms.m3dl.db.connection.InteractiveConnectionSetup
      - Failed to connect with current M3DL connection configuration.

**단, 이 로그는 Threshold=WARN 이라 성공 기록은 애초에 남지 않는다.**
위 3줄만으로 임포트 실패를 단정할 수 없다. Setup Connection 화면을
여닫는 과정의 경고일 수도 있다. **DB 실사가 필요하다.**

### 권장 조치

기존 설정을 보존하려면 별도 이름으로 생성한다.

    passwdenc.bat                       # 암호문 획득
    app-auto-login -ds -dslicense -dsprodlib -configname api_conf_lib ^
      -user admin -passenc <암호문> ^
      -server 10.102.69.191:31000 -license xedmlibrarian

## 15. 무인 로그인의 정식 소비 경로 (p.96)

    dmsdesktop [-configname <name>] [-appId <id>] [-remote]
               [-class <n>] [-object <id>] [-mode VIEW|MODIFY] [-retain]

> "To have the login configuration bypass display of a login dialog box and
>  automatically enter the login information, use the app-auto-login command
>  ... Include the -ds, -dslicense, and -dsprodlib switches" (p.96)

Windows 실행 파일은 `dmsdesktop.bat` (p.99). JNLP URL 인자 방식도 있다 (p.98).

**중요**: `-dmsloginconfig` 와 `createBatchAuthenticate` 는 Overview 문서
303페이지에서 **0건**이다. 단 `LibraryCacheClient.bat` 는 실제로
`-dmsloginconfig` 를 받는다(5항 실증). 문서화되지 않은 것뿐이다.

## 16. Overview 매뉴얼의 3D 관련 기술 — 역시 0건

303페이지 전수 검색 결과.

| 검색어 | 결과 |
|---|---|
| `M3DL` `.xdm` `alignment` | **0건** |
| `STEP`(파일형식) | **0건** (영단어 "step" 12건은 무관) |
| `3D` | 6건 (p.28 라이선스 2건, p.92 메뉴명 4건) |

p.92 의 메뉴 4개(`Bulk Import` / `Setup Connection` / `Import Mapping File` /
`3D Models Manager`)는 **"웹 브라우저로 기동 시 비활성화된다"는 맥락으로만**
등장하며 기능 설명도 CLI 대응도 없다.

다만 비활성화 사유가 시사적이다 — *"applications or executables requiring a
Siemens EDA software tree"* (p.92).
→ 9항에서 찾은 `common3D\win64\lib\BulkImportWorker.exe` 를 호출하는
   구조라는 방증이다. 실행파일명 자체는 어느 문서에도 없다.

**결론**: API 가이드(135p) + Overview 가이드(303p) **양쪽 모두
3D 자동화 경로를 문서화하지 않는다.** 10항의 결론이 굳어졌다.

## 17. 남은 문서 후보

Overview 가 반복 참조하는 외부 매뉴얼이다.

1. **Xpedition EDM Server and Utilities Guide** — 이름상 유틸리티 CLI
   레퍼런스일 가능성이 가장 높다. **3D CLI 가 있다면 여기다.**
2. Xpedition EDM Library Guide for Administrators — `xml-console` 전체 구문
   (Appendix B), `ascld2dms` 배치 모드
3. EDA Library Module Guide — `dynprodlib`

Chapter 4 의 일반 서술 (p.276):

> "Most data import and export loader programs have both a graphical user
>  interface and a command line user interface. ... the loaders are often
>  called from a cron script"

→ loader 계열은 CLI 배치 호출이 **정식 용법**임을 명시한다.
   3D import 가 loader 로 분류된다면 CLI 가 존재할 수 있다.

## 18. 검증 도구 — tools/edmprobe

`api_conf` 로 접속해 3D/model 관련 DB 클래스를 조회하는 읽기 전용 프로그램.
생성/수정/삭제를 하지 않는다. **아직 실행하지 않았다** (라이선스 정리 선행 필요).

    # 컴파일 (JDK 21 로 Java 17 타깃 — EDM 런타임이 17)
    javac --release 17 -cp "<8개 jar>" -d tools/edmprobe tools/edmprobe/EdmProbe.java

필요 classpath (`ConnectExamples\.classpath` 기준, 경로만 실제 설치본으로 교체):

    SDD_HOME\dms\java\DMSBrowser\plugins\com.mentor.datafusion.dfo.is3.jar
    SDD_HOME\dms\java\DMSBrowser\plugins\com.mentor.datafusion.dfo.jar
    SDD_HOME\dms\java\DMSBrowser\plugins\com.mentor.datafusion.dfodeps.jar
    SDD_HOME\dms\java\DMSBrowser\plugins\com.mentor.datafusion.oi.jar
    SDD_HOME\dms\java\DMSBrowser\plugins\com.mentor.datafusion.utils.jar
    SDD_HOME\dms\java\dmsapi.jar
    SDD_HOME\dms\java\logkit-1.2.2.jar
    SDD_HOME\dms\java\avalon-framework-4.2.0.jar

**주의**: 샘플 `.classpath` 의 `C:/MGCNoScan/XENTP2510/...` 는 작성자 PC 경로다.
이 PC 는 `C:\MentorGraphics\EEVX.2.14.1`.
또 샘플의 IPC 포트는 `4001` 이지만 이 PC 설정은 `4000` 이다
(`DFConnector.properties`).

## 19. 미해결 — 임포트 반영 여부

2026-09-17 오후 사용자가 Cockpit 에서 수행한 작업:
- Bulk Import: `dateFolderRoot\2026-09-17` 의 STEP 파일
- Import Mapping File: 같은 폴더의 `Mapping.xdm` + `Alignment.dat`

배치 폴더 상태 (11:13 기준, 4건):

    0404-001650.stp  0404-001651.stp  2007-007741.stp  2007-008047.stp
    Mapping.xdm (4건 기재)  Alignment.dat (4건 기재)

**DB 반영 여부는 미확정.** 근거가 엇갈린다.

| 정황 | 해석 |
|---|---|
| 매핑/alignment 파일 4건 정상 생성 | 입력은 정상 |
| M3DL 연결 실패 경고 3회 | 실패 시사 — 단 성공 로그는 남지 않음 |
| `%TEMP%\bulkimporttmp\` 에 14:47 생성 파일 | 실행은 됨 |
| 그 파일이 **페이지 0개 빈 PDF** | 프리뷰 생성 실패 시사 |

**확인 방법 (빠른 순)**
1. Cockpit 에서 `0404-001650` / `2007-007741` 검색 → `3D PDF` 컬럼 확인
2. 라이선스 정리 후 `tools/edmprobe` 실행

---

# 【결정적 검증 2026-09-17 16시】 api_conf_lib 접속 실증

`api_conf_lib`(Librarian) 생성 후 `tools/edmprobe` 로 실제 접속해 얻은 결과다.
**14항의 라이선스 우려는 해소되었고, 자동화 가능성이 크게 올라갔다.**

## 20. 사용자 확인: Cockpit 임포트는 성공했다

사용자 확인 (2026-09-17): **임포트한 4개 부품에 3D Model 이 정상적으로 붙었다.**

→ 14항의 `Failed to connect with current M3DL connection configuration` 경고
  3회는 **임포트 실패를 의미하지 않았다.** Setup Connection 화면을 여닫는
  과정의 경고로 보인다. 로그 Threshold 가 WARN 이라 성공 기록이 남지 않아
  생긴 오해였다. **경고 로그만으로 실패를 단정하면 안 된다는 교훈.**

또한 `api_conf`(developer) 상태에서도 GUI 임포트는 동작했다.
Cockpit 자체가 별도 라이선스로 기동되므로 `api_conf` 의 역할과 무관했던 것이다.

## 21. api_conf_lib 접속 성공 ★

    app-auto-login -list
    api_conf_lib   admin   [nolimits]   [xedmlibrarian_c]   10.102.69.191:31000

`EdmProbe api_conf_lib` 실행 결과:

    [1] 접속 성공
        DFO Version: 2.4.1 Build 2024.33.24128628
        DB 사용자 : xdm-0d7bfecf3c8
        서버      : 10.102.69.191:31000

**OI API 배치 인증이 완전히 동작한다.** 매뉴얼 p.32-33 의 공식 경로 그대로다.

## 22. ★★ 3D 모델이 공식 OI API 로 보인다 ★★

`OIClassManager.getAllClasses()` → **351개 클래스**. 그중 3D 관련:

    Model3D          3DModel          M3DLModel      UserModel
    Package3D        3DPackage        M3DLPackage    GeneratedModel
    SeriesFile3D     3DSeriesFile     M3DLSeriesFile
    DefaultModelAssignment            3DModelsDocuments
    M3DLModel/Resistors/Film          M3DLModel/Diodes/Schottky  (계층 존재)

### 클래스 계층 (getPath / getLabel / getSuperclass)

    Model3D                          label="3D Model"   (최상위)
      └─ Model3D/3DModel             label="TOP"
           ├─ .../M3DLModel          label="M3DL"
           └─ .../UserModel          ← 우리가 등록하는 경로

### Model3D 필드 (25개, getFields())

    ModelId            ModelName         Vendor           ModelCatalog
    PackageRef         PackageType       MountType        ElectricalLabel
    SeriesFileRef      Subseries         DocumentRef      Preview3DModel
    3DModelToCompRef   3DModelToCellRef  3DModelToCellRefKey
    3DModelToCompRefKey                  ModelToComponentRefKey
    Model3D_Dyn_id     obj_lock  obj_skn  obj_user
    CreatedBy  CreatedAt  ModifiedBy  ModifiedAt

**매핑 파일 필드와의 대응이 명확하다.**

| Mapping.xdm | Model3D 필드 |
|---|---|
| `FPT:` (부품명) | `3DModelToCompRef` / `ModelToComponentRefKey` |
| `XDP:` (모델명) | `ModelName` |
| `VND: User` | `Vendor` + `UserModel` 서브클래스 |
| (3D PDF 컬럼) | `Preview3DModel` |

8-2 에서 역해석한 `Model3D` transfer 객체의 필드
(name/manufacturer/seriesName/subseriesName/isUser)와도 일치한다.

## 23. 객체 조회 실증

    OIObjectManager.createQuery(String className, boolean lock)  -> OIQuery
    OIQuery.addColumn(String field)        ← 필수. 없으면
                                             "No columns have been added to the query"
    OIQuery.execute()                      -> OICursor (CursorWrapper)
    OICursor.next()                        -> boolean (전진)
    OICursor.getObject() / getProxyObject() / getObjectID() / getOIClass()

`Model3D/3DModel/UserModel` 쿼리에 컬럼 4개를 지정하고 실행한 결과
**행이 30건 이상 반환되었다** (커서가 계속 전진). 즉 **UserModel 클래스에
실제 데이터가 존재하며 공식 API 로 열거된다.**

다만 커서에서 개별 필드 값을 꺼내는 부분은 미완이다
(`getProxyObject()` 반환 객체의 접근자 미확인, 값이 null 로 나옴).
객체 식별까지는 도달했고, 값 추출은 `OIProxyObject` API 를 더 봐야 한다.

## 24. 수정된 최종 결론 ★

| 단계 | 이전 판단 | **수정 후** |
|---|---|---|
| 접속·인증 | 공식 가능 | **실증 완료** (api_conf_lib) |
| 3D 모델 조회 | 불명 | **공식 OI API 로 가능** (Model3D 계층) |
| 3D 모델 등록 | 비문서화 내부 클래스만 | **OI API 가능성 있음** — 일반 클래스로 노출됨 |
| 매핑 연결 | 비문서화 | **가능성 있음** — `3DModelToCompRef` 필드 |

**핵심 전환**: 3D 모델은 전용 바이너리 저장소가 아니라 **EDM DB 의 일반
오브젝트 클래스**다. 매뉴얼 p.7 이 금지하는 것은 "비공개 내부 클래스 사용"인데,
`Model3D` / `UserModel` 은 `getAllClasses()` 로 열거되는 **정규 클래스**이며
`createObject` / `set` / `makePermanent` (p.55, p.57) 대상이 될 수 있다.

**단 아직 검증되지 않은 것**
- 쓰기(등록)가 실제로 허용되는지 — 조회만 확인했다
- STEP 파일 바이트를 어디에 넣는지 (`DocumentRef`? `Preview3DModel`? BLOB?)
- Bulk Import 가 수행하는 지오메트리 파싱·변환을 API 가 대신할 수 있는지
  (`ACGExecutor` 가 별도 실행파일을 호출하는 것으로 보아 **불가능할 가능성**)

→ **현실적 전망**: 매핑 연결(6단계)은 OI API 로 자동화 가능성이 높다.
   모델 파일 등록(5단계)은 지오메트리 처리가 얽혀 있어 여전히 어렵다.

## 25. 다음 단계

1. `OIProxyObject` 값 추출 완성 → 임포트된 4건이 실제로 보이는지 확인
2. `3DModelToCompRef` 로 부품↔모델 연결 구조 확인 (읽기)
3. 쓰기 가능성 타진 — **테스트 DB 또는 샌드박스에서만**
4. `Xpedition EDM Server and Utilities Guide` 확보 (17항)

## 26. 도구 사용법

    cd tools\edmprobe
    # 컴파일
    javac --release 17 -proc:none -cp "<jar 6개>" -d . EdmProbe.java
    # 실행 (읽기 전용)
    java -cp "<edmprobe>;<SDD_HOME jar 전체>" ^
      "-DDMS_DFCONNECTOR_PROPERTY=file:/<SDD_HOME>\dms\java\config\DFConnector.properties" ^
      EdmProbe api_conf_lib

**주의**: 콘솔 한글은 코드페이지 문제로 깨져 보인다. 출력은 영문 위주로 작성했다.

---

# 【쓰기 가능성 조사 2026-09-17 17시】 — 탐색만 수행 (DB 무변경)

사용자 요청: 5단계(모델 등록)가 안 되면 6단계(매핑)는 의미가 없으므로
쓰기 API 를 확인할 것. 테스트 DB 이므로 진행 가능.
**범위는 "탐색만" 으로 합의. 객체를 생성하지 않았고 DB 는 전혀 변경되지 않았다.**

## 27. 접근 구조 — 이 장비에 서버·DB 가 없어도 된다

    이 장비                      EDM 서버 (10.102.69.191)      DB 서버
    ───────                      ────────────────────────     ──────
    EdmProbe (Java) ──OI API──►   IS3/CORBA :31000      ──►   (EDM 이 관리)
    Cockpit         ──────────►

**OI API 는 EDM 서버에 붙는 클라이언트 API 이며 DB 에 직접 연결하지 않는다.**
서버가 DB 접근을 대행하고 권한·락·무결성을 처리한다.
21항에서 이 장비의 `EdmProbe` 가 원격 서버의 351개 클래스를 읽어온 것이 증거다.

→ **DB 직접 접속은 불필요하며 권장되지도 않는다** (EDM 의 객체 모델과 락을 우회).
   필요한 것은 네트워크 경로 + `api_conf_lib` + jar 뿐이고 이미 모두 갖춰져 있다.

## 28. 쓰기 API 는 전부 존재한다 ★

`OIObjectManager` 의 실제 메서드 (매뉴얼 p.55·57 과 일치):

    createObject(String)              -> OIObject
    makePermanent(OIObject)           -> void
    makePermanent(Collection)         -> void
    deleteObject(OIObject)            -> void
    refreshAndLockObject(OIObject)    -> void
    refreshObject(OIObject|Collection)-> void
    createQuery(String, boolean)      -> OIQuery

**즉 Model3D 객체를 API 로 생성하는 것 자체는 막혀 있지 않다.**
(실제 생성은 시도하지 않았다 — 합의된 범위 밖)

## 29. ★ 그러나 STEP 파일을 넣을 BLOB 필드가 없다 ★

`Model3D` 와 `Model3D/3DModel/UserModel` 의 필드 타입을 전수 확인한 결과:

| 필드 | 타입 |
|---|---|
| ModelName, Vendor | `OIStringField` (STRING) |
| PackageRef, SeriesFileRef, DocumentRef | `OIReferenceField` (REFERENCE) |
| 3DModelToCompRef, 3DModelToCellRef | `OIReferenceField` (REFERENCE) |
| 3DModelToCompRefKey, ModelToComponentRefKey | `OIStringField` (STRING) |
| **Preview3DModel** | **`OIActionField` (ACTION)** ← BLOB 아님, 실행 트리거 |

**`OIBlobField` 가 하나도 없다.**

### BLOB 을 가진 클래스는 따로 있다

전체 351개 클래스를 스캔한 결과 BLOB 보유 클래스는 다음뿐이다.

    Picture                        -> PictureBlob
    VariantBOM                     -> VariantBlob
    Mapping (+ RootMapping/SMC/*)  -> HkpBlob
    DXSymbol (+ 하위)              -> HkpBlob, OleBlob

→ **Model3D 계열은 목록에 없다.**

`Mapping/RootMapping/SMC/...` 계층이 보이는 점은 주목할 만하다.
Import Mapping File 다이얼로그의 `Import to library: SMC` 와 일치하며,
M04_diode / M20_fixed_resistor 등 Cockpit 좌측 트리와 같은 파티션 구조다.

### Document 클래스도 BLOB 이 아니다

`DocumentRef` 가 가리키는 `Document` 클래스의 필드:

    Path [OIStringField]          ← 파일시스템 경로 (문자열)
    FileInformation [OISetField]
    CheckOutStatus [OIIntegerField]
    DocumentName, DocumentKey, TitleOfDocument [OIStringField]
    MajorVersion / MinorVersion, CreationDate, Status ...

**파일 본체는 DB BLOB 이 아니라 파일시스템 경로로 참조된다.**

## 30. 5단계에 대한 판단 — 부정적

종합하면 STEP 파일을 OI API 로 등록하는 경로가 보이지 않는다.

1. `Model3D` 에 파일 바이트를 담을 BLOB 필드가 없다
2. `Preview3DModel` 이 ACTION 타입이라는 것은 **서버/클라이언트가 실행하는
   동작**이지 데이터 슬롯이 아니라는 뜻이다
3. 9항의 `ACGExecutor` 가 `BulkImportWorker.exe` 를 호출하는 구조와 정합한다
   — 지오메트리 파싱·변환·프리뷰 생성은 네이티브 실행파일의 몫이다
4. 따라서 `createObject("Model3D/...")` 로 레코드만 만들어도
   **실제 3D 형상이 없는 껍데기**가 될 가능성이 높다

**→ 5단계(모델 등록)는 OI API 만으로는 자동화하기 어렵다.**
   Bulk Import 가 수행하는 것은 DB 레코드 생성 + 네이티브 변환의 조합이며,
   후자를 API 가 대체하지 못한다.

## 31. 그래서 6단계도 재평가가 필요하다

사용자 지적대로 5단계가 막히면 6단계만으로는 효용이 제한된다.
다만 완전히 무의미하지는 않다.

**여전히 가치 있는 시나리오**
- 모델 등록은 Cockpit 으로 수동 1회, 이후 **매핑 연결만 자동화**
  (`3DModelToCompRef` 는 REFERENCE 필드이므로 API 로 설정 가능해 보인다)
- 부품이 많고 모델이 재사용되는 경우 매핑 작업량이 더 크다면 실익이 있다

**현 시점의 현실적 권고**
1. 5·6단계 모두 Cockpit 수동 유지 (현행)
2. 1~4단계 자동 파이프라인은 그대로 유지 — 이미 잘 동작한다
3. **Import 완료 검증을 자동화**하는 것이 투자 대비 효과가 가장 크다.
   `UserModel` 조회가 실증되었으므로(23항), 배치 폴더의 부품이 실제로
   DB 에 등록됐는지 OI API 로 확인하는 스크립트는 지금 바로 만들 수 있다

## 32. 남은 확인 사항

- `Preview3DModel` ACTION 필드가 무엇을 실행하는지 (OIActionField API)
- Bulk Import 직후 `Document.Path` 에 어떤 경로가 기록되는지
  → 임포트된 4건을 조회하면 파일이 어디로 복사되는지 드러난다
- `xml-console` 로 Model3D 객체를 XML import 할 수 있는지
  (Administrators 가이드 Appendix B 필요)

---

# 【xml-console BLOB 조사 2026-09-17 18시】

사용자 가설: *"3D Model 파일 BLOB 은 xml-console 로 넣고, 나머지 객체는
OI API 로 만들면 되지 않을까?"*

도구를 직접 실행하고 내부 구현을 확인해 검증했다.

## 33. xml-console 실제 사용법 (실행 확인)

실행 진입점 (`xml-console.bat` 마지막 줄):

    java -Dlog4j1.compatibility=true -Xmx1024m ^
         -Djava.class.path="<CLASS_PATH>" ^
         com.mentor.dms.xml.importexport.console.Main %*

**`-help` 실행 결과 (축자)**:

    Export: xml-console -configname <login_config> -export -queryfile <query_file>
                        -outfile <export_file>
                        [-blobdir <blob_directory>] [-dateformat UTC|LOCAL|LEGACY]
                        [-pack [-packsize <n>]] [-verbose]
    Import: xml-console -configname <login_config> -import
                        -importfile <import_file>
                        [-blobdir <blob_directory>] [-complete] [-transaction]
                        [-pack] [-verbose]

| 옵션 | 설명 |
|---|---|
| `-configname` | **로그인 설정 이름** → `api_conf_lib` 를 그대로 쓸 수 있다 |
| **`-blobdir`** | **"directory for save and restore BLOBs"** ★ |
| `-transaction` | 트랜잭션 모드 (import) |
| `-complete` | 타임스탬프 특성까지 모두 import |
| `-pack` / `-packsize` | 대용량 분할 (기본 5000 객체/파일) |

**→ BLOB 입출력 기능은 실재한다. 사용자 가설의 전제는 맞다.**

주의: 이 PC 에서 `xml-console.bat` 은 PATH 문제로 직접 실행이 안 됐다.
`Main` 클래스를 직접 호출하면 동작한다. `.bat` 은 EBS 환경에서 실행해야 한다.

## 34. XML 스키마 — BLOB 표현 방식

`com.mentor.dms.xml.engine.XMLTags` 에서 추출한 **전체 태그 목록**:

    export  data  object  field  catalog  class  objectid  id  value
    restrictions  restriction  ignore  sort  sorting  ascending
    blobs   path   graphic   version  unit  date  format  list
    dynamic  comments  emptyfields  noninputfields  defaultvalues
    multirefclass  broken_ref  numwithnull  canonicaloutput
    command  modify  delete  clear  only  null  true  false

**BLOB 관련 태그는 `blobs`, `path`, `graphic` 이다.**

`XmlImport` / `XmlExport` 내부 심볼:

    DFBlobField   DFBlob   getBlob   putToBlob   exportBlob
    blobPath   blobOutputDir   mBlobImportPath   hkp_blob
    BlobEncryptDecrypt        ← BLOB 암호화 계층 존재
    Graphic / graphicBlob / setGraphicXML / loadGraphicXML
    "Cannot decrypt graphics BLOB from object "
    " has to be directory for BLOB files"

→ BLOB 본체는 XML 안에 base64 로 인라인되지 않는다.
   **`-blobdir` 디렉토리에 별도 파일로 두고 XML 은 `path` 로 참조**하는 방식이다.

기존 데이터 예제(`XMLDataExample.xml`)의 필드 표기는 숫자 코드 기반이다.

    <object objectid="PN-1234" class="001" catalog="AA">
      <field id="001obj_id">PN-1234</field>

## 35. ★ 가설의 결정적 문제 ★

`XmlImport` 는 BLOB 을 쓸 때 **`DFBlobField` 를 통해서만** 접근한다
(`getBlob` → `putToBlob`). 즉 **대상 클래스에 BLOB 필드가 정의돼 있어야 한다.**

그런데 29항에서 전수 확인한 결과:

    Model3D                    → OIBlobField 0개
    Model3D/3DModel/UserModel  → OIBlobField 0개
    Document                   → OIBlobField 0개 (Path 문자열만)

    BLOB 보유 클래스: Picture(PictureBlob) / VariantBOM(VariantBlob)
                     Mapping+SMC/*(HkpBlob) / DXSymbol(HkpBlob,OleBlob)

**→ `Model3D` 에는 BLOB 을 넣을 슬롯 자체가 없다.**
   `-blobdir` 이 있어도 넣을 곳이 없으면 의미가 없다.

`hkp_blob` 심볼이 보이는 것도 정합한다 — xml-console 의 BLOB 처리는
`Mapping` / `DXSymbol` 계열의 `HkpBlob` 을 위한 것이다.

### 결론: 가설은 현재 스키마에서 성립하지 않는다

| 가설 구성요소 | 판정 |
|---|---|
| xml-console 로 BLOB 주입 가능? | **예** — `-blobdir` 실재 |
| 그 대상이 3D 모델 파일이 될 수 있나? | **아니오** — Model3D 에 BLOB 필드 없음 |
| OI API 로 나머지 객체 생성 가능? | **아마도** — createObject 등 존재(28항) |
| **조합해서 5단계 자동화?** | **불가** — 파일 본체를 넣을 자리가 없다 |

## 36. 그렇다면 STEP 파일은 어디에 저장되는가

`Document` 클래스가 `Path`(문자열) + `FileInformation`(Set) +
`CheckOutStatus`(int) 를 갖는 구조로 보아,
**파일 본체는 DB BLOB 이 아니라 파일시스템에 두고 경로로 참조**된다.

이는 Setup Connection 의 M3DL Root (`\10.102.69.191\sdd_home\M3DL`,
7항)와도 부합한다. 3D 모델 파일은 그 공유 경로에 물리적으로 놓이고
DB 는 메타데이터와 경로만 관리하는 구조로 추정된다.

**→ 검증 방법**: 임포트된 4건의 `Document.Path` 를 조회하면
   파일이 실제로 어디로 복사되는지 확정할 수 있다. (다음 단계 후보)

이것이 사실이라면 5단계 자동화의 그림이 달라진다.
BLOB 주입이 아니라 **① 파일을 정해진 경로에 복사 + ② DB 메타데이터 생성**
이 되며, ②는 OI API 로 가능할 수 있다.
다만 지오메트리 변환·프리뷰 생성(`ACGExecutor`)은 여전히 별개 문제다.

## 37. Administrators 가이드 확인 결과 (edm_lib_admin_gd.pdf, 434p)

Appendix B "XML Console" = **p.407~434**. 도구 실행 결과(33~35항)와 일치하며,
**실행만으로는 알 수 없었던 두 가지**가 추가로 확인됐다.

### 37-1. ★ Mapping 클래스는 xml-console 사용이 금지다 ★

p.407 (p.424 반복), 축자:

> "**Do not use the xml-console command to create or modify EDA library objects
>  in the following object classes: Mapping (10), Interface (70), Symbol (71),
>  Package (3), Cell (130), Padstack (120), Pad (122), and Hole (123).
>  Do not use xml-console to load EDA library object BLOBs.**
>  As an alternate to xml-console, use **EDX Export and EDX Import**."

35항에서 "BLOB 보유 클래스는 Picture / VariantBOM / Mapping / DXSymbol" 이라 했는데,
그중 **`Mapping`(class 10)은 명시적 금지**이고 `DXSymbol` 도 Symbol(71) 계열이라
사실상 금지다. → **매핑 파일을 xml-console 로 밀어넣는 것은 매뉴얼 위반이다.**
대안은 **EDX Import** 이나 CLI 문법은 이 매뉴얼에 없다.

### 37-2. BLOB 특성의 데이터 모델 요건 (p.119-120)

BLOB 임포트가 동작하려면 대상 클래스에 **type 9 (BLOB)** 특성이 있어야 하고,
다음 이름 규칙의 짝이 필요하다.

    <blob_char_name>      메인 BLOB 특성 (type 9, value type 6)
    <blob_char_name>_p    파일 경로 특성 (필수)
    <blob_char_name>_s    상태 (선택, 0=checked out / 1=checked in)
    <blob_char_name>_d    날짜 (선택)
    <blob_char_name>_u    사용자 (선택)

BLOB 최대 크기 4GB (p.119).

→ **`Model3D` 에는 이 특성 쌍이 없다**(29항 실측과 일치). 매뉴얼 근거로도
   `-blobdir` 로 STEP 파일을 `Model3D` 에 직접 넣을 수단은 존재하지 않는다.

### 37-3. 인증은 `-configname` 이다 (p.408)

`-dmsloginconfig` 는 **`ascld2dms` 전용**(p.402)이다. 도구마다 다르니 주의.
`LibraryCacheClient` 도 `-dmsloginconfig` 를 쓴다(5항).

    xml-console  -configname api_conf_lib   ← 우리 설정 그대로 사용 가능

## 38. ★ 문서화된 우회로 — Document(110) 경유 ★

p.427-430 "Bulk Loading Documents With xml-console" 에 **완전한 절차와 예제**가 있다.
`Document` 클래스는 금지 목록에 없고 BLOB 로드가 **명시적으로 지원**된다.

    <?xml version="1.0" encoding="UTF-8"?>
    <data>
      <object objectid="" class="110" broken_ref="true">
          <field id="110snr">datasheet_example1.pdf</field>       <!-- Document Name -->
          <field id="110obj_skn">NNDM</field>                     <!-- Catalog Group Key -->
          <field id="110dokname">XMLIO_datasheet_example1.pdf</field>
          <list id="110doc_lst" clear="true">
               <field id="110doc_idx">0</field>                   <!-- Index=0 -->
               <field id="110filetype">pdf</field>
               <field id="110d_blob_p">C:\edm_documents\datasheet_example1.pdf</field>
               <field id="110d_blob">datasheet_example1.pdf</field>
            </list>
      </object>
    </data>

- `110d_blob`   = 파일명(leaf name) — 실제 BLOB 특성
- `110d_blob_p` = 소스 전체 경로
- objectid 는 `<110snr 값>:1:1` 형태(버전 포함) 또는 `""` 로 두면 자동 결정 (p.427)
- 같은 객체에 **두 번째 파일**을 붙일 때는 `clear="true"` 를 **빼야 한다** (p.428)
- 100건 이상이면 `-transaction` 권장 (p.428)

### 가능성 있는 3단계 경로 (★ 미검증 추론)

p.431 의 문장이 실마리다.

> "you can create a document reference from **any class that has a Documents tab**
>  (for example, the Manufacturer Part, Variant BOM, or Audit class)"

`Model3D` 에는 `DocumentRef` (REFERENCE) 필드가 있다(22항 실측).

    ① xml-console -blobdir  →  STEP 파일을 Document(110) 첨부로 벌크 로드
    ② OI API createObject   →  Model3D 객체 생성
    ③ DocumentRef 연결      →  ①의 Document 를 가리키게

**단 매뉴얼은 `Model3D` 를 예시로 들지 않는다. 검증이 필요한 추론이다.**

**그리고 이 경로가 되더라도 지오메트리 문제는 남는다.**
Document 에 STEP 파일이 첨부되고 Model3D 레코드가 생겨도
`ACGExecutor` 가 하던 변환·프리뷰 생성은 일어나지 않는다.
Cockpit 에서 3D 형상이 정상으로 보일지는 별개 문제다.

## 39. xml-console 의 조용한 실패 모드 (운영 시 필수 숙지)

| 상황 | 결과 | 페이지 |
|---|---|---|
| `-blobdir` 에 파일이 없음 | **에러 없이 첨부 없이 객체만 임포트** | p.410 |
| `broken_ref` 생략 (기본 false) | 참조 깨진 객체가 **조용히 미로드** | p.423 |
| non-input 특성 | 익스포트돼도 **재임포트 불가** | p.413 |
| `defaultvalues` (take-over) 특성 | 임포트 시 무시 | p.416 |
| `<only>` 를 `<restrictions>` 앞에 배치 | 파싱 에러로 실패 | p.418 |
| `<list clear>` 누락 (첫 요소) | 항목 중복 시 임포트 에러 | p.422 |

임포트에는 **edit rights 필수**이며 Librarian 또는 Developer 라이선스가 필요하다
(p.407, p.9). `api_conf_lib`(Librarian) 가 적합하다.

임포트 XML 은 **UTF-8 / version="1.0" 만 허용**된다 (p.422).
BOM 요구사항은 매뉴얼이 언급하지 않는다 ([[powershell-51-korean-bom]] 관련 주의).

## 40. 3D 관련 — 이 매뉴얼도 침묵 (3번째 문서)

434페이지 전수 검색.

| 검색어 | 결과 |
|---|---|
| `Model3D` `M3DL` `UserModel` `STEP` `.stp` `.xdm` | **전부 0건** |
| `3D` | 3건뿐. 모두 임포트와 무관 |
| `alignment` | 다수 있으나 **전부 UI 레이아웃 정렬**. 3D 얼라인먼트 아님 |
| `bulk` | "Bulk Loading Documents" / "bulk modification" 뿐 |

**유일한 3D 실마리 (p.30)**:

> ".NET Framework — To create a new 3D model on any Windows 8 and later client
>  system, the system must have the .NET framework from Microsoft"
>
> Related Topics: *"Creating a New 3D Model Using a Template
>  [**Xpedition EDM Library EDA Library Module Guide**]"*

→ **3D 모델 생성의 공식 문서는 《EDA Library Module Guide》 에 있다.**
   지금까지 확인한 3개 문서(API 135p / Overview 303p / Admin 434p)가
   모두 3D 에 침묵했으나, 이 문서는 상호참조로 직접 지목된다.
   **다음 확보 우선순위 1위.**

## 41. 기타 도구 (Admin 가이드 기준)

| 도구 | 용도 | 파일 로드 | 페이지 |
|---|---|---|---|
| `xml-console` | XML ↔ DB, `-blobdir` 로 첨부 동반 | **예 (BLOB)** | p.408-414 |
| `ascld2dms` | ASCII 로더. `-batch` 지원, **임포트 전용** | 아니오 (텍스트만) | p.377-406 |
| `batchadmin` | 스키마·인덱스 관리. **서버에서만 실행** | 아니오 | p.362-368 |
| `data_model_checker` / `domain_model_checker` | 모델 정합성 검사 | 아니오 | p.369-376 |
| **EDX Import / Export** | **EDA 라이브러리 객체의 공식 경로** (Mapping 포함) | 예 | p.407, p.424 (CLI 문법 없음) |

`dbomloader` 는 이 매뉴얼에 없다 (검색 0건).

---

# 【A: DB 실사 + B: Module Guide 2026-09-17 19시】

## 42. ★ 임포트된 4건을 DB 에서 확인했다 ★

`api_conf_lib` 로 `Model3D/3DModel/UserModel` 을 조회한 결과다.

    ModelName=0404-001650  Vendor=User  ModelCatalog=User  Subseries=0404-001650
    ModelName=0404-001651  Vendor=User  ModelCatalog=User  Subseries=0404-001651
    ModelName=2007-007741  Vendor=User  ModelCatalog=User  Subseries=2007-007741
    ModelName=2007-008047  Vendor=User  ModelCatalog=User  Subseries=2007-008047
    (그 외 기존 모델 7건: wjTest / 0402C / 1206R / 0402R / 063R_temp x3)

**Cockpit Bulk Import 결과가 OI API 로 완전히 조회된다.**
`Vendor=User`, `ModelCatalog=User` 는 매핑 파일의 `VND: User` 와 대응하며
Module Guide p.251 의 "custom 3D user model" = User 카탈로그 서술과 일치한다.

### 쿼리 작성 시 함정 (실증)

`createQuery` 에 **ID 필드를 컬럼으로 넣지 않으면** 커서가
`dfObjectID is null` 상태가 되어 `getObject()` / `getObjectID()` 가
전부 null 을 반환한다. 행 수는 정상인데 값만 비는 형태라 원인 파악이 어렵다.

    OIClass.getIDField().getName()  →  "ModelId"     ← 이걸 먼저 addColumn
    이후 ObjectWrapper.get(String) / getString(String) 으로 값 접근

## 43. ★★ STEP 파일 저장 구조 규명 ★★

`Model3D.DocumentRef` 를 따라간 결과:

    Model3D/3DModel/UserModel  "0404-001650"
      └─ DocumentRef ─► Document/RootDocument/3DModelsDocuments
                          DocumentName    = User:0404-001650
                          DocumentKey     = User:0404-001650:1:1   ← 버전 포함 키
                          TitleOfDocument = User:0404-001650
                          CheckOutStatus  = 0
                          MajorVersion=01  MinorVersion=1
                          FileInformation = ObjectSetWrapper (비어있지 않음)

**`3DModelsDocuments` 는 `Document` 의 하위 클래스다.**
38항에서 "가능성 있는 우회로"로 추론했던 Document 경유가
**실제 구조임이 확인되었다.** STEP 파일은 Document 첨부로 관리된다.

`DocumentKey` 형식 `User:<모델명>:1:1` 은 Admin 가이드 p.427 의
`<110snr>:1:1` 규칙과 정확히 같다. 즉 **xml-console 의 Document 벌크 로드
규격(p.427-430)이 그대로 적용될 수 있는 형태다.**

Module Guide 도 이를 뒷받침한다 (p.254):

> "**3D Model button** -- Displays the content of the **.STEP model**...
>  **Save button** -- Enables you save the .STEP model to a new name."
> (둘 다 User 카탈로그 모델에서만 활성)

그리고 p.57-58 의 production library `Export 3D Model` 특성:

> "Y: Yes (include native format) — ... include any **stored native source files**
>  of custom models in the export"

→ **원본 .stp 가 EDM 안에 보관된다**는 것이 문서로도 확인된다.

미완: `FileInformation` Set 순회는 `ObjectSetWrapper` 의 API 가 달라
(`next()` 없음) 파일 경로 실값까지는 못 읽었다. 구조 파악에는 지장 없다.

## 44. Module Guide (edm_lib_module_gd.pdf) — 결정적 획득물

3D Model Management 챕터 = **p.264~292**.

### 44-1. ★ Mapping.xdm 완전 규격 (p.286-292) ★

**두 가지 포맷이 있으며 우리는 thin format 을 쓰고 있다.**

**Thin format**

    FPT: <Component Part Number>
    XDP: <Model Name>
    ALT_CELL: <Alternate Cell Name>   (선택)
    VND: <Vendor name>                (선택)

**Extended format**

    FPT: <Component Part Number>
    FPH: <Factory Path>
    ALT_CELL: <Alternate Cell Name>   (선택)
    XDP: <Model Name> <Series Name> <Default T/F> <UserModel T/F> <Obsolete T/F>
    XDP1: Imported/Imported.edp        ← 리터럴 고정
    XDP2: <path to .edp>

**포맷 판별 (p.286)**: `FPT:` 다음에 `FPH:` 가 있으면 extended 로 해석하며
XDP/XDP1/XDP2 가 없으면 **에러**. `VND:` 는 thin 전용이며
**extended 에 넣으면 임포트가 실패할 수 있다** (p.288).

**커스텀(User) 모델 규칙 (p.287-288)**
- `XDP:` 모델명에 **확장자를 넣지 않는다**
- `<Series Name>` 은 더미값 (모델명 반복 가능)
- `<UserModel Flag>` = **T**, `<Obsolete>` = F (값은 무시되나 관례상 F)
- `VND: User` — "When loading custom models the value **must be `User`**"
- `FPH: Imported` — 값은 무시되지만 라인은 필요.
  **커스텀 모델은 전부 같은 디렉터리에 있어야 한다** (p.287)

→ **현재 우리 출력(`FPT:`/`XDP:`/`VND: User`/`ALT:`)은 thin format 이며
   규격에 부합한다.** 다만 우리는 `ALT:` 를 쓰는데 매뉴얼의 키워드는
   **`ALT_CELL:`** 이다 (p.287). 빈 값이라 무시됐을 가능성이 높으나
   **키워드 불일치이므로 확인이 필요하다.**

3-4 항에서 "정품 XDMapping.xdm 과 형식이 다르다"고 했던 의문이 해소된다.
번들 파일은 extended format 이고 우리 출력은 thin format 이다. **둘 다 정상이다.**

### 44-2. Alignment.dat 규격 (p.283)

    "<comp_part_no>" "<mfg_part_no>" <vendor> <Trans_X> <Trans_Y> <Trans_Z>
      <Rot_X> <Rot_Y> <Rot_Z> <A|M> "<ALT_CELL>"

우리 출력: `"0404-001650" "0404-001650" User  0 0 0 0 0 0 M` — **규격에 부합**한다.

**매뉴얼 미기재**: `<A|M>` 의 정확한 의미, 좌표 단위(mm/mil), 각도 단위.
p.284 Figure 164 에 실제 예시가 있으나 **이미지라 텍스트 추출 불가**.

### 44-3. Bulk Import 사양 (p.282-283)

- 지원 포맷: **STEP, SAT, IGES**, Siemens 암호화 **XTD** (p.282)
- **Windows 전용** (p.283)
- 입력: **디렉터리 또는 개별 파일** (p.283) — 우리 날짜 폴더를 그대로 지정 가능
- 결과: `Library > 3D Model > User` 카탈로그에 적재 (p.283)
- **할당 없이 모델만 적재 가능** (p.251) ← 5단계와 6단계를 분리 설계할 근거

### 44-4. Import Mapping File 의 중요 제약 (p.284)

> "Import Mapping File only imports 3D models for components that are in the
>  **production library specified by the production library setting in
>  EDM Library Cockpit**."

→ 대상 부품이 현재 production library 에 없으면 **조용히 누락**된다.
   자동화 시 이 설정을 반드시 선행 확인해야 한다.

### 44-5. CLI/배치 — 이 문서도 침묵 (4번째 문서)

3D 챕터(p.264-292) 전 구간에서 `command` `batch` `script` `.exe` `CLI` `API`
실질 히트 **0건**. 문서 전체에서 `3DLT` `XD3DFileInterop` `BulkImportWorker`
`xml-console` **0건**. `ACG` 는 p.260 에 용어로 1회만 등장한다.

이 문서에 있는 CLI 는 3D 와 무관한 `CapitalLibraryImporter`(p.304)와
`update_cache_wg`(p.324)뿐이며, 후자에 3D 스위치는 없다.
3D export 여부는 CLI 가 아니라 **Production Library 의 `Export 3D Model`
특성(S/Y/N, p.57)** 으로만 제어된다.

**Admin 가이드 p.30 이 가리킨 "Creating a New 3D Model Using a Template"
(p.279-281)은 STEP 임포트와 무관하다.** M3DL 파라메트릭 템플릿으로
치수를 넣어 모델을 생성하는 기능이며 GUI 전용이다. 상호참조가
우리 목표 기준으로는 잘못된 방향을 가리켰다.

## 45. 최종 결론 — 4개 문서 + 실측 종합

| 단계 | 공식 CLI/API | 현실적 자동화 |
|---|---|---|
| 1~4 (동기화·배치·파일생성) | — | **완료. 잘 동작 중** |
| 5 STEP 임포트 | **없음** (4개 문서 전부 침묵) | GUI 필요 |
| 6 매핑 임포트 | **없음** | GUI 필요 |
| 검증 (등록 확인) | **OI API 로 가능** | **지금 구현 가능** ★ |

**공식 문서 4종(API 135p / Overview 303p / Admin 434p / Module 292p+)
어디에도 3D 임포트의 CLI·API 경로가 없다.** 이것이 확정적 결론이다.

### 그럼에도 확보한 실질적 성과

1. **Mapping.xdm / Alignment.dat 규격을 문서로 확정**했다 (p.283, p.286-292).
   현재 파이프라인 출력이 규격에 부합함을 확인했다 (`ALT:` 키워드만 확인 필요).
2. **STEP 저장 구조를 규명**했다 — `Model3D → DocumentRef → 3DModelsDocuments`,
   키 형식 `User:<모델명>:1:1`.
3. **Bulk Import 가 디렉터리 단위 입력**을 받으므로 (p.283)
   날짜 폴더를 그대로 지정하면 GUI 조작 1회로 N건이 처리된다.
   현재 파이프라인 구조가 이미 최적이다.
4. **검증 자동화 경로 확보** — `UserModel` 조회로 배치한 부품이 실제
   등록됐는지 확인 가능. 5·6단계가 수동이어도 **누락은 자동 검출**할 수 있다.

### 남은 가능성 (미검증)

43항의 구조가 Admin 가이드 p.427-430 의 Document 벌크 로드 규격과
일치하므로, 이론적으로는 다음이 가능할 수 있다.

    ① xml-console -blobdir → 3DModelsDocuments 에 STEP 파일 적재
    ② OI API createObject  → Model3D/UserModel 객체 생성
    ③ DocumentRef 연결

**단 지오메트리 변환·프리뷰 생성은 여전히 공백이다.**
Bulk Import 가 네이티브 실행파일로 수행하는 그 처리를 대체할 수단이 없다.
껍데기 레코드만 생길 위험이 크므로 **운영 적용은 권하지 않는다.**
시도한다면 반드시 테스트 DB 에서, 그리고 Cockpit 에서 3D 형상이
정상 표시되는지 눈으로 확인해야 한다.

## 46. 권고

**지금 할 것**: 검증 자동화. 5·6단계 수동은 유지하되
배치 폴더의 부품이 DB 에 등록됐는지 파이프라인이 자동 확인하게 한다.
누락을 사람이 눈으로 찾지 않아도 된다.

**하지 말 것**: 미문서화 실행파일(`BulkImportWorker.exe` 등) 역공학.
`-handshk` 토큰 의존성이 있고(9항) 버전 업 시 깨진다.

**확인할 것**: 우리 `ALT:` vs 매뉴얼 `ALT_CELL:` 키워드 불일치 (44-1).
현재 빈 값이라 문제없어 보이나, 대체 셀을 쓰게 되면 영향이 있다.

---

# 【정정 2026-09-17 20시】 BLOB 은 존재한다 — 29항·35항 결론 수정

사용자 반문: *"OI API 로 Object 생성 후 OIBlob 으로 STEP 업로드하는 게
정말 안될까? 메타데이터는 API 로 나중에 만들고"*
+ Cockpit UI 증거 (`3D_Model_Documents.jpg`): Documents > 3D Models 카탈로그에
**Attachments 탭**으로 파일이 붙어 있음.

**사용자 지적이 옳았다. 29항과 35항의 "BLOB 필드가 없다"는 결론은 틀렸다.**

## 47. 오류의 원인

나는 클래스의 **최상위 필드만** 스캔했다. 그런데 첨부는 최상위가 아니라
**`FileInformation` (OISetField) 내부의 행 객체**에 들어 있다.
Admin 가이드의 `110doc_lst` 리스트 프레임과 같은 구조다 (p.427-429).

또 `OIObjectSet` 을 커서처럼 `next()` 로 순회하려다 실패했는데,
실제로는 **표준 Java `Collection`** 이다. `iterator()` 로 돌면 된다.

## 48. ★ 실제 구조 — BLOB 실재 확인 ★

`0404-001650` 의 `DocumentRef → FileInformation` 내부:

    [1] InnerObjectWrapper
        ViewDocument  [OIActionField]  =
        Index         [OIIntegerField] = 1
        Vault         [OIStringField]  = Default
        FileType      [OIStringField]  = pdf
        ObjectPath    [OIStringField]  =
            C:\Users\m3nz95\AppData\Local\Temp\m3nz95_3DModels\PartDB\
            Packages\User\0404-001650\SAT\PD...
        ObjectStatus  [OIIntegerField] = 1
        ObjectDate    [OIDateField]    = Thu Sep 17 14:46:56 KST 2026
        ObjectUser    [OIStringField]  = admin
        ★ Object     [OIBlobField]    = BlobImpl  getChunkSize=1048576

### OIBlob 에 쓰기 메서드가 전부 있다

    setInputStream(...)   setBytes(...)   getOutputStream()
    getMakePermanentStream()   getInputStream()   getBytes()
    discardCachedInputStream()

매뉴얼 p.35 의 `OIBlob` API 그대로다. **읽기뿐 아니라 쓰기도 가능한 형태다.**

### OIObjectSet 에 행 추가 메서드가 있다

    createLine() -> OIObject      ← 새 첨부 행 생성
    add(OIObject) -> boolean
    remove / clear / size / iterator / toArray

→ **`createLine()` 으로 첨부 행을 만들고 그 `Object` 필드에
   `setInputStream()` 으로 파일을 밀어넣는 경로가 API 상 열려 있다.**

## 49. 그러나 — 첨부된 것은 STEP 이 아니다

결정적 관찰 두 가지.

1. **`FileType = pdf`** — 첨부가 1건뿐이고 그것이 PDF 다.
2. **`ObjectPath` 에 `\SAT\` 가 들어 있다** —
   `...\PartDB\Packages\User\0404-001650\SAT\PD...`

SAT 는 ACIS 계열 3D 포맷이다. 즉 이 첨부는 **원본 STEP 이 아니라
Bulk Import 가 생성한 변환·프리뷰 산출물(3D PDF)** 로 보인다.
경로가 `%TEMP%\m3nz95_3DModels\...` 인 것도 변환 작업 디렉토리를 시사한다.

30항에서 `Preview3DModel` 이 ACTION 타입이라 한 것과 정합한다.

**→ 사용자 가설을 다시 평가하면:**

| 항목 | 판정 |
|---|---|
| `Model3D` 에 BLOB 슬롯이 있나 | **없다** (직접 필드 0개, 변함 없음) |
| `3DModelsDocuments.FileInformation` 에 BLOB 이 있나 | **있다 ★** (내가 틀렸던 부분) |
| OI API 로 그 BLOB 에 쓸 수 있나 | **API 상 가능해 보인다** (createLine + setInputStream) |
| 거기에 STEP 을 넣으면 Bulk Import 와 같아지나 | **아니다** — 현재 첨부는 변환 산출물(pdf/SAT)이다 |

## 50. 수정된 판단

**가능한 것**: OI API 만으로 `Model3D` 객체 + `3DModelsDocuments` 문서 +
첨부 BLOB 까지 **생성 자체는** 할 수 있을 것으로 보인다. xml-console 도 필요 없다.

**여전히 막힌 것**: Bulk Import 가 하는 일은 파일 적재가 아니라
**STEP → SAT 변환 + 3D PDF 프리뷰 생성 + 지오메트리 등록**이다.
원본 STEP 바이트를 첨부에 넣어도 그 변환물이 없으면
Cockpit 3D 뷰어와 Xpedition 에서 형상이 나오지 않을 가능성이 높다.

즉 **병목은 "파일을 어디에 넣느냐"가 아니라 "지오메트리 변환을
누가 하느냐"** 였다. 이 부분은 `ACGExecutor → BulkImportWorker.exe`
네이티브 경로이며 문서화되지 않았다(9항, 44-5항).

## 51. 다음에 확인할 것 (권고 순)

1. **첨부가 정말 1건뿐인지 재확인** — `FileInformation.size()` 를 직접 찍어보고,
   Cockpit Attachments 탭에서 눈으로 확인. STEP 원본이 별도 첨부로
   있는데 내가 첫 행만 본 것일 수 있다. **이게 뒤집히면 50항 판단도 바뀐다.**
2. `ObjectPath` 전체 문자열 확인 (현재 90자에서 잘림).
   `%TEMP%\m3nz95_3DModels\` 가 임시인지 영구 저장소인지 판별.
3. Module Guide p.254 의 **"3D Model button — Displays the content of the
   .STEP model"** 과 대조. STEP 내용을 보여준다면 어딘가에 원본이 있다.
4. 쓰기 실험은 **테스트 DB 에서** — `createLine()` + `setInputStream()` 으로
   더미 파일을 넣어보고 Cockpit 에 어떻게 보이는지 확인.

**교훈**: 컨테이너 필드(SET/LIST) 내부를 열지 않고 "없다"고 결론내면 안 된다.
EDM 데이터 모델은 리스트 프레임 안에 실제 데이터를 두는 패턴을 쓴다.
