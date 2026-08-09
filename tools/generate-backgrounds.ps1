# Procedural background art generator. Deterministic (seeded) renders of
# 1920x1080 PNGs into public/backgrounds/, referenced by theme bgArt.
# Re-run after tweaking: pwsh tools/generate-backgrounds.ps1
# hyperspace.jpg / dune.jpg are real NASA photos: see tools/fetch-nasa-backgrounds.ps1
# NOTE: PowerShell variables are case-insensitive -- never name a local $w or $h,
# they would clobber the canvas dimensions $W/$H.
Add-Type -AssemblyName System.Drawing
$ErrorActionPreference = "Stop"
$out = Join-Path (Split-Path $PSScriptRoot -Parent) "public\backgrounds"
New-Item -ItemType Directory -Force $out | Out-Null
$W = 1920; $H = 1080

function New-Canvas {
  $bmp = New-Object System.Drawing.Bitmap($W, $H)
  $gg = [System.Drawing.Graphics]::FromImage($bmp)
  $gg.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $bmp
  $gg
}
function C { param($a, $r, $g2, $b) [System.Drawing.Color]::FromArgb($a, $r, $g2, $b) }
function Fill-Vertical {
  param($g, $top, $bottom)
  $rect = New-Object System.Drawing.Rectangle(0, 0, $W, $H)
  $br = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $top, $bottom, 90.0)
  $g.FillRectangle($br, $rect); $br.Dispose()
}
function Glow {
  param($g, $x, $y, $r, $color)
  $path = New-Object System.Drawing.Drawing2D.GraphicsPath
  $path.AddEllipse($x - $r, $y - $r, 2 * $r, 2 * $r)
  $br = New-Object System.Drawing.Drawing2D.PathGradientBrush($path)
  $br.CenterColor = $color
  $br.SurroundColors = @((C 0 $color.R $color.G $color.B))
  $g.FillEllipse($br, $x - $r, $y - $r, 2 * $r, 2 * $r)
  $br.Dispose(); $path.Dispose()
}
function Save {
  param($bmp, $g, $name)
  $g.Dispose()
  $p = Join-Path $out $name
  $bmp.Save($p, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  "$name  $([math]::Round((Get-Item $p).Length/1KB))KB"
}

# ── Blade Runner: skyline, lit windows, fog, rain ──
$rng = New-Object System.Random(2049)
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 10 18 26) (C 255 38 34 34)
Glow $g 500 1130 780 (C 130 255 138 61)    # street-level smog
Glow $g 1250 980 500 (C 70 255 80 120)     # magenta haze
Glow $g 1650 80 420 (C 70 82 224 224)      # cold sign glow
# far skyline (dark towers against the lighter smog)
$x = 0
while ($x -lt $W) {
  $bw = $rng.Next(40, 130); $h2 = $rng.Next(200, 460)
  $b = New-Object System.Drawing.SolidBrush((C 255 6 10 15))
  $g.FillRectangle($b, $x, $H - 300 - $h2, $bw, $h2 + 400); $b.Dispose()
  for ($i = 0; $i -lt ($bw * $h2 / 450); $i++) {
    $wx = $x + $rng.Next(3, $bw - 3); $wy = $H - 300 - $h2 + $rng.Next(5, $h2 + 260)
    $cc = if ($rng.NextDouble() -lt 0.28) { C $rng.Next(90, 230) 255 180 100 } else { C $rng.Next(60, 170) 130 215 235 }
    $b = New-Object System.Drawing.SolidBrush($cc); $g.FillRectangle($b, $wx, $wy, 2, 3); $b.Dispose()
  }
  # occasional neon sign strip on a tower face
  if ($rng.NextDouble() -lt 0.22 -and $bw -gt 60) {
    $nx = $x + $rng.Next(8, $bw - 16); $ny = $H - 300 - $h2 + $rng.Next(20, 200)
    $nc = if ($rng.NextDouble() -lt 0.5) { C 200 255 60 120 } else { C 200 60 220 220 }
    Glow $g ($nx + 3) ($ny + 20) 46 (C 90 $nc.R $nc.G $nc.B)
    $b = New-Object System.Drawing.SolidBrush($nc); $g.FillRectangle($b, $nx, $ny, 6, $rng.Next(24, 70)); $b.Dispose()
  }
  $x += $bw + $rng.Next(2, 16)
}
# near silhouettes (pure black rooftops in front)
$x = -40
while ($x -lt $W) {
  $bw = $rng.Next(120, 320); $h2 = $rng.Next(60, 200)
  $b = New-Object System.Drawing.SolidBrush((C 255 2 4 7))
  $g.FillRectangle($b, $x, $H - $h2, $bw, $h2); $b.Dispose()
  if ($rng.NextDouble() -lt 0.5) {  # rooftop antenna beacon
    $ax = $x + $rng.Next(20, $bw - 20)
    $pen = New-Object System.Drawing.Pen((C 255 2 4 7), 3)
    $g.DrawLine($pen, $ax, $H - $h2, $ax, $H - $h2 - $rng.Next(20, 60)); $pen.Dispose()
    $b = New-Object System.Drawing.SolidBrush((C 220 255 70 70)); $g.FillEllipse($b, $ax - 2, $H - $h2 - $rng.Next(20, 60) - 2, 5, 5); $b.Dispose()
  }
  $x += $bw + $rng.Next(10, 60)
}
# rain
for ($i = 0; $i -lt 1100; $i++) {
  $rx = $rng.Next(0, $W); $ry = $rng.Next(0, $H); $len = $rng.Next(12, 38)
  $pen = New-Object System.Drawing.Pen((C $rng.Next(24, 70) 160 210 230), 1)
  $g.DrawLine($pen, $rx, $ry, $rx - [int]($len * 0.18), $ry + $len); $pen.Dispose()
}
Save $bmp $g "bladerunner.png"

