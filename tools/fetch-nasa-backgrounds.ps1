# Downloads public-domain NASA photos and processes them into theme backgrounds:
# cover-crop to 1920x1080 + darken for terminal readability.
# Sources are listed in public/backgrounds/CREDITS.md.
# Re-run: pwsh tools/fetch-nasa-backgrounds.ps1
Add-Type -AssemblyName System.Drawing
$ErrorActionPreference = "Stop"
$dst = Join-Path (Split-Path $PSScriptRoot -Parent) "public\backgrounds"
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "gterminal-nasa"
New-Item -ItemType Directory -Force $dst, $tmp | Out-Null
$TW = 1920; $TH = 1080

$jpegCodec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq "image/jpeg" }
$encParams = New-Object System.Drawing.Imaging.EncoderParameters(1)
$encParams.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, 82L)

function Get-NasaImage {
  param($nasaId)
  $dest = Join-Path $tmp "$nasaId.jpg"
  if (Test-Path $dest) { return $dest }
  $assets = Invoke-RestMethod "https://images-api.nasa.gov/asset/$nasaId"
  $links = $assets.collection.items.href
  $pick = ($links | Where-Object { $_ -match "~large\.jpg$" } | Select-Object -First 1)
  if (-not $pick) { $pick = ($links | Where-Object { $_ -match "~orig\.jpg$" } | Select-Object -First 1) }
  if (-not $pick) { throw "$nasaId : no jpg asset found" }
  Invoke-WebRequest $pick -OutFile $dest
  $dest
}

function Process-Image {
  param($inFile, $outName, $anchorX, $anchorY, $darken, $frac = 1.0)
  # anchorX/anchorY: 0..1 position of the crop window within the source (0.5 = center)
  # frac: shrink the crop window to zoom in (1.0 = largest cover window)
  $img = [System.Drawing.Image]::FromFile($inFile)
  $iw = $img.Width; $ih = $img.Height
  $cw = $iw; $ch = [int]($cw * $TH / $TW)
  if ($ch -gt $ih) { $ch = $ih; $cw = [int]($ch * $TW / $TH) }
  $cw = [int]($cw * $frac); $ch = [int]($ch * $frac)
  $cx = [int](($iw - $cw) * $anchorX); $cy = [int](($ih - $ch) * $anchorY)
  $bmp = New-Object System.Drawing.Bitmap($TW, $TH)
  $gfx = [System.Drawing.Graphics]::FromImage($bmp)
  $gfx.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $srcRect = New-Object System.Drawing.Rectangle($cx, $cy, $cw, $ch)
  $dstRect = New-Object System.Drawing.Rectangle(0, 0, $TW, $TH)
  $gfx.DrawImage($img, $dstRect, $srcRect, [System.Drawing.GraphicsUnit]::Pixel)
  $ov = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb([int](255 * $darken), 0, 0, 0))
  $gfx.FillRectangle($ov, $dstRect); $ov.Dispose()
  $gfx.Dispose(); $img.Dispose()
  $p = Join-Path $dst $outName
  $bmp.Save($p, $jpegCodec, $encParams)
  $bmp.Dispose()
  "$outName  $([math]::Round((Get-Item $p).Length/1KB))KB"
}

# "A Hubble Sky Full of Stars" -- globular cluster IC 4499
Process-Image (Get-NasaImage "GSFC_20171208_Archive_e000256") "hyperspace.jpg" 0.5 0.4 0.52
# Namib Desert sand sea from the ISS, zoomed into the orange dune field
Process-Image (Get-NasaImage "iss073e0511487") "dune.jpg" 1.0 0.3 0.45 0.55
