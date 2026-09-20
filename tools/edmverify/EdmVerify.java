import java.io.File;
import java.io.PrintWriter;
import java.lang.reflect.Method;
import java.nio.charset.Charset;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

import com.mentor.datafusion.oi.OIObjectManagerFactory;
import com.mentor.datafusion.oi.login.OIAuthenticate;
import com.mentor.datafusion.oi.login.OIAuthenticateFactory;

/**
 * 설계팀 라이브러리의 STEP 파일이 EDM 서버에 실제로 등록돼 있는지 대조한다.
 *
 * 하는 일
 *   1. 로그인 설정(api_conf_lib 등)으로 배치 접속
 *   2. Model3D/3DModel/UserModel 을 전부 열거
 *   3. 라이브러리 STEP 파일명(확장자 제외)과 ModelName 을 대조
 *   4. 결과를 CSV 로 기록
 *
 * ★ 읽기 전용 ★ 아무것도 생성/수정/삭제하지 않는다.
 *   누락이 발견되어도 재Import 는 하지 않는다. 보고만 한다.
 *
 * 사용법:
 *   EdmVerify <loginConfig> <libraryRoot> <outCsv>
 *
 * EdmProbe 에서 실증된 접근 방식을 그대로 쓴다:
 *   - createQuery(className, false) 로 읽기 전용 쿼리
 *   - ID 필드를 반드시 첫 컬럼으로 (빠뜨리면 커서가 전부 null 을 반환)
 *   - 값 접근자 이름이 버전마다 달라 여러 후보를 시도
 */
public class EdmVerify {

    /** 대조에 필요한 필드. ModelName 이 파일명과 대응한다. */
    private static final String[] FIELDS = {
        "ModelName", "Vendor", "ModelCatalog", "Subseries", "CreatedAt", "CreatedBy"
    };

    private static final String MODEL_CLASS = "Model3D/3DModel/UserModel";

    /** 라이브러리에서 훑을 확장자. config.json 의 scan.includeExtensions 와 맞춘다. */
    private static final String[] EXTENSIONS = { ".step", ".stp" };

