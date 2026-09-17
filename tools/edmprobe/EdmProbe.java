import java.util.Collection;

import com.mentor.datafusion.oi.OIObjectManagerFactory;
import com.mentor.datafusion.oi.login.OIAuthenticate;
import com.mentor.datafusion.oi.login.OIAuthenticateFactory;

/**
 * EDM 접속 + 3D 모델 등록 여부 조회 (읽기 전용).
 *
 * 하는 일
 *   1. api_conf 로그인 설정으로 배치 접속
 *   2. 접속 정보 출력
 *   3. 클래스 목록에서 3D/model 관련 클래스 탐색
 *
 * 아무것도 생성/수정/삭제하지 않는다.
 *
 * 사용법: EdmProbe [loginConfigName]   (기본값 api_conf)
 */
public class EdmProbe {

    public static void main(String[] args) {
        String loginConfig = (args.length > 0) ? args[0] : "api_conf";
        OIObjectManagerFactory omf = null;

        try {
            System.out.println("[1] 로그인 설정 '" + loginConfig + "' 로 접속 시도...");
            OIAuthenticate auth = OIAuthenticateFactory.createBatchAuthenticate(loginConfig);
            omf = auth.login("EdmProbe");

            System.out.println("    접속 성공");
            System.out.println("    DB 사용자 : " + omf.getDBUserName());
            try {
                System.out.println("    서버      : " + auth.getLoginData().getServer());
            } catch (Throwable t) {
                System.out.println("    서버      : (조회 불가: " + t.getClass().getSimpleName() + ")");
            }

            System.out.println();
            System.out.println("[2] 클래스 목록 조회...");
            dumpClasses(omf);

            System.out.println();
            System.out.println("[4] UserModel objects (imported 3D models):");
            dumpUserModels(omf);

            System.out.println();
            System.out.println("[5] WRITE-CAPABILITY PROBE (read-only: no object is created)");
            probeWriteApi(omf);

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
        } finally {
            if (omf != null) {
                try {
                    omf.close();
                    System.out.println();
                    System.out.println("접속 종료.");
                } catch (Exception ignored) {
                    // 종료 실패는 조회 결과에 영향 없음
                }
            }
        }
    }

