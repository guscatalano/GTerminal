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

# ── Cyberpunk: neon night city — magenta/cyan/yellow, edge-lit towers,
# holo-ad, katakana signboards, light trails, street-glow reflections ──
$rng = New-Object System.Random(2077)
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 24 10 44) (C 255 8 6 16)
# dusk bloom on the horizon
Glow $g 960 660 760 (C 66 255 60 180)
Glow $g 420 620 420 (C 40 0 240 255)
Glow $g 1560 640 430 (C 44 80 110 255)
# far skyline: violet silhouettes, sparse windows
$far = New-Object System.Drawing.SolidBrush((C 255 20 11 38))
$x = -20
while ($x -lt $W) {
  $bw = $rng.Next(60, 150); $h2 = $rng.Next(240, 430)
  $g.FillRectangle($far, $x, (660 - $h2), $bw, (420 + $h2))
  for ($i = 0; $i -lt [int]($bw * $h2 / 2600); $i++) {
    $cc = if ($rng.NextDouble() -lt 0.5) { C $rng.Next(40, 100) 255 90 200 } else { C $rng.Next(40, 100) 90 230 255 }
    $b = New-Object System.Drawing.SolidBrush($cc)
    $g.FillRectangle($b, ($x + $rng.Next(4, $bw - 6)), (660 - $h2 + $rng.Next(8, $h2)), 3, 4); $b.Dispose()
  }
  $x += $bw + $rng.Next(4, 18)
}
$far.Dispose()
# mid skyline: darker, denser windows, neon rooflines on some towers
$mid = New-Object System.Drawing.SolidBrush((C 255 11 8 22))
$x = -40
while ($x -lt $W) {
  $bw = $rng.Next(110, 260); $h2 = $rng.Next(360, 620)
  $top = $H - $h2 - 60
  $g.FillRectangle($mid, $x, $top, $bw, ($h2 + 60))
  for ($wy = $top + 18; $wy -lt $H - 40; $wy += 26) {
    for ($wx = $x + 12; $wx -lt $x + $bw - 14; $wx += 20) {
      if ($rng.NextDouble() -lt 0.62) { continue }
      $roll = $rng.NextDouble()
      $cc = if ($roll -lt 0.4) { C $rng.Next(50, 140) 255 90 200 }
      elseif ($roll -lt 0.75) { C $rng.Next(50, 140) 90 230 255 }
      else { C $rng.Next(50, 130) 252 238 10 }
      $b = New-Object System.Drawing.SolidBrush($cc); $g.FillRectangle($b, $wx, $wy, 7, 10); $b.Dispose()
    }
  }
  if ($rng.NextDouble() -lt 0.6) {
    $edge = if ($rng.NextDouble() -lt 0.5) { C 200 255 60 180 } else { C 200 0 240 255 }
    $pen = New-Object System.Drawing.Pen($edge, 3)
    $g.DrawLine($pen, $x, $top, ($x + $bw), $top)
    $g.DrawLine($pen, $x, $top, $x, ($top + $rng.Next(40, 120)))
    $pen.Dispose()
    Glow $g ($x + [int]($bw / 2)) $top 90 (C 50 $edge.R $edge.G $edge.B)
  }
  $x += $bw + $rng.Next(10, 40)
}
$mid.Dispose()
# framing megatowers left and right with katakana signboards
$fg = New-Object System.Drawing.SolidBrush((C 255 6 5 13))
$g.FillRectangle($fg, -60, 0, 300, $H)
$g.FillRectangle($fg, 1690, 0, 300, $H)
$fg.Dispose()
$font = New-Object System.Drawing.Font("MS Gothic", 30, [System.Drawing.FontStyle]::Bold)
$boards = @(
  @(96, 130, 620, (C 235 255 60 180)),
  @(178, 320, 520, (C 235 0 240 255)),
  @(1724, 90, 700, (C 235 252 238 10)),
  @(1830, 380, 480, (C 235 255 60 180))
)
foreach ($bd in $boards) {
  $bx = $bd[0]; $by = $bd[1]; $bh = $bd[2]; $cc = $bd[3]
  $b = New-Object System.Drawing.SolidBrush((C 40 $cc.R $cc.G $cc.B))
  $g.FillRectangle($b, $bx, $by, 48, $bh); $b.Dispose()
  $pen = New-Object System.Drawing.Pen((C 140 $cc.R $cc.G $cc.B), 2)
  $g.DrawRectangle($pen, $bx, $by, 48, $bh); $pen.Dispose()
  Glow $g ($bx + 24) ($by + [int]($bh / 2)) 130 (C 44 $cc.R $cc.G $cc.B)
  $gy = $by + 12
  while ($gy -lt $by + $bh - 40) {
    $ch = [char](0x30A0 + $rng.Next(0, 96))
    $b = New-Object System.Drawing.SolidBrush((C 220 $cc.R $cc.G $cc.B))
    $g.DrawString($ch, $font, $b, ($bx + 7), $gy); $b.Dispose()
    $gy += 44
  }
}
$font.Dispose()
# floating holo-ad between the towers: scanlined cyan panel, ghost offset
foreach ($off in @(8, 0)) {
  $al = if ($off -eq 0) { 40 } else { 16 }
  $b = New-Object System.Drawing.SolidBrush((C $al 0 240 255))
  $g.FillRectangle($b, (690 + $off), 170, 520, 190); $b.Dispose()
}
$pen = New-Object System.Drawing.Pen((C 150 0 240 255), 2)
$g.DrawRectangle($pen, 690, 170, 520, 190); $pen.Dispose()
for ($gy = 176; $gy -lt 356; $gy += 7) {
  $pen = New-Object System.Drawing.Pen((C 40 8 6 16), 2)
  $g.DrawLine($pen, 692, $gy, 1208, $gy); $pen.Dispose()
}
$font = New-Object System.Drawing.Font("MS Gothic", 60, [System.Drawing.FontStyle]::Bold)
$b = New-Object System.Drawing.SolidBrush((C 150 120 245 255))
$g.DrawString([string][char](0x30B5) + [string][char](0x30A4) + [string][char](0x30D0) + [string][char](0x30FC), $font, $b, 760, 220)
$b.Dispose(); $font.Dispose()
$b = New-Object System.Drawing.SolidBrush((C 220 255 40 70)); $g.FillEllipse($b, 1176, 184, 12, 12); $b.Dispose()
Glow $g 950 265 260 (C 36 0 240 255)
# flying-car light trails
foreach ($tr in @(@(240, 470, 620, (C 170 252 238 10)), @(1120, 430, 540, (C 170 255 40 70)), @(520, 540, 420, (C 150 0 240 255)), @(1240, 560, 500, (C 150 252 238 10)))) {
  $tx = $tr[0]; $ty = $tr[1]; $tl = $tr[2]; $cc = $tr[3]
  for ($seg = 0; $seg -lt $tl; $seg += 6) {
    $fade = [int]($cc.A * $seg / $tl)
    $b = New-Object System.Drawing.SolidBrush((C $fade $cc.R $cc.G $cc.B))
    $g.FillRectangle($b, ($tx + $seg), ($ty - [int]($seg / 40)), 5, 3); $b.Dispose()
  }
  Glow $g ($tx + $tl) ($ty - [int]($tl / 40)) 60 (C 70 $cc.R $cc.G $cc.B)
}
# street glow + neon reflections rising from the bottom edge
Glow $g 700 1120 520 (C 90 255 60 180)
Glow $g 1300 1140 560 (C 80 0 240 255)
for ($k = 0; $k -lt 60; $k++) {
  $rx = $rng.Next(240, 1690)
  $roll = $rng.NextDouble()
  $cc = if ($roll -lt 0.4) { C $rng.Next(24, 70) 255 60 180 } elseif ($roll -lt 0.75) { C $rng.Next(24, 70) 0 240 255 } else { C $rng.Next(20, 60) 252 238 10 }
  $b = New-Object System.Drawing.SolidBrush($cc)
  $g.FillRectangle($b, $rx, ($H - $rng.Next(50, 150)), $rng.Next(3, 8), 200); $b.Dispose()
}
# haze grain
for ($i = 0; $i -lt 2600; $i++) {
  $tone = if ($rng.NextDouble() -lt 0.5) { 255 } else { 0 }
  $b = New-Object System.Drawing.SolidBrush((C $rng.Next(4, 11) $tone $tone $tone))
  $g.FillRectangle($b, $rng.Next(0, $W), $rng.Next(0, $H), 1, 1); $b.Dispose()
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
# icarus delta: nested gold triangles, glowing, with radiating spokes
$dcx = 1320; $dcy = 460
Glow $g $dcx $dcy 340 (C 70 226 168 62)
foreach ($sc in @(250, 175, 105)) {
  $pen = New-Object System.Drawing.Pen((C 170 226 168 62), 3)
  $g.DrawPolygon($pen, (MkPts @(@($dcx, ($dcy - $sc)), @(($dcx + [int]($sc * 0.87)), ($dcy + [int]($sc / 2))), @(($dcx - [int]($sc * 0.87)), ($dcy + [int]($sc / 2))))))
  $pen.Dispose()
}
$b = New-Object System.Drawing.SolidBrush((C 220 226 168 62))
$g.FillPolygon($b, (MkPts @(@($dcx, ($dcy - 44)), @(($dcx + 38), ($dcy + 22)), @(($dcx - 38), ($dcy + 22)))))
$b.Dispose()
for ($k = 0; $k -lt 12; $k++) {
  $ang = $k * [math]::PI / 6 + 0.26
  $pen = New-Object System.Drawing.Pen((C 46 226 168 62), 1)
  $g.DrawLine($pen,
    ($dcx + [int](280 * [math]::Cos($ang))), ($dcy + [int](280 * [math]::Sin($ang))),
    ($dcx + [int](430 * [math]::Cos($ang))), ($dcy + [int](430 * [math]::Sin($ang))))
  $pen.Dispose()
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
Glow $g 1390 330 420 (C 46 200 20 24)      # red containment glow
# containment floor grid
$pen = New-Object System.Drawing.Pen((C 16 200 210 220), 1)
for ($gx = 0; $gx -lt $W; $gx += 90) { $g.DrawLine($pen, $gx, 0, $gx, $H) }
for ($gy = 0; $gy -lt $H; $gy += 90) { $g.DrawLine($pen, 0, $gy, $W, $gy) }
$pen.Dispose()
# the emblem: eight-panel umbrella canopy — scalloped outer edges,
# panels meeting at a sharp center point, red/white alternating, red up
$er = 205.0; $ex2 = 1390.0; $ey2 = 330.0
for ($k = 0; $k -lt 8; $k++) {
  $a0 = ([math]::PI / 180) * (45 * $k - 112.5)
  $a1 = $a0 + [math]::PI / 4
  $am = ($a0 + $a1) / 2
  $t0x = $ex2 + $er * [math]::Cos($a0); $t0y = $ey2 + $er * [math]::Sin($a0)
  $t1x = $ex2 + $er * [math]::Cos($a1); $t1y = $ey2 + $er * [math]::Sin($a1)
  # canopy sag: edges dip inward between rib tips, like a real umbrella
  $mx2 = $ex2 + $er * 0.84 * [math]::Cos($am); $my2 = $ey2 + $er * 0.84 * [math]::Sin($am)
  $path = New-Object System.Drawing.Drawing2D.GraphicsPath
  $path.AddLine([single]$ex2, [single]$ey2, [single]$t0x, [single]$t0y)
  $path.AddBezier([single]$t0x, [single]$t0y, [single]$mx2, [single]$my2, [single]$mx2, [single]$my2, [single]$t1x, [single]$t1y)
  $path.AddLine([single]$t1x, [single]$t1y, [single]$ex2, [single]$ey2)
  $path.CloseFigure()
  $col = if ($k % 2 -eq 0) { C 235 226 28 36 } else { C 225 242 242 236 }
  $b = New-Object System.Drawing.SolidBrush($col)
  $g.FillPath($b, $path); $b.Dispose()
  $path.Dispose()
}
# panel separation spokes + scallop outlines in the background ink
for ($k = 0; $k -lt 8; $k++) {
  $a0 = ([math]::PI / 180) * (45 * $k - 112.5)
  $a1 = $a0 + [math]::PI / 4
  $am = ($a0 + $a1) / 2
  $t0x = $ex2 + $er * [math]::Cos($a0); $t0y = $ey2 + $er * [math]::Sin($a0)
  $t1x = $ex2 + $er * [math]::Cos($a1); $t1y = $ey2 + $er * [math]::Sin($a1)
  $mx2 = $ex2 + $er * 0.84 * [math]::Cos($am); $my2 = $ey2 + $er * 0.84 * [math]::Sin($am)
  $pen = New-Object System.Drawing.Pen((C 255 8 9 12), 4)
  $g.DrawLine($pen, [single]$ex2, [single]$ey2, [single]$t0x, [single]$t0y)
  $g.DrawBezier($pen, [single]$t0x, [single]$t0y, [single]$mx2, [single]$my2, [single]$mx2, [single]$my2, [single]$t1x, [single]$t1y)
  $pen.Dispose()
}
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
# double helix down the left: two strands with base-pair rungs
Glow $g 330 540 300 (C 26 200 20 24)
for ($yy = 90; $yy -lt 960; $yy += 7) {
  $ph = $yy / 64.0
  $x1 = 330 + [int](100 * [math]::Sin($ph))
  $x2 = 330 + [int](100 * [math]::Sin($ph + [math]::PI))
  $b = New-Object System.Drawing.SolidBrush((C 110 190 22 28)); $g.FillEllipse($b, $x1, $yy, 6, 6); $b.Dispose()
  $b = New-Object System.Drawing.SolidBrush((C 85 226 226 220)); $g.FillEllipse($b, $x2, $yy, 6, 6); $b.Dispose()
  if (($yy % 49) -lt 7) {
    $pen = New-Object System.Drawing.Pen((C 46 226 226 220), 2)
    $g.DrawLine($pen, ($x1 + 3), ($yy + 3), ($x2 + 3), ($yy + 3)); $pen.Dispose()
  }
}
# faint containment hexes scattered mid-field
for ($i = 0; $i -lt 10; $i++) {
  $hx = $rng.Next(600, 1000); $hy = $rng.Next(150, 900); $hr2 = $rng.Next(28, 60)
  $pts = New-Object 'System.Drawing.Point[]' 6
  for ($k = 0; $k -lt 6; $k++) {
    $ang = [math]::PI / 3 * $k
    $pts[$k] = New-Object System.Drawing.Point(([int]($hx + $hr2 * [math]::Cos($ang))), ([int]($hy + $hr2 * [math]::Sin($ang))))
  }
  $pen = New-Object System.Drawing.Pen((C $rng.Next(14, 34) 200 20 24), 1)
  $g.DrawPolygon($pen, $pts); $pen.Dispose()
}
# specimen dust
for ($i = 0; $i -lt 1400; $i++) {
  $b = New-Object System.Drawing.SolidBrush((C $rng.Next(6, 20) 220 225 230))
  $g.FillRectangle($b, $rng.Next(0, $W), $rng.Next(0, $H), 1, 1); $b.Dispose()
}
Save $bmp $g "umbrella.png"

# ── One Dark: an editor at dusk — gutter, indent guides, bright tokens ──
$rng = New-Object System.Random(2014)
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 24 29 45) (C 255 12 14 20)
Glow $g 1520 120 620 (C 44 97 175 239)
Glow $g 340 980 520 (C 30 198 120 221)
$syntax = @((C 255 97 175 239), (C 255 152 195 121), (C 255 198 120 221), (C 255 229 192 123), (C 255 224 108 117), (C 255 86 182 194))
# gutter with line-number dashes
$b = New-Object System.Drawing.SolidBrush((C 40 40 44 60)); $g.FillRectangle($b, 90, 0, 90, $H); $b.Dispose()
for ($lineY = 40; $lineY -lt $H; $lineY += 34) {
  $b = New-Object System.Drawing.SolidBrush((C 70 92 99 112))
  $g.FillRectangle($b, 118, $lineY, 34, 6); $b.Dispose()
}
# indent guides
for ($k = 0; $k -lt 6; $k++) {
  $pen = New-Object System.Drawing.Pen((C 20 92 99 112), 1)
  $g.DrawLine($pen, (230 + 70 * $k), 0, (230 + 70 * $k), $H); $pen.Dispose()
}
# current-line band + block cursor
$b = New-Object System.Drawing.SolidBrush((C 24 97 175 239)); $g.FillRectangle($b, 90, 448, 1500, 30); $b.Dispose()
$b = New-Object System.Drawing.SolidBrush((C 220 97 175 239)); $g.FillRectangle($b, 760, 452, 13, 22); $b.Dispose()
Glow $g 766 462 60 (C 70 97 175 239)
# code tokens: bright rounded bars with indentation structure
$lineY = 44
$indent = 0
while ($lineY -lt $H) {
  $roll = $rng.NextDouble()
  if ($roll -lt 0.2 -and $indent -lt 4) { $indent++ } elseif ($roll -gt 0.85 -and $indent -gt 0) { $indent-- }
  $bx = 230 + 70 * $indent
  $segs = $rng.Next(2, 6)
  for ($s = 0; $s -lt $segs; $s++) {
    $segw = $rng.Next(46, 210)
    $cc = $syntax[$rng.Next(0, $syntax.Count)]
    $al = $rng.Next(38, 84)
    $b = New-Object System.Drawing.SolidBrush((C $al $cc.R $cc.G $cc.B))
    $g.FillRectangle($b, $bx, $lineY, $segw, 15); $b.Dispose()
    $b = New-Object System.Drawing.SolidBrush((C $al $cc.R $cc.G $cc.B))
    $g.FillEllipse($b, ($bx - 7), $lineY, 15, 15); $g.FillEllipse($b, ($bx + $segw - 8), $lineY, 15, 15); $b.Dispose()
    $bx += $segw + $rng.Next(22, 52)
    if ($bx -gt $W - 160) { break }
  }
  $lineY += 34
}
# diagonal light shaft
$path = New-Object System.Drawing.Drawing2D.GraphicsPath
$path.AddPolygon((MkPts @(@(700, 0), @(1180, 0), @(560, $H), @(80, $H))))
$br = New-Object System.Drawing.Drawing2D.PathGradientBrush($path)
$br.CenterColor = (C 20 255 255 255)
$br.SurroundColors = @((C 0 255 255 255))
$g.FillPath($br, $path); $br.Dispose(); $path.Dispose()
Save $bmp $g "onedark.png"

# ── Dracula: castle on a crag against a huge moon, fog and bats ──
$rng = New-Object System.Random(1897)
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 48 42 84) (C 255 16 14 24)
for ($i = 0; $i -lt 320; $i++) {
  $b = New-Object System.Drawing.SolidBrush((C $rng.Next(30, 130) 248 248 242))
  $g.FillEllipse($b, $rng.Next(0, $W), $rng.Next(0, 700), $rng.Next(1, 3), $rng.Next(1, 3)); $b.Dispose()
}
# the moon: huge, haloed, cratered
Glow $g 1310 330 520 (C 90 189 147 249)
$b = New-Object System.Drawing.SolidBrush((C 248 248 248 242)); $g.FillEllipse($b, 1100, 120, 420, 420); $b.Dispose()
foreach ($cr in @(@(1210, 240, 46), @(1350, 400, 64), @(1430, 220, 30), @(1250, 430, 26))) {
  $b = New-Object System.Drawing.SolidBrush((C 34 98 90 130))
  $g.FillEllipse($b, $cr[0], $cr[1], $cr[2], $cr[2]); $b.Dispose()
}
# crag rising from the right, castle silhouetted inside the moon disc
$ink = New-Object System.Drawing.SolidBrush((C 255 13 11 22))
$g.FillPolygon($ink, (MkPts @(@(900, $H), @(1020, 760), @(1140, 620), @(1240, 590), @(1420, 610), @(1560, 700), @(1720, 860), @($W, 980), @($W, $H))))
# keep + towers on the crag
$g.FillRectangle($ink, 1180, 430, 200, 170)
foreach ($t in @(@(1150, 340, 54), @(1300, 300, 64), @(1420, 380, 44))) {
  $tx = $t[0]; $ty = $t[1]; $tw = $t[2]
  $g.FillRectangle($ink, $tx, $ty, $tw, (620 - $ty))
  $g.FillPolygon($ink, (MkPts @(@(($tx - 10), $ty), @(($tx + [int]($tw / 2)), ($ty - 70)), @(($tx + $tw + 10), $ty))))
  $pen = New-Object System.Drawing.Pen((C 255 13 11 22), 2)
  $g.DrawLine($pen, ($tx + [int]($tw / 2)), ($ty - 70), ($tx + [int]($tw / 2)), ($ty - 100)); $pen.Dispose()
  $g.FillPolygon($ink, (MkPts @(@(($tx + [int]($tw / 2)), ($ty - 100)), @(($tx + [int]($tw / 2) + 26), ($ty - 92)), @(($tx + [int]($tw / 2)), ($ty - 84)))))
}
$ink.Dispose()
# lit windows on the keep and towers
foreach ($wpos in @(@(1225, 470), @(1290, 500), @(1170, 380), @(1322, 340), @(1440, 420), @(1330, 460))) {
  $b = New-Object System.Drawing.SolidBrush((C 210 255 184 108))
  $g.FillRectangle($b, $wpos[0], $wpos[1], 10, 16); $b.Dispose()
}
# fog bands drifting across the crag
foreach ($fy in @(700, 800, 900)) {
  $b = New-Object System.Drawing.SolidBrush((C 16 189 147 249))
  $g.FillRectangle($b, 0, $fy, $W, 46); $b.Dispose()
  Glow $g $rng.Next(400, 1500) ($fy + 20) 260 (C 22 189 147 249)
}
# pine forest along the bottom
$ink = New-Object System.Drawing.SolidBrush((C 255 10 9 18))
$tx = -20
while ($tx -lt $W) {
  $th = $rng.Next(80, 180)
  $g.FillPolygon($ink, (MkPts @(@(($tx - 34), $H), @($tx, ($H - $th)), @(($tx + 34), $H))))
  $tx += $rng.Next(36, 70)
}
$ink.Dispose()
# bats silhouetted against the moon
$pen = New-Object System.Drawing.Pen((C 230 13 11 22), 4)
foreach ($bat in @(@(1180, 250, 30), @(1370, 300, 22), @(1260, 480, 26), @(980, 380, 18), @(1500, 180, 16))) {
  $bxx = $bat[0]; $byy = $bat[1]; $bs = $bat[2]
  $g.DrawArc($pen, ($bxx - $bs), ($byy - [int]($bs / 2)), $bs, $bs, 200, 140)
  $g.DrawArc($pen, $bxx, ($byy - [int]($bs / 2)), $bs, $bs, 200, 140)
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

# ── Everforest: sun through mist over a pine valley ──
$rng = New-Object System.Random(1990)
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 74 85 86) (C 255 42 50 54)
# low sun with rays
Glow $g 1360 300 520 (C 70 219 188 127)
$b = New-Object System.Drawing.SolidBrush((C 130 219 188 127)); $g.FillEllipse($b, 1300, 240, 120, 120); $b.Dispose()
for ($k = 0; $k -lt 7; $k++) {
  $ang = -0.5 + $k * 0.28
  $pen = New-Object System.Drawing.Pen((C 22 219 188 127), 22)
  $g.DrawLine($pen, 1360, 300, (1360 + [int](900 * [math]::Cos($ang))), (300 + [int](900 * [math]::Sin($ang)))); $pen.Dispose()
}
# far ridge
$g.FillPolygon((New-Object System.Drawing.SolidBrush((C 255 64 76 76))),
  (MkPts @(@(0, $H), @(0, 620), @(300, 520), @(640, 640), @(1000, 540), @(1400, 660), @($W, 560), @($W, $H))))
