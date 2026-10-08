#Requires -Version 5.1
<#
.SYNOPSIS
    Java Access Bridge (JAB) P/Invoke 래퍼 모듈.

.DESCRIPTION
    windowsaccessbridge-64.dll 을 직접 호출해 Java Swing 앱의
    접근성 트리를 탐색한다.

    dot-source 로 로드한다:
        . .\tools\Jab-Bridge.ps1

    그러면 아래 함수가 세션에 노출된다:
        Initialize-Jab            - DLL 초기화 (한 번만)
        Get-JabContextFromHwnd    - HWND → AccessibleContext
        Get-JabContextInfo        - 컨텍스트 → AccessibleContextInfo
        Get-JabChildren           - 자식 컨텍스트 목록
        Get-JabActions            - 컴포넌트가 지원하는 액션 목록
        Invoke-JabAction          - 액션 실행
        Release-JabObject         - 컨텍스트 핸들 해제
        Get-JabContextWithFocus   - 현재 포커스된 컴포넌트
        Find-JabElement           - 이름/역할 조건으로 트리 탐색

.NOTES
    JAB 가 활성화된 JRE 가 있어야 한다 (jabswitch -enable 후 재기동).
    DLL 경로: SDD_HOME\common\win64\jre\default\bin\windowsaccessbridge-64.dll
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# 설치 경로 탐색은 Common.SddHome.ps1 이 담당한다 (버전이 올라가도 코드 수정 불필요)
. (Join-Path $PSScriptRoot 'Common.SddHome.ps1')