# ── Matrix: falling glyph columns ──
$rng = New-Object System.Random(1999)
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 3 14 7) (C 255 1 5 3)
$font = New-Object System.Drawing.Font("Consolas", 15, [System.Drawing.FontStyle]::Bold)
$dimFont = New-Object System.Drawing.Font("Consolas", 13)
$maxRow = [int]($H / 18)
# faint background layer of static glyphs for depth
for ($i = 0; $i -lt 700; $i++) {
  $ch = [char](0x30A0 + $rng.Next(0, 96))
  $b = New-Object System.Drawing.SolidBrush((C $rng.Next(12, 40) 0 140 55))
  $g.DrawString($ch, $dimFont, $b, $rng.Next(0, $W), $rng.Next(0, $H)); $b.Dispose()
}
# bright falling streams: multiple per column band
$cols = [int]($W / 22)
foreach ($pass in 1, 2) {
  for ($ci = 0; $ci -lt $cols; $ci++) {
    if ($rng.NextDouble() -lt 0.45) { continue }
    $cx = $ci * 22
    $head = $rng.Next(6, $maxRow + 14)
    $len = $rng.Next(10, 42)
    for ($k = 0; $k -lt $len; $k++) {
      $row = $head - $k
      if ($row -lt 0) { break }
      if ($row -gt $maxRow) { continue }
      $ch = [char](0x30A0 + $rng.Next(0, 96))
      if ($rng.NextDouble() -lt 0.3) { $ch = [char](0x30 + $rng.Next(0, 10)) }
      $fade = [math]::Max(0.0, 1.0 - ($k / [double]$len))
      $al = [int](70 + 185 * $fade)
      $gr = [int](160 + 95 * $fade)
      $cc = if ($k -eq 0) { C 250 200 255 200 } elseif ($k -eq 1) { C 230 120 255 140 } else { C $al 0 $gr 70 }
      $b = New-Object System.Drawing.SolidBrush($cc)
      $g.DrawString($ch, $font, $b, $cx, $row * 18); $b.Dispose()
    }
  }
}
$font.Dispose(); $dimFont.Dispose()
# scanlines
for ($y = 0; $y -lt $H; $y += 3) {
  $pen = New-Object System.Drawing.Pen((C 40 0 0 0), 1)
  $g.DrawLine($pen, 0, $y, $W, $y); $pen.Dispose()
}
Save $bmp $g "matrix.png"

# ── Synthwave: striped sun, mountains, perspective grid ──
$rng = New-Object System.Random(1984)
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 24 16 48) (C 255 45 27 66)
$horizon = [int]($H * 0.62)
Glow $g ($W / 2) $horizon 640 (C 70 255 126 219)
# sun with stripe cutouts
$sunR = 230; $sunX = $W / 2; $sunY = $horizon - 40
$rect = New-Object System.Drawing.Rectangle(($sunX - $sunR), ($sunY - $sunR), (2 * $sunR), (2 * $sunR))
$sunBr = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, (C 255 254 222 93), (C 255 255 80 160), 90.0)
$g.FillEllipse($sunBr, $rect); $sunBr.Dispose()
$stripe = New-Object System.Drawing.SolidBrush((C 255 30 20 52))
for ($i = 0; $i -lt 7; $i++) {
  $sy = $sunY + 10 + $i * 30
  $g.FillRectangle($stripe, $sunX - $sunR, $sy, 2 * $sunR, 6 + $i * 2)
}
$stripe.Dispose()
# clip sun below horizon
$b = New-Object System.Drawing.SolidBrush((C 255 26 17 42)); $g.FillRectangle($b, 0, $horizon, $W, $H - $horizon); $b.Dispose()
# mountains
$pts1 = @((New-Object System.Drawing.Point(0, $horizon)))
$mx = 0
while ($mx -lt $W) { $mx += $rng.Next(120, 260); $pts1 += New-Object System.Drawing.Point($mx, ($horizon - $rng.Next(20, 130))) }
$pts1 += New-Object System.Drawing.Point($W, $horizon)
$b = New-Object System.Drawing.SolidBrush((C 255 16 10 30)); $g.FillPolygon($b, $pts1); $b.Dispose()
# grid floor
$vp = $W / 2
for ($i = 0; $i -le 24; $i++) {
  $gx = ($i - 12) * 220
  $pen = New-Object System.Drawing.Pen((C 120 255 126 219), 1)
  $g.DrawLine($pen, $vp + $gx * 0.06, $horizon, $vp + $gx, $H); $pen.Dispose()
}
$gy = $horizon + 4; $step = 4
while ($gy -lt $H) {
  $pen = New-Object System.Drawing.Pen((C 150 255 126 219), 1)
  $g.DrawLine($pen, 0, $gy, $W, $gy); $pen.Dispose()
  $step = [int]($step * 1.35) + 1; $gy += $step
}
Save $bmp $g "synthwave.png"

