Add-Type -AssemblyName System.Drawing
# The same generated mark as the macOS app; refresh docs/icon/variant-4.png
# with Sources/IconRender before regenerating the Windows icon.
$source = Join-Path $PSScriptRoot '..\docs\icon\variant-4.png'
$bitmap = New-Object System.Drawing.Bitmap $source
try {
  $icon = [System.Drawing.Icon]::FromHandle($bitmap.GetHicon())
  $output = Join-Path $PSScriptRoot 'app\DiskMap.App\app.ico'
  $stream = [System.IO.File]::Create($output)
  try { $icon.Save($stream) } finally { $stream.Close(); $icon.Dispose() }
} finally { $bitmap.Dispose() }
Write-Output 'freedisk.space icon written'
