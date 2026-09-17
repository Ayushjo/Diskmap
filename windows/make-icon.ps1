Add-Type -AssemblyName System.Drawing
$bmp = New-Object System.Drawing.Bitmap 256, 256
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.Clear([System.Drawing.Color]::FromArgb(30, 34, 42))
$rects = @(
  @{X=12;  Y=12;  W=120; H=120; C='#4E9AEF'},
  @{X=136; Y=12;  W=108; H=64;  C='#F2A93B'},
  @{X=136; Y=80;  W=108; H=52;  C='#7BC47F'},
  @{X=12;  Y=136; W=64;  H=52;  C='#E05D5D'},
  @{X=80;  Y=136; W=52;  H=52;  C='#9B7BD3'},
  @{X=136; Y=136; W=108; H=52;  C='#4ECDC4'},
  @{X=12;  Y=192; W=84;  H=52;  C='#F2A93B'},
  @{X=100; Y=192; W=68;  H=52;  C='#7BC47F'},
  @{X=172; Y=192; W=72;  H=52;  C='#4E9AEF'}
)
$stroke = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(30, 34, 42)), 4
foreach ($r in $rects) {
  $col = [System.Drawing.ColorTranslator]::FromHtml($r.C)
  $brush = New-Object System.Drawing.SolidBrush $col
  $g.FillRectangle($brush, $r.X, $r.Y, $r.W, $r.H)
  $g.DrawRectangle($stroke, $r.X, $r.Y, $r.W, $r.H)
  $brush.Dispose()
}
$g.Dispose()
$stroke.Dispose()
$icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
$fs = [System.IO.File]::Create("$PSScriptRoot\app\DiskMap.App\app.ico")
$icon.Save($fs)
$fs.Close()
$bmp.Dispose()
Write-Output "icon written"