# ── Hermes: International Klein Blue field, chartreuse registration marks ──
$rng = New-Object System.Random(1960)
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 26 26 252) (C 255 0 0 150)
Glow $g 960 180 700 (C 16 237 255 69)          # faint chartreuse halo up top
foreach ($cx in @(@(0,0), @($W,0), @(0,$H), @($W,$H))) {
  Glow $g $cx[0] $cx[1] 520 (C 80 0 0 90)      # deepen the corners
}
# large circle outlines
$pen = New-Object System.Drawing.Pen((C 150 237 255 69), 2)
$g.DrawEllipse($pen, (1400 - 250), (290 - 250), 500, 500); $pen.Dispose()
$pen = New-Object System.Drawing.Pen((C 55 237 255 69), 1)
$g.DrawEllipse($pen, (1400 - 400), (290 - 400), 800, 800); $pen.Dispose()
# registration cross marks on a loose grid
$pen = New-Object System.Drawing.Pen((C 70 237 255 69), 1)
for ($gx = 120; $gx -lt $W; $gx += 240) {
  for ($gy = 100; $gy -lt $H; $gy += 240) {
    $g.DrawLine($pen, $gx - 7, $gy, $gx + 7, $gy)
    $g.DrawLine($pen, $gx, $gy - 7, $gx, $gy + 7)
  }
}
$pen.Dispose()
# rule lines + accent square at their crossing
$pen = New-Object System.Drawing.Pen((C 100 237 255 69), 1)
$g.DrawLine($pen, 0, 760, $W, 760); $pen.Dispose()
$pen = New-Object System.Drawing.Pen((C 55 237 255 69), 1)
$g.DrawLine($pen, 430, 0, 430, $H); $pen.Dispose()
$b = New-Object System.Drawing.SolidBrush((C 220 237 255 69)); $g.FillRectangle($b, 425, 755, 11, 11); $b.Dispose()
# stars + film grain
for ($i = 0; $i -lt 220; $i++) {
  $b = New-Object System.Drawing.SolidBrush((C $rng.Next(20, 70) 240 245 255))
  $g.FillEllipse($b, $rng.Next(0, $W), $rng.Next(0, $H), $rng.Next(1, 3), $rng.Next(1, 3)); $b.Dispose()
}
for ($i = 0; $i -lt 5000; $i++) {
  $tone = if ($rng.NextDouble() -lt 0.5) { 255 } else { 0 }
  $b = New-Object System.Drawing.SolidBrush((C $rng.Next(6, 16) $tone $tone $tone))
  $g.FillRectangle($b, $rng.Next(0, $W), $rng.Next(0, $H), 1, 1); $b.Dispose()
}
Save $bmp $g "hermes.png"

# ── Nous: cyanotype blueprint diagram on warm paper ──
$rng = New-Object System.Random(1842)
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 251 250 247) (C 255 238 235 228)
# faint drafting grid
$pen = New-Object System.Drawing.Pen((C 12 4 113 169), 1)
for ($gx = 0; $gx -lt $W; $gx += 160) { $g.DrawLine($pen, $gx, 0, $gx, $H) }
for ($gy = 0; $gy -lt $H; $gy += 160) { $g.DrawLine($pen, 0, $gy, $W, $gy) }
$pen.Dispose()
# cyanotype exposure blots
Glow $g 260 880 430 (C 34 4 113 169)
Glow $g 90 110 300 (C 20 26 60 100)
# concentric survey circles with spokes
$ccx = 1450; $ccy = 320
for ($r = 70; $r -le 370; $r += 60) {
  $pen = New-Object System.Drawing.Pen((C 70 4 113 169), 1)
  $g.DrawEllipse($pen, $ccx - $r, $ccy - $r, 2 * $r, 2 * $r); $pen.Dispose()
}
$pen = New-Object System.Drawing.Pen((C 30 4 113 169), 1)
for ($k = 0; $k -lt 12; $k++) {
  $ang = $k * [math]::PI / 6
  $g.DrawLine($pen, $ccx, $ccy, $ccx + [int](370 * [math]::Cos($ang)), $ccy + [int](370 * [math]::Sin($ang)))
}
$pen.Dispose()
$b = New-Object System.Drawing.SolidBrush((C 140 4 113 169)); $g.FillEllipse($b, $ccx - 4, $ccy - 4, 8, 8); $b.Dispose()
# measure line with ticks
$pen = New-Object System.Drawing.Pen((C 80 4 113 169), 1)
$g.DrawLine($pen, 120, 170, 640, 170)
for ($gx = 120; $gx -le 640; $gx += 40) { $g.DrawLine($pen, $gx, 166, $gx, 178) }
$pen.Dispose()
# paper grain
for ($i = 0; $i -lt 5000; $i++) {
  $b = New-Object System.Drawing.SolidBrush((C $rng.Next(5, 12) 70 60 50))
  $g.FillRectangle($b, $rng.Next(0, $W), $rng.Next(0, $H), 1, 1); $b.Dispose()
}
Save $bmp $g "nous.png"