    /**
     * 클래스 목록을 덤프한다. OIClassManager 의 메서드 이름이 버전마다 다를 수 있어
     * 리플렉션으로 후보를 순회한다.
     */
    private static void dumpClasses(OIObjectManagerFactory omf) throws Exception {
        Object cm = null;
        for (String getter : new String[] { "getClassManager", "createClassManager" }) {
            try {
                cm = omf.getClass().getMethod(getter).invoke(omf);
                System.out.println("    ClassManager 획득: " + getter + "()");
                break;
            } catch (NoSuchMethodException ignored) {
                // 다음 후보 시도
            }
        }
        if (cm == null) {
            System.out.println("    ClassManager 를 얻지 못했습니다. 사용 가능한 메서드:");
            for (java.lang.reflect.Method m : omf.getClass().getMethods()) {
                if (m.getParameterCount() == 0 && m.getName().startsWith("get")) {
                    System.out.println("      " + m.getName() + "() -> " + m.getReturnType().getSimpleName());
                }
            }
            return;
        }

        Collection<?> classes = null;
        for (String getter : new String[] { "getAllClasses", "getClasses" }) {
            try {
                Object r = cm.getClass().getMethod(getter).invoke(cm);
                if (r instanceof Collection) {
                    classes = (Collection<?>) r;
                } else if (r != null && r.getClass().isArray()) {
                    // OIClassManager.getAllClasses() 는 OIClass[] 를 반환한다
                    classes = java.util.Arrays.asList((Object[]) r);
                }
                if (classes != null) {
                    System.out.println("    " + getter + "() -> " + classes.size() + " classes");
                    break;
                }
            } catch (NoSuchMethodException ignored) {
                // 다음 후보 시도
            }
        }
        if (classes == null) {
            System.out.println("    클래스 목록 조회 메서드를 찾지 못했습니다. ClassManager 메서드:");
            for (java.lang.reflect.Method m : cm.getClass().getMethods()) {
                if (m.getParameterCount() == 0) {
                    System.out.println("      " + m.getName() + "() -> " + m.getReturnType().getSimpleName());
                }
            }
            return;
        }

        System.out.println();
        System.out.println("[3] 3D/model related classes:");
        int hit = 0;
        for (Object c : classes) {
            String desc = describe(c);
            String low = desc.toLowerCase();
            if (low.contains("3d") || low.contains("model") || low.contains("m3dl")) {
                System.out.println("    * " + desc);
                hit++;
            }
        }
        if (hit == 0) {
            System.out.println("    (none matched)");
        }

        System.out.println();
        System.out.println("[3b] OIClass available methods (first match):");
        for (Object c : classes) {
            for (java.lang.reflect.Method m : c.getClass().getMethods()) {
                if (m.getParameterCount() == 0 && !m.getName().equals("wait")) {
                    System.out.println("      " + m.getName() + "() -> " + m.getReturnType().getSimpleName());
                }
            }
            break;
        }

        System.out.println();
        System.out.println("[3c] 3D class detail:");
        for (Object c : classes) {
            String n = describe(c);
            if (n.equals("Model3D") || n.equals("3DModel") || n.equals("M3DLModel")
                    || n.equals("UserModel") || n.equals("DefaultModelAssignment")) {
                System.out.println("    --- " + n + " ---");
                try {
                    System.out.println("        path  = " + c.getClass().getMethod("getPath").invoke(c));
                    System.out.println("        label = " + c.getClass().getMethod("getLabel").invoke(c));
                    Object sup = c.getClass().getMethod("getSuperclass").invoke(c);
                    System.out.println("        super = " + (sup == null ? "(none)" : describe(sup)));
                    Object fs = c.getClass().getMethod("getFields").invoke(c);
                    if (fs instanceof Collection) {
                        Collection<?> fields = (Collection<?>) fs;
                        System.out.println("        fields(" + fields.size() + "):");
                        int i = 0;
                        for (Object f : fields) {
                            if (i++ >= 25) {
                                System.out.println("            ... (" + (fields.size() - 25) + " more)");
                                break;
                            }
                            System.out.println("            " + describe(f));
                        }
                    }
                } catch (Exception e) {
                    System.out.println("        (detail failed: " + e.getClass().getSimpleName() + ")");
                }
            }
        }
    }

