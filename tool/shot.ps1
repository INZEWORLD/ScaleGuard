param(
  [string]$Path = 'C:\Temp\shot.png',
  [int]$X = -1, [int]$Y = -1, [int]$W = 0, [int]$H = 0
)
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
if ($W -le 0 -or $H -le 0) {
  $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
  $X = $b.X; $Y = $b.Y; $W = $b.Width; $H = $b.Height
}
$bmp = New-Object System.Drawing.Bitmap $W, $H
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($X, $Y, 0, 0, $bmp.Size)
$dir = Split-Path -Parent $Path
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
$bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
Write-Output $Path