# ── Cyberpunk: Night City neon canyon, yellow/cyan signage, glitch bands ──
$rng = New-Object System.Random(2077)
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 10 10 18) (C 255 24 16 34)
Glow $g 300 980 640 (C 70 252 238 10)      # street haze, cyberpunk yellow
Glow $g 1560 760 560 (C 60 0 240 255)      # cyan district
Glow $g 980 120 480 (C 40 255 0 60)        # red skyline bloom
# tower blocks with dense window grids
$x = -30
while ($x -lt $W) {
  $bw = $rng.Next(90, 240); $h2 = $rng.Next(340, 820)
  $top = $H - $h2
  $b = New-Object System.Drawing.SolidBrush((C 255 7 8 14))
  $g.FillRectangle($b, $x, $top, $bw, $h2); $b.Dispose()
  for ($wy = $top + 16; $wy -lt $H - 20; $wy += 22) {
    for ($wx = $x + 10; $wx -lt $x + $bw - 12; $wx += 16) {
      if ($rng.NextDouble() -lt 0.45) { continue }
      $roll = $rng.NextDouble()
      $cc = if ($roll -lt 0.5) { C $rng.Next(40, 150) 252 238 10 }
      elseif ($roll -lt 0.8) { C $rng.Next(40, 140) 0 240 255 }
      else { C $rng.Next(40, 130) 255 0 90 }
      $b = New-Object System.Drawing.SolidBrush($cc); $g.FillRectangle($b, $wx, $wy, 6, 9); $b.Dispose()
    }
  }
  # vertical neon signboard on some faces
  if ($rng.NextDouble() -lt 0.45 -and $bw -gt 120) {
    $sx = $x + $rng.Next(20, $bw - 30); $sy = $top + $rng.Next(30, 180); $sh = $rng.Next(120, 320)
    $neon = if ($rng.NextDouble() -lt 0.5) { C 235 252 238 10 } else { C 235 0 240 255 }
    Glow $g ($sx + 5) ($sy + $sh / 2) 90 (C 60 $neon.R $neon.G $neon.B)
    $b = New-Object System.Drawing.SolidBrush($neon); $g.FillRectangle($b, $sx, $sy, 10, $sh); $b.Dispose()
  }
  $x += $bw + $rng.Next(6, 26)
}
# glitch bands: horizontal slices offset in hot colors
for ($i = 0; $i -lt 14; $i++) {
  $gy = $rng.Next(0, $H); $gh = $rng.Next(2, 9)
  $cc = if ($rng.NextDouble() -lt 0.5) { C $rng.Next(30, 90) 0 240 255 } else { C $rng.Next(30, 90) 255 0 90 }
  $b = New-Object System.Drawing.SolidBrush($cc)
  $g.FillRectangle($b, $rng.Next(0, 400), $gy, $rng.Next(300, $W), $gh); $b.Dispose()
}
# scanlines
for ($y = 0; $y -lt $H; $y += 4) {
  $pen = New-Object System.Drawing.Pen((C 30 0 0 0), 1)
  $g.DrawLine($pen, 0, $y, $W, $y); $pen.Dispose()
}
Save $bmp $g "cyberpunk.png"

# ── Deus Ex: black-gold hexagon lattice, circuit traces, icarus glow ──
$rng = New-Object System.Random(2027)
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 14 11 6) (C 255 6 5 3)
Glow $g 1420 300 520 (C 46 226 168 62)     # gold aura
Glow $g 360 900 460 (C 26 180 130 40)
# hexagon lattice
$hr = 46.0
$penHex = New-Object System.Drawing.Pen((C 40 226 168 62), 1)
for ($row = -1; $row -lt 16; $row++) {
  for ($col = -1; $col -lt 26; $col++) {
    $cx2 = $col * ($hr * 1.5)
    $cy2 = $row * ($hr * 1.732) + $(if ($col % 2 -ne 0) { $hr * 0.866 } else { 0 })
    $pts = New-Object 'System.Drawing.Point[]' 6
    for ($k = 0; $k -lt 6; $k++) {
      $ang = [math]::PI / 180 * (60 * $k)
      $pts[$k] = New-Object System.Drawing.Point(([int]($cx2 + $hr * [math]::Cos($ang))), ([int]($cy2 + $hr * [math]::Sin($ang))))
    }
    $g.DrawPolygon($penHex, $pts)
  }
}
$penHex.Dispose()
# brighter gold hexes scattered through the lattice
for ($i = 0; $i -lt 26; $i++) {
  $cx2 = $rng.Next(0, $W); $cy2 = $rng.Next(0, $H)
  $pts = New-Object 'System.Drawing.Point[]' 6
  for ($k = 0; $k -lt 6; $k++) {
    $ang = [math]::PI / 180 * (60 * $k)
    $pts[$k] = New-Object System.Drawing.Point(([int]($cx2 + $hr * [math]::Cos($ang))), ([int]($cy2 + $hr * [math]::Sin($ang))))
  }
  $b = New-Object System.Drawing.SolidBrush((C $rng.Next(10, 34) 226 168 62))
  $g.FillPolygon($b, $pts); $b.Dispose()
}
# circuit traces with solder pads
for ($i = 0; $i -lt 26; $i++) {
  $cx2 = $rng.Next(0, $W); $cy2 = $rng.Next(0, $H)
  $pen = New-Object System.Drawing.Pen((C 70 226 168 62), 1)
  $len = $rng.Next(80, 340)
  $horiz = $rng.NextDouble() -lt 0.5
  $mx2 = if ($horiz) { $cx2 + $len } else { $cx2 }
  $my2 = if ($horiz) { $cy2 } else { $cy2 + $len }
  $g.DrawLine($pen, $cx2, $cy2, $mx2, $my2)
  $ex = if ($horiz) { $mx2 + 60 } else { $mx2 + 60 }
  $ey = if ($horiz) { $my2 + 60 } else { $my2 }
  $g.DrawLine($pen, $mx2, $my2, $ex, $ey); $pen.Dispose()
  $b = New-Object System.Drawing.SolidBrush((C 150 226 168 62))
  $g.FillEllipse($b, $ex - 3, $ey - 3, 6, 6); $b.Dispose()
}
# vignette
foreach ($corner in @(@(0,0), @($W,0), @(0,$H), @($W,$H))) {
  Glow $g $corner[0] $corner[1] 620 (C 120 0 0 0)
}
Save $bmp $g "deusex.png"

