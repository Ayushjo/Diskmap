Add-Type -AssemblyName System.Drawing, System.Windows.Forms, UIAutomationClient, UIAutomationTypes
$sig = @'
using System;
using System.Runtime.InteropServices;
public class W {
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, int flags);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
    [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int hh, bool repaint);
}
'@
Add-Type -TypeDefinition $sig -ReferencedAssemblies System.Drawing

$exe = 'C:\Users\kkfah\Documents\codes\Diskmap\windows\app\DiskMap.App\bin\Debug\net10.0-windows\DiskMap.App.exe'
$pages = $args
foreach ($page in $pages) {
    Stop-Process -Name DiskMap.App -Force -ErrorAction SilentlyContinue
    $env:__COMPAT_LAYER = 'RunAsInvoker'
    $env:DISKMAP_AUTOSCAN = 'C:\Users\kkfah\Documents\codes\Diskmap'
    $env:DISKMAP_PAGE = $page
    Start-Process $exe
    Start-Sleep -Seconds 8
    $p = Get-Process DiskMap.App -ErrorAction SilentlyContinue
    if (-not $p -or $p.MainWindowHandle -eq 0) { Write-Output "$page -> no window"; continue }
    [W]::ShowWindow($p.MainWindowHandle, 9) | Out-Null
    [W]::MoveWindow($p.MainWindowHandle, 20, 20, 1400, 720, $true) | Out-Null
    Start-Sleep -Milliseconds 600
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, "DiskMap")
    $win = $root.FindFirst([System.Windows.Automation.TreeScope]::Children, $cond)
    $r = $win.Current.BoundingRectangle
    $w = [int]$r.Width; $h = [int]$r.Height
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    [W]::PrintWindow($p.MainWindowHandle, $g.GetHdc(), 2) | Out-Null
    $g.ReleaseHdc()
    $safe = ($page -replace '[^a-zA-Z0-9]', '-').ToLower()
    $bmp.Save("C:\Users\kkfah\Documents\codes\Diskmap\page-$safe.png")
    $g.Dispose(); $bmp.Dispose()
    Write-Output "$page -> page-$safe.png"
}
Stop-Process -Name DiskMap.App -Force -ErrorAction SilentlyContinue
