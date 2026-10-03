Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$root = [System.Windows.Automation.AutomationElement]::RootElement
$cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, "DiskMap")
$win = $root.FindFirst([System.Windows.Automation.TreeScope]::Children, $cond)
if (-not $win) { Write-Output "no window"; exit }
function Walk($el, $depth) {
    if ($depth -gt 7) { return }
    $r = $el.Current.BoundingRectangle
    $t = $el.Current.ControlType.ProgrammaticName
    $n = $el.Current.Name
    if ($n.Length -gt 40) { $n = $n.Substring(0, 40) }
    Write-Output ("  " * $depth + "$t [$([int]$r.X),$([int]$r.Y) $([int]$r.Width)x$([int]$r.Height)] '$n'")
    $child = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetFirstChild($el)
    while ($child) {
        Walk $child ($depth + 1)
        $child = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetNextSibling($child)
    }
}
Walk $win 0