# pine layers: small trees, dense rows, mist between
$layers = @(
  @(700, (C 255 56 68 68), 60, 110),
  @(830, (C 255 47 57 58), 80, 140),
  @(960, (C 255 38 47 49), 100, 170),
  @(1075, (C 255 30 38 40), 120, 200)
)
foreach ($ly in $layers) {
  $baseY = $ly[0]; $col = $ly[1]; $minH = $ly[2]; $maxH = $ly[3]
  $b = New-Object System.Drawing.SolidBrush($col)
  $tx = -30
  while ($tx -lt $W + 30) {
    $th = $rng.Next($minH, $maxH)
    $half = [int]($th * 0.34)
    # tiered pine: three overlapping triangles, each tier narrower
    for ($k = 0; $k -lt 3; $k++) {
      $tierBase = $baseY - [int]($th * 0.26 * $k)
      $tierHalf = [int]($half * (1.0 - 0.26 * $k))
      $tierTop = $tierBase - [int]($th * 0.5)
      $g.FillPolygon($b, (MkPts @(@(($tx - $tierHalf), $tierBase), @($tx, $tierTop), @(($tx + $tierHalf), $tierBase))))
    }
    $tx += $rng.Next(26, 52)
  }
  $b.Dispose()
  $mist = New-Object System.Drawing.SolidBrush((C 38 211 198 170))
  $g.FillRectangle($mist, 0, ($baseY - 14), $W, 56); $mist.Dispose()
  Glow $g $rng.Next(300, 1600) $baseY 300 (C 26 211 198 170)
}
# birds
$pen = New-Object System.Drawing.Pen((C 120 35 42 44), 3)
foreach ($bd in @(@(420, 300), @(500, 340), @(360, 380), @(620, 260))) {
  $g.DrawArc($pen, $bd[0], $bd[1], 26, 18, 200, 140)
  $g.DrawArc($pen, ($bd[0] + 26), $bd[1], 26, 18, 200, 140)
}
$pen.Dispose()
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
Stamp $g $heart 250 180 18 (C 90 155 188 15)
Stamp $g $alien 420 560 22 (C 80 139 172 15)
Stamp $g $alien 180 820 14 (C 60 139 172 15)
Stamp $g $heart 660 380 12 (C 55 155 188 15)
# a Tetris well mid-right: settled stack, falling T piece, side panel
$wellX = 1120; $wellY = 220; $cellPx = 44; $wellCols = 10; $wellRows = 17
$pen = New-Object System.Drawing.Pen((C 110 139 172 15), 4)
$g.DrawRectangle($pen, ($wellX - 8), ($wellY - 8), ($wellCols * $cellPx + 16), ($wellRows * $cellPx + 16)); $pen.Dispose()
$stack = @(
  "0000000000", "0000000000", "0000000000", "0000000000", "0000000000",
  "0000000000", "0000000000", "0000000000", "0000000000", "0000000000",
  "0000110000", "0001111000", "1101111011", "1111111111", "1111110111",
  "1111111111", "1110111111"
)
for ($r = 0; $r -lt $wellRows; $r++) {
  for ($c2 = 0; $c2 -lt $wellCols; $c2++) {
    if ($stack[$r][$c2] -ne '1') { continue }
    $al = 70 + 20 * ($r % 3)
    $b = New-Object System.Drawing.SolidBrush((C $al 139 172 15))
    $g.FillRectangle($b, ($wellX + $c2 * $cellPx), ($wellY + $r * $cellPx), ($cellPx - 5), ($cellPx - 5)); $b.Dispose()
    $pen = New-Object System.Drawing.Pen((C 60 15 56 15), 2)
    $g.DrawRectangle($pen, ($wellX + $c2 * $cellPx), ($wellY + $r * $cellPx), ($cellPx - 5), ($cellPx - 5)); $pen.Dispose()
  }
}
# falling T piece
foreach ($pc in @(@(4, 4), @(3, 5), @(4, 5), @(5, 5))) {
  $b = New-Object System.Drawing.SolidBrush((C 130 155 188 15))
  $g.FillRectangle($b, ($wellX + $pc[0] * $cellPx), ($wellY + $pc[1] * $cellPx), ($cellPx - 5), ($cellPx - 5)); $b.Dispose()
}
# score panel: label dashes + digits blocks
for ($k = 0; $k -lt 5; $k++) {
  $b = New-Object System.Drawing.SolidBrush((C 70 139 172 15))
  $g.FillRectangle($b, 1650, (260 + $k * 70), (140 - 18 * ($k % 3)), 18); $b.Dispose()
}
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

