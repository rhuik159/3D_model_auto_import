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

# ============================================================ C# 타입 정의
if (-not ('Jab.Bridge' -as [type])) {
    Add-Type -TypeDefinition @'
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
        private const string DLL = @"C:\MentorGraphics\EEVX.2.14.1\SDD_HOME\common\win64\jre\default\bin\windowsaccessbridge-64.dll";

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

        // 액션 목록
        [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool getAccessibleActions(
            int vmID, long ac, out AccessibleActions actions);

        // 액션 실행
        [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool doAccessibleActions(
            int vmID, long ac, ref AccessibleActionsToDo actionsToDo, out int failure);

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
    }
}
'@ -ErrorAction Stop
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

    [Jab.Bridge]::Windows_run()
    [Jab.Win32]::PumpMessages(50)
    Start-Sleep -Milliseconds 300

    if ($Hwnd -eq [IntPtr]::Zero) {
        $proc = @(Get-Process -Name 'xDMLibraryClient' -ErrorAction SilentlyContinue |
                  Where-Object { $_.MainWindowHandle -ne 0 })
        if ($proc.Count -eq 0) { throw "Cockpit 프로세스를 찾을 수 없습니다." }
        $Hwnd = [IntPtr]$proc[0].MainWindowHandle
        Write-Verbose "자동 감지된 HWND: 0x$($Hwnd.ToString('X'))  PID $($proc[0].Id)"
    }

    if (-not [Jab.Bridge]::isJavaWindow($Hwnd)) {
        throw "HWND 0x$($Hwnd.ToString('X')) 는 Java 창이 아닙니다. JAB 가 활성화됐는지 확인하세요."
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
    if (-not [Jab.Bridge]::getAccessibleContextInfo($VmId, $Ac, [ref]$info)) {
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
    if ($null -eq $info -or $info.childrenCount -le 0) { return @() }

    $children = [System.Collections.Generic.List[long]]::new()
    for ($i = 0; $i -lt $info.childrenCount; $i++) {
        $child = [Jab.Bridge]::getAccessibleChildFromContext($VmId, $Ac, $i)
        if ($child -ne 0) { $children.Add($child) }
    }
    $children.ToArray()
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
    $actions = New-Object Jab.AccessibleActions
    if (-not [Jab.Bridge]::getAccessibleActions($VmId, $Ac, [ref]$actions)) {
        return @()
    }
    $result = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $actions.actionsCount; $i++) {
        $result.Add($actions.actionInfo[$i].name)
    }
    , $result.ToArray()   # 쉼표로 배열 래핑 - 단일 항목도 배열로 반환
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

    if ($ActionName -eq '') {
        $avail = Get-JabActions -Ac $Ac -VmId $VmId
        if ($avail.Count -eq 0) { throw "이 컴포넌트에 액션이 없습니다." }
        $ActionName = $avail[0]
    }

    $todo = New-Object Jab.AccessibleActionsToDo
    $todo.actionsCount = 1
    $todo.actions = New-Object 'Jab.AccessibleActionInfo[]' 32
    $todo.actions[0] = New-Object Jab.AccessibleActionInfo
    $todo.actions[0].name = $ActionName

    $failure = 0
    $ok = [Jab.Bridge]::doAccessibleActions($VmId, $Ac, [ref]$todo, [ref]$failure)
    if (-not $ok) { throw "doAccessibleActions 실패 (failure=$failure, action='$ActionName')" }
    [Jab.Win32]::PumpMessages(10)
    $true
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
    #>
    param(
        [long]$Ac = $script:JabRootAc,
        [string]$Name = '',
        [string]$Role = '',
        [int]$MaxDepth = 10,
        [switch]$All,
        [int]$VmId = $script:JabVmId,
        [int]$_Depth = 0
    )
    _AssertInit

    $results = [System.Collections.Generic.List[PSObject]]::new()

    function _Search {
        param([long]$node, [int]$depth)
        if ($depth -gt $MaxDepth) { return }

        $info = Get-JabContextInfo -Ac $node -VmId $VmId
        if ($null -eq $info) { return }

        $nameMatch = ($Name -eq '') -or ($info.name -like "*$Name*")
        $roleMatch = ($Role -eq '') -or ($info.role_en_US -like "*$Role*")

        if ($nameMatch -and $roleMatch) {
            $results.Add([PSCustomObject]@{
                Ac          = $node
                Name        = $info.name
                Role        = $info.role_en_US
                States      = $info.states_en_US
                Children    = $info.childrenCount
                Depth       = $depth
            })
            if (-not $All) { return }
        }

        $children = Get-JabChildren -Ac $node -VmId $VmId
        foreach ($child in $children) {
            _Search -node $child -depth ($depth + 1)
            if (-not $All -and $results.Count -gt 0) { return }
        }
    }

    _Search -node $Ac -depth $_Depth

    if ($All) { return $results.ToArray() }
    if ($results.Count -gt 0) { return $results[0] }
    return $null
}

Write-Verbose "Jab-Bridge.ps1 로드 완료. Initialize-Jab 를 호출해 연결하세요."
