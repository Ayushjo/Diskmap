param(
    [Parameter(Mandatory=$true)][string]$Out,
    [string]$ProcessName = "DiskMap.App",
    [int]$SettleSeconds = 2
)
# Brings the app's main window forward, waits, captures it to a PNG.
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Win32Cap {
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
    public struct RECT { public int Left, Top, Right, Bottom; }
}
"@
$p = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
    Where-Object { $_.MainWindowHandle -ne 0 } |
    Sort-Object StartTime -Descending | Select-Object -First 1
if (-not $p) { Write-Error "no $ProcessName window"; exit 1 }
[Win32Cap]::ShowWindow($p.MainWindowHandle, 9) | Out-Null   # SW_RESTORE
# The app runs elevated; z-order APIs are UIPI-gated from here. Foreground
# rights are a different mechanism — borrow the foreground thread's.
$fg = [Win32Cap]::GetForegroundWindow()
$fgThread = [Win32Cap]::GetWindowThreadProcessId($fg, [ref]([uint32]$pidDummy = 0))
$me = [Win32Cap]::GetCurrentThreadId()
[Win32Cap]::AttachThreadInput($me, $fgThread, $true) | Out-Null
[Win32Cap]::BringWindowToTop($p.MainWindowHandle) | Out-Null
[Win32Cap]::SetForegroundWindow($p.MainWindowHandle) | Out-Null
[Win32Cap]::AttachThreadInput($me, $fgThread, $false) | Out-Null
Start-Sleep -Seconds $SettleSeconds
$r = New-Object Win32Cap+RECT
[Win32Cap]::GetWindowRect($p.MainWindowHandle, [ref]$r) | Out-Null
$w = $r.Right - $r.Left; $h = $r.Bottom - $r.Top
$bmp = New-Object System.Drawing.Bitmap $w, $h
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object System.Drawing.Size $w, $h))
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
Write-Output "captured ${w}x${h} -> $Out"