# ── Umbrella: red/white octagon emblem over a sterile containment grid ──
$rng = New-Object System.Random(1998)
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 12 13 16) (C 255 6 6 8)
Glow $g 1430 470 560 (C 46 200 20 24)      # red containment glow
# containment floor grid
$pen = New-Object System.Drawing.Pen((C 16 200 210 220), 1)
for ($gx = 0; $gx -lt $W; $gx += 90) { $g.DrawLine($pen, $gx, 0, $gx, $H) }
for ($gy = 0; $gy -lt $H; $gy += 90) { $g.DrawLine($pen, 0, $gy, $W, $gy) }
$pen.Dispose()
# the emblem: 8 alternating wedges, red and bone-white
$er = 300.0; $ex2 = 1430.0; $ey2 = 470.0
for ($k = 0; $k -lt 8; $k++) {
  $col = if ($k % 2 -eq 0) { C 120 190 22 28 } else { C 60 226 226 220 }
  $b = New-Object System.Drawing.SolidBrush($col)
  $g.FillPie($b, ($ex2 - $er), ($ey2 - $er), (2 * $er), (2 * $er), (45 * $k + 22.5), 45.0)
  $b.Dispose()
}
# emblem rings
$pen = New-Object System.Drawing.Pen((C 150 226 226 220), 3)
$g.DrawEllipse($pen, ($ex2 - $er), ($ey2 - $er), (2 * $er), (2 * $er)); $pen.Dispose()
$pen = New-Object System.Drawing.Pen((C 90 226 226 220), 2)
$g.DrawEllipse($pen, ($ex2 - 96), ($ey2 - 96), 192, 192); $pen.Dispose()
$b = New-Object System.Drawing.SolidBrush((C 210 12 13 16))
$g.FillEllipse($b, ($ex2 - 92), ($ey2 - 92), 184, 184); $b.Dispose()
# hazard stripe bar along the bottom
$stripeY = $H - 74
$b = New-Object System.Drawing.SolidBrush((C 60 20 20 24)); $g.FillRectangle($b, 0, $stripeY, $W, 74); $b.Dispose()
for ($sx = -80; $sx -lt $W; $sx += 76) {
  $pts = New-Object 'System.Drawing.Point[]' 4
  $pts[0] = New-Object System.Drawing.Point($sx, ($stripeY + 74))
  $pts[1] = New-Object System.Drawing.Point(($sx + 38), $stripeY)
  $pts[2] = New-Object System.Drawing.Point(($sx + 76), $stripeY)
  $pts[3] = New-Object System.Drawing.Point(($sx + 38), ($stripeY + 74))
  $b = New-Object System.Drawing.SolidBrush((C 42 190 22 28)); $g.FillPolygon($b, $pts); $b.Dispose()
}
# specimen dust
for ($i = 0; $i -lt 1400; $i++) {
  $b = New-Object System.Drawing.SolidBrush((C $rng.Next(6, 20) 220 225 230))
  $g.FillRectangle($b, $rng.Next(0, $W), $rng.Next(0, $H), 1, 1); $b.Dispose()
}
Save $bmp $g "umbrella.png"

# Typed Point[] builder: FillPolygon/DrawPolygon reject PowerShell's
# loosely-typed @() arrays. Input is an array of @(x, y) pairs.
# NOTE: parenthesize arithmetic inside these pairs -- the comma operator
# binds tighter than minus, so @($a - 1, $b - 2) parses as $a - (1,$b) - 2.
function MkPts {
  param($list)
  $arr = New-Object 'System.Drawing.Point[]' $list.Count
  for ($i = 0; $i -lt $list.Count; $i++) {
    $arr[$i] = New-Object System.Drawing.Point([int]$list[$i][0], [int]$list[$i][1])
  }
  return , $arr
}

# ── One Dark: blurred code — light shaft over syntax-colored bars ──
$rng = New-Object System.Random(2014)
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 22 27 42) (C 255 10 12 18)
Glow $g 1500 120 620 (C 40 97 175 239)
Glow $g 380 950 520 (C 26 198 120 221)
$syntax = @((C 255 97 175 239), (C 255 152 195 121), (C 255 198 120 221), (C 255 229 192 123), (C 255 224 108 117))
# "code lines": indented bars in muted syntax colors
$lineY = 40
while ($lineY -lt $H) {
  $indent = 90 + 60 * $rng.Next(0, 4)
  $segs = $rng.Next(1, 5)
  $bx = $indent
  for ($s = 0; $s -lt $segs; $s++) {
    $segw = $rng.Next(60, 260)
    $cc = $syntax[$rng.Next(0, $syntax.Count)]
    $b = New-Object System.Drawing.SolidBrush((C $rng.Next(10, 26) $cc.R $cc.G $cc.B))
    $g.FillRectangle($b, $bx, $lineY, $segw, 12); $b.Dispose()
    $bx += $segw + $rng.Next(18, 46)
    if ($bx -gt $W - 100) { break }
  }
  $lineY += 30
}
# diagonal light shaft
$path = New-Object System.Drawing.Drawing2D.GraphicsPath
$path.AddPolygon((MkPts @(@(700, 0), @(1180, 0), @(560, $H), @(80, $H))))
$br = New-Object System.Drawing.Drawing2D.PathGradientBrush($path)
$br.CenterColor = (C 22 255 255 255)
$br.SurroundColors = @((C 0 255 255 255))
$g.FillPath($br, $path); $br.Dispose(); $path.Dispose()
Save $bmp $g "onedark.png"