# ── LCARS: the classic rail-and-elbow console frame ──
$rng = New-Object System.Random(2364)
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 4 4 6) (C 255 0 0 0)
$lc = @((C 255 255 153 51), (C 255 153 153 255), (C 255 204 153 204), (C 255 255 204 102), (C 255 224 122 102), (C 255 153 204 255))
# elbow: top bar + left rail joined with a rounded inner corner
$path = New-Object System.Drawing.Drawing2D.GraphicsPath
$path.AddLine(80, 150, 1420, 150)
$path.AddLine(1420, 200, 340, 200)
$path.AddArc(240, 200, 200, 200, 270, -90)
$path.AddLine(240, 300, 240, 540)
$path.AddLine(240, 540, 80, 540)
$path.CloseFigure()
$b = New-Object System.Drawing.SolidBrush($lc[0]); $g.FillPath($b, $path); $b.Dispose(); $path.Dispose()
# capsule cap on the top bar's right end
$b = New-Object System.Drawing.SolidBrush($lc[0]); $g.FillEllipse($b, 1395, 150, 50, 50); $b.Dispose()
# secondary thin bar under the top bar
$b = New-Object System.Drawing.SolidBrush($lc[1]); $g.FillRectangle($b, 420, 216, 620, 22); $g.FillEllipse($b, 1029, 216, 22, 22); $g.FillEllipse($b, 409, 216, 22, 22); $b.Dispose()
# left rail segments below the elbow
$railY = 556
$si = 1
while ($railY -lt $H - 40) {
  $segH = $rng.Next(70, 200)
  if ($railY + $segH -gt $H - 20) { $segH = $H - 20 - $railY }
  $b = New-Object System.Drawing.SolidBrush($lc[$si % $lc.Count])
  $g.FillRectangle($b, 80, $railY, 160, $segH); $b.Dispose()
  $railY += $segH + 14
  $si++
}
# data blocks: short colored bars right of the rail, like readouts
for ($k = 0; $k -lt 9; $k++) {
  $cc = $lc[$rng.Next(0, $lc.Count)]
  $bw2 = $rng.Next(40, 180)
  $b = New-Object System.Drawing.SolidBrush((C 200 $cc.R $cc.G $cc.B))
  $g.FillRectangle($b, (1560 + $rng.Next(0, 120)), (300 + $k * 78), $bw2, 26); $b.Dispose()
}
# bottom-right footer bar with capsule ends
$b = New-Object System.Drawing.SolidBrush($lc[3]); $g.FillRectangle($b, 420, ($H - 70), 900, 34); $g.FillEllipse($b, 403, ($H - 70), 34, 34); $g.FillEllipse($b, 1303, ($H - 70), 34, 34); $b.Dispose()
$b = New-Object System.Drawing.SolidBrush($lc[4]); $g.FillRectangle($b, 1370, ($H - 70), 220, 34); $b.Dispose()
Save $bmp $g "lcars.png"

