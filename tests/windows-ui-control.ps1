param(
    [ValidateSet(0, 1)]
    [int]$Mode = 0,
    [switch]$InspectOnly,
    [string]$OutputPath = "$env:TEMP\Auvol-test-status.txt",
    [string]$ScreenshotPath = ""
)

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class NativeWindowBounds {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);

    [DllImport("user32.dll")]
    public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
}
'@

[void][NativeWindowBounds]::SetThreadDpiAwarenessContext([IntPtr](-4))

function Find-AutomationId {
    param(
        [System.Windows.Automation.AutomationElement]$Root,
        [string]$Id
    )
    $condition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty,
        $Id
    )
    return $Root.FindFirst(
        [System.Windows.Automation.TreeScope]::Descendants,
        $condition
    )
}

try {
    $process = Get-Process Auvol -ErrorAction Stop |
        Sort-Object StartTime -Descending |
        Select-Object -First 1
    $processCondition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ProcessIdProperty,
        $process.Id
    )

    $window = $null
    for ($attempt = 0; $attempt -lt 20 -and -not $window; $attempt++) {
        $window = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst(
            [System.Windows.Automation.TreeScope]::Children,
            $processCondition
        )
        if (-not $window) { Start-Sleep -Milliseconds 250 }
    }
    if (-not $window) { throw "Auvol WinUI window was not found" }

    if (-not $InspectOnly) {
        $modeId = if ($Mode -eq 0) { "SendToMac" } else { "ReceiveFromMac" }
        $modeButton = Find-AutomationId -Root $window -Id $modeId
        if (-not $modeButton) { throw "Direction control '$modeId' was not found" }
        $pattern = $null
        if ($modeButton.TryGetCurrentPattern(
            [System.Windows.Automation.TogglePattern]::Pattern,
            [ref]$pattern)) {
            if ($pattern.Current.ToggleState -ne
                [System.Windows.Automation.ToggleState]::On) {
                $pattern.Toggle()
            }
        } else {
            throw "Direction control '$modeId' does not support TogglePattern"
        }
        Start-Sleep -Milliseconds 500
    }

    $all = $window.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition
    )
    $controls = foreach ($element in $all) {
        if ($element.Current.AutomationId -or $element.Current.Name) {
            [PSCustomObject]@{
                Name = $element.Current.Name
                AutomationId = $element.Current.AutomationId
                ControlType = $element.Current.ControlType.ProgrammaticName
                Enabled = $element.Current.IsEnabled
            }
        }
    }

    $topWindows = foreach ($element in
        [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
            [System.Windows.Automation.TreeScope]::Children,
            [System.Windows.Automation.Condition]::TrueCondition)) {
        [PSCustomObject]@{
            Name = $element.Current.Name
            ProcessId = $element.Current.ProcessId
            ClassName = $element.Current.ClassName
            Bounds = $element.Current.BoundingRectangle.ToString()
        }
    }

    if ($ScreenshotPath) {
        Add-Type -AssemblyName System.Drawing
        $native = New-Object NativeWindowBounds+RECT
        $handle = [IntPtr]$window.Current.NativeWindowHandle
        if (-not [NativeWindowBounds]::GetWindowRect($handle, [ref]$native)) {
            throw "Could not read the native WinUI window bounds"
        }
        $width = [Math]::Max(1, $native.Right - $native.Left)
        $height = [Math]::Max(1, $native.Bottom - $native.Top)
        $bitmap = New-Object System.Drawing.Bitmap($width, $height)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.CopyFromScreen(
                $native.Left, $native.Top, 0, 0,
                (New-Object System.Drawing.Size($width, $height))
            )
            $bitmap.Save($ScreenshotPath, [System.Drawing.Imaging.ImageFormat]::Png)
        } finally {
            $graphics.Dispose()
            $bitmap.Dispose()
        }
    }

    [PSCustomObject]@{
        ProcessId = $process.Id
        WindowName = $window.Current.Name
        Bounds = $window.Current.BoundingRectangle.ToString()
        Controls = $controls
        TopWindows = $topWindows
    } | ConvertTo-Json -Depth 5 | Set-Content -Path $OutputPath -Encoding UTF8
} catch {
    $_.Exception.ToString() | Set-Content -Path $OutputPath -Encoding UTF8
    throw
}