    /**
     * UserModel 클래스의 객체를 조회해 실제 임포트 결과를 확인한다 (읽기 전용).
     * OIObjectManager 의 조회 메서드 시그니처를 먼저 덤프한 뒤, 가능한 것을 시도한다.
     */
    private static void dumpUserModels(OIObjectManagerFactory omf) {
        for (String cls : new String[] { "Model3D/3DModel/UserModel", "Model3D" }) {
            try {
                Object om = omf.createObjectManager();
                // createQuery(String className, boolean lock) — lock=false 로 읽기 전용
                Object q = om.getClass().getMethod("createQuery", String.class, boolean.class)
                        .invoke(om, cls, false);
                System.out.println("    [" + cls + "] query created: " + q.getClass().getSimpleName());

                // "No columns have been added to the query" 방지 — 조회할 필드를 먼저 지정한다.
                java.util.List<String> added = new java.util.ArrayList<>();
                for (String col : new String[] { "ModelName", "Vendor", "ModelCatalog", "PackageType" }) {
                    for (String adder : new String[] { "addColumn", "addField", "addSelect" }) {
                        try {
                            q.getClass().getMethod(adder, String.class).invoke(q, col);
                            added.add(col);
                            break;
                        } catch (NoSuchMethodException ignored) {
                            // 다음 후보
                        } catch (Exception e) {
                            break;
                        }
                    }
                }
                if (added.isEmpty()) {
                    System.out.println("        (no column adder worked) query methods:");
                    for (java.lang.reflect.Method m : q.getClass().getMethods()) {
                        if (m.getName().startsWith("add") || m.getName().startsWith("set")) {
                            StringBuilder ps = new StringBuilder();
                            for (Class<?> p : m.getParameterTypes()) {
                                if (ps.length() > 0) {
                                    ps.append(", ");
                                }
                                ps.append(p.getSimpleName());
                            }
                            System.out.println("            " + m.getName() + "(" + ps + ")");
                        }
                    }
                    return;
                }
                System.out.println("        columns added: " + added);

                Object result = null;
                for (String exec : new String[] { "execute", "getResult", "run" }) {
                    try {
                        result = q.getClass().getMethod(exec).invoke(q);
                        System.out.println("        " + exec + "() ok -> "
                                + (result == null ? "null" : result.getClass().getSimpleName()));
                        break;
                    } catch (NoSuchMethodException ignored) {
                        // 다음 후보
                    }
                }
                if (result == null) {
                    System.out.println("        query methods:");
                    for (java.lang.reflect.Method m : q.getClass().getMethods()) {
                        if (m.getParameterCount() == 0 && !m.getName().equals("wait")
                                && !m.getName().equals("toString")) {
                            System.out.println("            " + m.getName() + "() -> "
                                    + m.getReturnType().getSimpleName());
                        }
                    }
                    return;
                }
                printResults(result);
                return;
            } catch (Throwable t) {
                Throwable r = (t.getCause() != null) ? t.getCause() : t;
                System.out.println("    [" + cls + "] failed: " + r.getClass().getSimpleName()
                        + " - " + r.getMessage());
            }
        }
    }

    /** 조회 결과를 최대 20건까지 출력한다. */
    private static void printResults(Object result) throws Exception {
        java.util.Iterator<?> it = null;
        if (result instanceof java.util.Iterator) {
            it = (java.util.Iterator<?>) result;
        } else if (result instanceof Iterable) {
            it = ((Iterable<?>) result).iterator();
        } else {
            try {
                Object o = result.getClass().getMethod("iterator").invoke(result);
                it = (java.util.Iterator<?>) o;
            } catch (Exception ignored) {
                // OI 의 Cursor 는 Iterator 가 아니라 next()/hasNext() 스타일이다
                printCursor(result);
                return;
            }
        }
        int n = 0;
        while (it.hasNext() && n < 20) {
            Object o = it.next();
            n++;
            StringBuilder sb = new StringBuilder("        " + n + ". ");
            for (String f : new String[] { "ModelName", "Vendor", "ModelCatalog" }) {
                try {
                    Object v = o.getClass().getMethod("get", String.class).invoke(o, f);
                    sb.append(f).append('=').append(v).append("  ");
                } catch (Exception ignored) {
                    // 필드 접근 실패는 건너뛴다
                }
            }
            if (sb.length() <= 13) {
                sb.append(o);
            }
            System.out.println(sb);
        }
        System.out.println("        total listed: " + n);
    }