# ── TRON: grid floor, light-cycle trails, recognizer ──
$rng = New-Object System.Random(1982)
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 7 11 18) (C 255 2 4 8)
$horizon = 430
# sky: faint arcs of the MCP disc
foreach ($r in @(200, 260, 330)) {
  $pen = New-Object System.Drawing.Pen((C 26 0 229 255), 2)
  $g.DrawEllipse($pen, (1450 - $r), (150 - $r), (2 * $r), (2 * $r)); $pen.Dispose()
}
# horizon glow line
Glow $g 960 $horizon 560 (C 46 0 229 255)
$pen = New-Object System.Drawing.Pen((C 140 0 229 255), 2); $g.DrawLine($pen, 0, $horizon, $W, $horizon); $pen.Dispose()
# perspective grid floor
for ($i = -16; $i -le 16; $i++) {
  $pen = New-Object System.Drawing.Pen((C 60 0 170 200), 1)
  $g.DrawLine($pen, (960 + $i * 34), $horizon, (960 + $i * 260), $H); $pen.Dispose()
}
$gy = $horizon + 5; $step = 5
while ($gy -lt $H) {
  $pen = New-Object System.Drawing.Pen((C 66 0 170 200), 1)
  $g.DrawLine($pen, 0, $gy, $W, $gy); $pen.Dispose()
  $step = [int]($step * 1.33) + 1; $gy += $step
}
# light-cycle trails: glowing walls with right-angle jogs
$cyan = (C 235 0 240 255)
foreach ($seg in @(@(330, 1080, 330, 800), @(330, 800, 880, 800), @(880, 800, 880, 620))) {
  $pen = New-Object System.Drawing.Pen($cyan, 6)
  $g.DrawLine($pen, $seg[0], $seg[1], $seg[2], $seg[3]); $pen.Dispose()
  Glow $g ([int](($seg[0] + $seg[2]) / 2)) ([int](($seg[1] + $seg[3]) / 2)) 120 (C 60 0 240 255)
}
$orange = (C 235 255 136 54)
foreach ($seg in @(@(1610, 1080, 1610, 720), @(1610, 720, 1150, 720), @(1150, 720, 1150, 560))) {
  $pen = New-Object System.Drawing.Pen($orange, 6)
  $g.DrawLine($pen, $seg[0], $seg[1], $seg[2], $seg[3]); $pen.Dispose()
  Glow $g ([int](($seg[0] + $seg[2]) / 2)) ([int](($seg[1] + $seg[3]) / 2)) 120 (C 60 255 136 54)
}
# recognizer silhouette hovering top-center
$ink = New-Object System.Drawing.SolidBrush((C 255 4 7 12))
$g.FillRectangle($ink, 820, 110, 60, 190)
$g.FillRectangle($ink, 1060, 110, 60, 190)
$g.FillRectangle($ink, 820, 70, 300, 60)
$ink.Dispose()
$pen = New-Object System.Drawing.Pen((C 170 0 229 255), 2)
$g.DrawRectangle($pen, 820, 70, 300, 60); $g.DrawRectangle($pen, 820, 110, 60, 190); $g.DrawRectangle($pen, 1060, 110, 60, 190)
$pen.Dispose()
$b = New-Object System.Drawing.SolidBrush((C 200 255 136 54)); $g.FillRectangle($b, 940, 84, 60, 30); $b.Dispose()
Save $bmp $g "tron.png"