# ============================================================ C# 타입 정의
if (-not ('Jab.Bridge' -as [type])) {
    # DllImport 의 경로는 컴파일 시점 상수라 변수를 쓸 수 없다.
    # 그래서 탐색한 실제 경로를 소스에 치환해 넣는다.
    $script:JabDllPath = Get-JabDllPath
    Write-Verbose "JAB DLL: $script:JabDllPath"

    $jabSource = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

namespace Jab
{
    // 실측 레이아웃 (windowsaccessbridge-64.dll JRE 17.0.8.1 기준)
    // 공식 헤더와 달리 name 이 첫 번째, role 이 세 번째다.
    // raw dump 로 확인:
    //   off 0x0000 name(2048)        off 0x0800 description(2048)
    //   off 0x1000 role(512)         off 0x1200 role_en_US(512)
    //   off 0x1400 states(512)       off 0x1600 states_en_US(512)
    //   off 0x1800 indexInParent(int) childrenCount x y w h + BOOL×5
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct AccessibleContextInfo
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 1024)]
        public string name;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 1024)]
        public string description;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string role;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string role_en_US;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string states;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string states_en_US;
        public int    indexInParent;
        public int    childrenCount;
        public int    x;
        public int    y;
        public int    width;
        public int    height;
        [MarshalAs(UnmanagedType.Bool)] public bool accessibleComponent;
        [MarshalAs(UnmanagedType.Bool)] public bool accessibleAction;
        [MarshalAs(UnmanagedType.Bool)] public bool accessibleSelection;
        [MarshalAs(UnmanagedType.Bool)] public bool accessibleText;
        [MarshalAs(UnmanagedType.Bool)] public bool accessibleInterfaces;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct AccessibleActionInfo
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string name;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct AccessibleActions
    {
        public int actionsCount;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 256)]
        public AccessibleActionInfo[] actionInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct AccessibleActionsToDo
    {
        public int actionsCount;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 32)]
        public AccessibleActionInfo[] actions;
    }

    public static class Bridge
    {
        private const string DLL = @"__JAB_DLL_PATH__";

        // 초기화: 메시지 루프를 돌려야 JAB 가 응답한다
        [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
        public static extern void Windows_run();

        [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool isJavaWindow(IntPtr hwnd);

        // HWND → (vmID, AccessibleContext)
        [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool getAccessibleContextFromHWND(
            IntPtr hwnd, out int vmID, out long ac);

        // 현재 포커스
        [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool getAccessibleContextWithFocus(
            IntPtr hwnd, out int vmID, out long ac);

        // 컨텍스트 정보
        [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool getAccessibleContextInfo(
            int vmID, long ac, out AccessibleContextInfo info);

        // 자식 N번째
        [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
        public static extern long getAccessibleChildFromContext(
            int vmID, long ac, int index);

        // 부모
        [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
        public static extern long getAccessibleParentFromContext(
            int vmID, long ac);

        // 액션 목록.
        // AccessibleActions 는 4 + 256*512 = 131076 바이트라 CLR 구조체 마샬링
        // 한도를 넘는다([ref] 로 넘기면 "structure is too complex or too large").
        // raw IntPtr 로 받아서 직접 파싱한다. 실측 레이아웃:
        //   off 0    actionsCount(int)
        //   off 4+   name[i] : wchar_t[256] = 512 바이트 간격
        [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool getAccessibleActions(
            int vmID, long ac, IntPtr actions);

        // 액션 실행 (구조체 마샬링 문제 우회용 raw IntPtr 버전)
        [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool doAccessibleActions(
            int vmID, long ac, IntPtr actionsToDo, out int failure);

        // 좌표로 컨텍스트 찾기
        [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
        public static extern long getAccessibleContextAt(
            int vmID, long acParent, int x, int y);

        // 핸들 해제
        [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
        public static extern void releaseJavaObject(int vmID, long ac);

        // 같은 객체 비교
        [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool isSameObject(int vmID, long ac1, long ac2);

        // 텍스트 내용 설정
        [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool setTextContents(
            int vmID, long ac,
            [MarshalAs(UnmanagedType.LPWStr)] string text);

        // 포커스 요청
        [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool requestFocus(int vmID, long ac);

        // 버전 정보
        [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool getVersionInfo(int vmID, out AccessBridgeVersionInfo info);
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct AccessBridgeVersionInfo
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string VMversion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string bridgeJavaClassVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string bridgeJavaDLLVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string bridgeWinDLLVersion;
    }

    // 메시지 펌프 - JAB 는 WM_COPYDATA 기반이므로 초기화 후 메시지를 처리해야 함
    public static class Win32
    {
        [StructLayout(LayoutKind.Sequential)]
        public struct MSG
        {
            public IntPtr hwnd;
            public uint   message;
            public IntPtr wParam;
            public IntPtr lParam;
            public uint   time;
            public int    ptX, ptY;
        }

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool PeekMessage(out MSG msg, IntPtr hwnd,
            uint wMsgFilterMin, uint wMsgFilterMax, uint wRemoveMsg);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool TranslateMessage(ref MSG msg);

        [DllImport("user32.dll")]
        public static extern IntPtr DispatchMessage(ref MSG msg);

        // --- 실제 마우스 클릭 ---
        // JAB 의 doAccessibleActions 는 이 JRE 에서 성공을 반환하고도 동작하지
        // 않는다. 클릭은 반드시 실제 입력 이벤트로 보내야 한다.
        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool SetForegroundWindow(IntPtr hwnd);

        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool BringWindowToTop(IntPtr hwnd);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool ShowWindow(IntPtr hwnd, int nCmdShow);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool MoveWindow(IntPtr hwnd, int x, int y, int w, int h,
            [MarshalAs(UnmanagedType.Bool)] bool repaint);

        [DllImport("user32.dll")]
        public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo,
            [MarshalAs(UnmanagedType.Bool)] bool fAttach);

        [DllImport("kernel32.dll")]
        public static extern uint GetCurrentThreadId();

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool IsWindowVisible(IntPtr hwnd);

        [StructLayout(LayoutKind.Sequential)]
        public struct RECT { public int Left, Top, Right, Bottom; }

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GetWindowRect(IntPtr hwnd, out RECT r);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetWindowText(IntPtr hwnd, System.Text.StringBuilder s, int n);

        public static string GetWindowTitle(IntPtr hwnd)
        {
            var sb = new System.Text.StringBuilder(512);
            GetWindowText(hwnd, sb, sb.Capacity);
            return sb.ToString();
        }

        private delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);

        // 지정 프로세스의 보이는 최상위 창 목록.
        // 대화상자가 별도 창으로 뜨는지 확인할 때 쓴다.
        // 비대화형 세션에서는 IsWindowVisible 이 항상 false 를 반환하므로
        // 목록이 비면 WS_VISIBLE 스타일 플래그로 한 번 더 시도한다.
        public static IntPtr[] GetVisibleWindows(uint targetPid)
        {
            var list = new System.Collections.Generic.List<IntPtr>();
            EnumWindows((h, l) => {
                uint pid;
                GetWindowThreadProcessId(h, out pid);
                if (pid == targetPid && IsWindowVisible(h)) list.Add(h);
                return true;
            }, IntPtr.Zero);
            if (list.Count == 0)
            {
                EnumWindows((h, l) => {
                    uint pid;
                    GetWindowThreadProcessId(h, out pid);
                    if (pid == targetPid) {
                        int style = GetWindowLong(h, -16);
                        if ((style & 0x10000000) != 0) list.Add(h);
                    }
                    return true;
                }, IntPtr.Zero);
            }
            return list.ToArray();
        }

        // 비대화형 세션에서 IsWindowVisible 과 무관하게 전체 창을 열거한다.
        public static IntPtr[] GetAllWindows(uint targetPid)
        {
            var list = new System.Collections.Generic.List<IntPtr>();
            EnumWindows((h, l) => {
                uint pid;
                GetWindowThreadProcessId(h, out pid);
                if (pid == targetPid) list.Add(h);
                return true;
            }, IntPtr.Zero);
            return list.ToArray();
        }

        [DllImport("user32.dll", EntryPoint = "GetWindowLongW")]
        private static extern int GetWindowLong(IntPtr hwnd, int nIndex);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool IsWindow(IntPtr hwnd);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool PostMessage(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool ScreenToClient(IntPtr hwnd, ref POINT pt);

        [DllImport("user32.dll")]
        private static extern IntPtr ChildWindowFromPointEx(IntPtr hwnd, POINT pt, uint flags);

        [DllImport("wtsapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool WTSQuerySessionInformation(IntPtr hServer, int sessionId, int infoClass, out IntPtr buffer, out int bytes);

        [DllImport("wtsapi32.dll")]
        private static extern void WTSFreeMemory(IntPtr buffer);

        // WTSConnectState: 0=Active, 4=Disconnected. 조회 실패 시 Active 로 간주한다.
        public static bool IsSessionActive()
        {
            IntPtr buf; int bytes;
            if (!WTSQuerySessionInformation(IntPtr.Zero, -1, 8, out buf, out bytes)) return true;
            try { return Marshal.ReadInt32(buf) == 0; }
            finally { WTSFreeMemory(buf); }
        }

        // RDP 가 끊긴 세션에서는 SendInput 이 입력 데스크톱에 닿지 않는다.
        // Java AWT 는 마우스 진입(WM_MOUSEMOVE) 없이 온 down/up 을 무시할 수 있어 move 를 먼저 보낸다.
        public static void PostClick(IntPtr hwnd, int screenX, int screenY)
        {
            const uint WM_MOUSEMOVE   = 0x0200;
            const uint WM_LBUTTONDOWN = 0x0201;
            const uint WM_LBUTTONUP   = 0x0202;
            IntPtr target = hwnd;
            var pt = new POINT { x = screenX, y = screenY };
            ScreenToClient(hwnd, ref pt);
            IntPtr child = ChildWindowFromPointEx(hwnd, pt, 0);
            if (child != IntPtr.Zero && child != hwnd)
            {
                target = child;
                pt = new POINT { x = screenX, y = screenY };
                ScreenToClient(child, ref pt);
            }
            IntPtr lp = (IntPtr)((pt.y << 16) | (pt.x & 0xFFFF));
            PostMessage(target, WM_MOUSEMOVE,   IntPtr.Zero,     lp);
            System.Threading.Thread.Sleep(60);
            PostMessage(target, WM_MOUSEMOVE,   IntPtr.Zero,     lp);
            System.Threading.Thread.Sleep(60);
            PostMessage(target, WM_LBUTTONDOWN, (IntPtr)0x0001, lp);
            System.Threading.Thread.Sleep(80);
            PostMessage(target, WM_LBUTTONUP,   IntPtr.Zero,     lp);
        }

        public static void SmartClick(IntPtr hwnd, int screenX, int screenY)
        {
            if (IsSessionActive()) ClickAt(screenX, screenY);
            else PostClick(hwnd, screenX, screenY);
        }

        // 다른 프로세스 창은 SetForegroundWindow 만으로는 전면 전환이 거부된다.
        // 현재 포그라운드 스레드에 입력을 붙여야 확실히 올라온다.
        // 전면 확보에 실패하면 SendKeys 가 엉뚱한 창으로 가므로 반드시 확인할 것.
        public static bool ForceForeground(IntPtr hwnd)
        {
            for (int i = 0; i < 5; i++)
            {
                uint pid;
                uint fgTid = GetWindowThreadProcessId(GetForegroundWindow(), out pid);
                uint myTid = GetCurrentThreadId();
                AttachThreadInput(myTid, fgTid, true);
                ShowWindow(hwnd, 9); // SW_RESTORE
                BringWindowToTop(hwnd);
                SetForegroundWindow(hwnd);
                AttachThreadInput(myTid, fgTid, false);
                System.Threading.Thread.Sleep(300);
                if (GetForegroundWindow() == hwnd) return true;
            }
            return GetForegroundWindow() == hwnd;
        }

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool SetCursorPos(int x, int y);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool SetProcessDPIAware();

        [DllImport("user32.dll")]
        public static extern int GetSystemMetrics(int index);

        [StructLayout(LayoutKind.Sequential)]
        public struct MOUSEINPUT
        {
            public int dx, dy;
            public uint mouseData, dwFlags, time;
            public IntPtr dwExtraInfo;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct INPUT
        {
            public uint type;
            public MOUSEINPUT mi;
        }

        [DllImport("user32.dll", SetLastError = true)]
        private static extern uint SendInput(uint nInputs, INPUT[] inputs, int size);

        private const uint MOUSEEVENTF_MOVE        = 0x0001;
        private const uint MOUSEEVENTF_LEFTDOWN    = 0x0002;
        private const uint MOUSEEVENTF_LEFTUP      = 0x0004;
        private const uint MOUSEEVENTF_ABSOLUTE    = 0x8000;
        private const uint MOUSEEVENTF_VIRTUALDESK = 0x4000;

        private static void Send(uint flags, int dx, int dy)
        {
            var inp = new INPUT[1];
            inp[0].type = 0; // INPUT_MOUSE
            inp[0].mi.dx = dx;
            inp[0].mi.dy = dy;
            inp[0].mi.dwFlags = flags;
            SendInput(1, inp, System.Runtime.InteropServices.Marshal.SizeOf(typeof(INPUT)));
        }

        // 멀티모니터에서 SetCursorPos 는 프로세스가 DPI-aware 가 아니면 좌표가
        // 엉뚱한 모니터로 재매핑된다(관측: (131,41) 요청 -> 실제 (-1565,-1232)).
        // 가상 데스크톱 전체를 0..65535 로 정규화한 절대 좌표로 SendInput 한다.
        public static void MoveAbs(int x, int y)
        {
            int vx = GetSystemMetrics(76);  // SM_XVIRTUALSCREEN
            int vy = GetSystemMetrics(77);  // SM_YVIRTUALSCREEN
            int vw = GetSystemMetrics(78);  // SM_CXVIRTUALSCREEN
            int vh = GetSystemMetrics(79);  // SM_CYVIRTUALSCREEN
            int ax = (int)Math.Round((double)(x - vx) * 65535.0 / (vw - 1));
            int ay = (int)Math.Round((double)(y - vy) * 65535.0 / (vh - 1));
            Send(MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK, ax, ay);
        }

        // 커서 이동은 SetCursorPos 로 한다.
        // SendInput 의 ABSOLUTE|VIRTUALDESK 정규화는 이 다중 모니터 구성에서
        // 좌표가 엉뚱한 화면으로 날아간다(요청 1304,1005 -> 실제 1280,4).
        // SetProcessDPIAware 를 부른 뒤의 SetCursorPos 는 정확히 일치한다.
        public static void ClickAt(int x, int y)
        {
            SetCursorPos(x, y);
            System.Threading.Thread.Sleep(150);
            // 이동이 실제로 반영됐는지 확인하고, 아니면 한 번 더 시도한다.
            POINT p;
            if (GetCursorPos(out p) && (Math.Abs(p.x - x) > 2 || Math.Abs(p.y - y) > 2))
            {
                SetCursorPos(x, y);
                System.Threading.Thread.Sleep(120);
            }
            Send(MOUSEEVENTF_LEFTDOWN, 0, 0);
            System.Threading.Thread.Sleep(70);
            Send(MOUSEEVENTF_LEFTUP, 0, 0);
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct POINT { public int x, y; }

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GetCursorPos(out POINT p);

        public static void PumpMessages(int iterations = 20)
        {
            MSG msg;
            for (int i = 0; i < iterations; i++)
            {
                if (PeekMessage(out msg, IntPtr.Zero, 0, 0, 1 /* PM_REMOVE */))
                {
                    TranslateMessage(ref msg);
                    DispatchMessage(ref msg);
                }
            }
        }

        // JAB 함수는 WM_COPYDATA IPC 응답이 필요하므로 메인 스레드의 메시지 루프가
        // 살아 있어야 한다. 워커 스레드에서 fn() 을 실행하고 메인 스레드는 메시지를
        // 처리하면서 완료를 기다린다.
        private static void _Pump(int ms)
        {
            MSG msg;
            var sw = System.Diagnostics.Stopwatch.StartNew();
            while (sw.ElapsedMilliseconds < ms)
            {
                if (PeekMessage(out msg, IntPtr.Zero, 0, 0, 1))
                {
                    TranslateMessage(ref msg);
                    DispatchMessage(ref msg);
                }
                else { System.Threading.Thread.Sleep(1); }
            }
        }

        // 메인 스레드 메시지 루프를 돌리면서 완료 플래그를 기다린다.
        // C# 람다에서 ref bool 캡처 불가 → bool[] 배열 사용
        private static bool _WaitDone(bool[] done, int timeoutMs)
        {
            MSG msg;
            var sw = System.Diagnostics.Stopwatch.StartNew();
            while (!System.Threading.Volatile.Read(ref done[0]) && sw.ElapsedMilliseconds < timeoutMs)
            {
                if (PeekMessage(out msg, IntPtr.Zero, 0, 0, 1))
                {
                    TranslateMessage(ref msg);
                    DispatchMessage(ref msg);
                }
                else { System.Threading.Thread.Sleep(1); }
            }
            return System.Threading.Volatile.Read(ref done[0]);
        }

        // 워커 스레드에서 JAB getAccessibleContextInfo 를 호출한다.
        public static bool GetContextInfoW(int vmId, long ac, out AccessibleContextInfo info, int timeoutMs = 5000)
        {
            var _info = new AccessibleContextInfo[1];
            var _ok = new bool[1];
            var _done = new bool[1];
            var t = new System.Threading.Thread(() => {
                AccessibleContextInfo tmp;
                _ok[0] = Bridge.getAccessibleContextInfo(vmId, ac, out tmp);
                _info[0] = tmp;
                System.Threading.Volatile.Write(ref _done[0], true);
            });
            t.IsBackground = true; t.Start();
            _WaitDone(_done, timeoutMs);
            info = _info[0];
            return _ok[0];
        }

        public static long GetChildW(int vmId, long ac, int index, int timeoutMs = 3000)
        {
            var _result = new long[1];
            var _done = new bool[1];
            var t = new System.Threading.Thread(() => {
                _result[0] = Bridge.getAccessibleChildFromContext(vmId, ac, index);
                System.Threading.Volatile.Write(ref _done[0], true);
            });
            t.IsBackground = true; t.Start();
            _WaitDone(_done, timeoutMs);
            return _result[0];
        }

        public const int ACTION_NAME_STRIDE = 512;   // wchar_t[256]
        public const int ACTION_MAX         = 256;

        public static string[] GetActionsW(int vmId, long ac, int timeoutMs = 3000)
        {
            var _result = new string[1][];
            _result[0] = new string[0];
            var _done = new bool[1];
            var t = new System.Threading.Thread(() => {
                int bufSz = 4 + ACTION_MAX * ACTION_NAME_STRIDE;
                IntPtr buf = System.Runtime.InteropServices.Marshal.AllocHGlobal(bufSz);
                try {
                    for (int i = 0; i < bufSz; i++)
                        System.Runtime.InteropServices.Marshal.WriteByte(buf, i, 0);
                    if (Bridge.getAccessibleActions(vmId, ac, buf)) {
                        int count = System.Runtime.InteropServices.Marshal.ReadInt32(buf, 0);
                        if (count < 0) count = 0;
                        if (count > ACTION_MAX) count = ACTION_MAX;
                        var names = new string[count];
                        for (int i = 0; i < count; i++)
                            names[i] = System.Runtime.InteropServices.Marshal.PtrToStringUni(
                                IntPtr.Add(buf, 4 + i * ACTION_NAME_STRIDE)) ?? "";
                        _result[0] = names;
                    }
                } catch { }
                finally {
                    System.Runtime.InteropServices.Marshal.FreeHGlobal(buf);
                    System.Threading.Volatile.Write(ref _done[0], true);
                }
            });
            t.IsBackground = true; t.Start();
            _WaitDone(_done, timeoutMs);
            return _result[0];
        }

        public static void DoActionsW(int vmId, long ac, IntPtr buf, int timeoutMs = 3000)
        {
            var _failure = new int[1];
            var _ok = new bool[1];
            var _done = new bool[1];
            var _ex = new Exception[1];
            var t = new System.Threading.Thread(() => {
                try {
                    _ok[0] = Bridge.doAccessibleActions(vmId, ac, buf, out _failure[0]);
                } catch (Exception ex) { _ex[0] = ex; }
                System.Threading.Volatile.Write(ref _done[0], true);
            });
            t.IsBackground = true; t.Start();
            _WaitDone(_done, timeoutMs);
            if (_ex[0] != null) throw _ex[0];
            // failure=-1 은 모두 성공
            if (!_ok[0] || _failure[0] >= 0)
                throw new InvalidOperationException(
                    string.Format("doAccessibleActions failed ok={0} failure={1}", _ok[0], _failure[0]));
        }

        // C# 레벨에서 DFS 탐색 - 각 노드를 워커 스레드 없이 순차 호출
        // (Bridge 함수들을 워커에서 한 번에 묶어서 호출)
        public class JabElement
        {
            public long Ac;
            public string Name;
            public string Role;
            public string States;
            public int Children;
            public int Depth;
        }

        private static JabElement _FindDFS(int vmId, long ac, string name, string role, int depth, int maxDepth)
        {
            if (depth > maxDepth) return null;
            AccessibleContextInfo info;
            if (!Bridge.getAccessibleContextInfo(vmId, ac, out info)) return null;

            bool nameMatch = string.IsNullOrEmpty(name) || (info.name != null && info.name.IndexOf(name, StringComparison.OrdinalIgnoreCase) >= 0);
            bool roleMatch = string.IsNullOrEmpty(role) || (info.role_en_US != null && info.role_en_US.IndexOf(role, StringComparison.OrdinalIgnoreCase) >= 0);

            if (nameMatch && roleMatch)
                return new JabElement { Ac=ac, Name=info.name, Role=info.role_en_US, States=info.states_en_US, Children=info.childrenCount, Depth=depth };

            for (int i = 0; i < info.childrenCount; i++)
            {
                long child = Bridge.getAccessibleChildFromContext(vmId, ac, i);
                if (child == 0) continue;
                var found = _FindDFS(vmId, child, name, role, depth+1, maxDepth);
                // 찾은 노드(또는 그 조상)의 핸들은 호출자가 쓰므로 해제하면 안 된다.
                // 해제하면 Ac 가 dangling 이 되어 이후 getAccessibleContextInfo /
                // doAccessibleActions 가 조용히 실패한다.
                if (found != null) return found;
                Bridge.releaseJavaObject(vmId, child);
            }
            return null;
        }

        public static JabElement FindElementW(int vmId, long rootAc, string name, string role, int maxDepth, int timeoutMs = 30000)
        {
            var _result = new JabElement[1];
            var _done = new bool[1];
            var _ex = new Exception[1];
            var t = new System.Threading.Thread(() => {
                try { _result[0] = _FindDFS(vmId, rootAc, name, role, 0, maxDepth); }
                catch (Exception ex) { _ex[0] = ex; }
                System.Threading.Volatile.Write(ref _done[0], true);
            });
            t.IsBackground = true; t.Start();
            _WaitDone(_done, timeoutMs);
            if (_ex[0] != null) throw _ex[0];
            return _result[0];
        }

        // 깊이 우선 덤프 (C# 레벨) - 트리를 JSON-like 구조로 반환
        public static JabElement[] DumpTreeW(int vmId, long rootAc, int maxDepth, int timeoutMs = 60000)
        {
            var results = new System.Collections.Generic.List<JabElement>();
            var _ex = new Exception[1];
            var _done_arr = new bool[1];
            var t = new System.Threading.Thread(() => {
                try {
                    var stack = new System.Collections.Generic.Stack<System.Tuple<long,int>>();
                    stack.Push(System.Tuple.Create(rootAc, 0));
                    while (stack.Count > 0) {
                        var item = stack.Pop();
                        long ac = item.Item1; int depth = item.Item2;
                        AccessibleContextInfo info;
                        if (!Bridge.getAccessibleContextInfo(vmId, ac, out info)) continue;
                        results.Add(new JabElement { Ac=ac, Name=info.name, Role=info.role_en_US, States=info.states_en_US, Children=info.childrenCount, Depth=depth });
                        if (depth < maxDepth) {
                            for (int i = info.childrenCount-1; i >= 0; i--) {
                                long child = Bridge.getAccessibleChildFromContext(vmId, ac, i);
                                if (child != 0) stack.Push(System.Tuple.Create(child, depth+1));
                            }
                        }
                    }
                } catch (Exception ex) { _ex[0] = ex; }
                System.Threading.Volatile.Write(ref _done_arr[0], true);
            });
            t.IsBackground = true; t.Start();
            _WaitDone(_done_arr, timeoutMs);
            if (_ex[0] != null) throw _ex[0];
            return results.ToArray();
        }
    }
}
'@

    # C# verbatim 문자열(@"...") 안이라 백슬래시를 이스케이프하면 안 된다.
    # -replace 의 치환문자열에서 '$' 만 의미를 가지므로 그것만 막는다.
    Add-Type -TypeDefinition ($jabSource -replace '__JAB_DLL_PATH__',
                              $script:JabDllPath.Replace('$', '$$')) -ErrorAction Stop
}

# ============================================================ 전역 상태
$script:JabVmId = 0
$script:JabRootAc = 0L
$script:JabInitialized = $false

# ============================================================ 공개 함수

function Initialize-Jab {
    <#
    .SYNOPSIS
        JAB DLL 을 초기화하고 Cockpit 창에 연결한다.
    .PARAMETER Hwnd
        Cockpit MainWindowHandle. 생략하면 xDMLibraryClient 에서 자동 탐지.
    .OUTPUTS
        PSCustomObject { VmId, RootAc, VersionInfo }
    #>
    param([IntPtr]$Hwnd = [IntPtr]::Zero)

    # 멀티모니터 환경에서 DPI-aware 가 아니면 마우스 좌표가 다른 모니터로
    # 재매핑되어 클릭이 엉뚱한 곳에 떨어진다. 좌표를 쓰기 전에 반드시 호출.
    $null = [Jab.Win32]::SetProcessDPIAware()

    [Jab.Bridge]::Windows_run()
    Start-Sleep -Milliseconds 1000
    [Jab.Win32]::PumpMessages(100)
    Start-Sleep -Milliseconds 500

    if ($Hwnd -eq [IntPtr]::Zero) {
        $proc = @(Get-Process -Name 'xDMLibraryClient' -ErrorAction SilentlyContinue |
                  Where-Object { $_.MainWindowHandle -ne 0 })
        if ($proc.Count -eq 0) { throw "Cockpit 프로세스를 찾을 수 없습니다." }
        $Hwnd = [IntPtr]$proc[0].MainWindowHandle
        Write-Verbose "자동 감지된 HWND: 0x$($Hwnd.ToString('X'))  PID $($proc[0].Id)"
    }

    if (-not [Jab.Bridge]::isJavaWindow($Hwnd)) {
        # 가장 흔한 원인은 이 계정에 JAB 이 활성화되지 않은 것이다.
        # 그냥 "Java 창이 아니다" 라고만 하면 원인을 찾기 어려우므로 먼저 확인한다.
        Assert-JabEnabled | Out-Null

        # JAB 은 켜져 있는데도 실패한 경우 (대화상자가 떠서 핸들이 바뀌었거나,
        # Cockpit 이 아직 창을 다 만들지 않았거나)
        throw ("HWND 0x$($Hwnd.ToString('X')) 는 Java 창이 아닙니다.`n" +
               "  JAB 은 이 계정에 활성화돼 있습니다. 다른 원인을 확인하세요:`n" +
               "   - Cockpit 이 아직 창을 만드는 중인가 (기동 직후)`n" +
               "   - 대화상자가 떠서 메인 창 핸들이 바뀌었는가`n" +
               "   - 32/64비트 불일치 (windowsaccessbridge-64.dll 과 JRE)")
    }

    $vmId = 0
    $ac   = 0L
    if (-not [Jab.Bridge]::getAccessibleContextFromHWND($Hwnd, [ref]$vmId, [ref]$ac)) {
        throw "getAccessibleContextFromHWND 실패."
    }

    $verInfo = New-Object Jab.AccessBridgeVersionInfo
    $null = [Jab.Bridge]::getVersionInfo($vmId, [ref]$verInfo)

    $script:JabVmId  = $vmId
    $script:JabRootAc = $ac
    $script:JabInitialized = $true

    [PSCustomObject]@{
        VmId        = $vmId
        RootAc      = $ac
        Hwnd        = $Hwnd
        VersionInfo = $verInfo
    }
}

function _AssertInit {
    if (-not $script:JabInitialized) { throw "먼저 Initialize-Jab 를 호출하세요." }
}

function Get-JabContextInfo {
    <#
    .SYNOPSIS
        AccessibleContext 의 정보를 반환한다.
    #>
    param(
        [Parameter(Mandatory)][long]$Ac,
        [int]$VmId = $script:JabVmId
    )
    _AssertInit
    $info = New-Object Jab.AccessibleContextInfo
    if (-not [Jab.Win32]::GetContextInfoW($VmId, $Ac, [ref]$info)) {
        return $null
    }
    $info
}

function Get-JabChildren {
    <#
    .SYNOPSIS
        AccessibleContext 의 자식 목록을 반환한다.
    .OUTPUTS
        long[] (AccessibleContext 핸들)
    #>
    param(
        [Parameter(Mandatory)][long]$Ac,
        [int]$VmId = $script:JabVmId
    )
    _AssertInit
    $info = Get-JabContextInfo -Ac $Ac -VmId $VmId
    if ($null -eq $info -or $info.childrenCount -le 0) { return , @() }

    $children = [System.Collections.Generic.List[long]]::new()
    for ($i = 0; $i -lt $info.childrenCount; $i++) {
        $child = [Jab.Win32]::GetChildW($VmId, $Ac, $i)
        if ($child -ne 0) { $children.Add($child) }
    }
    , $children.ToArray()
}

function Get-JabActions {
    <#
    .SYNOPSIS
        컴포넌트가 지원하는 액션 이름 목록을 반환한다.
    #>
    param(
        [Parameter(Mandatory)][long]$Ac,
        [int]$VmId = $script:JabVmId
    )
    _AssertInit
    $names = [Jab.Win32]::GetActionsW($VmId, $Ac, 3000)
    , $names
}

function Invoke-JabAction {
    <#
    .SYNOPSIS
        컴포넌트의 액션을 실행한다.
    .PARAMETER Ac
        대상 AccessibleContext
    .PARAMETER ActionName
        실행할 액션 이름. 생략하면 첫 번째 액션을 실행.
    #>
    param(
        [Parameter(Mandatory)][long]$Ac,
        [string]$ActionName = '',
        [int]$VmId = $script:JabVmId
    )
    _AssertInit

    # 액션 이름은 JVM 로캘을 따른다. 한국어 JRE 에서는 'click'/'press' 가 아니라
    # '누르기' 같은 현지화된 이름이라 하드코딩하면 안 되고, 반드시 열거해서 써야 한다.
    if ($ActionName -eq '') {
        # @() 로 감싸지 않으면 원소가 1개일 때 PowerShell 이 문자열로 풀어버리고,
        # StrictMode 에서 .Count 접근이 예외가 된다.
        $avail = @([Jab.Win32]::GetActionsW($VmId, $Ac, 3000))
        if ($avail.Count -eq 0) { throw "이 컴포넌트에 액션이 없습니다." }
        $ActionName = $avail[0]
    }

    # AccessibleActionsToDo: int actionsCount + AccessibleActionInfo[32]
    # AccessibleActionInfo:  wchar_t name[256] = 512 bytes
    $bufSz = 4 + 32 * 512
    $buf   = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($bufSz)
    try {
        for ($i = 0; $i -lt $bufSz; $i++) {
            [System.Runtime.InteropServices.Marshal]::WriteByte($buf, $i, 0)
        }
        [System.Runtime.InteropServices.Marshal]::WriteInt32($buf, 0, 1)
        $nameBytes = [System.Text.Encoding]::Unicode.GetBytes($ActionName)
        for ($i = 0; $i -lt $nameBytes.Length; $i++) {
            [System.Runtime.InteropServices.Marshal]::WriteByte($buf, 4 + $i, $nameBytes[$i])
        }
        [Jab.Win32]::DoActionsW($VmId, $Ac, $buf)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($buf)
    }
    [Jab.Win32]::PumpMessages(10)
    $true
}

function Click-JabElement {
    <#
    .SYNOPSIS
        JAB 로 좌표를 얻고 실제 Win32 마우스 이벤트로 클릭한다.

    .DESCRIPTION
        doAccessibleActions 는 이 JRE 에서 ok=True/failure=-1 을 반환하면서도
        실제로는 아무 일도 일어나지 않는다. 그래서 클릭은 반드시 실제 마우스
        이벤트로 해야 한다. JAB 좌표(x,y,width,height)는 화면 절대 좌표로 정확하다.

        성공 여부는 이 함수가 판정하지 않는다. 호출자가 관찰 가능한 결과
        (창이 닫혔는지, 요소가 사라졌는지)로 검증해야 한다.

    .PARAMETER Ac
        클릭할 컴포넌트의 AccessibleContext
    .PARAMETER Hwnd
        전면으로 올릴 창. 생략하면 포그라운드 전환을 하지 않는다.
    #>
    param(
        [Parameter(Mandatory)][long]$Ac,
        [IntPtr]$Hwnd = [IntPtr]::Zero,
        [int]$VmId = $script:JabVmId
    )
    _AssertInit

    $info = New-Object Jab.AccessibleContextInfo
    if (-not [Jab.Win32]::GetContextInfoW($VmId, $Ac, [ref]$info, 3000)) {
        throw "컨텍스트 정보를 읽지 못했습니다 (ac=0x$($Ac.ToString('X')))."
    }
    if ($info.width -le 0 -or $info.height -le 0) {
        throw ("좌표가 비어 있습니다 ({0},{1} {2}x{3}). 핸들이 이미 해제되었을 수 있습니다." -f `
               $info.x, $info.y, $info.width, $info.height)
    }

    # 포그라운드 전환 직후 바로 누르면 Swing 이 포커스 획득 클릭으로 삼켜서
    # 메뉴가 열리지 않는다. 활성화 → 커서 이동(호버) → 클릭 순서로 간격을 둔다.
    if ($Hwnd -ne [IntPtr]::Zero) {
        if (-not [Jab.Win32]::ForceForeground($Hwnd)) {
            throw "창을 전면으로 가져오지 못했습니다. 클릭이 빗나갑니다."
        }
        Start-Sleep -Milliseconds 300
    }

    # 디스플레이 배율 보정 (JAB 은 배율 미적용 좌표를 준다)
    if ($Hwnd -ne [IntPtr]::Zero) {
        $pt = Get-JabScreenPoint -Hwnd $Hwnd -VmId $VmId -RootAc $script:JabRootAc `
                                 -JabX $info.x -JabY $info.y -JabW $info.width -JabH $info.height
        $cx = $pt.X; $cy = $pt.Y
    } else {
        $cx = $info.x + [int]($info.width / 2)
        $cy = $info.y + [int]($info.height / 2)
    }

    [Jab.Win32]::SetCursorPos($cx, $cy) | Out-Null
    Start-Sleep -Milliseconds 300
    if ($Hwnd -ne [IntPtr]::Zero) { [Jab.Win32]::SmartClick($Hwnd, $cx, $cy) } else { [Jab.Win32]::ClickAt($cx, $cy) }
    [Jab.Win32]::PumpMessages(20)

    [PSCustomObject]@{ X = $cx; Y = $cy }
}

# ============================================================ 메뉴 네비게이션
#
# 펼쳐진 팝업 메뉴 항목은 JAB 가 좌표를 주지 않는다(rect = -1,-1).
# 그래서 좌표 클릭 대신 키보드로 이동하고, 현재 위치는 'selected' 상태를
# 이름으로 읽어서 확인한다. 항목 순서에 의존하지 않으므로 메뉴에 항목이
# 추가돼도 깨지지 않는다.

function Get-JabSelectedMenuItem {
    <#
    .SYNOPSIS
        메뉴 바 하위에서 현재 하이라이트된(selected) 가장 깊은 메뉴 항목을 반환한다.
    .DESCRIPTION
        상위 메뉴도 selected 를 유지하므로(예: Tools 와 Library 가 동시에 selected),
        가장 depth 가 큰 것이 실제 커서 위치다.
    #>
    param(
        [Parameter(Mandatory)][long]$MenuBarAc,
        [int]$VmId = $script:JabVmId,
        [int]$MaxDepth = 10
    )
    _AssertInit
    $nodes = [Jab.Win32]::DumpTreeW($VmId, $MenuBarAc, $MaxDepth, 20000)
    $best = $null
    foreach ($n in $nodes) {
        if ($n.Role -ne 'menu' -and $n.Role -ne 'menu item') { continue }
        if ($n.States -notmatch 'selected') { continue }
        if ($null -eq $best -or $n.Depth -gt $best.Depth) { $best = $n }
    }
    return $best
}

function Select-JabMenuItem {
    <#
    .SYNOPSIS
        열려 있는 팝업에서 DOWN 키로 이동해 지정한 이름의 항목을 선택한다.
    .DESCRIPTION
        이름이 일치할 때까지 DOWN 을 누른다. MaxSteps 를 넘으면 실패로 본다
        (한 바퀴 돌았는데 못 찾은 경우).
    .OUTPUTS
        성공하면 $true.
    #>
    param(
        [Parameter(Mandatory)][long]$MenuBarAc,
        [Parameter(Mandatory)][string]$Name,
        [int]$VmId = $script:JabVmId,
        [int]$MaxSteps = 25,
        [int]$StepDelayMs = 350
    )
    _AssertInit
    for ($i = 0; $i -lt $MaxSteps; $i++) {
        $cur = Get-JabSelectedMenuItem -MenuBarAc $MenuBarAc -VmId $VmId
        if ($null -ne $cur -and $cur.Name -eq $Name) { return $true }
        [System.Windows.Forms.SendKeys]::SendWait('{DOWN}')
        Start-Sleep -Milliseconds $StepDelayMs
        [Jab.Win32]::PumpMessages(20)
    }
    return $false
}

function Invoke-JabMenuPath {
    <#
    .SYNOPSIS
        메뉴 경로를 끝까지 따라가 마지막 항목을 실행한다.

    .DESCRIPTION
        1단계(최상위 메뉴)는 JAB 좌표가 정확하므로 마우스로 연다.
        2단계부터는 팝업이라 좌표가 없으므로 키보드로 이동한다.
        각 단계는 'selected' 상태를 이름으로 확인하며 진행한다.

    .PARAMETER Path
        예: @('Tools','Library','3D Models','Bulk Import')

    .PARAMETER Hwnd
        Cockpit 메인 창 핸들.

    .PARAMETER NoInvoke
        마지막 항목을 선택만 하고 ENTER 를 누르지 않는다(디버깅용).
    #>
    param(
        [Parameter(Mandatory)][string[]]$Path,
        [Parameter(Mandatory)][IntPtr]$Hwnd,
        [int]$VmId = $script:JabVmId,
        [long]$RootAc = $script:JabRootAc,
        [switch]$NoInvoke
    )
    _AssertInit
    Add-Type -AssemblyName System.Windows.Forms

    if (-not [Jab.Win32]::ForceForeground($Hwnd)) {
        throw "창을 전면으로 가져오지 못했습니다. 키 입력이 다른 창으로 갑니다."
    }

    # 이전 시도에서 메뉴가 열린 채 남아 있을 수 있으므로 초기화한다.
    [System.Windows.Forms.SendKeys]::SendWait('{ESC}')
    Start-Sleep -Milliseconds 250
    [System.Windows.Forms.SendKeys]::SendWait('{ESC}')
    Start-Sleep -Milliseconds 400

    $menuBar = [Jab.Win32]::FindElementW($VmId, $RootAc, '', 'menu bar', 6, 5000)
    if ($null -eq $menuBar) { throw "메뉴 바를 찾지 못했습니다." }

    # 1단계: 최상위 메뉴를 마우스로 연다.
    # 루트 전체에서 찾으면 본문의 동명 텍스트에 잘못 걸리므로 메뉴 바로 스코프를 좁힌다.
    $top = [Jab.Win32]::FindElementW($VmId, $menuBar.Ac, $Path[0], 'menu', 3, 5000)
    if ($null -eq $top) { throw "최상위 메뉴 '$($Path[0])' 를 찾지 못했습니다." }
    $ti = New-Object Jab.AccessibleContextInfo
    [Jab.Win32]::GetContextInfoW($VmId, $top.Ac, [ref]$ti, 3000) | Out-Null
    if ($ti.width -le 0) { throw "'$($Path[0])' 좌표를 얻지 못했습니다." }

    # 디스플레이 배율 보정. 안 하면 클릭이 옆 메뉴에 떨어진다(Tools 대신 View 등).
    $tp = Get-JabScreenPoint -Hwnd $Hwnd -VmId $VmId -RootAc $RootAc `
                             -JabX $ti.x -JabY $ti.y -JabW $ti.width -JabH $ti.height
    $tcx = $tp.X
    $tcy = $tp.Y

    # 메뉴 바 클릭은 토글이다. 직전 상태에 따라 열리는 대신 닫힐 수 있으므로
    # 열렸는지 확인하고 안 열렸으면 다시 누른다.
    #
    # 확인용으로 DOWN 을 눌러서는 안 된다. 선택이 한 칸 밀려서, 찾으려는 항목이
    # 팝업의 첫 번째일 때(예: 3D Models > Bulk Import) 지나쳐 버린다.
    # 팝업이 열리면 메뉴 바보다 깊은 depth 의 항목이 selected 가 되므로
    # 그것만으로 판정한다.
    $opened = $false
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        [Jab.Win32]::SmartClick($Hwnd, $tcx, $tcy)
        Start-Sleep -Milliseconds 900
        [Jab.Win32]::PumpMessages(30)

        $cur = Get-JabSelectedMenuItem -MenuBarAc $menuBar.Ac -VmId $VmId
        if ($null -ne $cur -and $cur.Depth -gt 1) { $opened = $true; break }

        # 클릭만으로는 최상위 메뉴가 하이라이트만 되고 팝업이 안 펼쳐지는 경우가 있다.
        # 이때는 아래 화살표로 펼친다. DOWN 은 선택을 첫 항목에 놓는데,
        # 그 자체가 유효한 후보이므로 이후 탐색에서 건너뛰면 안 된다
        # (Select-JabMenuItem 이 '현재 선택'부터 검사하므로 문제없다).
        if ($null -ne $cur -and $cur.Name -eq $Path[0]) {
            [System.Windows.Forms.SendKeys]::SendWait('{DOWN}')
            Start-Sleep -Milliseconds 500
            [Jab.Win32]::PumpMessages(20)
            $cur2 = Get-JabSelectedMenuItem -MenuBarAc $menuBar.Ac -VmId $VmId
            if ($null -ne $cur2 -and $cur2.Depth -gt 1) { $opened = $true; break }
        }
    }
    if (-not $opened) { throw "'$($Path[0])' 메뉴를 열지 못했습니다." }

    # 2단계 이후: 키보드 이동
    for ($i = 1; $i -lt $Path.Count; $i++) {
        $step   = $Path[$i]
        $isLast = ($i -eq $Path.Count - 1)

        if (-not (Select-JabMenuItem -MenuBarAc $menuBar.Ac -Name $step -VmId $VmId)) {
            throw "메뉴 항목 '$step' 을 선택하지 못했습니다."
        }

        if ($isLast) {
            if ($NoInvoke) { return $true }
            [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
            Start-Sleep -Milliseconds 800
            [Jab.Win32]::PumpMessages(30)
        }
        else {
            # 서브메뉴 펼치기
            [System.Windows.Forms.SendKeys]::SendWait('{RIGHT}')
            Start-Sleep -Milliseconds 900
            [Jab.Win32]::PumpMessages(30)
        }
    }
    return $true
}

function Dismiss-CockpitStartupDialog {
    <#
    .SYNOPSIS
        기동 중 뜨는 관문 대화상자(License Selector / Production library selection)를
        처리하고 넘어간다.

    .DESCRIPTION
        둘 다 '안 뜰 수도 있다'. 설정(Remember selection / Don't prompt)에 따라
        건너뛰어진다. 그래서 없으면 조용히 $false 를 돌려주고 넘어가야 한다.

        - License Selector          : Librarian 열의 Select 를 누른 뒤 OK
                                      (이미 Selected 면 OK 만)
        - Production library select : 기본 라디오가 이미 선택돼 있으므로 Next 만

        버튼 좌표는 JAB 가 정상으로 주므로 일반적인
        "JAB 로 찾고 Win32 로 클릭" 패턴을 쓴다.

    .OUTPUTS
        처리했으면 $true, 대화상자가 없었으면 $false.
    #>
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][IntPtr]$MainHwnd,
        [int]$TimeoutMs = 20000
    )
    _AssertInit

    foreach ($h in [Jab.Win32]::GetVisibleWindows([uint32]$ProcessId)) {
        if ($h -eq $MainHwnd) { continue }
        $title = [Jab.Win32]::GetWindowTitle($h)
        $vm = 0; $ac = [long]0
        if (-not [Jab.Bridge]::getAccessibleContextFromHWND($h, [ref]$vm, [ref]$ac)) { continue }
        if ($ac -eq 0) { continue }

        # --- License Selector : Librarian 열 선택 후 OK ---
        if ($title -like '*License Selector*') {
            Write-Verbose "License Selector 처리 중"

            # 전면 전환 과정에서 창이 움직이면 이미 읽어둔 좌표가 어긋나
            # 엉뚱한 열(Base)을 눌러버린다(실제로 겪음).
            # 위치를 고정하고 충분히 안정된 뒤에 좌표를 읽는다.
            [Jab.Win32]::ForceForeground($h) | Out-Null
            Start-Sleep -Milliseconds 400
            [Jab.Win32]::MoveWindow($h, 100, 100, 730, 496, $true) | Out-Null
            Start-Sleep -Milliseconds 900
            [Jab.Win32]::PumpMessages(30)

            # 열 버튼은 전부 이름이 'Select'(선택된 것만 'Selected') 라서
            # 'Librarian' 이라는 이름으로는 찾을 수 없다. 열 순서로 구분해야 한다.
            #   Base | Engineer | Librarian | Developer  → x 오름차순 index 2
            $btns = @()
            foreach ($n in [Jab.Win32]::DumpTreeW($vm, $ac, 14, 30000)) {
                if ($n.Role -ne 'push button') { continue }
                if ($n.Name -ne 'Select' -and $n.Name -ne 'Selected') { continue }
                $bi2 = New-Object Jab.AccessibleContextInfo
                if (-not [Jab.Win32]::GetContextInfoW($vm, $n.Ac, [ref]$bi2, 2000)) { continue }
                if ($bi2.width -le 0) { continue }
                $btns += [PSCustomObject]@{
                    Ac = $n.Ac; Name = $n.Name
                    X = $bi2.x; Y = $bi2.y; W = $bi2.width; H = $bi2.height
                }
            }
            $btns = @($btns | Sort-Object X)

            if ($btns.Count -lt 3) {
                throw "License Selector 의 열 버튼을 찾지 못했습니다 (발견 $($btns.Count) 개)."
            }
            $librarian = $btns[2]   # 0:Base 1:Engineer 2:Librarian 3:Developer

            # 이미 선택돼 있으면('Selected') 다시 누르지 않는다.
            if ($librarian.Name -ne 'Selected') {
                $libAc = $librarian.Ac; $libVm = $vm
                $selected = {
                    $ci0 = New-Object Jab.AccessibleContextInfo
                    [Jab.Win32]::GetContextInfoW($libVm, $libAc, [ref]$ci0, 2000) -and $ci0.name -eq 'Selected'
                }.GetNewClosure()
                Invoke-JabPress -Hwnd $h -VmId $vm -RootAc $ac -TargetAc $libAc `
                                -IsDone $selected -TimeoutMs 6000 -What 'Librarian Select' | Out-Null
                Start-Sleep -Milliseconds 800
                [Jab.Win32]::PumpMessages(20)

                # 반환값이 없는 조작이라 관찰로 검증한다.
                # 3번째 열이 'Selected' 가 됐는지 다시 읽어 확인.
                $chk = @()
                foreach ($n2 in [Jab.Win32]::DumpTreeW($vm, $ac, 14, 20000)) {
                    if ($n2.Role -ne 'push button') { continue }
                    if ($n2.Name -ne 'Select' -and $n2.Name -ne 'Selected') { continue }
                    $ci = New-Object Jab.AccessibleContextInfo
                    if (-not [Jab.Win32]::GetContextInfoW($vm, $n2.Ac, [ref]$ci, 2000)) { continue }
                    if ($ci.width -le 0) { continue }
                    $chk += [PSCustomObject]@{ Name = $n2.Name; X = $ci.x }
                }
                $chk = @($chk | Sort-Object X)
                if ($chk.Count -ge 3 -and $chk[2].Name -ne 'Selected') {
                    throw "Librarian 열 선택에 실패했습니다 (현재 '$($chk[2].Name)')."
                }
            }

            return (_ClickDialogButton -Hwnd $h -VmId $vm -Ac $ac `
                                       -Labels @('OK','확인') -TimeoutMs $TimeoutMs)
        }

        # --- Production library selection : 기본값 그대로 Next ---
        if ($title -like '*Production library*') {
            Write-Verbose "Production library selection 처리 중"
            return (_ClickDialogButton -Hwnd $h -VmId $vm -Ac $ac `
                                       -Labels @('Next','다음','OK','확인') -TimeoutMs $TimeoutMs)
        }

        # --- Setup M3DL Connection : 'EDM Server only' 선택 후 OK ---
        if ($title -like '*M3DL*') {
            Write-Verbose "Setup M3DL Connection 처리 중"

            # 라디오/체크박스 중 'EDM Server only' 를 찾아 선택한다.
            # 이미 선택돼 있으면(states 에 checked) 건너뛴다.
            $opt = $null
            foreach ($role in @('radio button','check box')) {
                $o = [Jab.Win32]::FindElementW($vm, $ac, 'EDM Server only', $role, 12, 4000)
                if ($null -ne $o) { $opt = $o; break }
            }
            if ($null -eq $opt) {
                throw "'EDM Server only' 선택지를 찾지 못했습니다."
            }
            if ($opt.States -notmatch 'checked') {
                $optAc = $opt.Ac; $optVm = $vm
                $checked = {
                    $ci0 = New-Object Jab.AccessibleContextInfo
                    [Jab.Win32]::GetContextInfoW($optVm, $optAc, [ref]$ci0, 2000) -and $ci0.states_en_US -match 'checked'
                }.GetNewClosure()
                Invoke-JabPress -Hwnd $h -VmId $vm -RootAc $ac -TargetAc $optAc `
                                -IsDone $checked -TimeoutMs 6000 -What 'EDM Server only' | Out-Null
                Start-Sleep -Milliseconds 600
                [Jab.Win32]::PumpMessages(20)
            }
            return (_ClickDialogButton -Hwnd $h -VmId $vm -Ac $ac `
                                       -Labels @('OK','확인') -TimeoutMs $TimeoutMs)
        }
    }
    return $false
}

function Get-JabScreenPoint {
    <#
    .SYNOPSIS
        JAB 가 보고한 좌표를 실제 화면 좌표로 변환한다.

    .DESCRIPTION
        디스플레이 배율(예: 125%)이 걸린 환경에서 JAB 은 배율이 적용되지 않은
        논리 좌표를 준다. 그대로 클릭하면 빗나간다.

        보정 방법: 같은 창에 대해 JAB 이 보고하는 루트 사각형과 Win32 의
        GetWindowRect 를 비교하면 배율/오프셋이 그대로 드러난다.
        그 선형 변환을 자식 요소 좌표에 그대로 적용한다.

          화면X = 창.Left + (JAB_X - 루트.x) * (창너비 / 루트너비)

        실측(125% 배율): 루트 584x397 ↔ 창 730x496 → 배율 1.25

    .OUTPUTS
        PSCustomObject { X, Y } - 클릭할 화면 좌표
    #>
    param(
        [Parameter(Mandatory)][IntPtr]$Hwnd,
        [Parameter(Mandatory)][int]$VmId,
        [Parameter(Mandatory)][long]$RootAc,
        [Parameter(Mandatory)][int]$JabX,
        [Parameter(Mandatory)][int]$JabY,
        [int]$JabW = 0,
        [int]$JabH = 0
    )
    _AssertInit

    # 요소의 중심을 기준으로 계산한다
    $px = $JabX + [int]($JabW / 2)
    $py = $JabY + [int]($JabH / 2)

    $wr = New-Object Jab.Win32+RECT
    if (-not [Jab.Win32]::GetWindowRect($Hwnd, [ref]$wr)) {
        return [PSCustomObject]@{ X = $px; Y = $py }
    }
    $ri = New-Object Jab.AccessibleContextInfo
    if (-not [Jab.Win32]::GetContextInfoW($VmId, $RootAc, [ref]$ri, 3000)) {
        return [PSCustomObject]@{ X = $px; Y = $py }
    }
    if ($ri.width -le 0 -or $ri.height -le 0) {
        return [PSCustomObject]@{ X = $px; Y = $py }
    }

    $sx = ($wr.Right  - $wr.Left) / [double]$ri.width
    $sy = ($wr.Bottom - $wr.Top)  / [double]$ri.height

    [PSCustomObject]@{
        X = $wr.Left + [int](($px - $ri.x) * $sx)
        Y = $wr.Top  + [int](($py - $ri.y) * $sy)
    }
}

function Invoke-JabPress {
    <#
    .SYNOPSIS
        버튼류를 누르고 IsDone 이 참이 될 때까지 기다린다 (내부 헬퍼).

    .DESCRIPTION
        세션이 연결돼 있으면 실제 마우스 클릭(ClickAt) 한 가지만 쓴다.
        RDP 가 끊긴 세션에서는 실제 입력이 닿지 않고, AWT 가 커서 위치(GetMessagePos)로
        마우스 진입을 판정해서 PostMessage 클릭도 무시될 수 있다.
        그래서 JAB 액션(doClick) → PostMessage 순으로 시도하고 결과로 검증한다.
        IsDone 은 호출 측 변수를 쓰므로 GetNewClosure() 로 만들어 넘길 것.
    #>
    param(
        [Parameter(Mandatory)][IntPtr]$Hwnd,
        [Parameter(Mandatory)][int]$VmId,
        [Parameter(Mandatory)][long]$RootAc,
        [Parameter(Mandatory)][long]$TargetAc,
        [Parameter(Mandatory)][scriptblock]$IsDone,
        [int]$TimeoutMs = 20000,
        [string]$What = '버튼'
    )
    $ti = New-Object Jab.AccessibleContextInfo
    [Jab.Win32]::GetContextInfoW($VmId, $TargetAc, [ref]$ti, 3000) | Out-Null
    $pt = $null
    if ($ti.width -gt 0) {
        $pt = Get-JabScreenPoint -Hwnd $Hwnd -VmId $VmId -RootAc $RootAc `
                                 -JabX $ti.x -JabY $ti.y -JabW $ti.width -JabH $ti.height
    }

    $methods = @(if ([Jab.Win32]::IsSessionActive()) { 'mouse' } else { 'action', 'post' })
    $perMs = [int]($TimeoutMs / $methods.Count)

    foreach ($m in $methods) {
        try {
            switch ($m) {
                'mouse' {
                    if ($null -eq $pt) { throw "$What 좌표를 얻지 못했습니다." }
                    [Jab.Win32]::ClickAt($pt.X, $pt.Y)
                }
                'action' {
                    $acts = @([Jab.Win32]::GetActionsW($VmId, $TargetAc, 3000))
                    Write-Log "  [$What] JAB 액션 시도 (사용 가능: $($acts -join ', '))"
                    Invoke-JabAction -Ac $TargetAc -VmId $VmId | Out-Null
                }
                'post' {
                    if ($null -eq $pt) { throw "$What 좌표를 얻지 못했습니다." }
                    Write-Log "  [$What] PostMessage 클릭 시도"
                    [Jab.Win32]::PostClick($Hwnd, $pt.X, $pt.Y)
                }
            }
        } catch {
            Write-Log "  [$What] '$m' 방식 실패: $($_.Exception.Message)"
            continue
        }
        $deadline = (Get-Date).AddMilliseconds($perMs)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 400
            [Jab.Win32]::PumpMessages(20)
            if (& $IsDone) {
                if ($m -ne 'mouse') { Write-Log "  [$What] '$m' 방식으로 성공" }
                return $true
            }
        }
    }
    return $false
}

function _ClickDialogButton {
    <#
    .SYNOPSIS
        대화상자의 버튼을 눌러 창이 닫히는 것까지 확인한다 (내부 헬퍼).
    #>
    param(
        [Parameter(Mandatory)][IntPtr]$Hwnd,
        [Parameter(Mandatory)][int]$VmId,
        [Parameter(Mandatory)][long]$Ac,
        [Parameter(Mandatory)][string[]]$Labels,
        [int]$TimeoutMs = 20000
    )
    $btn = $null
    foreach ($lb in $Labels) {
        $b = [Jab.Win32]::FindElementW($VmId, $Ac, $lb, 'push button', 12, 3000)
        if ($null -ne $b) { $btn = $b; break }
    }
    if ($null -eq $btn) { throw "대화상자 버튼을 찾지 못했습니다 (시도: $($Labels -join ', '))." }

    # 전면 전환이 창을 움직일 수 있으므로 반드시 '올린 뒤에' 좌표를 읽는다.
    [Jab.Win32]::ForceForeground($Hwnd) | Out-Null
    Start-Sleep -Milliseconds 500
    [Jab.Win32]::PumpMessages(20)

    $dlgHwnd = $Hwnd
    $closed = { -not [Jab.Win32]::IsWindow($dlgHwnd) -or -not [Jab.Win32]::IsWindowVisible($dlgHwnd) }.GetNewClosure()
    if (Invoke-JabPress -Hwnd $Hwnd -VmId $VmId -RootAc $Ac -TargetAc $btn.Ac `
                        -IsDone $closed -TimeoutMs $TimeoutMs -What "'$($btn.Name)' 버튼") {
        return $true
    }
    throw "버튼을 눌렀지만 대화상자가 닫히지 않았습니다."
}

function Wait-CockpitReady {
    <#
    .SYNOPSIS
        Cockpit 이 메뉴 바를 그릴 때까지 기다린다.

    .DESCRIPTION
        Start-Cockpit 은 '창이 떴는지' 까지만 확인한다. 창이 떠도 한동안은
        서버 접속 중(.Connecting. 스플래시) 이라 메뉴 바가 아예 없다.
        이 상태에서 메뉴를 찾으면 "메뉴 바를 찾지 못했습니다" 로 실패한다.

        메뉴 바가 실제로 나타날 때까지 폴링한다.

    .OUTPUTS
        준비되면 $true, 제한 시간을 넘기면 $false.
    #>
    param(
        [Parameter(Mandatory)][int]$VmId,
        [Parameter(Mandatory)][long]$RootAc,
        [int]$TimeoutMs = 180000,
        [int]$ProcessId = 0,
        [IntPtr]$MainHwnd = [IntPtr]::Zero
    )
    _AssertInit
    $curVmId  = $VmId
    $curRoot  = $RootAc
    $curHwnd  = $MainHwnd
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)

    while ((Get-Date) -lt $deadline) {
        [Jab.Win32]::PumpMessages(30)

        # 기동 중에는 Cockpit 이 메인 창을 다시 만들기도 한다. 처음에 잡아둔
        # HWND 가 죽어버리므로(실제로 겪음) 매 회차 제목으로 다시 찾는다.
        if ($ProcessId -gt 0) {
            $h2 = Get-CockpitMainWindow -ProcessId $ProcessId
            if ($h2 -ne [IntPtr]::Zero -and $h2 -ne $curHwnd) {
                $curHwnd = $h2
                Write-Verbose ("메인 창 핸들이 갱신됐습니다: 0x{0:X}" -f [int64]$h2)
            }
        }

        # 기동 관문 대화상자(License Selector / Production library selection /
        # Setup M3DL Connection)가 떠 있으면 메뉴 바는 영원히 안 나온다.
        # 매 회차마다 확인해서 넘긴다. (설정에 따라 안 뜰 수 있으므로 없으면 통과)
        if ($ProcessId -gt 0 -and $curHwnd -ne [IntPtr]::Zero) {
            try {
                if (Dismiss-CockpitStartupDialog -ProcessId $ProcessId -MainHwnd $curHwnd) {
                    Start-Sleep -Milliseconds 1500
                }
            } catch {
                Write-Log "기동 대화상자 처리 실패(재시도): $($_.Exception.Message)"
            }
        }

        # 스플래시 → 본 화면으로 바뀌면 루트 AccessibleContext 자체가 갈린다.
        # 처음에 잡아둔 root 로 계속 찾으면 화면에 메뉴 바가 멀쩡히 보이는데도
        # 영영 못 찾는다(실제로 겪음). 매번 HWND 에서 다시 얻는다.
        if ($curHwnd -ne [IntPtr]::Zero -and [Jab.Bridge]::isJavaWindow($curHwnd)) {
            $vm2 = 0; $ac2 = [long]0
            if ([Jab.Bridge]::getAccessibleContextFromHWND($curHwnd, [ref]$vm2, [ref]$ac2) -and $ac2 -ne 0) {
                $curVmId = $vm2
                $curRoot = $ac2
                $script:JabVmId   = $vm2
                $script:JabRootAc = $ac2
            }
        }

        if ($curRoot -ne 0) {
            $mb = [Jab.Win32]::FindElementW($curVmId, $curRoot, '', 'menu bar', 6, 3000)
            if ($null -ne $mb) { return $true }
        }

        Start-Sleep -Milliseconds 2000
    }
    return $false
}

function Get-CockpitMainWindow {
    <#
    .SYNOPSIS
        Cockpit 메인 프레임 창 핸들을 제목으로 찾는다.

    .DESCRIPTION
        Process.MainWindowHandle 를 믿으면 안 된다. 대화상자(예: 'Bulk Import
        finished')가 떠 있으면 Windows 가 그쪽을 MainWindowHandle 로 보고해서,
        JAB 를 대화상자에 붙이게 되고 메뉴 바를 찾지 못한다.
        제목이 'Xpedition EDM Library Cockpit' 인 창을 직접 찾는다.
    #>
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [string]$TitlePattern = 'Xpedition EDM Library Cockpit',
        [int]$WaitMs = 0
    )
    $deadline = (Get-Date).AddMilliseconds([Math]::Max($WaitMs, 1))
    if (-not (Get-Variable -Name SessionStateLogged -Scope Script -ErrorAction SilentlyContinue)) {
        $script:SessionStateLogged = $true
        $state = if ([Jab.Win32]::IsSessionActive()) { 'Active(SendInput 클릭)' } else { 'Disconnected(PostMessage 클릭)' }
        Write-Log "세션 상태: $state"
    }
    do {
        $allWindows = [Jab.Win32]::GetAllWindows([uint32]$ProcessId)
        foreach ($h in $allWindows) {
            if ([Jab.Win32]::GetWindowTitle($h) -eq $TitlePattern) { return $h }
        }
        foreach ($h in $allWindows) {
            if ([Jab.Win32]::GetWindowTitle($h) -like "*$TitlePattern*") { return $h }
        }
        if ((Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 1000 }
    } while ((Get-Date) -lt $deadline)
    if ($WaitMs -gt 0) {
        $list = @([Jab.Win32]::GetAllWindows([uint32]$ProcessId) | ForEach-Object { "'$([Jab.Win32]::GetWindowTitle($_))'" }) -join ', '
        Write-Log "메인 창 대기 시간 초과 (${WaitMs}ms). 현재 창: $list"
    }
    return [IntPtr]::Zero
}

function Close-JabResultDialog {
    <#
    .SYNOPSIS
        Import 완료 창('... finished')이 떠 있으면 Close 를 눌러 닫는다.

    .DESCRIPTION
        Bulk Import 가 끝나면 결과 로그를 담은 전체 화면 창이 뜬다.
        이 창이 남아 있으면 Process.MainWindowHandle 이 그쪽을 가리켜서
        다음 단계가 메뉴 바를 못 찾는다. 반드시 닫고 진행해야 한다.

    .PARAMETER AppearMs
        결과 창이 나타날 때까지 기다리는 시간. 메뉴 실행 직후에는 아직 창이
        없을 수 있어서, 바로 훑으면 '없음'으로 오판하고 넘어가 버린다.

    .OUTPUTS
        닫았으면 $true, 제한 시간 안에 결과 창이 나타나지 않았으면 $false.
    #>
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][IntPtr]$MainHwnd,
        [int]$TimeoutMs = 20000,
        [int]$WaitFinishMs = 600000,
        [int]$AppearMs = 15000,
        [string[]]$ButtonLabels = @('Close','OK','확인','닫기')
    )
    _AssertInit

    # 1) 결과 창이 뜰 때까지 기다린다.
    $target = $null
    $appearDeadline = (Get-Date).AddMilliseconds($AppearMs)
    while ((Get-Date) -lt $appearDeadline) {
        [Jab.Win32]::PumpMessages(20)
        foreach ($h in [Jab.Win32]::GetVisibleWindows([uint32]$ProcessId)) {
            if ($h -eq $MainHwnd) { continue }
            $vm = 0; $ac = [long]0
            if (-not [Jab.Bridge]::getAccessibleContextFromHWND($h, [ref]$vm, [ref]$ac)) { continue }
            if ($ac -eq 0) { continue }
            $target = [PSCustomObject]@{ Hwnd = $h; VmId = $vm; Ac = $ac }
            break
        }
        if ($null -ne $target) { break }
        Start-Sleep -Milliseconds 500
    }
    if ($null -eq $target) { return $false }

    # 2) 버튼 라벨은 창마다 다르다.
    #    Bulk Import  → 'Bulk Import finished'   / Close
    #    Mapping File → 'Importing Mapping File' / OK
    function _FindBtn {
        param($t, [string[]]$labels)
        foreach ($lb in $labels) {
            $b = [Jab.Win32]::FindElementW($t.VmId, $t.Ac, $lb, 'push button', 10, 3000)
            if ($null -ne $b) { return $b }
        }
        return $null
    }

    # 3) 작업 중에는 버튼이 비활성(states 에 'enabled' 없음)이다.
    #    활성화되는 시점이 곧 완료 시점이므로 이걸 완료 대기로 쓴다.
    $btn = $null
    $deadline = (Get-Date).AddMilliseconds($WaitFinishMs)
    while ((Get-Date) -lt $deadline) {
        [Jab.Win32]::PumpMessages(20)
        $cur = _FindBtn -t $target -labels $ButtonLabels
        if ($null -ne $cur -and $cur.States -match 'enabled') { $btn = $cur; break }
        Start-Sleep -Milliseconds 1000
    }
    if ($null -eq $btn) {
        throw "작업이 끝나지 않아 결과 창의 버튼이 활성화되지 않았습니다 (${WaitFinishMs}ms 대기)."
    }

    [Jab.Win32]::ForceForeground($target.Hwnd) | Out-Null
    Start-Sleep -Milliseconds 400

    $resHwnd = $target.Hwnd
    $closed = { -not [Jab.Win32]::IsWindow($resHwnd) -or -not [Jab.Win32]::IsWindowVisible($resHwnd) }.GetNewClosure()
    if (Invoke-JabPress -Hwnd $target.Hwnd -VmId $target.VmId -RootAc $target.Ac -TargetAc $btn.Ac `
                        -IsDone $closed -TimeoutMs $TimeoutMs -What "결과 창 '$($btn.Name)'") {
        return $true
    }
    throw "결과 창을 닫지 못했습니다."
}

function Wait-JabDialog {
    <#
    .SYNOPSIS
        Cockpit 프로세스에 새로 뜬 대화상자 창을 기다렸다 반환한다.
    .PARAMETER MainHwnd
        메인 창 핸들(이 창은 제외하고 찾는다).
    .OUTPUTS
        PSCustomObject { Hwnd, Title, VmId, Ac } / 시간 초과면 $null
    #>
    param(
        [Parameter(Mandatory)][IntPtr]$MainHwnd,
        [Parameter(Mandatory)][int]$ProcessId,
        [int]$TimeoutMs = 15000
    )
    _AssertInit
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        [Jab.Win32]::PumpMessages(30)
        foreach ($h in [Jab.Win32]::GetVisibleWindows([uint32]$ProcessId)) {
            if ($h -eq $MainHwnd) { continue }
            $vm = 0; $ac = [long]0
            if (-not [Jab.Bridge]::getAccessibleContextFromHWND($h, [ref]$vm, [ref]$ac)) { continue }
            if ($ac -eq 0) { continue }
            return [PSCustomObject]@{
                Hwnd  = $h
                Title = [Jab.Win32]::GetWindowTitle($h)
                VmId  = $vm
                Ac    = $ac
            }
        }
        Start-Sleep -Milliseconds 400
    }
    return $null
}

function Do-JabFileDialog {
    <#
    .SYNOPSIS
        Swing JFileChooser 에 경로를 입력하고 확인 버튼을 누른다.

    .DESCRIPTION
        파일 대화상자는 팝업 메뉴와 달리 JAB 좌표가 정상으로 나오므로
        일반적인 "JAB 로 찾고 Win32 로 클릭" 패턴을 쓴다.
        텍스트 입력은 setTextContents 가 실제로 동작한다(화면으로 확인함).

        확인 버튼 라벨은 대화상자마다 다르므로 후보를 순서대로 시도한다.

    .PARAMETER Dialog
        Wait-JabDialog 가 돌려준 객체.
    .PARAMETER Path
        입력할 경로.
    #>
    param(
        [Parameter(Mandatory)]$Dialog,
        [Parameter(Mandatory)][string]$Path,
        [string[]]$ConfirmLabels = @('Open','OK','열기','확인','Select','Choose'),
        [int]$TimeoutMs = 20000
    )
    _AssertInit

    if (-not [Jab.Win32]::ForceForeground($Dialog.Hwnd)) {
        throw "대화상자를 전면으로 가져오지 못했습니다."
    }
    Start-Sleep -Milliseconds 300

    # 1) 텍스트 필드 (보통 'File name:')
    $tf = $null
    foreach ($label in @('File name:','파일 이름:','')) {
        $tf = [Jab.Win32]::FindElementW($Dialog.VmId, $Dialog.Ac, $label, 'text', 10, 4000)
        if ($null -ne $tf) { break }
    }
    if ($null -eq $tf) { throw "파일 이름 입력 필드를 찾지 못했습니다." }

    $fi = New-Object Jab.AccessibleContextInfo
    [Jab.Win32]::GetContextInfoW($Dialog.VmId, $tf.Ac, [ref]$fi, 3000) | Out-Null
    if ($fi.width -gt 0) {
        # 포커스를 줘야 입력이 반영되는 경우가 있다 (배율 보정 적용)
        $fp = Get-JabScreenPoint -Hwnd $Dialog.Hwnd -VmId $Dialog.VmId -RootAc $Dialog.Ac `
                                 -JabX $fi.x -JabY $fi.y -JabW $fi.width -JabH $fi.height
        [Jab.Win32]::SmartClick($Dialog.Hwnd, $fp.X, $fp.Y)
        Start-Sleep -Milliseconds 300
        [Jab.Win32]::PumpMessages(20)
    }

    if (-not [Jab.Bridge]::setTextContents($Dialog.VmId, $tf.Ac, $Path)) {
        throw "경로 입력에 실패했습니다: $Path"
    }
    Start-Sleep -Milliseconds 400
    [Jab.Win32]::PumpMessages(20)

    # 2) 확인 버튼
    $btn = $null
    foreach ($label in $ConfirmLabels) {
        $btn = [Jab.Win32]::FindElementW($Dialog.VmId, $Dialog.Ac, $label, 'push button', 10, 3000)
        if ($null -ne $btn) { break }
    }
    if ($null -eq $btn) { throw "확인 버튼을 찾지 못했습니다 (시도: $($ConfirmLabels -join ', '))." }

    $bi = New-Object Jab.AccessibleContextInfo
    [Jab.Win32]::GetContextInfoW($Dialog.VmId, $btn.Ac, [ref]$bi, 3000) | Out-Null
    if ($bi.width -le 0) { throw "확인 버튼 좌표를 얻지 못했습니다." }
    $bp = Get-JabScreenPoint -Hwnd $Dialog.Hwnd -VmId $Dialog.VmId -RootAc $Dialog.Ac `
                             -JabX $bi.x -JabY $bi.y -JabW $bi.width -JabH $bi.height
    [Jab.Win32]::SmartClick($Dialog.Hwnd, $bp.X, $bp.Y)

    # 3) 닫혔는지 관찰로 검증 (반환값은 믿지 않는다)
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        [Jab.Win32]::PumpMessages(30)
        if (-not [Jab.Win32]::IsWindowVisible($Dialog.Hwnd)) { return $true }
    }
    throw "확인 버튼을 눌렀지만 대화상자가 닫히지 않았습니다."
}

function Do-JabMappingDialog {
    <#
    .SYNOPSIS
        'Import mapping file' 전용 폼에 매핑 파일 경로를 넣고 Import 를 누른다.

    .DESCRIPTION
        이 대화상자는 JFileChooser 가 아니라 전용 폼이라 Do-JabFileDialog 로는
        처리할 수 없다. 텍스트 필드에 이름이 없어서(name='') 라벨로 못 찾으므로
        role='text' 인 것들을 모아 y 좌표 순으로 정렬해 구분한다.
          - 첫 번째(위, y≈347) = Mapping file
          - 두 번째(아래, y≈427) = Alignment file

    .PARAMETER Dialog
        Wait-JabDialog 가 돌려준 객체.
    .PARAMETER MappingPath
        Mapping.xdm 경로.
    .PARAMETER AlignmentPath
        정렬 파일 경로. 생략하면 건드리지 않는다.
    #>
    param(
        [Parameter(Mandatory)]$Dialog,
        [Parameter(Mandatory)][string]$MappingPath,
        [string]$AlignmentPath = '',
        [int]$TimeoutMs = 30000
    )
    _AssertInit

    if (-not [Jab.Win32]::ForceForeground($Dialog.Hwnd)) {
        throw "대화상자를 전면으로 가져오지 못했습니다."
    }
    Start-Sleep -Milliseconds 300

    # 이름 없는 text 필드들을 좌표로 구분한다
    $nodes = [Jab.Win32]::DumpTreeW($Dialog.VmId, $Dialog.Ac, 12, 30000)
    $fields = @()
    foreach ($n in $nodes) {
        if ($n.Role -ne 'text') { continue }
        $i = New-Object Jab.AccessibleContextInfo
        if (-not [Jab.Win32]::GetContextInfoW($Dialog.VmId, $n.Ac, [ref]$i, 2000)) { continue }
        # 폭이 넓은 한 줄짜리 입력칸만 (상단 안내문 text 제외)
        if ($i.width -lt 100 -or $i.height -gt 30) { continue }
        $fields += [PSCustomObject]@{ Ac = $n.Ac; X = $i.x; Y = $i.y; W = $i.width; H = $i.height }
    }
    $fields = @($fields | Sort-Object Y)
    if ($fields.Count -eq 0) { throw "매핑 파일 입력 필드를 찾지 못했습니다." }

    function Set-Field {
        param($f, [string]$Value)
        $fp = Get-JabScreenPoint -Hwnd $Dialog.Hwnd -VmId $Dialog.VmId -RootAc $Dialog.Ac `
                                 -JabX $f.X -JabY $f.Y -JabW $f.W -JabH $f.H
        [Jab.Win32]::SmartClick($Dialog.Hwnd, $fp.X, $fp.Y)
        Start-Sleep -Milliseconds 300
        [Jab.Win32]::PumpMessages(20)
        if (-not [Jab.Bridge]::setTextContents($Dialog.VmId, $f.Ac, $Value)) {
            throw "입력 실패: $Value"
        }
        Start-Sleep -Milliseconds 300
        [Jab.Win32]::PumpMessages(20)
    }

    Set-Field -f $fields[0] -Value $MappingPath
    if ($AlignmentPath -ne '' -and $fields.Count -ge 2) {
        Set-Field -f $fields[1] -Value $AlignmentPath
    }

    # Import 버튼
    $btn = [Jab.Win32]::FindElementW($Dialog.VmId, $Dialog.Ac, 'Import', 'push button', 10, 4000)
    if ($null -eq $btn) { throw "Import 버튼을 찾지 못했습니다." }
    $bi = New-Object Jab.AccessibleContextInfo
    [Jab.Win32]::GetContextInfoW($Dialog.VmId, $btn.Ac, [ref]$bi, 3000) | Out-Null
    if ($bi.width -le 0) { throw "Import 버튼 좌표를 얻지 못했습니다." }
    $bp = Get-JabScreenPoint -Hwnd $Dialog.Hwnd -VmId $Dialog.VmId -RootAc $Dialog.Ac `
                             -JabX $bi.x -JabY $bi.y -JabW $bi.width -JabH $bi.height
    [Jab.Win32]::SmartClick($Dialog.Hwnd, $bp.X, $bp.Y)

    # 닫힘을 관찰로 검증
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        [Jab.Win32]::PumpMessages(30)
        if (-not [Jab.Win32]::IsWindowVisible($Dialog.Hwnd)) { return $true }
    }
    throw "Import 를 눌렀지만 대화상자가 닫히지 않았습니다."
}

function Release-JabObject {
    <#
    .SYNOPSIS
        AccessibleContext 핸들을 JAB 에 반환한다.
    #>
    param(
        [Parameter(Mandatory, ValueFromPipeline)][long]$Ac,
        [int]$VmId = $script:JabVmId
    )
    process {
        [Jab.Bridge]::releaseJavaObject($VmId, $Ac)
    }
}

function Get-JabContextWithFocus {
    <#
    .SYNOPSIS
        현재 키보드 포커스를 가진 컴포넌트의 AccessibleContext 를 반환한다.
    #>
    param(
        [IntPtr]$Hwnd = [IntPtr]::Zero,
        [int]$VmId = $script:JabVmId
    )
    _AssertInit
    if ($Hwnd -eq [IntPtr]::Zero) {
        $proc = @(Get-Process -Name 'xDMLibraryClient' -ErrorAction SilentlyContinue |
                  Where-Object { $_.MainWindowHandle -ne 0 })
        $Hwnd = [IntPtr]$proc[0].MainWindowHandle
    }
    $vmIdOut = 0
    $ac      = 0L
    if (-not [Jab.Bridge]::getAccessibleContextWithFocus($Hwnd, [ref]$vmIdOut, [ref]$ac)) {
        return $null
    }
    $ac
}

function Find-JabElement {
    <#
    .SYNOPSIS
        트리를 깊이 우선으로 탐색하여 조건에 맞는 AccessibleContext 를 찾는다.
        C# 레벨 FindElementW/DumpTreeW 를 사용하므로 빠르다.
    .PARAMETER Ac
        탐색 시작 노드. 생략하면 루트.
    .PARAMETER Name
        Name 에 포함된 문자열 (부분 일치).
    .PARAMETER Role
        Role 에 포함된 문자열 (부분 일치, 영문 role_en_US 사용).
    .PARAMETER MaxDepth
        최대 탐색 깊이. 기본 10.
    .PARAMETER All
        이 스위치를 주면 첫 번째만이 아니라 전부 반환한다.
    .PARAMETER TimeoutMs
        탐색 타임아웃 (ms). 기본 30000.
    #>
    param(
        [long]$Ac = $script:JabRootAc,
        [string]$Name = '',
        [string]$Role = '',
        [int]$MaxDepth = 10,
        [switch]$All,
        [int]$VmId = $script:JabVmId,
        [int]$TimeoutMs = 30000
    )
    _AssertInit

    if (-not $All) {
        # 단일 결과 탐색
        $el = [Jab.Win32]::FindElementW($VmId, $Ac, $Name, $Role, $MaxDepth, $TimeoutMs)
        if ($null -eq $el) { return $null }
        return [PSCustomObject]@{
            Ac       = $el.Ac
            Name     = $el.Name
            Role     = $el.Role
            States   = $el.States
            Children = $el.Children
            Depth    = $el.Depth
        }
    }

    # All: DumpTree 후 필터
    $nodes = [Jab.Win32]::DumpTreeW($VmId, $Ac, $MaxDepth, $TimeoutMs)
    $results = [System.Collections.Generic.List[PSObject]]::new()
    foreach ($n in $nodes) {
        $nameMatch = ($Name -eq '') -or ($n.Name -like "*$Name*")
        $roleMatch = ($Role -eq '') -or ($n.Role -like "*$Role*")
        if ($nameMatch -and $roleMatch) {
            $results.Add([PSCustomObject]@{
                Ac       = $n.Ac
                Name     = $n.Name
                Role     = $n.Role
                States   = $n.States
                Children = $n.Children
                Depth    = $n.Depth
            })
        }
    }
    return $results.ToArray()
}

Write-Verbose "Jab-Bridge.ps1 로드 완료. Initialize-Jab 를 호출해 연결하세요."