    public static void main(String[] args) {
        if (args.length < 3) {
            System.out.println("사용법: EdmVerify <loginConfig> <libraryRoot> <outCsv>");
            System.out.println("  예: EdmVerify api_conf_lib \\\\server\\share\\3D_Models out.csv");
            System.exit(2);
        }
        String loginConfig = args[0];
        String libraryRoot = args[1];
        String outCsv      = args[2];

        OIObjectManagerFactory omf = null;
        int exit = 0;

        try {
            // ------------------------------------------------ 1) 라이브러리 스캔
            System.out.println("[1] 라이브러리 스캔: " + libraryRoot);
            File root = new File(libraryRoot);
            if (!root.isDirectory()) {
                System.out.println("    [오류] 폴더에 접근할 수 없습니다: " + libraryRoot);
                System.exit(3);
            }
            // key = 대조용 소문자 이름, value = 실제 파일 정보
            Map<String, FileRec> files = new LinkedHashMap<>();
            scan(root, root, files);
            System.out.println("    STEP 파일 " + files.size() + " 건");

            // ------------------------------------------------ 2) 서버 접속
            System.out.println();
            System.out.println("[2] EDM 접속: 로그인 설정 '" + loginConfig + "'");
            OIAuthenticate auth = OIAuthenticateFactory.createBatchAuthenticate(loginConfig);
            omf = auth.login("EdmVerify");
            System.out.println("    접속 성공");
            // getDBUserName() 은 EDM API 에서 deprecated 다. 진단용 표시일 뿐이므로
            // 사라진 버전에서도 대조가 멈추지 않도록 감싸 둔다.
            try {
                @SuppressWarnings("deprecation")
                String dbUser = omf.getDBUserName();
                System.out.println("    DB 사용자 = " + dbUser);
            } catch (Throwable ignored) {
                // 표시 실패는 대조에 영향 없음
            }
            try {
                System.out.println("    서버 = " + auth.getLoginData().getServer());
            } catch (Throwable t) {
                System.out.println("    서버 = (조회 불가)");
            }

            // ------------------------------------------------ 3) 등록 모델 열거
            System.out.println();
            System.out.println("[3] 등록된 3D 모델 조회: " + MODEL_CLASS);
            // key = 소문자 ModelName, value = 같은 이름으로 등록된 행들(중복 탐지용)
            Map<String, List<ModelRec>> models = new LinkedHashMap<>();
            int rows = queryModels(omf, models);
            System.out.println("    조회된 행 " + rows + " 건 / 고유 모델명 " + models.size() + " 건");
            if (rows == 0) {
                System.out.println("    [경고] 한 건도 조회되지 않았습니다.");
                System.out.println("           로그인 설정의 라이브러리가 맞는지 확인하세요.");
                exit = 1;
            }

            // ------------------------------------------------ 4) 대조
            System.out.println();
            System.out.println("[4] 대조 결과");
            List<Row> report = compare(files, models);

            int ok = 0, missing = 0, orphan = 0, dup = 0;
            for (Row r : report) {
                if ("OK".equals(r.status))            { ok++; }
                else if ("MISSING".equals(r.status))  { missing++; }
                else if ("ORPHAN".equals(r.status))   { orphan++; }
                if (r.dupCount > 1)                   { dup++; }
            }
            System.out.println("    정상 등록      : " + ok);
            System.out.println("    ★ 미등록      : " + missing + "   (파일은 있는데 서버에 없음)");
            System.out.println("    서버에만 존재  : " + orphan);
            System.out.println("    중복 등록      : " + dup);

            if (missing > 0) {
                System.out.println();
                System.out.println("    미등록 목록 (최대 20건):");
                int shown = 0;
                for (Row r : report) {
                    if ("MISSING".equals(r.status) && shown++ < 20) {
                        System.out.println("      - " + r.relPath);
                    }
                }
                if (missing > 20) {
                    System.out.println("      ... 외 " + (missing - 20) + " 건 (CSV 참조)");
                }
                exit = 1;
            }

            // ------------------------------------------------ 5) CSV
            System.out.println();
            System.out.println("[5] CSV 기록: " + outCsv);
            writeCsv(report, outCsv);
            System.out.println("    완료");

        } catch (Throwable e) {
            System.out.println();
            System.out.println("[오류] " + e.getClass().getName());
            System.out.println("       " + e.getMessage());
            Throwable c = e.getCause();
            int depth = 0;
            while (c != null && depth++ < 5) {
                System.out.println("  cause: " + c.getClass().getName() + " - " + c.getMessage());
                c = c.getCause();
            }
            exit = 4;
        } finally {
            if (omf != null) {
                try { omf.close(); } catch (Exception ignored) { }
            }
        }
        System.exit(exit);
    }

    // ==================================================================== 스캔

    private static void scan(File root, File dir, Map<String, FileRec> out) {
        File[] kids = dir.listFiles();
        if (kids == null) { return; }
        for (File f : kids) {
            if (f.isDirectory()) {
                String n = f.getName().toLowerCase(Locale.ROOT);
                // 배치 폴더와 보관 폴더는 라이브러리 본체가 아니므로 건너뛴다.
                // (config.json 의 scan.excludeFolderNames 와 같은 취지)
                if (n.equals("datefolderroot") || n.equals("_archive")
                        || n.equals("temp") || n.equals("~snapshot")) {
                    continue;
                }
                scan(root, f, out);
                continue;
            }
            String name = f.getName();
            int dot = name.lastIndexOf('.');
            if (dot < 0) { continue; }
            String ext = name.substring(dot).toLowerCase(Locale.ROOT);
            if (!Arrays.asList(EXTENSIONS).contains(ext)) { continue; }

            String bare = name.substring(0, dot);
            String key = bare.toLowerCase(Locale.ROOT);
            String rel = f.getAbsolutePath();
            String rootPath = root.getAbsolutePath();
            if (rel.startsWith(rootPath)) {
                rel = rel.substring(rootPath.length());
                if (rel.startsWith(File.separator)) { rel = rel.substring(1); }
            }
            // 같은 이름이 여러 폴더에 있으면 첫 건만 쓰고 경로를 합쳐 둔다.
            FileRec prev = out.get(key);
            if (prev == null) {
                out.put(key, new FileRec(bare, rel));
            } else {
                prev.extraPaths.add(rel);
            }
        }
    }

    // ==================================================================== 조회

