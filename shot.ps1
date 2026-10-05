Add-Type -AssemblyName System.Drawing, System.Windows.Forms, UIAutomationClient, UIAutomationTypes
$sig = @'
using System;
using System.Runtime.InteropServices;
public class W {
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, int flags);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
    [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int hh, bool repaint);
    public struct RECT { public int Left, Top, Right, Bottom; }
}
'@
Add-Type -TypeDefinition $sig -ReferencedAssemblies System.Drawing
$p = Get-Process DiskMap.App -ErrorAction SilentlyContinue
if (-not $p -or $p.MainWindowHandle -eq 0) { Write-Output "no window"; exit }
[W]::ShowWindow($p.MainWindowHandle, 9) | Out-Null
# 1400 physical px wide — well inside the 1536 screen
[W]::MoveWindow($p.MainWindowHandle, 20, 20, 1400, 720, $true) | Out-Null
[W]::SetForegroundWindow($p.MainWindowHandle) | Out-Null
Start-Sleep -Milliseconds 700
# UIA reports the real on-screen rect regardless of DPI context
$root = [System.Windows.Automation.AutomationElement]::RootElement
$cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, "DiskMap")
$win = $root.FindFirst([System.Windows.Automation.TreeScope]::Children, $cond)
$r = $win.Current.BoundingRectangle
$w = [int]$r.Width; $h = [int]$r.Height
Write-Output "uia rect $([int]$r.X),$([int]$r.Y) ${w}x${h}"
if ($w -gt 1900) { $w = 1900 }
$bmp = New-Object System.Drawing.Bitmap $w, $h
$g = [System.Drawing.Graphics]::FromImage($bmp)
$ok = [W]::PrintWindow($p.MainWindowHandle, $g.GetHdc(), 2)
$g.ReleaseHdc()
$bmp.Save('C:\Users\kkfah\Documents\codes\Diskmap\shot.png')
$g.Dispose(); $bmp.Dispose()
Write-Output "PrintWindow=$ok"