    /**
     * 쓰기 API 가 존재하는지, STEP 파일을 넣을 BLOB 필드가 있는지 조사한다.
     *
     * ★ 이 메서드는 아무것도 생성/수정/삭제하지 않는다. ★
     *   메서드 시그니처와 필드 메타데이터만 읽는다.
     */
    private static void probeWriteApi(OIObjectManagerFactory omf) {
        try {
            Object om = omf.createObjectManager();

            System.out.println("    (a) write-ish methods on OIObjectManager:");
            for (java.lang.reflect.Method m : om.getClass().getMethods()) {
                String n = m.getName();
                if (n.startsWith("create") || n.startsWith("makePermanent") || n.startsWith("delete")
                        || n.startsWith("lock") || n.startsWith("commit") || n.startsWith("refresh")) {
                    StringBuilder ps = new StringBuilder();
                    for (Class<?> p : m.getParameterTypes()) {
                        if (ps.length() > 0) {
                            ps.append(", ");
                        }
                        ps.append(p.getSimpleName());
                    }
                    System.out.println("        " + n + "(" + ps + ") -> " + m.getReturnType().getSimpleName());
                }
            }

            System.out.println();
            System.out.println("    (b) Model3D field types (looking for BLOB):");
            Object cm = omf.getClass().getMethod("getClassManager").invoke(omf);
            Object arr = cm.getClass().getMethod("getAllClasses").invoke(cm);
            for (Object c : (Object[]) arr) {
                String path = String.valueOf(c.getClass().getMethod("getPath").invoke(c));
                if (!path.equals("Model3D") && !path.equals("Model3D/3DModel/UserModel")) {
                    continue;
                }
                System.out.println("        --- " + path + " ---");
                Object fs = c.getClass().getMethod("getFields").invoke(c);
                for (Object f : (Collection<?>) fs) {
                    String fname = String.valueOf(f.getClass().getMethod("getName").invoke(f));
                    String iface = "";
                    for (Class<?> i : f.getClass().getInterfaces()) {
                        iface = i.getSimpleName();
                        break;
                    }
                    String extra = "";
                    for (String g : new String[] { "getType", "getDataType", "isReadOnly", "isRequired" }) {
                        try {
                            Object v = f.getClass().getMethod(g).invoke(f);
                            extra += " " + g.replace("get", "").replace("is", "") + "=" + v;
                        } catch (Exception ignored) {
                            // 해당 버전에 없는 접근자
                        }
                    }
                    boolean interesting = iface.toLowerCase().contains("blob")
                            || fname.toLowerCase().contains("preview")
                            || fname.toLowerCase().contains("document")
                            || fname.toLowerCase().contains("ref")
                            || fname.equals("ModelName") || fname.equals("Vendor");
                    if (interesting) {
                        System.out.println("            " + fname + "  [" + iface + "]" + extra);
                    }
                }
            }
            System.out.println();
            System.out.println("    (c) classes that DO have BLOB fields (where file bytes live):");
            for (Object c : (Object[]) arr) {
                String path = String.valueOf(c.getClass().getMethod("getPath").invoke(c));
                Object fs = c.getClass().getMethod("getFields").invoke(c);
                StringBuilder blobs = new StringBuilder();
                for (Object f : (Collection<?>) fs) {
                    String iface = "";
                    for (Class<?> i : f.getClass().getInterfaces()) {
                        iface = i.getSimpleName();
                        break;
                    }
                    if (iface.toLowerCase().contains("blob")) {
                        if (blobs.length() > 0) {
                            blobs.append(", ");
                        }
                        blobs.append(f.getClass().getMethod("getName").invoke(f));
                    }
                }
                if (blobs.length() > 0) {
                    System.out.println("        " + path + "  ->  " + blobs);
                }
            }

            System.out.println();
            System.out.println("    (d) 3DModelsDocuments / Document-ish class fields:");
            for (Object c : (Object[]) arr) {
                String path = String.valueOf(c.getClass().getMethod("getPath").invoke(c));
                if (!path.contains("Document")) {
                    continue;
                }
                System.out.println("        --- " + path + " ---");
                Object fs = c.getClass().getMethod("getFields").invoke(c);
                for (Object f : (Collection<?>) fs) {
                    String fname = String.valueOf(f.getClass().getMethod("getName").invoke(f));
                    String iface = "";
                    for (Class<?> i : f.getClass().getInterfaces()) {
                        iface = i.getSimpleName();
                        break;
                    }
                    if (fname.startsWith("obj_") || fname.endsWith("At") || fname.endsWith("By")) {
                        continue;
                    }
                    System.out.println("            " + fname + "  [" + iface + "]");
                }
            }
        } catch (Throwable t) {
            Throwable r = (t.getCause() != null) ? t.getCause() : t;
            System.out.println("    probe failed: " + r.getClass().getSimpleName() + " - " + r.getMessage());
        }
    }

