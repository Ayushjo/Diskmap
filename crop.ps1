Add-Type -AssemblyName System.Drawing
$src = [System.Drawing.Bitmap]::FromFile('C:\Users\kkfah\Documents\codes\Diskmap\shot.png')
# Top bar area, right half
$src.Dispose() | Out-Null
$src = [System.Drawing.Bitmap]::FromFile('C:\Users\kkfah\Documents\codes\Diskmap\page-snapshots.png')
$rect = New-Object System.Drawing.Rectangle(430, 430, 800, 200)
$crop = $src.Clone($rect, $src.PixelFormat)
$crop.Save('C:\Users\kkfah\Documents\codes\Diskmap\crop.png')
$crop.Dispose(); $src.Dispose()
Write-Output "cropped"
