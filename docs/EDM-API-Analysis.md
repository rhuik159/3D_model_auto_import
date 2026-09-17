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
