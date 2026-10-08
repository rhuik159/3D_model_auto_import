#Requires -RunAsAdministrator
$code = @'
using System;
using System.Runtime.InteropServices;
public class DeviceInstaller {
    [DllImport("setupapi.dll", SetLastError=true, CharSet=CharSet.Auto)]
    public static extern IntPtr SetupDiCreateDeviceInfoList(ref Guid ClassGuid, IntPtr hwndParent);
    [DllImport("setupapi.dll", SetLastError=true, CharSet=CharSet.Auto)]
    public static extern bool SetupDiCreateDeviceInfo(IntPtr DeviceInfoSet, string DeviceName, ref Guid ClassGuid, string DeviceDescription, IntPtr hwndParent, int CreationFlags, ref SP_DEVINFO_DATA DeviceInfoData);
    [DllImport("setupapi.dll", SetLastError=true, CharSet=CharSet.Auto)]
    public static extern bool SetupDiSetDeviceRegistryProperty(IntPtr DeviceInfoSet, ref SP_DEVINFO_DATA DeviceInfoData, int Property, byte[] PropertyBuffer, int PropertyBufferSize);
    [DllImport("setupapi.dll", SetLastError=true)]
    public static extern bool SetupDiCallClassInstaller(int InstallFunction, IntPtr DeviceInfoSet, ref SP_DEVINFO_DATA DeviceInfoData);
    [DllImport("setupapi.dll", SetLastError=true)]
    public static extern bool SetupDiDestroyDeviceInfoList(IntPtr DeviceInfoSet);
    [StructLayout(LayoutKind.Sequential)]
    public struct SP_DEVINFO_DATA {
        public int cbSize;
        public Guid ClassGuid;
        public int DevInst;
        public IntPtr Reserved;
    }
    public static int Create(string hwid) {
        Guid guid = new Guid("{4d36e968-e325-11ce-bfc1-08002be10318}");
        IntPtr devList = SetupDiCreateDeviceInfoList(ref guid, IntPtr.Zero);
        if (devList == (IntPtr)(-1)) return Marshal.GetLastWin32Error();
        var devData = new SP_DEVINFO_DATA();
        devData.cbSize = Marshal.SizeOf(devData);
        if (!SetupDiCreateDeviceInfo(devList, "IddSampleDriver", ref guid, "IddSampleDriver Virtual Display", IntPtr.Zero, 0x1, ref devData))
            return Marshal.GetLastWin32Error();
        byte[] buf = System.Text.Encoding.Unicode.GetBytes(hwid + "\0\0");
        if (!SetupDiSetDeviceRegistryProperty(devList, ref devData, 1, buf, buf.Length))
            return Marshal.GetLastWin32Error();
        if (!SetupDiCallClassInstaller(0x19, devList, ref devData))
            return Marshal.GetLastWin32Error();
        SetupDiDestroyDeviceInfoList(devList);
        return 0;
    }
}
'@
Add-Type -TypeDefinition $code
$result = [DeviceInstaller]::Create("Root\IddSampleDriver")
if ($result -eq 0) {
    Write-Host "SUCCESS: Virtual display device created." -ForegroundColor Green
} else {
    Write-Host "FAILED (error code: $result)" -ForegroundColor Red
}

Write-Host ""
Write-Host "=== Display devices ==="
Get-PnpDevice -Class Display | Select-Object Status, FriendlyName
