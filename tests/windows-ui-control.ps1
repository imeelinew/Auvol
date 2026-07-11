param(
    [ValidateSet(0, 1)]
    [int]$Mode,
    [switch]$InspectOnly,
    [string]$OutputPath = "$env:TEMP\Auvol-test-status.txt"
)

Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class AuvolUI {
    public delegate bool EnumWindowsProc(IntPtr window, IntPtr parameter);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetClassName(IntPtr window, StringBuilder text,
                                          int capacity);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr FindWindow(string className, string windowName);

    [DllImport("user32.dll")]
    public static extern IntPtr GetDlgItem(IntPtr window, int id);

    [DllImport("user32.dll")]
    public static extern IntPtr SendMessage(IntPtr window, uint message,
                                            IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr window, StringBuilder text,
                                           int capacity);
}
'@

try {
    $script:auvolWindow = [IntPtr]::Zero
    $finder = [AuvolUI+EnumWindowsProc]{
        param($handle, $parameter)
        $class = New-Object Text.StringBuilder 256
        [void][AuvolUI]::GetClassName($handle, $class, 256)
        if ($class.ToString() -eq "AuvolMain") {
            $script:auvolWindow = $handle
            return $false
        }
        return $true
    }
    [void][AuvolUI]::EnumWindows($finder, [IntPtr]::Zero)
    $window = $script:auvolWindow
    if ($window -eq [IntPtr]::Zero) { throw "Auvol window was not found" }
    if (-not $InspectOnly) {
        $combo = [AuvolUI]::GetDlgItem($window, 106)
        [void][AuvolUI]::SendMessage($combo, 0x014E, [IntPtr]$Mode, [IntPtr]::Zero)
        $command = 106 + (1 -shl 16) # CBN_SELCHANGE
        [void][AuvolUI]::SendMessage($window, 0x0111, [IntPtr]$command, $combo)
        Start-Sleep -Seconds 3
    }

    $text = New-Object Text.StringBuilder 512
    [void][AuvolUI]::GetWindowText([AuvolUI]::GetDlgItem($window, 104), $text, 512)
    $status = $text.ToString()
    [void]$text.Clear()
    [void][AuvolUI]::GetWindowText([AuvolUI]::GetDlgItem($window, 105), $text, 512)
    Set-Content -Path $OutputPath -Encoding UTF8 -Value @($status, $text.ToString())
} catch {
    $session = (Get-Process -Id $PID).SessionId
    $windows = New-Object Collections.Generic.List[string]
    $callback = [AuvolUI+EnumWindowsProc]{
        param($handle, $parameter)
        $class = New-Object Text.StringBuilder 256
        $title = New-Object Text.StringBuilder 256
        [void][AuvolUI]::GetClassName($handle, $class, 256)
        [void][AuvolUI]::GetWindowText($handle, $title, 256)
        $windows.Add(("{0}: {1}" -f $class.ToString(), $title.ToString()))
        return $true
    }
    [void][AuvolUI]::EnumWindows($callback, [IntPtr]::Zero)
    Set-Content -Path $OutputPath -Encoding UTF8 -Value @(
        "Helper session: $session"
        $_.Exception.ToString()
        $windows
    )
    throw
}