    /** UserModel 을 전부 읽어 models 에 채운다. 반환값은 읽은 행 수. */
    private static int queryModels(OIObjectManagerFactory omf,
                                   Map<String, List<ModelRec>> models) throws Exception {
        Object om = omf.createObjectManager();
        Object q = om.getClass().getMethod("createQuery", String.class, boolean.class)
                     .invoke(om, MODEL_CLASS, false);

        // ★ ID 필드를 첫 컬럼으로 넣어야 한다.
        //   빠뜨리면 커서가 "dfObjectID is null" 상태가 되어 값이 전부 null 로 나온다.
        String idField = resolveIdField(omf, MODEL_CLASS);

        List<String> cols = new ArrayList<>();
        if (idField != null) { cols.add(idField); }
        cols.addAll(Arrays.asList(FIELDS));
        for (String col : cols) {
            for (String adder : new String[] { "addColumn", "addField", "addSelect" }) {
                try {
                    q.getClass().getMethod(adder, String.class).invoke(q, col);
                    break;
                } catch (NoSuchMethodException ignored) {
                    // 다음 후보
                } catch (Exception e) {
                    break;  // 그 컬럼은 이 클래스에 없다
                }
            }
        }

        Object cur = q.getClass().getMethod("execute").invoke(q);
        Method next = cur.getClass().getMethod("next");
        Method getObj = cur.getClass().getMethod("getObject");
        Method getProxy = null;
        try { getProxy = cur.getClass().getMethod("getProxyObject"); }
        catch (NoSuchMethodException ignored) { }

        int n = 0;
        while (Boolean.TRUE.equals(next.invoke(cur))) {
            n++;
            Object o = null;
            try { o = getObj.invoke(cur); } catch (Exception ignored) { }
            String name = str(fieldValue(o, "ModelName"));
            if (name.isEmpty() && getProxy != null) {
                try {
                    Object px = getProxy.invoke(cur);
                    o = px;
                    name = str(fieldValue(px, "ModelName"));
                } catch (Exception ignored) { }
            }
            if (name.isEmpty()) { continue; }

            ModelRec rec = new ModelRec();
            rec.modelName   = name;
            rec.vendor      = str(fieldValue(o, "Vendor"));
            rec.catalog     = str(fieldValue(o, "ModelCatalog"));
            rec.subseries   = str(fieldValue(o, "Subseries"));
            rec.createdAt   = str(fieldValue(o, "CreatedAt"));
            rec.createdBy   = str(fieldValue(o, "CreatedBy"));

            String key = name.toLowerCase(Locale.ROOT);
            models.computeIfAbsent(key, k -> new ArrayList<>()).add(rec);
        }
        return n;
    }

    private static String resolveIdField(OIObjectManagerFactory omf, String cls) {
        try {
            Object cm = omf.getClass().getMethod("getClassManager").invoke(omf);
            Object arr = cm.getClass().getMethod("getAllClasses").invoke(cm);
            for (Object c : (Object[]) arr) {
                if (cls.equals(String.valueOf(c.getClass().getMethod("getPath").invoke(c)))) {
                    Object idf = c.getClass().getMethod("getIDField").invoke(c);
                    if (idf != null) {
                        return String.valueOf(idf.getClass().getMethod("getName").invoke(idf));
                    }
                    break;
                }
            }
        } catch (Exception ignored) {
            // 못 찾아도 진행한다
        }
        return null;
    }

    /** 값 접근자 이름이 버전마다 달라 후보를 순회한다. */
    private static Object fieldValue(Object o, String field) {
        if (o == null) { return null; }
        for (String getter : new String[] { "get", "getValue", "getString", "getFieldValue" }) {
            try {
                return o.getClass().getMethod(getter, String.class).invoke(o, field);
            } catch (NoSuchMethodException ignored) {
                // 다음 후보
            } catch (Exception e) {
                return null;
            }
        }
        return null;
    }

    private static String str(Object o) {
        if (o == null) { return ""; }
        String s = String.valueOf(o);
        return "null".equals(s) ? "" : s.trim();
    }

    // ==================================================================== 대조