# ── Monokai: neon ribbon sweep with drifting code glyphs ──
$rng = New-Object System.Random(2006)
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 43 44 36) (C 255 28 29 24)
$mk = @((C 255 249 38 114), (C 255 166 226 46), (C 255 102 217 239), (C 255 253 151 31), (C 255 230 219 116))
for ($k = 0; $k -lt 5; $k++) {
  $cc = $mk[$k]
  $off = 900 + $k * 190
  $al = 96 - 12 * $k
  $b = New-Object System.Drawing.SolidBrush((C $al $cc.R $cc.G $cc.B))
  $g.FillPolygon($b, (MkPts @(@($off, 0), @(($off + 90), 0), @(($off - 610), $H), @(($off - 700), $H))))
  $b.Dispose()
  Glow $g ($off - 300) 540 200 (C ([int]($al / 3)) $cc.R $cc.G $cc.B)
}
$font = New-Object System.Drawing.Font("Consolas", 26, [System.Drawing.FontStyle]::Bold)
$glyphs = "{}();=<>[]&|!?:".ToCharArray()
for ($i = 0; $i -lt 70; $i++) {
  $cc = $mk[$rng.Next(0, $mk.Count)]
  $b = New-Object System.Drawing.SolidBrush((C $rng.Next(16, 60) $cc.R $cc.G $cc.B))
  $g.DrawString($glyphs[$rng.Next(0, $glyphs.Count)], $font, $b, $rng.Next(0, $W), $rng.Next(0, $H)); $b.Dispose()
}
$font.Dispose()
foreach ($corner in @(@(0, 0), @($W, 0), @(0, $H), @($W, $H))) {
  Glow $g $corner[0] $corner[1] 560 (C 70 0 0 0)
}
Save $bmp $g "monokai.png"