# ── Dracula: full moon, castle silhouette, bats, violet fog ──
$rng = New-Object System.Random(1897)
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 46 40 78) (C 255 18 16 28)
Glow $g 1430 260 420 (C 90 189 147 249)
$b = New-Object System.Drawing.SolidBrush((C 235 248 248 242))
$g.FillEllipse($b, 1330, 160, 200, 200); $b.Dispose()
Glow $g 1430 260 150 (C 60 255 121 198)
for ($i = 0; $i -lt 260; $i++) {
  $b = New-Object System.Drawing.SolidBrush((C $rng.Next(30, 120) 248 248 242))
  $g.FillEllipse($b, $rng.Next(0, $W), $rng.Next(0, 620), $rng.Next(1, 3), $rng.Next(1, 3)); $b.Dispose()
}
# castle: towers with pointed roofs and lit windows
$dark = New-Object System.Drawing.SolidBrush((C 255 12 10 20))
$baseY = $H - 210
$g.FillRectangle($dark, 120, $baseY, 620, 260)
foreach ($t in @(@(150, 300), @(330, 380), @(520, 330), @(660, 250))) {
  $tx = $t[0]; $th = $t[1]
  $g.FillRectangle($dark, $tx, ($H - $th), 90, $th)
  $g.FillPolygon($dark, (MkPts @(@(($tx - 12), ($H - $th)), @(($tx + 45), ($H - $th - 90)), @(($tx + 102), ($H - $th)))))
  for ($k = 0; $k -lt 3; $k++) {
    if ($rng.NextDouble() -lt 0.45) { continue }
    $b = New-Object System.Drawing.SolidBrush((C 190 255 184 108))
    $g.FillRectangle($b, ($tx + 20 + 30 * $rng.Next(0, 2)), ($H - $th + 40 + 70 * $k), 12, 18); $b.Dispose()
  }
}
$dark.Dispose()
# bats
$pen = New-Object System.Drawing.Pen((C 200 12 10 20), 3)
foreach ($bat in @(@(980, 300, 26), @(1080, 420, 18), @(880, 480, 14), @(1180, 200, 12))) {
  $bxx = $bat[0]; $byy = $bat[1]; $bs = $bat[2]
  $g.DrawArc($pen, ($bxx - $bs), ($byy - $bs / 2), $bs, $bs, 200, 140)
  $g.DrawArc($pen, $bxx, ($byy - $bs / 2), $bs, $bs, 200, 140)
}
$pen.Dispose()
Save $bmp $g "dracula.png"

# ── Nord: aurora curtains over snow peaks ──
$rng = New-Object System.Random(1888)
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 30 36 48) (C 255 46 52 64)
for ($i = 0; $i -lt 340; $i++) {
  $b = New-Object System.Drawing.SolidBrush((C $rng.Next(30, 130) 236 239 244))
  $g.FillEllipse($b, $rng.Next(0, $W), $rng.Next(0, 700), $rng.Next(1, 3), $rng.Next(1, 3)); $b.Dispose()
}
# aurora: filled ribbons that fade downward, drawn as vertical strips
for ($c = 0; $c -lt 6; $c++) {
  $cx = $rng.Next(60, $W - 60)
  $cc = if ($c % 2 -eq 0) { C 255 163 190 140 } else { C 255 136 192 208 }
  $ribbonW = $rng.Next(150, 300)
  $topY = $rng.Next(30, 130)
  $botY = $rng.Next(560, 760)
  for ($sx = 0; $sx -lt $ribbonW; $sx += 3) {
    # sinusoidal sway plus a soft edge falloff across the ribbon
    $edge = [math]::Sin([math]::PI * $sx / $ribbonW)
    $sway = [int](70 * [math]::Sin($sx / 46.0 + $c * 1.7))
    for ($yy = $topY; $yy -lt $botY; $yy += 6) {
      $fade = 1.0 - ($yy - $topY) / [double]($botY - $topY)
      $al = [int](150 * $edge * $fade * $fade)
      if ($al -le 2) { continue }
      $drift = [int](40 * [math]::Sin($yy / 190.0 + $c))
      $b = New-Object System.Drawing.SolidBrush((C $al $cc.R $cc.G $cc.B))
      $g.FillRectangle($b, ($cx + $sx + $sway + $drift), $yy, 4, 7); $b.Dispose()
    }
  }
  Glow $g ($cx + $ribbonW / 2) (($topY + $botY) / 2) 320 (C 40 $cc.R $cc.G $cc.B)
}
# snow peaks
$g.FillPolygon((New-Object System.Drawing.SolidBrush((C 255 59 66 82))),
  (MkPts @(@(0, $H), @(0, 800), @(260, 610), @(520, 830), @(760, 640), @(1080, 860), @(1380, 620), @(1700, 840), @($W, 700), @($W, $H))))
$g.FillPolygon((New-Object System.Drawing.SolidBrush((C 255 46 52 64))),
  (MkPts @(@(0, $H), @(0, 930), @(340, 820), @(700, 960), @(1100, 850), @(1520, 980), @($W, 880), @($W, $H))))
Save $bmp $g "nord.png"

# ── Gruvbox: 70s sunburst over grain ──
$rng = New-Object System.Random(1974)
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 40 40 40) (C 255 24 22 20)
$scx = 960.0; $scy = 1180.0
for ($k = 0; $k -lt 26; $k++) {
  $col = if ($k % 3 -eq 0) { C 34 251 73 52 } elseif ($k % 3 -eq 1) { C 30 254 128 25 } else { C 26 250 189 47 }
  $b = New-Object System.Drawing.SolidBrush($col)
  $g.FillPie($b, ($scx - 1500), ($scy - 1500), 3000, 3000, (180 + 6.92 * $k), 3.4)
  $b.Dispose()
}
Glow $g 960 1150 640 (C 90 254 128 25)
Glow $g 960 1150 300 (C 110 250 189 47)
# horizon band + retro stripes
$b = New-Object System.Drawing.SolidBrush((C 255 29 32 33)); $g.FillRectangle($b, 0, 980, $W, ($H - 980)); $b.Dispose()
foreach ($s in @(@(1000, 8, (C 120 250 189 47)), @(1016, 5, (C 90 254 128 25)), @(1028, 3, (C 70 251 73 52)))) {
  $b = New-Object System.Drawing.SolidBrush($s[2]); $g.FillRectangle($b, 0, $s[0], $W, $s[1]); $b.Dispose()
}
for ($i = 0; $i -lt 6000; $i++) {
  $b = New-Object System.Drawing.SolidBrush((C $rng.Next(5, 14) 235 219 178))
  $g.FillRectangle($b, $rng.Next(0, $W), $rng.Next(0, $H), 1, 1); $b.Dispose()
}
Save $bmp $g "gruvbox.png"

