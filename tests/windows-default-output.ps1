param(
    [Parameter(Mandatory = $true)]
    [string]$EndpointId
)

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public enum AudioRole { Console = 0, Multimedia = 1, Communications = 2 }

[ComImport]
[Guid("f8679f50-850a-41cf-9c72-430f290290c8")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IPolicyConfig {
    [PreserveSig] int GetMixFormat(string a, IntPtr b);
    [PreserveSig] int GetDeviceFormat(string a, int b, IntPtr c);
    [PreserveSig] int ResetDeviceFormat(string a);
    [PreserveSig] int SetDeviceFormat(string a, IntPtr b, IntPtr c);
    [PreserveSig] int GetProcessingPeriod(string a, int b, IntPtr c, IntPtr d);
    [PreserveSig] int SetProcessingPeriod(string a, IntPtr b);
    [PreserveSig] int GetShareMode(string a, IntPtr b);
    [PreserveSig] int SetShareMode(string a, IntPtr b);
    [PreserveSig] int GetPropertyValue(string a, IntPtr b, IntPtr c);
    [PreserveSig] int SetPropertyValue(string a, IntPtr b, IntPtr c);
    [PreserveSig] int SetDefaultEndpoint(
        [MarshalAs(UnmanagedType.LPWStr)] string id, AudioRole role);
    [PreserveSig] int SetEndpointVisibility(string a, int b);
}

[ComImport]
[Guid("870af99c-171d-4f9e-af0d-e63df40c2bc9")]
class PolicyConfigClient {}

public static class DefaultAudioEndpoint {
    public static void Set(string id) {
        var policy = (IPolicyConfig)new PolicyConfigClient();
        for (int role = 0; role < 3; role++) {
            int result = policy.SetDefaultEndpoint(id, (AudioRole)role);
            if (result != 0) Marshal.ThrowExceptionForHR(result);
        }
    }
}
'@

[DefaultAudioEndpoint]::Set($EndpointId)