    private static List<Row> compare(Map<String, FileRec> files,
                                     Map<String, List<ModelRec>> models) {
        List<Row> out = new ArrayList<>();

        // 파일 기준 — 등록됐는지 본다
        for (Map.Entry<String, FileRec> e : files.entrySet()) {
            FileRec f = e.getValue();
            List<ModelRec> m = models.get(e.getKey());
            Row r = new Row();
            r.fileName = f.bareName;
            r.relPath  = f.relPath;
            if (m == null || m.isEmpty()) {
                r.status = "MISSING";
                r.note   = "라이브러리에 파일은 있으나 서버에 등록되지 않았습니다";
            } else {
                r.status    = "OK";
                r.modelName = m.get(0).modelName;
                r.vendor    = m.get(0).vendor;
                r.catalog   = m.get(0).catalog;
                r.subseries = m.get(0).subseries;
                r.createdAt = m.get(0).createdAt;
                r.createdBy = m.get(0).createdBy;
                r.dupCount  = m.size();
                if (m.size() > 1) {
                    r.note = "서버에 " + m.size() + " 건 중복 등록";
                }
            }
            if (!f.extraPaths.isEmpty()) {
                String add = "라이브러리에 동명 파일 " + (f.extraPaths.size() + 1) + " 개";
                r.note = r.note.isEmpty() ? add : (r.note + "; " + add);
            }
            out.add(r);
        }

        // 서버 기준 — 파일 없는 등록분
        for (Map.Entry<String, List<ModelRec>> e : models.entrySet()) {
            if (files.containsKey(e.getKey())) { continue; }
            List<ModelRec> m = e.getValue();
            Row r = new Row();
            r.status    = "ORPHAN";
            r.modelName = m.get(0).modelName;
            r.vendor    = m.get(0).vendor;
            r.catalog   = m.get(0).catalog;
            r.subseries = m.get(0).subseries;
            r.createdAt = m.get(0).createdAt;
            r.createdBy = m.get(0).createdBy;
            r.dupCount  = m.size();
            r.note      = "서버에 등록돼 있으나 라이브러리에 STEP 파일이 없습니다";
            if (m.size() > 1) {
                r.note += "; " + m.size() + " 건 중복 등록";
            }
            out.add(r);
        }

        // 미등록을 맨 위로 — CSV 를 열자마자 보이도록
        out.sort(Comparator
                .comparingInt((Row r) -> rank(r.status))
                .thenComparing(r -> (r.fileName + r.modelName).toLowerCase(Locale.ROOT)));
        return out;
    }

    private static int rank(String status) {
        if ("MISSING".equals(status)) { return 0; }
        if ("ORPHAN".equals(status))  { return 1; }
        return 2;
    }

    // ==================================================================== CSV

    private static void writeCsv(List<Row> rows, String path) throws Exception {
        File out = new File(path);
        File parent = out.getParentFile();
        if (parent != null && !parent.isDirectory()) { parent.mkdirs(); }

        // Excel 이 한글을 깨뜨리지 않도록 UTF-8 BOM 을 넣는다.
        try (PrintWriter w = new PrintWriter(out, Charset.forName("UTF-8"))) {
            w.print('﻿');
            w.println("Status,FileName,RelativePath,ModelName,Vendor,ModelCatalog,"
                    + "Subseries,CreatedAt,CreatedBy,DuplicateCount,Note");
            for (Row r : rows) {
                w.println(String.join(",",
                        csv(r.status), csv(r.fileName), csv(r.relPath), csv(r.modelName),
                        csv(r.vendor), csv(r.catalog), csv(r.subseries),
                        csv(r.createdAt), csv(r.createdBy),
                        csv(r.dupCount > 0 ? String.valueOf(r.dupCount) : ""),
                        csv(r.note)));
            }
        }
    }

    /** CSV 이스케이프. 선행 =+-@ 는 Excel 수식 주입 방지로 앞에 '를 붙인다. */
    private static String csv(String v) {
        if (v == null) { v = ""; }
        if (!v.isEmpty() && "=+-@".indexOf(v.charAt(0)) >= 0) {
            v = "'" + v;
        }
        if (v.indexOf(',') >= 0 || v.indexOf('"') >= 0
                || v.indexOf('\n') >= 0 || v.indexOf('\r') >= 0) {
            return '"' + v.replace("\"", "\"\"") + '"';
        }
        return v;
    }

    // ==================================================================== 자료형

    private static class FileRec {
        final String bareName;
        final String relPath;
        final List<String> extraPaths = new ArrayList<>();
        FileRec(String bareName, String relPath) {
            this.bareName = bareName;
            this.relPath  = relPath;
        }
    }

    private static class ModelRec {
        String modelName = "", vendor = "", catalog = "";
        String subseries = "", createdAt = "", createdBy = "";
    }

    private static class Row {
        String status = "", fileName = "", relPath = "", modelName = "";
        String vendor = "", catalog = "", subseries = "";
        String createdAt = "", createdBy = "", note = "";
        int dupCount = 0;
    }
}