# ── Solarized Light: ink sun and arcs on warm paper ──
$rng = New-Object System.Random(1854)
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 253 246 227) (C 255 238 232 213)
# faint ruled grid
$pen = New-Object System.Drawing.Pen((C 10 101 123 131), 1)
for ($gx = 0; $gx -lt $W; $gx += 120) { $g.DrawLine($pen, $gx, 0, $gx, $H) }
for ($gy = 0; $gy -lt $H; $gy += 120) { $g.DrawLine($pen, 0, $gy, $W, $gy) }
$pen.Dispose()
# sun upper-right with concentric arc rings
Glow $g 1430 300 460 (C 60 181 137 0)
$b = New-Object System.Drawing.SolidBrush((C 210 181 137 0)); $g.FillEllipse($b, 1340, 210, 180, 180); $b.Dispose()
foreach ($r in @(170, 240, 320, 410, 510)) {
  $pen = New-Object System.Drawing.Pen((C 60 181 137 0), 2)
  $g.DrawArc($pen, (1430 - $r), (300 - $r), (2 * $r), (2 * $r), 100, 250); $pen.Dispose()
}
$pen = New-Object System.Drawing.Pen((C 70 203 75 22), 2)
$g.DrawArc($pen, (1430 - 280), (300 - 280), 560, 560, 140, 90); $pen.Dispose()
# horizon + dune hills in ink washes
$pen = New-Object System.Drawing.Pen((C 70 101 123 131), 2); $g.DrawLine($pen, 0, 800, $W, 800); $pen.Dispose()
$path = New-Object System.Drawing.Drawing2D.GraphicsPath
$path.AddBezier(0, 890, 500, 810, 900, 950, $W, 860)
$path.AddLine($W, 860, $W, $H); $path.AddLine($W, $H, 0, $H); $path.CloseFigure()
$b = New-Object System.Drawing.SolidBrush((C 30 181 137 0)); $g.FillPath($b, $path); $b.Dispose(); $path.Dispose()
$path = New-Object System.Drawing.Drawing2D.GraphicsPath
$path.AddBezier(0, 980, 600, 930, 1200, 1030, $W, 950)
$path.AddLine($W, 950, $W, $H); $path.AddLine($W, $H, 0, $H); $path.CloseFigure()
$b = New-Object System.Drawing.SolidBrush((C 34 203 75 22)); $g.FillPath($b, $path); $b.Dispose(); $path.Dispose()
# birds
$pen = New-Object System.Drawing.Pen((C 110 88 110 117), 2)
foreach ($bd in @(@(420, 330), @(520, 290), @(360, 420), @(640, 370), @(760, 300))) {
  $g.DrawArc($pen, $bd[0], $bd[1], 30, 20, 200, 140)
  $g.DrawArc($pen, ($bd[0] + 30), $bd[1], 30, 20, 200, 140)
}
$pen.Dispose()
# paper grain
for ($i = 0; $i -lt 4000; $i++) {
  $b = New-Object System.Drawing.SolidBrush((C $rng.Next(4, 10) 88 70 50))
  $g.FillRectangle($b, $rng.Next(0, $W), $rng.Next(0, $H), 1, 1); $b.Dispose()
}
Save $bmp $g "solarizedlight.png"

"done -> $out"