# ── Tokyo Night: Fuji under a pale moon, city glow below ──
$rng = New-Object System.Random(2019)
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 26 27 56) (C 255 13 14 26)
for ($i = 0; $i -lt 380; $i++) {
  $b = New-Object System.Drawing.SolidBrush((C $rng.Next(30, 140) 192 202 245))
  $g.FillEllipse($b, $rng.Next(0, $W), $rng.Next(0, 720), $rng.Next(1, 3), $rng.Next(1, 3)); $b.Dispose()
}
Glow $g 520 240 300 (C 60 187 154 247)
$b = New-Object System.Drawing.SolidBrush((C 220 220 226 250)); $g.FillEllipse($b, 440, 160, 160, 160); $b.Dispose()
# Fuji: wide base, dark enough to separate from the sky
$g.FillPolygon((New-Object System.Drawing.SolidBrush((C 255 11 11 24))),
  (MkPts @(@(-200, $H), @(180, 980), @(620, 640), @(860, 430), @(960, 380), @(1060, 430), @(1320, 660), @(1780, 990), @(2120, $H))))
# ridge highlight
$pen = New-Object System.Drawing.Pen((C 80 122 162 247), 2)
$g.DrawLines($pen, (MkPts @(@(620, 640), @(860, 430), @(960, 380), @(1060, 430), @(1320, 660))))
$pen.Dispose()
# snow cap: jagged lower edge, kept inside the silhouette
$g.FillPolygon((New-Object System.Drawing.SolidBrush((C 235 192 202 245))),
  (MkPts @(@(960, 385), @(1024, 432), @(999, 452), @(972, 430), @(948, 456), @(921, 432), @(898, 428))))
# city light band
for ($i = 0; $i -lt 900; $i++) {
  $lx = $rng.Next(0, $W); $ly = $rng.Next($H - 150, $H)
  $cc = if ($rng.NextDouble() -lt 0.3) { C $rng.Next(60, 180) 247 118 142 } else { C $rng.Next(60, 180) 122 162 247 }
  $b = New-Object System.Drawing.SolidBrush($cc); $g.FillRectangle($b, $lx, $ly, 2, 2); $b.Dispose()
}
Glow $g 960 1080 700 (C 40 122 162 247)
Save $bmp $g "tokyonight.png"

# ── Catppuccin: pastel wave interference ──
$rng = New-Object System.Random(2021)
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 30 30 48) (C 255 20 20 32)
$pastels = @((C 255 245 194 231), (C 255 137 180 250), (C 255 166 227 161), (C 255 250 179 135), (C 255 203 166 247))
for ($layer = 0; $layer -lt 5; $layer++) {
  $cc = $pastels[$layer]
  $phase = $layer * 1.1
  $amp = 70 + 20 * $layer
  $baseY = 220 + 170 * $layer
  for ($rep = 0; $rep -lt 6; $rep++) {
    $pen = New-Object System.Drawing.Pen((C ([int](120 - 15 * $rep)) $cc.R $cc.G $cc.B), 3)
    $prevX = 0
    $prevY = $baseY + $rep * 13
    for ($x2 = 20; $x2 -le $W; $x2 += 20) {
      $yy = $baseY + $rep * 13 + [int]($amp * [math]::Sin($x2 / 260.0 + $phase) + 24 * [math]::Sin($x2 / 90.0 - $phase))
      $g.DrawLine($pen, $prevX, $prevY, $x2, $yy)
      $prevX = $x2; $prevY = $yy
    }
    $pen.Dispose()
  }
}
Glow $g 300 260 420 (C 70 245 194 231)
Glow $g 1600 800 460 (C 66 137 180 250)
Save $bmp $g "catppuccin.png"

# ── Solarized Dark: solar corona with measured grid ──
$rng = New-Object System.Random(1976)
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 0 50 63) (C 255 0 18 23)
$pen = New-Object System.Drawing.Pen((C 14 147 161 161), 1)
for ($gx = 0; $gx -lt $W; $gx += 80) { $g.DrawLine($pen, $gx, 0, $gx, $H) }
for ($gy = 0; $gy -lt $H; $gy += 80) { $g.DrawLine($pen, 0, $gy, $W, $gy) }
$pen.Dispose()
# sun low-left with corona rings
Glow $g 240 940 620 (C 80 181 137 0)
Glow $g 240 940 300 (C 90 203 75 22)
$b = New-Object System.Drawing.SolidBrush((C 190 253 246 227)); $g.FillEllipse($b, 150, 850, 180, 180); $b.Dispose()
foreach ($r in @(280, 380, 500, 640)) {
  $pen = New-Object System.Drawing.Pen((C 40 42 161 152), 1)
  $g.DrawEllipse($pen, (240 - $r), (940 - $r), (2 * $r), (2 * $r)); $pen.Dispose()
}
# flare arcs
for ($i = 0; $i -lt 5; $i++) {
  $pen = New-Object System.Drawing.Pen((C $rng.Next(30, 70) 203 75 22), 2)
  $rr = $rng.Next(320, 700)
  $g.DrawArc($pen, (240 - $rr), (940 - $rr), (2 * $rr), (2 * $rr), $rng.Next(250, 300), $rng.Next(20, 60))
  $pen.Dispose()
}
Save $bmp $g "solarizeddark.png"