    /** OI Cursor 를 순회해 결과를 출력한다. */
    private static void printCursor(Object cur) {
        System.out.println("        cursor methods:");
        for (java.lang.reflect.Method m : cur.getClass().getMethods()) {
            String n = m.getName();
            if ((n.startsWith("next") || n.startsWith("has") || n.startsWith("get")
                    || n.startsWith("size") || n.startsWith("count")) && m.getParameterCount() == 0) {
                System.out.println("            " + n + "() -> " + m.getReturnType().getSimpleName());
            }
        }
        int n = 0;
        try {
            // OI Cursor: next() 가 boolean 을 반환하며 커서를 전진시킨다.
            java.lang.reflect.Method next = cur.getClass().getMethod("next");
            java.lang.reflect.Method getId = cur.getClass().getMethod("getObjectID");
            java.lang.reflect.Method getObj = cur.getClass().getMethod("getObject");
            System.out.println("        rows:");
            java.lang.reflect.Method getProxy = null;
            try {
                getProxy = cur.getClass().getMethod("getProxyObject");
            } catch (NoSuchMethodException ignored) {
                // 없으면 getObject 만 사용
            }
            while (n < 30 && Boolean.TRUE.equals(next.invoke(cur))) {
                n++;
                String id;
                try {
                    id = String.valueOf(getId.invoke(cur));
                } catch (Exception e) {
                    id = "(id?)";
                }
                String detail = "";
                // ProxyObject 가 조회 컬럼 값을 들고 있다
                if (getProxy != null) {
                    try {
                        detail = row(getProxy.invoke(cur));
                    } catch (Exception ignored) {
                        detail = "";
                    }
                }
                if (detail.isEmpty()) {
                    try {
                        detail = row(getObj.invoke(cur));
                    } catch (Exception ignored) {
                        detail = "";
                    }
                }
                System.out.println("        " + n + ". id=" + id + "   " + detail);
            }
            System.out.println("        total listed: " + n + (n == 20 ? " (truncated)" : ""));
        } catch (Throwable t) {
            Throwable r = (t.getCause() != null) ? t.getCause() : t;
            System.out.println("        cursor walk failed after " + n + " rows: "
                    + r.getClass().getSimpleName() + " - " + r.getMessage());
        }
    }

    /** 객체 한 건에서 관심 필드를 뽑는다. */
    private static String row(Object o) {
        if (o == null) {
            return "(null)";
        }
        StringBuilder sb = new StringBuilder();
        for (String f : new String[] { "ModelName", "Vendor", "ModelCatalog", "PackageType" }) {
            try {
                Object v = o.getClass().getMethod("get", String.class).invoke(o, f);
                if (v != null && !String.valueOf(v).isEmpty()) {
                    sb.append(f).append('=').append(v).append("  ");
                }
            } catch (Exception ignored) {
                // 필드 없음
            }
        }
        if (sb.length() == 0) {
            try {
                sb.append(o.getClass().getMethod("getID").invoke(o));
            } catch (Exception ignored) {
                sb.append(o);
            }
        }
        return sb.toString();
    }

    /** OIClass 에서 번호와 이름을 뽑는다. 메서드 이름이 버전마다 달라 리플렉션으로 시도한다. */
    private static String describe(Object c) {
        if (c == null) {
            return "(null)";
        }
        StringBuilder sb = new StringBuilder();
        for (String g : new String[] { "getNumber", "getClassNumber", "getId" }) {
            try {
                Object v = c.getClass().getMethod(g).invoke(c);
                if (v != null) {
                    sb.append('[').append(v).append("] ");
                    break;
                }
            } catch (Exception ignored) {
                // 다음 후보 시도
            }
        }
        for (String g : new String[] { "getName", "getLabel", "getDomainName" }) {
            try {
                Object v = c.getClass().getMethod(g).invoke(c);
                if (v != null) {
                    sb.append(v);
                    return sb.toString();
                }
            } catch (Exception ignored) {
                // 다음 후보 시도
            }
        }
        sb.append(c);
        return sb.toString();
    }
}
