#Requires -Version 5.1
# JAB raw 구조체 덤프 - 넓은 범위로 실제 레이아웃 확정
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public class JabRaw {
    private const string DLL = @"C:\MentorGraphics\EEVX.2.14.1\SDD_HOME\common\win64\jre\default\bin\windowsaccessbridge-64.dll";
    [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)] public static extern void Windows_run();
    [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)] [return:MarshalAs(UnmanagedType.Bool)]
    public static extern bool isJavaWindow(IntPtr hwnd);
    [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)] [return:MarshalAs(UnmanagedType.Bool)]
    public static extern bool getAccessibleContextFromHWND(IntPtr hwnd, out int vmID, out long ac);
    [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)] [return:MarshalAs(UnmanagedType.Bool)]
    public static extern bool getAccessibleContextInfo(int vmID, long ac, IntPtr buf);
    [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
    public static extern long getAccessibleChildFromContext(int vmID, long ac, int index);
    [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
    public static extern void releaseJavaObject(int vmID, long ac);

    [StructLayout(LayoutKind.Sequential)]
    public struct MSG { public IntPtr h; public uint m; public IntPtr w,l; public uint t; public int x,y; }
    [DllImport("user32.dll")] public static extern bool PeekMessage(out MSG m,IntPtr h,uint f,uint t,uint r);
    [DllImport("user32.dll")] public static extern bool TranslateMessage(ref MSG m);
    [DllImport("user32.dll")] public static extern IntPtr DispatchMessage(ref MSG m);
    public static void Pump(int n) { MSG m; for(int i=0;i<n;i++) if(PeekMessage(out m,IntPtr.Zero,0,0,1)){TranslateMessage(ref m);DispatchMessage(ref m);} }
}
'@ -ErrorAction Stop

[JabRaw]::Windows_run(); [JabRaw]::Pump(100); Start-Sleep -Milliseconds 1000; [JabRaw]::Pump(100)

$proc = Get-Process -Name 'xDMLibraryClient' -EA SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
$hwnd = [IntPtr]$proc.MainWindowHandle
$vmId = 0; $ac = 0L
$null = [JabRaw]::getAccessibleContextFromHWND($hwnd, [ref]$vmId, [ref]$ac)
Write-Host "vmId=$vmId  ac=0x$($ac.ToString('X'))" -ForegroundColor Green

function Dump-Wide {
    param([int]$vmId, [long]$ac, [string]$label, [int]$totalBytes = 8192)
    $buf = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($totalBytes)
    for ($i = 0; $i -lt $totalBytes; $i++) {
        [System.Runtime.InteropServices.Marshal]::WriteByte($buf, $i, 0xAA)
    }
    $ok = [JabRaw]::getAccessibleContextInfo($vmId, $ac, $buf)
    $bytes = New-Object byte[] $totalBytes
    [System.Runtime.InteropServices.Marshal]::Copy($buf, $bytes, 0, $totalBytes)
    [System.Runtime.InteropServices.Marshal]::FreeHGlobal($buf)

    Write-Host "`n=== $label  ok=$ok ===" -ForegroundColor Yellow

    # 변경된(0xAA가 아닌) 구간 모두 찾기
    $inRun = $false; $runStart = 0
    for ($i = 0; $i -le $totalBytes; $i++) {
        $changed = ($i -lt $totalBytes) -and ($bytes[$i] -ne 0xAA)
        if ($changed -and -not $inRun) { $inRun = $true; $runStart = $i }
        elseif (-not $changed -and $inRun) {
            $inRun = $false
            $len = $i - $runStart
            # 이 구간의 unicode 시도
            $aligned = $runStart - ($runStart % 2)
            $uniLen = [Math]::Min(($i - $aligned + 1) -band -2, $totalBytes - $aligned)
            $s = [System.Text.Encoding]::Unicode.GetString($bytes, $aligned, $uniLen).TrimEnd([char]0)
            Write-Host ("  changed[0x{0:X4}..0x{1:X4}] len={2,-4}  uni='{3}'" -f $runStart, ($i-1), $len, $s)
        }
    }

    # 전체 hex dump (변경된 영역만)
    Write-Host "`n  Hex (0xAA = 변경없음):"
    for ($row = 0; $row -lt ($totalBytes / 16); $row++) {
        $allAA = $true
        for ($col = 0; $col -lt 16; $col++) { if ($bytes[$row*16+$col] -ne 0xAA) { $allAA = $false; break } }
        if ($allAA) { continue }
        $hex = ''; $asc = ''
        for ($col = 0; $col -lt 16; $col++) {
            $b = $bytes[$row*16+$col]
            $hex += $b.ToString('X2') + ' '
            $asc += if ($b -ge 0x20 -and $b -lt 0x7F) { [char]$b } else { '.' }
        }
        Write-Host ("  {0:X4}  {1} {2}" -f ($row*16), $hex, $asc)
    }
}

# 루트 (창 자체)
Dump-Wide -vmId $vmId -ac $ac -label "Root (frame)"

# 자식 탐색 - 이름이 있는 것 찾기
Write-Host "`n=== 자식 탐색 ===" -ForegroundColor Cyan
$buf2 = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(8192)

function Get-ShortInfo {
    param([int]$vmId,[long]$ac,[int]$depth,[string]$indent)
    if ($depth -gt 6) { Write-Host "$indent  [깊이제한]"; return }
    for ($i = 0; $i -lt 8192; $i++) { [System.Runtime.InteropServices.Marshal]::WriteByte($buf2, $i, 0xAA) }
    $ok = [JabRaw]::getAccessibleContextInfo($vmId, $ac, $buf2)
    if (-not $ok) { return }

    $bytes2 = New-Object byte[] 8192
    [System.Runtime.InteropServices.Marshal]::Copy($buf2, $bytes2, 0, 8192)

    # 처음 비어있지 않은 unicode 문자열 찾기 (최대 2048 바이트씩 탐색)
    $label = ''
    foreach ($off in @(0, 512, 1024, 1536, 2048, 2560, 3072, 3584)) {
        $s = [System.Text.Encoding]::Unicode.GetString($bytes2, $off, [Math]::Min(512, 8192-$off)).TrimEnd([char]0)
        if ($s.Length -gt 0) { $label += "[$off]='$s' "; if ($label.Length -gt 60) { break } }
    }

    # childrenCount 는 정수 - 큰 offset 에 있을 것, 스캔
    $nChildren = 0
    for ($off = 6144; $off -lt 8180; $off += 4) {
        $v = [BitConverter]::ToInt32($bytes2, $off)
        if ($v -ge 0 -and $v -le 200 -and $bytes2[$off] -ne 0xAA) {
            $nChildren = $v; break
        }
    }

    Write-Host ("{0}ac=0x{1:X}  {2}  ch~{3}" -f $indent, $ac, $label, $nChildren)

    # 자식 탐색
    for ($ci = 0; $ci -lt [Math]::Min($nChildren, 10); $ci++) {
        $ch = [JabRaw]::getAccessibleChildFromContext($vmId, $ac, $ci)
        if ($ch -ne 0) {
            Get-ShortInfo -vmId $vmId -ac $ch -depth ($depth+1) -indent ($indent+'  ')
            [JabRaw]::releaseJavaObject($vmId, $ch)
        }
    }
}

Get-ShortInfo -vmId $vmId -ac $ac -depth 0 -indent ''
[System.Runtime.InteropServices.Marshal]::FreeHGlobal($buf2)
[JabRaw]::releaseJavaObject($vmId, $ac)