# ── Everforest: misty pine layers ──
$rng = New-Object System.Random(1990)
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 61 71 77) (C 255 45 53 59)
Glow $g 1400 220 420 (C 40 219 188 127)
$layers = @(
  @(560, (C 255 66 78 74), 150, 210),
  @(720, (C 255 55 66 63), 190, 260),
  @(880, (C 255 45 54 52), 240, 330),
  @(1010, (C 255 36 43 42), 300, 420)
)
foreach ($ly in $layers) {
  $baseY = $ly[0]; $col = $ly[1]; $minH = $ly[2]; $maxH = $ly[3]
  $b = New-Object System.Drawing.SolidBrush($col)
  $tx = -60
  while ($tx -lt $W + 60) {
    $th = $rng.Next($minH, $maxH)
    $tw = [int]($th * 0.46)
    # three stacked triangles per pine
    for ($k = 0; $k -lt 3; $k++) {
      $ty = $baseY - [int]($th * (0.30 * $k))
      $kw = [int]($tw * (1 - 0.16 * $k))
      $g.FillPolygon($b, (MkPts @(@(($tx - $kw), $ty), @($tx, ($ty - $th * 0.62)), @(($tx + $kw), $ty))))
    }
    $g.FillRectangle($b, ($tx - 5), $baseY, 10, 60)
    $tx += $rng.Next(46, 96)
  }
  $b.Dispose()
  # mist band between layers
  $mist = New-Object System.Drawing.SolidBrush((C 26 211 198 170))
  $g.FillRectangle($mist, 0, ($baseY - 24), $W, 74); $mist.Dispose()
}
Save $bmp $g "everforest.png"

# ── Game Boy: DMG dot-matrix with 8-bit sprites ──
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 22 60 22) (C 255 12 40 12)
# dot matrix cells
$cell = 14
for ($gy = 0; $gy -lt $H; $gy += $cell) {
  for ($gx = 0; $gx -lt $W; $gx += $cell) {
    $b = New-Object System.Drawing.SolidBrush((C 20 155 188 15))
    $g.FillRectangle($b, $gx, $gy, ($cell - 3), ($cell - 3)); $b.Dispose()
  }
}
# 8-bit sprite stamps (heart, invader) drawn from row masks
$heart = @("01101100", "11111110", "11111110", "11111110", "01111100", "00111000", "00010000")
$alien = @("00100100", "00111100", "01111110", "11011011", "11111111", "01011010", "10000001")
function Stamp {
  param($g, $mask, $ox, $oy, $px, $col)
  for ($r = 0; $r -lt $mask.Count; $r++) {
    $rowStr = $mask[$r]
    for ($c2 = 0; $c2 -lt $rowStr.Length; $c2++) {
      if ($rowStr[$c2] -ne '1') { continue }
      $b = New-Object System.Drawing.SolidBrush($col)
      $g.FillRectangle($b, ($ox + $c2 * $px), ($oy + $r * $px), ($px - 2), ($px - 2)); $b.Dispose()
    }
  }
}
Stamp $g $heart 1380 220 16 (C 70 155 188 15)
Stamp $g $alien 300 700 18 (C 60 139 172 15)
Stamp $g $alien 1500 820 12 (C 45 139 172 15)
Stamp $g $heart 640 320 11 (C 40 155 188 15)
# screen edge vignette (DMG bezel shadow)
foreach ($corner in @(@(0, 0), @($W, 0), @(0, $H), @($W, $H))) {
  Glow $g $corner[0] $corner[1] 700 (C 90 4 20 4)
}
Save $bmp $g "gameboy.png"

# ── Amber CRT: phosphor scanlines, curvature vignette, test pattern ──
$rng = New-Object System.Random(1981)
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 26 16 2) (C 255 10 6 0)
Glow $g 960 540 820 (C 60 255 176 0)
# test-pattern circle + crosshair
$pen = New-Object System.Drawing.Pen((C 45 255 176 0), 2)
$g.DrawEllipse($pen, (960 - 330), (540 - 330), 660, 660)
$g.DrawLine($pen, 960, 150, 960, 930); $g.DrawLine($pen, 300, 540, 1620, 540); $pen.Dispose()
# grey-scale step bar
for ($k = 0; $k -lt 8; $k++) {
  $b = New-Object System.Drawing.SolidBrush((C ([int](12 + 9 * $k)) 255 176 0))
  $g.FillRectangle($b, (660 + $k * 80), 700, 78, 90); $b.Dispose()
}
# phosphor text-row afterglow
for ($k = 0; $k -lt 22; $k++) {
  $b = New-Object System.Drawing.SolidBrush((C $rng.Next(6, 16) 255 176 0))
  $g.FillRectangle($b, 120, (120 + $k * 42), $rng.Next(300, 1500), 16); $b.Dispose()
}
# scanlines + vignette
for ($y = 0; $y -lt $H; $y += 3) {
  $pen = New-Object System.Drawing.Pen((C 70 0 0 0), 1)
  $g.DrawLine($pen, 0, $y, $W, $y); $pen.Dispose()
}
foreach ($corner in @(@(0, 0), @($W, 0), @(0, $H), @($W, $H))) {
  Glow $g $corner[0] $corner[1] 640 (C 150 0 0 0)
}
Save $bmp $g "ambercrt.png"

"done -> $out"
