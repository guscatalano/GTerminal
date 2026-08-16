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

# ── Cyberpunk: neon night city, design pass ──
# Hierarchy: one hero (the holo-ad), two signboards, rings anchored on a
# real spire. Palette roles: cyan primary, magenta counter, gold rare.
# True indigo-black grounds so the neon has darkness to cut through.
function GradRect {
  param($g, $x, $y, $wd, $ht, $c1, $c2)
  if ($ht -le 0 -or $wd -le 0) { return }
  $rect = New-Object System.Drawing.Rectangle([int]$x, [int]$y, [int]$wd, [int]$ht)
  $br = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $c1, $c2, 90.0)
  $g.FillRectangle($br, $rect); $br.Dispose()
}
function NeonLine {
  param($g, $x1, $y1, $x2, $y2, $cr, $cg, $cb)
  foreach ($pass in @(@(11, 16), @(6, 44), @(3, 110), @(1, 210))) {
    $pen = New-Object System.Drawing.Pen((C $pass[1] $cr $cg $cb), $pass[0])
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $g.DrawLine($pen, [single]$x1, [single]$y1, [single]$x2, [single]$y2); $pen.Dispose()
  }
  $wr = [int](($cr + 510) / 3); $wg = [int](($cg + 510) / 3); $wb = [int](($cb + 510) / 3)
  $pen = New-Object System.Drawing.Pen((C 150 $wr $wg $wb), 1)
  $g.DrawLine($pen, [single]$x1, [single]$y1, [single]$x2, [single]$y2); $pen.Dispose()
}
function NeonFrame {
  param($g, $x, $y, $wd, $ht, $cr, $cg, $cb)
  foreach ($pass in @(@(9, 16), @(5, 44), @(2, 120), @(1, 200))) {
    $pen = New-Object System.Drawing.Pen((C $pass[1] $cr $cg $cb), $pass[0])
    $g.DrawRectangle($pen, [single]$x, [single]$y, [single]$wd, [single]$ht); $pen.Dispose()
  }
}
function NeonOval {
  param($g, $x, $y, $wd, $ht, $cr, $cg, $cb)
  foreach ($pass in @(@(6, 14), @(3, 40), @(2, 90))) {
    $pen = New-Object System.Drawing.Pen((C $pass[1] $cr $cg $cb), $pass[0])
    $g.DrawEllipse($pen, [single]$x, [single]$y, [single]$wd, [single]$ht); $pen.Dispose()
  }
}

$rng = New-Object System.Random(2077)
$bmp = New-Object System.Drawing.Bitmap(3840, 2160)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
$g.ScaleTransform(2.0, 2.0)

# ── sky: true dark indigo up top, restrained dusk at the horizon ──
Fill-Vertical $g (C 255 10 7 20) (C 255 30 16 52)
GradRect $g 0 420 $W 360 (C 0 226 60 150) (C 34 226 60 150)
GradRect $g 0 0 $W 320 (C 60 6 4 14) (C 0 6 4 14)
Glow $g 960 700 700 (C 22 255 63 168)
Glow $g 1350 690 420 (C 18 20 235 255)
# stars, sparse and quiet
for ($i = 0; $i -lt 130; $i++) {
  $b = New-Object System.Drawing.SolidBrush((C $rng.Next(14, 60) 214 210 235))
  $g.FillEllipse($b, $rng.Next(0, $W), $rng.Next(0, 330), $rng.Next(1, 3), $rng.Next(1, 3)); $b.Dispose()
}
# moon: quiet witness, not a feature
Glow $g 300 140 160 (C 20 220 214 240)
$b = New-Object System.Drawing.SolidBrush((C 44 222 216 242)); $g.FillEllipse($b, 250, 90, 100, 100); $b.Dispose()

# ── depth A: farthest ridge, tone-on-tone ──
$x = -20
while ($x -lt $W) {
  $bw = $rng.Next(50, 110); $h2 = $rng.Next(110, 240)
  GradRect $g $x (620 - $h2) $bw (460 + $h2) (C 255 40 24 70) (C 255 30 16 52)
  $x += $bw + $rng.Next(2, 10)
}
GradRect $g 0 440 $W 250 (C 0 50 28 84) (C 86 50 28 84)

# ── depth B: far towers, dim windows ──
$x = -30
while ($x -lt $W) {
  $bw = $rng.Next(70, 160); $h2 = $rng.Next(220, 410)
  $top = 690 - $h2
  GradRect $g $x $top $bw (390 + $h2) (C 255 32 18 56) (C 255 18 11 34)
  if ($rng.NextDouble() -lt 0.35) {
    GradRect $g ($x + [int]($bw * 0.22)) ($top - 32) ([int]($bw * 0.56)) 32 (C 255 32 18 56) (C 255 28 16 50)
  }
  for ($i = 0; $i -lt [int]($bw * $h2 / 4200); $i++) {
    $cc = if ($rng.NextDouble() -lt 0.7) { C $rng.Next(20, 52) 110 225 250 } else { C $rng.Next(20, 52) 255 110 205 }
    $b = New-Object System.Drawing.SolidBrush($cc)
    $g.FillRectangle($b, ($x + $rng.Next(4, $bw - 6)), ($top + $rng.Next(10, $h2)), 3, 4); $b.Dispose()
  }
  $x += $bw + $rng.Next(4, 16)
}
GradRect $g 0 560 $W 200 (C 0 46 26 78) (C 70 46 26 78)

# ── traffic trails live BEHIND the mid layer: three, no dot heads ──
foreach ($tr in @(@(300, 520, 560, 20, 235, 255), @(1050, 480, 520, 255, 63, 168), @(700, 590, 460, 255 , 210, 63))) {
  $tx = $tr[0]; $ty = $tr[1]; $tl = $tr[2]; $cr = $tr[3]; $cg = $tr[4]; $cb = $tr[5]
  for ($seg = 0; $seg -lt $tl; $seg += 5) {
    $t = $seg / [double]$tl
    $fade = [int](120 * $t * $t)
    if ($fade -le 2) { continue }
    $b = New-Object System.Drawing.SolidBrush((C $fade $cr $cg $cb))
    $g.FillRectangle($b, ($tx + $seg), ($ty - [int]($seg / 46)), 5, ([int](1 + 2 * $t))); $b.Dispose()
  }
}

# ── depth C: mid towers — per-building hue bias, quiet texture ──
$midTowers = @()
$x = -40
while ($x -lt $W) {
  $bw = $rng.Next(120, 270); $h2 = $rng.Next(380, 640)
  $top = $H - $h2 - 40
  $midTowers += , @($x, $top, $bw)
  GradRect $g $x $top $bw ($h2 + 40) (C 255 15 10 28) (C 255 7 5 14)
  if ($rng.NextDouble() -lt 0.45) {
    $crW = [int]($bw * (0.4 + 0.3 * $rng.NextDouble()))
    GradRect $g ($x + [int](($bw - $crW) / 2)) ($top - 42) $crW 42 (C 255 17 11 31) (C 255 13 9 25)
  }
  # district hue: most towers cool cyan, some warm gold, few magenta
  $district = $rng.NextDouble()
  for ($wy = $top + 16; $wy -lt $H - 60; $wy += 24) {
    $litFrac = 0.06 + 0.42 * $rng.NextDouble() * $rng.NextDouble()
    for ($wx = $x + 10; $wx -lt $x + $bw - 12; $wx += 17) {
      if ($rng.NextDouble() -gt $litFrac) { continue }
      $bri = $rng.Next(34, 120)
      $mix = $rng.NextDouble()
      if ($district -lt 0.55) { $cc = if ($mix -lt 0.8) { C $bri 110 225 250 } else { C $bri 250 226 70 } }
      elseif ($district -lt 0.82) { $cc = if ($mix -lt 0.8) { C $bri 250 214 90 } else { C $bri 110 225 250 } }
      else { $cc = if ($mix -lt 0.8) { C $bri 255 110 205 } else { C $bri 110 225 250 } }
      $b = New-Object System.Drawing.SolidBrush($cc); $g.FillRectangle($b, $wx, $wy, 6, 9); $b.Dispose()
      if ($bri -gt 108) { Glow $g ($wx + 3) ($wy + 4) 12 (C 40 $cc.R $cc.G $cc.B) }
    }
  }
  if ($rng.NextDouble() -lt 0.5) {
    if ($rng.NextDouble() -lt 0.68) { NeonLine $g $x $top ($x + $bw) $top 20 235 255 }
    else { NeonLine $g $x $top ($x + $bw) $top 255 63 168 }
  }
  if ($rng.NextDouble() -lt 0.4) {
    $ax = $x + $rng.Next(20, $bw - 20)
    $mastH = $rng.Next(36, 84)
    # mast readable against the sky: dark core with a lit edge
    $pen = New-Object System.Drawing.Pen((C 255 8 6 16), 3)
    $g.DrawLine($pen, $ax, $top, $ax, ($top - $mastH)); $pen.Dispose()
    $pen = New-Object System.Drawing.Pen((C 90 120 200 235), 1)
    $g.DrawLine($pen, ($ax - 1), $top, ($ax - 1), ($top - $mastH)); $pen.Dispose()
    Glow $g $ax ($top - $mastH) 16 (C 45 255 55 70)
    $b = New-Object System.Drawing.SolidBrush((C 235 255 90 95)); $g.FillEllipse($b, ($ax - 2), ($top - $mastH - 3), 5, 5); $b.Dispose()
  }
  if ($rng.NextDouble() -lt 0.22 -and $bw -gt 160) {
    $bbx = $x + $rng.Next(16, $bw - 100); $bby = $top + $rng.Next(70, 230)
    $warm = $rng.NextDouble() -lt 0.5
    if ($warm) { GradRect $g $bbx $bby 84 46 (C 110 250 220 70) (C 55 250 160 30) }
    else { GradRect $g $bbx $bby 84 46 (C 110 60 220 250) (C 55 20 140 190) }
    for ($sy2 = $bby + 4; $sy2 -lt $bby + 46; $sy2 += 5) {
      $pen = New-Object System.Drawing.Pen((C 60 10 7 20), 2); $g.DrawLine($pen, $bbx, $sy2, ($bbx + 84), $sy2); $pen.Dispose()
    }
    if ($warm) { NeonFrame $g $bbx $bby 84 46 250 214 90 } else { NeonFrame $g $bbx $bby 84 46 20 235 255 }
  }
  $x += $bw + $rng.Next(12, 44)
}
# skyways
foreach ($k in 0..($midTowers.Count - 2)) {
  if ($rng.NextDouble() -gt 0.28) { continue }
  $a = $midTowers[$k]; $c2 = $midTowers[$k + 1]
  $bx = $a[0] + $a[2]; $bw2 = $c2[0] - $bx
  if ($bw2 -lt 12 -or $bw2 -gt 140) { continue }
  $byy = [math]::Max($a[1], $c2[1]) + $rng.Next(70, 210)
  GradRect $g ($bx - 6) $byy ($bw2 + 12) 14 (C 255 12 8 22) (C 255 7 5 14)
  for ($wx = $bx; $wx -lt $bx + $bw2; $wx += 11) {
    $b = New-Object System.Drawing.SolidBrush((C 110 250 226 70))
    $g.FillRectangle($b, $wx, ($byy + 4), 4, 4); $b.Dispose()
  }
}
# ── the spire: rises clear above the skyline, rings on its crown ──
GradRect $g 1222 330 34 ($H - 330) (C 255 22 15 40) (C 255 9 7 18)
$pen = New-Object System.Drawing.Pen((C 80 120 200 235), 1)
$g.DrawLine($pen, 1222, 330, 1222, 700); $pen.Dispose()
GradRect $g 1214 470 50 22 (C 255 16 11 30) (C 255 12 9 24)
GradRect $g 1214 610 50 26 (C 255 15 10 28) (C 255 11 8 22)
$pen = New-Object System.Drawing.Pen((C 255 9 6 17), 3); $g.DrawLine($pen, 1239, 330, 1239, 286); $pen.Dispose()
$b = New-Object System.Drawing.SolidBrush((C 240 255 90 95)); $g.FillEllipse($b, 1236, 280, 6, 6); $b.Dispose()
Glow $g 1239 283 22 (C 60 255 55 70)
NeonOval $g (1239 - 66) (365 - 14) 132 28 20 235 255
NeonOval $g (1239 - 84) (394 - 17) 168 34 20 235 255
NeonOval $g (1239 - 102) (425 - 20) 204 40 20 235 255

# ── framing megatowers: true black, minimal greebles ──
GradRect $g -60 0 300 $H (C 255 7 5 14) (C 255 4 3 9)
GradRect $g 1690 0 300 $H (C 255 7 5 14) (C 255 4 3 9)
$pen = New-Object System.Drawing.Pen((C 22 90 200 235), 1)
for ($gy = 90; $gy -lt $H; $gy += 110) { $g.DrawLine($pen, 0, $gy, 232, $gy); $g.DrawLine($pen, 1696, $gy, $W, $gy) }
$pen.Dispose()
# ── two signboards: magenta left, gold right ──
$font = New-Object System.Drawing.Font("MS Gothic", 30, [System.Drawing.FontStyle]::Bold)
$boards = @(
  @(116, 150, 600, 255, 63, 168),
  @(1748, 120, 660, 255, 210, 63)
)
foreach ($bd in $boards) {
  $bx = $bd[0]; $by = $bd[1]; $bh = $bd[2]; $cr = $bd[3]; $cg = $bd[4]; $cb = $bd[5]
  $b = New-Object System.Drawing.SolidBrush((C 130 0 0 4))
  $g.FillRectangle($b, ($bx + 8), ($by + 10), 56, $bh); $b.Dispose()
  GradRect $g $bx $by 56 $bh (C 244 9 7 16) (C 244 5 4 10)
  GradRect $g ($bx + 4) ($by + 4) 48 ($bh - 8) (C 26 $cr $cg $cb) (C 9 $cr $cg $cb)
  NeonFrame $g $bx $by 56 $bh $cr $cg $cb
  Glow $g ($bx + 28) ($by + [int]($bh / 2)) 170 (C 24 $cr $cg $cb)
  $slots = [int](($bh - 40) / 46)
  $dead = $rng.Next(0, $slots)
  for ($si2 = 0; $si2 -lt $slots; $si2++) {
    $gy = $by + 16 + $si2 * 46
    $ch = [string][char](0x30A0 + $rng.Next(0, 96))
    if ($si2 -eq $dead) {
      $b = New-Object System.Drawing.SolidBrush((C 50 $cr $cg $cb))
      $g.DrawString($ch, $font, $b, ($bx + 12), $gy); $b.Dispose()
      continue
    }
    Glow $g ($bx + 28) ($gy + 20) 28 (C 50 $cr $cg $cb)
    $b = New-Object System.Drawing.SolidBrush((C 246 $cr $cg $cb))
    $g.DrawString($ch, $font, $b, ($bx + 12), $gy); $b.Dispose()
  }
}
$font.Dispose()

# ── HERO: rooftop-mounted ad screen ──
# host tower under the sign: wide enough to carry the whole span
GradRect $g 730 560 440 ($H - 560) (C 255 13 9 25) (C 255 6 4 12)
GradRect $g 764 528 372 32 (C 255 14 10 27) (C 255 12 8 23)
for ($wy = 600; $wy -lt $H - 80; $wy += 30) {
  for ($wx = 748; $wx -lt 1152; $wx += 24) {
    if ($rng.NextDouble() -gt 0.14) { continue }
    $b = New-Object System.Drawing.SolidBrush((C $rng.Next(30, 80) 110 225 250))
    $g.FillRectangle($b, $wx, $wy, 6, 9); $b.Dispose()
  }
}
# mounting rig: posts, cross-braces, catwalk
$steel = New-Object System.Drawing.SolidBrush((C 255 10 8 18))
$g.FillRectangle($steel, 768, 372, 14, 160)
$g.FillRectangle($steel, 1118, 372, 14, 160)
$g.FillRectangle($steel, 930, 372, 10, 160)
$steel.Dispose()
$pen = New-Object System.Drawing.Pen((C 255 10 8 18), 5)
$g.DrawLine($pen, 775, 400, 1125, 528); $g.DrawLine($pen, 1125, 400, 775, 528)
$pen.Dispose()
# faint cyan edge light catching the near side of each post
$pen = New-Object System.Drawing.Pen((C 60 110 225 250), 1)
$g.DrawLine($pen, 768, 372, 768, 532); $g.DrawLine($pen, 1118, 372, 1118, 532)
$pen.Dispose()
# catwalk with a center service light
GradRect $g 700 370 500 11 (C 255 12 9 21) (C 255 8 6 15)
$b = New-Object System.Drawing.SolidBrush((C 220 250 214 90)); $g.FillEllipse($b, 946, 374, 6, 6); $b.Dispose()
Glow $g 949 377 20 (C 60 250 214 90)
# searchlight, anchored: emitter housing on the host tower roof
$path = New-Object System.Drawing.Drawing2D.GraphicsPath
$path.AddPolygon((MkPts @(@(852, 552), @(560, 60), @(672, 36))))
$br = New-Object System.Drawing.Drawing2D.PathGradientBrush($path)
$br.CenterColor = (C 11 200 230 255)
$br.SurroundColors = @((C 0 200 230 255))
$g.FillPath($br, $path); $br.Dispose(); $path.Dispose()
$b = New-Object System.Drawing.SolidBrush((C 255 11 8 20)); $g.FillRectangle($b, 840, 546, 24, 14); $b.Dispose()
$b = New-Object System.Drawing.SolidBrush((C 200 200 235 255)); $g.FillEllipse($b, 848, 549, 8, 8); $b.Dispose()
foreach ($off in @(8, 0)) {
  $al = if ($off -eq 0) { 50 } else { 14 }
  GradRect $g (690 + $off) 160 520 210 (C $al 30 240 255) (C ([int]($al / 4)) 30 240 255)
}
NeonFrame $g 690 160 520 210 20 235 255
foreach ($tick in @(@(690, 160, -14, -14), @(1210, 160, 14, -14), @(690, 370, -14, 14), @(1210, 370, 14, 14))) {
  NeonLine $g $tick[0] $tick[1] ($tick[0] + $tick[2]) ($tick[1] + $tick[3]) 20 235 255
}
for ($gy = 166; $gy -lt 366; $gy += 6) {
  $pen = New-Object System.Drawing.Pen((C 30 8 6 16), 2)
  $g.DrawLine($pen, 692, $gy, 1208, $gy); $pen.Dispose()
}
# title
$font = New-Object System.Drawing.Font("MS Gothic", 58, [System.Drawing.FontStyle]::Bold)
Glow $g 945 245 170 (C 40 60 240 255)
$b = New-Object System.Drawing.SolidBrush((C 230 160 250 255))
$g.DrawString(([string][char](0x30B5) + [string][char](0x30A4) + [string][char](0x30D0) + [string][char](0x30FC)), $font, $b, 758, 196)
$b.Dispose(); $font.Dispose()
# divider + subtitle row + logo chip: reads as an ad, not a wireframe
$pen = New-Object System.Drawing.Pen((C 110 20 235 255), 1); $g.DrawLine($pen, 760, 296, 1140, 296); $pen.Dispose()
$font = New-Object System.Drawing.Font("MS Gothic", 20, [System.Drawing.FontStyle]::Bold)
$sub = ""
foreach ($k in 1..7) { $sub += [string][char](0x30A0 + $rng.Next(0, 96)) }
$b = New-Object System.Drawing.SolidBrush((C 130 120 230 250))
$g.DrawString($sub, $font, $b, 760, 312); $b.Dispose(); $font.Dispose()
$b = New-Object System.Drawing.SolidBrush((C 170 255 63 168)); $g.FillRectangle($b, 1104, 310, 34, 34); $b.Dispose()
$b = New-Object System.Drawing.SolidBrush((C 244 9 7 16)); $g.FillRectangle($b, 1112, 318, 18, 18); $b.Dispose()
$b = New-Object System.Drawing.SolidBrush((C 235 255 55 75)); $g.FillEllipse($b, 1178, 174, 11, 11); $b.Dispose()
Glow $g 1183 179 24 (C 80 255 55 75)
Glow $g 950 260 300 (C 26 20 235 255)

# ── street: teal-dominant sheen, grouped reflections ──
Glow $g 760 1130 520 (C 66 20 235 255)
Glow $g 1250 1150 520 (C 52 255 63 168)
GradRect $g 0 ($H - 220) $W 220 (C 0 24 90 110) (C 46 24 90 110)
foreach ($grp in 1..6) {
  $gx0 = $rng.Next(300, 1620)
  $grpRoll = $rng.NextDouble()
  $cr = 20; $cg = 235; $cb = 255
  if ($grpRoll -gt 0.62 -and $grpRoll -lt 0.85) { $cr = 255; $cg = 63; $cb = 168 }
  elseif ($grpRoll -ge 0.85) { $cr = 250; $cg = 214; $cb = 90 }
  foreach ($k in 1..$rng.Next(4, 8)) {
    $rx = $gx0 + $rng.Next(-46, 46)
    $rh = $rng.Next(60, 150)
    $baseAl = $rng.Next(22, 55)
    for ($seg2 = 0; $seg2 -lt 5; $seg2++) {
      $al2 = [int]($baseAl * ($seg2 + 1) / 5)
      $b = New-Object System.Drawing.SolidBrush((C $al2 $cr $cg $cb))
      $g.FillRectangle($b, $rx, ($H - $rh + [int]($rh * $seg2 / 5)), $rng.Next(3, 7), [int]($rh / 5)); $b.Dispose()
    }
  }
}
# ── grade: indigo shadows, restrained magenta lift, vignette ──
GradRect $g 0 0 $W 380 (C 24 8 6 24) (C 0 8 6 24)
GradRect $g 0 ($H - 380) $W 380 (C 0 90 20 70) (C 18 90 20 70)
foreach ($corner in @(@(0, 0), @($W, 0), @(0, $H), @($W, $H))) {
  Glow $g $corner[0] $corner[1] 500 (C 56 0 0 5)
}
for ($i = 0; $i -lt 2400; $i++) {
  $tone = if ($rng.NextDouble() -lt 0.5) { 255 } else { 0 }
  $b = New-Object System.Drawing.SolidBrush((C $rng.Next(4, 10) $tone $tone $tone))
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

# ── Deep Space: planet limb with sunrise, ringed giant, nebulae, station ──
$rng = New-Object System.Random(1969)
$bmp = New-Object System.Drawing.Bitmap(3840, 2160)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.ScaleTransform(2.0, 2.0)
Fill-Vertical $g (C 255 6 9 19) (C 255 10 14 28)
# nebulae: overlapping soft fields, violet and teal
Glow $g 420 260 460 (C 30 120 80 220)
Glow $g 560 380 300 (C 24 160 70 190)
Glow $g 1500 180 400 (C 26 40 160 200)
Glow $g 1350 300 240 (C 20 70 190 210)
Glow $g 1000 500 500 (C 14 90 60 180)
for ($i = 0; $i -lt 900; $i++) {
  $nx = $rng.Next(0, $W); $ny = $rng.Next(0, 700)
  $near = [math]::Exp(-([math]::Pow($nx - 480, 2) + [math]::Pow($ny - 300, 2)) / 180000) + [math]::Exp(-([math]::Pow($nx - 1450, 2) + [math]::Pow($ny - 240, 2)) / 140000)
  if ($rng.NextDouble() -gt $near) { continue }
  $cc = if ($rng.NextDouble() -lt 0.5) { C $rng.Next(8, 26) 150 100 230 } else { C $rng.Next(8, 26) 70 180 220 }
  $b = New-Object System.Drawing.SolidBrush($cc)
  $g.FillEllipse($b, $nx, $ny, $rng.Next(2, 7), $rng.Next(2, 7)); $b.Dispose()
}
# starfield: sizes, tints, sparkles on the brightest
for ($i = 0; $i -lt 620; $i++) {
  $mag = $rng.NextDouble()
  $sal = [int](20 + 200 * $mag * $mag)
  $tint = $rng.NextDouble()
  $cc = if ($tint -lt 0.12) { C $sal 170 200 255 } elseif ($tint -lt 0.2) { C $sal 255 220 170 } else { C $sal 235 240 250 }
  $sx = $rng.Next(0, $W); $sy2 = $rng.Next(0, $H)
  $sz = if ($mag -gt 0.97) { 3 } elseif ($mag -gt 0.86) { 2 } else { 1 }
  $b = New-Object System.Drawing.SolidBrush($cc); $g.FillEllipse($b, $sx, $sy2, $sz, $sz); $b.Dispose()
  if ($mag -gt 0.985) {
    $pen = New-Object System.Drawing.Pen((C 90 235 240 250), 1)
    $g.DrawLine($pen, ($sx - 7), ($sy2 + 1), ($sx + 8), ($sy2 + 1))
    $g.DrawLine($pen, ($sx + 1), ($sy2 - 7), ($sx + 1), ($sy2 + 8)); $pen.Dispose()
    Glow $g $sx $sy2 12 (C 80 235 240 250)
  }
}
# comet: tapered tail toward upper left
for ($seg = 0; $seg -lt 260; $seg += 3) {
  $t = $seg / 260.0
  $al = [int](130 * $t * $t)
  if ($al -le 2) { continue }
  $b = New-Object System.Drawing.SolidBrush((C $al 200 230 255))
  $g.FillEllipse($b, (300 + $seg), (120 + [int]($seg * 0.22)), (1 + [int](2 * $t)), (1 + [int](2 * $t))); $b.Dispose()
}
Glow $g 560 177 26 (C 130 220 240 255)
$b = New-Object System.Drawing.SolidBrush((C 240 240 250 255)); $g.FillEllipse($b, 557, 174, 5, 5); $b.Dispose()
# ── ringed gas giant, upper right ──
$gcx = 1430.0; $gcy = 300.0; $gr2 = 150.0
# back half of the ring system
foreach ($ring in @(@(300, 74, 95), @(258, 62, 65), @(348, 88, 48))) {
  $pen = New-Object System.Drawing.Pen((C $ring[2] 190 200 225), 4)
  $g.DrawArc($pen, ($gcx - $ring[0] / 2), ($gcy - $ring[1] / 2), $ring[0], $ring[1], 180.0, 180.0); $pen.Dispose()
}
# body: soft-shaded sphere with bands
$path = New-Object System.Drawing.Drawing2D.GraphicsPath
$path.AddEllipse(($gcx - $gr2), ($gcy - $gr2), (2 * $gr2), (2 * $gr2))
$br = New-Object System.Drawing.Drawing2D.PathGradientBrush($path)
$br.CenterPoint = New-Object System.Drawing.PointF(($gcx - 50), ($gcy - 60))
$br.CenterColor = (C 255 150 160 205)
$br.SurroundColors = @((C 255 40 48 86))
$g.FillPath($br, $path); $br.Dispose(); $path.Dispose()
$clip = New-Object System.Drawing.Drawing2D.GraphicsPath
$clip.AddEllipse(($gcx - $gr2), ($gcy - $gr2), (2 * $gr2), (2 * $gr2))
$g.SetClip($clip)
foreach ($band in @(@(-96, 16, 40), @(-52, 22, 30), @(6, 18, 44), @(58, 14, 34), @(96, 10, 26))) {
  $b = New-Object System.Drawing.SolidBrush((C $band[2] 90 100 150))
  $g.FillRectangle($b, ($gcx - $gr2), ($gcy + $band[0]), (2 * $gr2), $band[1]); $b.Dispose()
}
$g.ResetClip(); $clip.Dispose()
# front half of the rings, crossing the disc
foreach ($ring in @(@(300, 74, 160), @(258, 62, 105), @(348, 88, 75))) {
  $pen = New-Object System.Drawing.Pen((C $ring[2] 205 215 235), 4)
  $g.DrawArc($pen, ($gcx - $ring[0] / 2), ($gcy - $ring[1] / 2), $ring[0], $ring[1], 0.0, 180.0); $pen.Dispose()
}
Glow $g $gcx $gcy 260 (C 22 150 160 210)
# ── space station silhouette, small, left-center ──
$st = New-Object System.Drawing.SolidBrush((C 255 16 22 38))
$g.FillRectangle($st, 690, 415, 92, 12)
$g.FillRectangle($st, 722, 401, 28, 40)
$g.FillRectangle($st, 662, 418, 30, 6)
$g.FillRectangle($st, 780, 418, 30, 6)
$st.Dispose()
foreach ($pan in @(@(636, 408), @(806, 408))) {
  GradRect $g $pan[0] $pan[1] 28 26 (C 220 40 70 140) (C 220 20 40 90)
  $pen = New-Object System.Drawing.Pen((C 120 90 130 200), 1)
  $g.DrawRectangle($pen, $pan[0], $pan[1], 28, 26)
  $g.DrawLine($pen, ($pan[0] + 14), $pan[1], ($pan[0] + 14), ($pan[1] + 26)); $pen.Dispose()
}
foreach ($wl in @(@(700, 419), @(712, 419), @(740, 419), @(758, 419))) {
  $b = New-Object System.Drawing.SolidBrush((C 190 250 235 180)); $g.FillRectangle($b, $wl[0], $wl[1], 3, 3); $b.Dispose()
}
$b = New-Object System.Drawing.SolidBrush((C 230 255 80 90)); $g.FillEllipse($b, 686, 412, 4, 4); $b.Dispose()
$b = New-Object System.Drawing.SolidBrush((C 210 90 255 140)); $g.FillEllipse($b, 810, 412, 4, 4); $b.Dispose()
Glow $g 736 420 40 (C 20 200 220 255)
# ── planet limb: huge arc across the bottom with atmosphere + sunrise ──
$pcx = 700.0; $pcy = 2050.0; $pr = 1150.0
# atmosphere halo first, behind the limb
foreach ($atm in @(@(46, 26, 70, 190, 230), @(30, 60, 70, 190, 230), @(16, 110, 90, 200, 235))) {
  $pen = New-Object System.Drawing.Pen((C $atm[0] $atm[2] $atm[3] $atm[4]), $atm[1])
  $g.DrawEllipse($pen, ($pcx - $pr), ($pcy - $pr), (2 * $pr), (2 * $pr)); $pen.Dispose()
}
# the dark body
$path = New-Object System.Drawing.Drawing2D.GraphicsPath
$path.AddEllipse(($pcx - $pr), ($pcy - $pr), (2 * $pr), (2 * $pr))
$br = New-Object System.Drawing.Drawing2D.PathGradientBrush($path)
$br.CenterPoint = New-Object System.Drawing.PointF($pcx, ($pcy + 300))
$br.CenterColor = (C 255 8 12 24)
$br.SurroundColors = @((C 255 13 20 38))
$g.FillPath($br, $path); $br.Dispose(); $path.Dispose()
# rim light along the limb
$pen = New-Object System.Drawing.Pen((C 160 120 210 240), 2)
$g.DrawEllipse($pen, ($pcx - $pr), ($pcy - $pr), (2 * $pr), (2 * $pr)); $pen.Dispose()
# sunrise sliver: warm arc segment on the limb's right shoulder,
# on-screen at roughly (1112, 977) for this circle
foreach ($sun in @(@(30, 18, 255, 180, 90), @(70, 8, 255, 210, 120), @(150, 3, 255, 240, 200))) {
  $pen = New-Object System.Drawing.Pen((C $sun[0] $sun[2] $sun[3] $sun[4]), $sun[1])
  $g.DrawArc($pen, ($pcx - $pr), ($pcy - $pr), (2 * $pr), (2 * $pr), -76.0, 13.0); $pen.Dispose()
}
Glow $g 1112 977 150 (C 60 255 200 110)
Glow $g 1112 977 60 (C 110 255 230 170)
# city lights sprinkled on the night side
$clip = New-Object System.Drawing.Drawing2D.GraphicsPath
$clip.AddEllipse(($pcx - $pr), ($pcy - $pr), (2 * $pr), (2 * $pr))
$g.SetClip($clip)
for ($i = 0; $i -lt 260; $i++) {
  $ang = ([math]::PI / 180) * $rng.Next(200, 340)
  $rr = $pr * (0.955 - 0.1 * $rng.NextDouble() * $rng.NextDouble())
  $lx = $pcx + $rr * [math]::Cos($ang); $ly = $pcy + $rr * [math]::Sin($ang)
  if ($ly -gt $H -or $ly -lt 660) { continue }
  $b = New-Object System.Drawing.SolidBrush((C $rng.Next(30, 110) 255 205 130))
  $g.FillEllipse($b, $lx, $ly, $rng.Next(1, 4), $rng.Next(1, 3)); $b.Dispose()
}
$g.ResetClip(); $clip.Dispose()
# vignette
foreach ($corner in @(@(0, 0), @($W, 0))) {
  Glow $g $corner[0] $corner[1] 480 (C 50 0 2 8)
}
Save $bmp $g "space.png"

function EdgeFade {
  # subtle vignette: darken one edge with a linear falloff
  param($g, $side, $depth, $alpha)
  switch ($side) {
    "top"    { $rect = New-Object System.Drawing.Rectangle(0, 0, $W, $depth); $ang = 90.0 }
    "bottom" { $rect = New-Object System.Drawing.Rectangle(0, ($H - $depth), $W, $depth); $ang = 270.0 }
    "left"   { $rect = New-Object System.Drawing.Rectangle(0, 0, $depth, $H); $ang = 0.0 }
    "right"  { $rect = New-Object System.Drawing.Rectangle(($W - $depth), 0, $depth, $H); $ang = 180.0 }
  }
  $br = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, (C $alpha 0 0 0), (C 0 0 0 0), $ang)
  $g.FillRectangle($br, $rect); $br.Dispose()
}

# -- Pip-Boy: phosphor-green console screen (researched layout: tabs, list, radio graph, rad gauge, footer, CRT treatment) --
$rng = New-Object System.Random(76)
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 6 24 13) (C 255 2 11 6)
Glow $g 960 520 980 (C 22 26 255 128)            # CRT center bloom
Glow $g 1460 760 380 (C 22 26 255 128)           # bloom behind the graph
Glow $g 470 780 260 (C 16 26 255 128)            # bloom behind the gauge
# phosphor grain
for ($i = 0; $i -lt 1000; $i++) {
  $b = New-Object System.Drawing.SolidBrush((C $rng.Next(7, 22) 26 220 110))
  $g.FillRectangle($b, $rng.Next(0, $W), $rng.Next(0, $H), 1, 1); $b.Dispose()
}
$ln = C 225 26 255 128        # bright phosphor
$lnMid = C 130 24 220 110
$lnDim = C 80 20 180 92

# ── header: five tabs, active one bracketed + filled, underline, sub-ticks ──
foreach ($i in 0..4) {
  $tx = 1090 + $i * 140
  if ($i -eq 1) {
    $b = New-Object System.Drawing.SolidBrush((C 70 26 255 128)); $g.FillRectangle($b, $tx, 82, 118, 34); $b.Dispose()
    $pen = New-Object System.Drawing.Pen($ln, 2); $g.DrawRectangle($pen, $tx, 82, 118, 34); $pen.Dispose()
    # bracket ticks outside the active tab
    $pen = New-Object System.Drawing.Pen($ln, 2)
    $g.DrawLine($pen, ($tx - 8), 82, ($tx - 8), 116); $g.DrawLine($pen, ($tx + 126), 82, ($tx + 126), 116); $pen.Dispose()
    # label bar stand-in
    $b = New-Object System.Drawing.SolidBrush((C 190 26 255 128)); $g.FillRectangle($b, ($tx + 26), 96, 66, 7); $b.Dispose()
  } else {
    $b = New-Object System.Drawing.SolidBrush((C $rng.Next(60, 85) 24 220 110)); $g.FillRectangle($b, ($tx + 24), 96, 70, 7); $b.Dispose()
  }
}
$pen = New-Object System.Drawing.Pen($lnMid, 2); $g.DrawLine($pen, 1070, 130, 1810, 130); $pen.Dispose()
# sub-tab ticks under the header line
foreach ($i in 0..2) {
  $sx = 1180 + $i * 120
  $alpha = if ($i -eq 0) { 170 } else { 75 }
  $b = New-Object System.Drawing.SolidBrush((C $alpha 24 230 115)); $g.FillRectangle($b, $sx, 146, 74, 6); $b.Dispose()
}

# ── data list rows (dim), under the header on the right ──
$selRow = 1
for ($i = 0; $i -lt 5; $i++) {
  $ry = 205 + $i * 40
  if ($i -eq $selRow) {
    $b = New-Object System.Drawing.SolidBrush((C 60 26 255 128)); $g.FillRectangle($b, 1092, ($ry - 9), 560, 30); $b.Dispose()
    $b = New-Object System.Drawing.SolidBrush((C 200 26 255 128)); $g.FillRectangle($b, 1104, $ry, 10, 10); $b.Dispose()
  }
  $bw2 = $rng.Next(180, 420)
  $b = New-Object System.Drawing.SolidBrush((C $(if ($i -eq $selRow) { 170 } else { 85 }) 24 225 112))
  $g.FillRectangle($b, 1130, $ry, $bw2, 9); $b.Dispose()
  # right-aligned value stub
  $b = New-Object System.Drawing.SolidBrush((C $(if ($i -eq $selRow) { 150 } else { 70 }) 24 225 112))
  $g.FillRectangle($b, 1590, $ry, 52, 9); $b.Dispose()
}

# ── oscilloscope radio graph, lower right ──
$gx = 1130; $gy = 560; $gw = 640; $gh = 370
# grid
for ($i = 0; $i -le 8; $i++) {
  $pen = New-Object System.Drawing.Pen((C 30 24 200 100), 1)
  $g.DrawLine($pen, ($gx + [int]($gw * $i / 8)), $gy, ($gx + [int]($gw * $i / 8)), ($gy + $gh)); $pen.Dispose()
}
for ($i = 0; $i -le 5; $i++) {
  $pen = New-Object System.Drawing.Pen((C 30 24 200 100), 1)
  $g.DrawLine($pen, $gx, ($gy + [int]($gh * $i / 5)), ($gx + $gw), ($gy + [int]($gh * $i / 5))); $pen.Dispose()
}
# axes
$pen = New-Object System.Drawing.Pen($lnMid, 2)
$g.DrawLine($pen, $gx, $gy, $gx, ($gy + $gh)); $g.DrawLine($pen, $gx, ($gy + $gh), ($gx + $gw), ($gy + $gh)); $pen.Dispose()
# axis ticks
for ($i = 0; $i -le 8; $i++) {
  $pen = New-Object System.Drawing.Pen($lnMid, 2)
  $g.DrawLine($pen, ($gx + [int]($gw * $i / 8)), ($gy + $gh), ($gx + [int]($gw * $i / 8)), ($gy + $gh + 8)); $pen.Dispose()
}
# damped sine trace, three bloom passes
$mid = $gy + 185
foreach ($pass in @(@(36, 9), @(90, 5), @(230, 2))) {
  $prevX = $gx + 6; $prevY = $mid
  for ($x = $gx + 14; $x -le $gx + $gw - 6; $x += 7) {
    $t = ($x - $gx) / 34.0
    $decay = [math]::Exp( - ($x - $gx) / 520.0)
    $yy = $mid + [int](120 * $decay * [math]::Sin($t) * [math]::Sin($t * 0.23))
    $pen = New-Object System.Drawing.Pen((C $pass[0] 26 255 128), $pass[1])
    $g.DrawLine($pen, $prevX, $prevY, $x, $yy); $pen.Dispose()
    $prevX = $x; $prevY = $yy
  }
}
# tuning line + marker
$tunX = $gx + 430
$pen = New-Object System.Drawing.Pen((C 150 26 255 128), 2)
$g.DrawLine($pen, $tunX, ($gy - 6), $tunX, ($gy + $gh)); $pen.Dispose()
Glow $g $tunX ($gy - 10) 22 (C 140 26 255 128)
$tri = New-Object 'System.Drawing.Point[]' 3
$tri[0] = New-Object System.Drawing.Point(($tunX - 8), ($gy - 18))
$tri[1] = New-Object System.Drawing.Point(($tunX + 8), ($gy - 18))
$tri[2] = New-Object System.Drawing.Point($tunX, ($gy - 4))
$b = New-Object System.Drawing.SolidBrush($ln); $g.FillPolygon($b, $tri); $b.Dispose()

# ── radiation gauge, lower left: arc + ticks + needle + trefoil hub ──
$cx = 470; $cy = 810
$pen = New-Object System.Drawing.Pen($lnMid, 3)
$g.DrawArc($pen, ($cx - 170), ($cy - 170), 340, 340, 180, 180); $pen.Dispose()
$pen = New-Object System.Drawing.Pen($lnDim, 2)
$g.DrawArc($pen, ($cx - 140), ($cy - 140), 280, 280, 180, 180); $pen.Dispose()
for ($i = 0; $i -le 10; $i++) {
  $ang = (180 + 18 * $i) * [math]::PI / 180
  $r1 = if ($i % 5 -eq 0) { 146 } else { 156 }
  $x1 = $cx + [int]($r1 * [math]::Cos($ang)); $y1 = $cy + [int]($r1 * [math]::Sin($ang))
  $x2 = $cx + [int](170 * [math]::Cos($ang)); $y2 = $cy + [int](170 * [math]::Sin($ang))
  $pen = New-Object System.Drawing.Pen($(if ($i % 5 -eq 0) { $ln } else { $lnMid }), $(if ($i % 5 -eq 0) { 3 } else { 2 }))
  $g.DrawLine($pen, $x1, $y1, $x2, $y2); $pen.Dispose()
}
$nAng = 244 * [math]::PI / 180
$nx = $cx + [int](140 * [math]::Cos($nAng)); $ny = $cy + [int](140 * [math]::Sin($nAng))
Glow $g $nx $ny 24 (C 120 26 255 128)
$pen = New-Object System.Drawing.Pen($ln, 4); $g.DrawLine($pen, $cx, $cy, $nx, $ny); $pen.Dispose()
# trefoil hub: three 54-degree blades + center dot with a dark gap ring
$b = New-Object System.Drawing.SolidBrush($lnMid)
foreach ($sa in @(-117, 3, 123)) { $g.FillPie($b, ($cx - 38), ($cy - 38), 76, 76, $sa, 54) }
$b.Dispose()
$b = New-Object System.Drawing.SolidBrush((C 255 4 18 9)); $g.FillEllipse($b, ($cx - 16), ($cy - 16), 32, 32); $b.Dispose()
$b = New-Object System.Drawing.SolidBrush($lnMid); $g.FillEllipse($b, ($cx - 8), ($cy - 8), 16, 16); $b.Dispose()
$pen = New-Object System.Drawing.Pen($lnMid, 2); $g.DrawLine($pen, ($cx - 178), $cy, ($cx + 178), $cy); $pen.Dispose()

# ── STAT figure, center: solid retro-cartoon mascot — filled shapes,
# dark punched-out features, bright outlines (thumbs-up pose) ──
$fx = 860
Glow $g $fx 750 250 (C 24 26 255 128)
$body = C 205 23 225 112     # solid fill green
$dark = C 255 4 18 9         # feature color: the screen's dark
$bFill = New-Object System.Drawing.SolidBrush($body)
$outline = New-Object System.Drawing.Pen($ln, 3)
$limb = New-Object System.Drawing.Pen($body, 24)
$limb.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
$limb.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
# arms first so the torso overlaps their roots
# left arm akimbo: shoulder -> elbow out -> hand on hip
$g.DrawLine($limb, ($fx - 40), 696, ($fx - 88), 732)
$g.DrawLine($limb, ($fx - 88), 732, ($fx - 50), 768)
# right arm raised: shoulder -> elbow -> up toward the fist
$g.DrawLine($limb, ($fx + 40), 696, ($fx + 94), 674)
$g.DrawLine($limb, ($fx + 94), 674, ($fx + 112), 626)
# legs + cartoon shoe ovals pointing outward
$g.DrawLine($limb, ($fx - 18), 790, ($fx - 30), 906)
$g.DrawLine($limb, ($fx + 18), 790, ($fx + 30), 906)
$g.FillEllipse($bFill, ($fx - 76), 924, 62, 26)
$g.FillEllipse($bFill, ($fx + 14), 924, 62, 26)
# torso: filled, shoulders wider than the belted waist
$torso = New-Object 'System.Drawing.Point[]' 6
$torso[0] = New-Object System.Drawing.Point(($fx - 50), 678)
$torso[1] = New-Object System.Drawing.Point(($fx + 50), 678)
$torso[2] = New-Object System.Drawing.Point(($fx + 38), 780)
$torso[3] = New-Object System.Drawing.Point(($fx + 30), 800)
$torso[4] = New-Object System.Drawing.Point(($fx - 30), 800)
$torso[5] = New-Object System.Drawing.Point(($fx - 38), 780)
$g.FillPolygon($bFill, $torso)
$g.DrawPolygon($outline, $torso)
# dark suit details: V collar, belt band with a green buckle
$dpen = New-Object System.Drawing.Pen($dark, 5)
$dpen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
$dpen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
$g.DrawLine($dpen, ($fx - 24), 680, $fx, 706); $g.DrawLine($dpen, ($fx + 24), 680, $fx, 706)
$b = New-Object System.Drawing.SolidBrush($dark); $g.FillRectangle($b, ($fx - 38), 758, 76, 12); $b.Dispose()
$b = New-Object System.Drawing.SolidBrush($ln); $g.FillRectangle($b, ($fx - 8), 756, 16, 16); $b.Dispose()
# neck + big filled head with outline
$g.FillRectangle($bFill, ($fx - 12), 652, 24, 30)
$g.FillEllipse($bFill, ($fx - 56), 544, 112, 112)
$g.DrawEllipse($outline, ($fx - 56), 544, 112, 112)
# face punched out dark: oval eyes, wide grin with a lower-lip line, brow
$b = New-Object System.Drawing.SolidBrush($dark)
$g.FillEllipse($b, ($fx - 28), 578, 13, 18); $g.FillEllipse($b, ($fx + 15), 578, 13, 18); $b.Dispose()
$g.DrawArc($dpen, ($fx - 34), 584, 68, 56, 25, 130)
$smilePen = New-Object System.Drawing.Pen($dark, 4)
$g.DrawArc($smilePen, ($fx + 8), 566, 24, 12, 200, 120); $smilePen.Dispose()
$dpen.Dispose()
# fist: filled circle + chunky thumb, both outlined for definition
$g.FillEllipse($bFill, ($fx + 96), 588, 38, 34)
$g.DrawEllipse($outline, ($fx + 96), 588, 38, 34)
$thumb = New-Object System.Drawing.Pen($body, 13)
$thumb.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
$thumb.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
$g.DrawLine($thumb, ($fx + 108), 592, ($fx + 96), 562)
$thumb.Dispose()
$bFill.Dispose(); $outline.Dispose(); $limb.Dispose()
# limb condition bars: leader line + 4-segment bar, per head/arms/legs
function LimbBar {
  param($g2, $lx1, $ly1, $lx2, $ly2, $lit)
  $pen2 = New-Object System.Drawing.Pen($lnMid, 2)
  $g2.DrawLine($pen2, $lx1, $ly1, $lx2, $ly2); $pen2.Dispose()
  $bx = if ($lx2 -gt $lx1) { $lx2 + 4 } else { $lx2 - 66 }
  for ($i = 0; $i -lt 4; $i++) {
    $alpha = if ($i -lt $lit) { 210 } else { 55 }
    $b2 = New-Object System.Drawing.SolidBrush((C $alpha 26 240 120))
    $g2.FillRectangle($b2, ($bx + $i * 16), ($ly2 - 5), 12, 10); $b2.Dispose()
  }
}
LimbBar $g ($fx - 46) 574 ($fx - 140) 556 4      # head
LimbBar $g ($fx - 90) 734 ($fx - 165) 738 3      # left arm
LimbBar $g ($fx + 126) 610 ($fx + 190) 640 4     # right arm
LimbBar $g ($fx - 36) 912 ($fx - 150) 928 4      # left leg
LimbBar $g ($fx + 36) 912 ($fx + 150) 928 2      # right leg

# ── bracketed segmented footer: HP | LEVEL chevrons | AP ──
$fy = 986
foreach ($grp in 0..2) {
  $gx2 = 420 + $grp * 480
  $pen = New-Object System.Drawing.Pen($lnMid, 3)
  # end brackets
  $g.DrawLine($pen, ($gx2 - 22), ($fy - 6), ($gx2 - 22), ($fy + 26))
  $g.DrawLine($pen, ($gx2 - 22), ($fy - 6), ($gx2 - 10), ($fy - 6))
  $g.DrawLine($pen, ($gx2 - 22), ($fy + 26), ($gx2 - 10), ($fy + 26))
  $g.DrawLine($pen, ($gx2 + 322), ($fy - 6), ($gx2 + 322), ($fy + 26))
  $g.DrawLine($pen, ($gx2 + 310), ($fy - 6), ($gx2 + 322), ($fy - 6))
  $g.DrawLine($pen, ($gx2 + 310), ($fy + 26), ($gx2 + 322), ($fy + 26))
  $pen.Dispose()
  if ($grp -eq 1) {
    # chevron progress
    for ($i = 0; $i -lt 7; $i++) {
      $chX = $gx2 + 20 + $i * 42
      $pen = New-Object System.Drawing.Pen($(if ($i -lt 4) { $ln } else { $lnDim }), 4)
      $g.DrawLine($pen, $chX, ($fy - 2), ($chX + 14), ($fy + 10))
      $g.DrawLine($pen, ($chX + 14), ($fy + 10), $chX, ($fy + 22)); $pen.Dispose()
    }
  } else {
    $lit = if ($grp -eq 0) { 9 } else { 6 }
    for ($i = 0; $i -lt 12; $i++) {
      $alpha = if ($i -lt $lit) { 215 } else { 55 }
      $b = New-Object System.Drawing.SolidBrush((C $alpha 26 240 120))
      $g.FillRectangle($b, ($gx2 + $i * 25), $fy, 19, 20); $b.Dispose()
    }
  }
}

# ── CRT treatment ──
# interlaced scanlines, alternating weight
$row = 0
for ($y = 0; $y -lt $H; $y += 3) {
  $pen = New-Object System.Drawing.Pen((C $(if ($row % 2 -eq 0) { 30 } else { 15 }) 0 0 0), 1)
  $g.DrawLine($pen, 0, $y, $W, $y); $pen.Dispose()
  $row++
}
# jitter lines: a few brighter rows
foreach ($jy in @(348, 706, 902)) {
  $pen = New-Object System.Drawing.Pen((C 16 26 255 128), 1)
  $g.DrawLine($pen, 0, $jy, $W, $jy); $pen.Dispose()
}
# roll band: soft gradient stripe drifting down the tube
$band = New-Object System.Drawing.Rectangle(0, 200, $W, 150)
$br = New-Object System.Drawing.Drawing2D.LinearGradientBrush($band, (C 0 26 255 128), (C 0 26 255 128), 90.0)
$blend = New-Object System.Drawing.Drawing2D.ColorBlend(3)
$blend.Colors = @((C 0 26 255 128), (C 13 26 255 128), (C 0 26 255 128))
$blend.Positions = @([single]0, [single]0.5, [single]1)
$br.InterpolationColors = $blend
$g.FillRectangle($br, $band); $br.Dispose()
# rounded CRT corners: the sliver between the corner and a 100px arc
# (arc across the corner, two straight edges back to the corner point)
$cr = 100
foreach ($corner in @(
    @(0, 0, 180, 90),          # top-left: arc from (0,$cr) to ($cr,0)
    @($W, 0, 270, 90),         # top-right
    @($W, $H, 0, 90),          # bottom-right
    @(0, $H, 90, 90))) {       # bottom-left
  $px = $corner[0]; $py = $corner[1]
  $ex = if ($px -eq 0) { 0 } else { $W - 2 * $cr }
  $ey = if ($py -eq 0) { 0 } else { $H - 2 * $cr }
  $path = New-Object System.Drawing.Drawing2D.GraphicsPath
  $path.AddArc($ex, $ey, (2 * $cr), (2 * $cr), $corner[2], $corner[3])
  $path.AddLine($path.GetLastPoint(), (New-Object System.Drawing.PointF($px, $py)))
  $path.CloseFigure()
  $b = New-Object System.Drawing.SolidBrush((C 235 1 6 3)); $g.FillPath($b, $path); $b.Dispose(); $path.Dispose()
}
EdgeFade $g "top" 110 130; EdgeFade $g "bottom" 120 120; EdgeFade $g "left" 140 120; EdgeFade $g "right" 140 120
Save $bmp $g "pipboy.png"

# ── NieR: beige YoRHa-style menu UI, dithered paper, drop shadows ──
function Diamond {
  param($g, $x, $y, $r, $color)
  $pts = New-Object 'System.Drawing.Point[]' 4
  $pts[0] = New-Object System.Drawing.Point($x, ($y - $r))
  $pts[1] = New-Object System.Drawing.Point(($x + $r), $y)
  $pts[2] = New-Object System.Drawing.Point($x, ($y + $r))
  $pts[3] = New-Object System.Drawing.Point(($x - $r), $y)
  $b = New-Object System.Drawing.SolidBrush($color); $g.FillPolygon($b, $pts); $b.Dispose()
}

$rng = New-Object System.Random(2017)
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 214 209 188) (C 255 199 194 175)
$inkC = C 255 74 70 58            # muddy dark olive-gray "ink"
$blockC = C 245 64 60 50          # header/selection block fill
$shadowC = C 44 40 38 30          # drop shadow
$subBarC = C 255 224 219 200      # lighter beige sub-bar
$liteDash = C 200 214 209 188     # light text dash on dark blocks

# dither dot grid
for ($y = 8; $y -lt $H; $y += 13) {
  $off = if ((($y / 13) % 2) -eq 0) { 0 } else { 6 }
  for ($x = 8 + $off; $x -lt $W; $x += 13) {
    if ($rng.NextDouble() -lt 0.7) {
      $b = New-Object System.Drawing.SolidBrush((C 11 74 70 58))
      $g.FillRectangle($b, $x, $y, 1, 1); $b.Dispose()
    }
  }
}
# paper grain
for ($i = 0; $i -lt 2200; $i++) {
  $b = New-Object System.Drawing.SolidBrush((C $rng.Next(5, 13) 60 56 46))
  $g.FillRectangle($b, $rng.Next(0, $W), $rng.Next(0, $H), 1, 1); $b.Dispose()
}

# ── header: muddy dark block, letter-spaced dashes, tag chips ──
$b = New-Object System.Drawing.SolidBrush($shadowC); $g.FillRectangle($b, 1067, 77, 770, 54); $b.Dispose()
$b = New-Object System.Drawing.SolidBrush($blockC); $g.FillRectangle($b, 1060, 70, 770, 54); $b.Dispose()
$hx = 1092
foreach ($dw in @(64, 12, 46, 12, 78, 12, 30)) {
  if ($dw -gt 20) {
    $b = New-Object System.Drawing.SolidBrush($liteDash); $g.FillRectangle($b, $hx, 90, $dw, 13); $b.Dispose()
  }
  $hx += $dw
}
$pen = New-Object System.Drawing.Pen((C 130 74 70 58), 2); $g.DrawLine($pen, 1060, 146, 1830, 146); $pen.Dispose()
Diamond $g 1060 146 7 $inkC
# tag chips under the header line
$tx = 1060
foreach ($tw in @(96, 74, 118)) {
  if ($tx -eq 1060) {
    $b = New-Object System.Drawing.SolidBrush($blockC); $g.FillRectangle($b, $tx, 160, $tw, 24); $b.Dispose()
    $b = New-Object System.Drawing.SolidBrush($liteDash); $g.FillRectangle($b, ($tx + 14), 169, ($tw - 28), 7); $b.Dispose()
  } else {
    $pen = New-Object System.Drawing.Pen((C 120 74 70 58), 1); $g.DrawRectangle($pen, $tx, 160, $tw, 24); $pen.Dispose()
    $b = New-Object System.Drawing.SolidBrush((C 150 74 70 58)); $g.FillRectangle($b, ($tx + 14), 169, ($tw - 28), 7); $b.Dispose()
  }
  $tx += $tw + 14
}

# ── menu column: dark inverted selection first, beige sub-bars after ──
for ($i = 0; $i -lt 5; $i++) {
  $by = 226 + $i * 64
  $b = New-Object System.Drawing.SolidBrush($shadowC); $g.FillRectangle($b, 1157, ($by + 7), 500, 46); $b.Dispose()
  if ($i -eq 0) {
    $b = New-Object System.Drawing.SolidBrush($blockC); $g.FillRectangle($b, 1150, $by, 500, 46); $b.Dispose()
    Diamond $g 1176 ($by + 23) 7 $liteDash
    $b = New-Object System.Drawing.SolidBrush($liteDash); $g.FillRectangle($b, 1198, ($by + 19), 250, 9); $b.Dispose()
  } else {
    $b = New-Object System.Drawing.SolidBrush($subBarC); $g.FillRectangle($b, 1150, $by, 500, 46); $b.Dispose()
    $b = New-Object System.Drawing.SolidBrush((C 190 74 70 58)); $g.FillRectangle($b, 1178, ($by + 19), $rng.Next(170, 320), 9); $b.Dispose()
  }
}

# ── ring gauge lower right: ticks, arc highlight, diamond hub ──
$cx = 1420; $cy = 800
$pen = New-Object System.Drawing.Pen((C 160 74 70 58), 2)
$g.DrawEllipse($pen, ($cx - 140), ($cy - 140), 280, 280); $pen.Dispose()
$pen = New-Object System.Drawing.Pen((C 90 74 70 58), 1)
$g.DrawEllipse($pen, ($cx - 118), ($cy - 118), 236, 236); $pen.Dispose()
for ($i = 0; $i -lt 24; $i++) {
  $ang = ($i / 24.0) * 2 * [math]::PI
  $r1 = if ($i % 6 -eq 0) { 126 } else { 133 }
  $x1 = $cx + [int]($r1 * [math]::Cos($ang)); $y1 = $cy + [int]($r1 * [math]::Sin($ang))
  $x2 = $cx + [int](140 * [math]::Cos($ang)); $y2 = $cy + [int](140 * [math]::Sin($ang))
  $pen = New-Object System.Drawing.Pen((C $(if ($i % 6 -eq 0) { 190 } else { 110 }) 74 70 58), $(if ($i % 6 -eq 0) { 3 } else { 1 }))
  $g.DrawLine($pen, $x1, $y1, $x2, $y2); $pen.Dispose()
}
$pen = New-Object System.Drawing.Pen($inkC, 4)
$g.DrawArc($pen, ($cx - 140), ($cy - 140), 280, 280, 300, 62); $pen.Dispose()
$pen = New-Object System.Drawing.Pen((C 110 74 70 58), 1)
$g.DrawLine($pen, ($cx - 150), $cy, ($cx + 150), $cy)
$g.DrawLine($pen, $cx, ($cy - 150), $cx, ($cy + 150)); $pen.Dispose()
Diamond $g $cx $cy 9 $inkC

# ── chip inventory, bottom left: slot track + colored striped chips ──
$px = 300; $py = 770; $pw = 580; $ph = 170
$b = New-Object System.Drawing.SolidBrush((C 20 74 70 58)); $g.FillRectangle($b, $px, $py, $pw, $ph); $b.Dispose()
$pen = New-Object System.Drawing.Pen((C 150 74 70 58), 2); $g.DrawRectangle($pen, $px, $py, $pw, $ph); $pen.Dispose()
$b = New-Object System.Drawing.SolidBrush($inkC); $g.FillRectangle($b, ($px + 14), ($py - 26), 120, 10); $b.Dispose()
# slot ruler along the bottom of the panel
for ($i = 0; $i -le 20; $i++) {
  $sx = $px + 20 + $i * 27
  $pen = New-Object System.Drawing.Pen((C 130 74 70 58), 1)
  $g.DrawLine($pen, $sx, ($py + $ph - 22), $sx, ($py + $ph - 12)); $pen.Dispose()
}
# chips: striped colored bars of varying width plugged onto the track
$chipColors = @((C 235 163 73 47), (C 235 95 113 52), (C 235 79 114 102), (C 235 138 111 63))
$chX = $px + 20
foreach ($i in 0..3) {
  $cw = @(120, 66, 174, 93)[$i]
  $cc = $chipColors[$i]
  $chTop = $py + 52
  $b = New-Object System.Drawing.SolidBrush($cc); $g.FillRectangle($b, $chX, $chTop, $cw, 72); $b.Dispose()
  # stripes: dark thin verticals through the chip
  for ($sx = $chX + 5; $sx -lt $chX + $cw - 3; $sx += 9) {
    $b = New-Object System.Drawing.SolidBrush((C 90 40 38 30)); $g.FillRectangle($b, $sx, $chTop, 3, 72); $b.Dispose()
  }
  $pen = New-Object System.Drawing.Pen((C 170 40 38 30), 1); $g.DrawRectangle($pen, $chX, $chTop, $cw, 72); $pen.Dispose()
  $chX += $cw + 27 - (($cw + 20) % 27)  # snap the next chip to the slot grid
}

# ── footer: diagonal stripe band + button hint pairs ──
$clip = New-Object System.Drawing.Rectangle(0, 986, $W, 52)
$g.SetClip($clip)
for ($x = -80; $x -lt $W + 80; $x += 26) {
  $pen = New-Object System.Drawing.Pen((C 22 74 70 58), 9)
  $g.DrawLine($pen, $x, 1052, ($x + 56), 972); $pen.Dispose()
}
$g.ResetClip()
$pen = New-Object System.Drawing.Pen((C 90 74 70 58), 2)
$g.DrawLine($pen, 0, 986, $W, 986); $g.DrawLine($pen, 0, 1038, $W, 1038); $pen.Dispose()
$bx = 1490
foreach ($i in 0..2) {
  $pen = New-Object System.Drawing.Pen($inkC, 2); $g.DrawEllipse($pen, $bx, 1002, 20, 20); $pen.Dispose()
  $b = New-Object System.Drawing.SolidBrush((C 190 74 70 58)); $g.FillRectangle($b, ($bx + 30), 1009, 56, 7); $b.Dispose()
  $bx += 116
}
EdgeFade $g "top" 90 24; EdgeFade $g "bottom" 90 26; EdgeFade $g "left" 110 20; EdgeFade $g "right" 110 20
Save $bmp $g "nier.png"

function Scanlines {
  param($g, $alphaA, $alphaB)
  $row = 0
  for ($y = 0; $y -lt $H; $y += 3) {
    $pen = New-Object System.Drawing.Pen((C $(if ($row % 2 -eq 0) { $alphaA } else { $alphaB }) 0 0 0), 1)
    $g.DrawLine($pen, 0, $y, $W, $y); $pen.Dispose()
    $row++
  }
}
function DashRow {
  # a row of text-like dashes: x start, y, total width, color, dash height
  param($g, $x, $y, $total, $color, $dh)
  $cx2 = $x
  while ($cx2 -lt $x + $total) {
    $dw = Get-Random -Minimum 14 -Maximum 70
    if ($cx2 + $dw -gt $x + $total) { $dw = $x + $total - $cx2 }
    $b = New-Object System.Drawing.SolidBrush($color)
    $g.FillRectangle($b, $cx2, $y, $dw, $dh); $b.Dispose()
    $cx2 += $dw + (Get-Random -Minimum 8 -Maximum 22)
  }
}

# ── Nostromo: cold green shipboard computer, dense readout walls ──
$rng = New-Object System.Random(1979)
Get-Random -SetSeed 1979 | Out-Null
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 4 12 8) (C 255 2 7 4)
Glow $g 960 500 900 (C 18 80 255 160)
$ln = C 200 79 208 135
$lnDim = C 95 60 170 110
# dense readout wall, lower half, two columns
foreach ($col in @(@(150, 620), @(1030, 740))) {
  $rowY = 560
  while ($rowY -lt 940) {
    DashRow $g $col[0] $rowY $col[1] $(if ($rng.NextDouble() -lt 0.14) { $ln } else { $lnDim }) 7
    $rowY += 22
  }
}
# header band: thick rule, title dash, frame corners
$pen = New-Object System.Drawing.Pen($ln, 4); $g.DrawLine($pen, 130, 490, 1790, 490); $pen.Dispose()
$b = New-Object System.Drawing.SolidBrush($ln); $g.FillRectangle($b, 130, 462, 300, 14); $b.Dispose()
$b = New-Object System.Drawing.SolidBrush($lnDim); $g.FillRectangle($b, 460, 462, 120, 14); $g.FillRectangle($b, 1560, 462, 230, 14); $b.Dispose()
# interface frames right top: nested rectangles with tick edges
foreach ($fr in @(@(1120, 90, 640, 300), @(1150, 120, 380, 180))) {
  $pen = New-Object System.Drawing.Pen($(if ($fr[2] -gt 500) { $ln } else { $lnDim }), 2)
  $g.DrawRectangle($pen, $fr[0], $fr[1], $fr[2], $fr[3]); $pen.Dispose()
}
for ($i = 0; $i -lt 12; $i++) {
  $pen = New-Object System.Drawing.Pen($lnDim, 2)
  $g.DrawLine($pen, (1120 + $i * 54), 390, (1120 + $i * 54), 400); $pen.Dispose()
}
DashRow $g 1170 150 320 $ln 9
DashRow $g 1170 185 300 $lnDim 7
DashRow $g 1170 215 330 $lnDim 7
DashRow $g 1170 250 260 $lnDim 7
# semiotic icon strip: triangle / circle / halved circle / bars
$icoY = 330
$pen = New-Object System.Drawing.Pen($ln, 3)
$tri = New-Object 'System.Drawing.Point[]' 3
$tri[0] = New-Object System.Drawing.Point(1600, ($icoY + 34)); $tri[1] = New-Object System.Drawing.Point(1634, ($icoY + 34)); $tri[2] = New-Object System.Drawing.Point(1617, $icoY)
$g.DrawPolygon($pen, $tri)
$g.DrawEllipse($pen, 1652, $icoY, 34, 34)
$g.DrawEllipse($pen, 1704, $icoY, 34, 34); $g.FillPie((New-Object System.Drawing.SolidBrush($ln)), 1704, $icoY, 34, 34, 90, 180)
$g.DrawRectangle($pen, 1756, $icoY, 34, 34)
$pen.Dispose()
Scanlines $g 30 14
$b = New-Object System.Drawing.SolidBrush((C 9 90 255 160)); $g.FillRectangle($b, 0, 180, $W, 110); $b.Dispose()
EdgeFade $g "top" 110 120; EdgeFade $g "bottom" 120 130; EdgeFade $g "left" 140 110; EdgeFade $g "right" 140 110
Save $bmp $g "nostromo.png"

# ── Commodore 64: blue screen, lighter border, BASIC boot, PETSCII ──
$rng = New-Object System.Random(1982)
Get-Random -SetSeed 1982 | Out-Null
$bmp, $g = New-Canvas
# border in light periwinkle, screen inset in the classic blue
$b = New-Object System.Drawing.SolidBrush((C 255 120 105 196)); $g.FillRectangle($b, 0, 0, $W, $H); $b.Dispose()
$b = New-Object System.Drawing.SolidBrush((C 255 58 46 134)); $g.FillRectangle($b, 96, 78, ($W - 192), ($H - 156)); $b.Dispose()
$lite = C 235 158 146 224
$liteDim = C 130 158 146 224
# boot header: centered starred banner dashes
DashRow $g 560 130 800 $lite 12
$b = New-Object System.Drawing.SolidBrush($liteDim); $g.FillRectangle($b, 660, 168, 600, 10); $b.Dispose()
# READY. and block cursor
$b = New-Object System.Drawing.SolidBrush($lite); $g.FillRectangle($b, 150, 300, 130, 13); $b.Dispose()
$b = New-Object System.Drawing.SolidBrush($lite); $g.FillRectangle($b, 150, 336, 26, 30); $b.Dispose()
# PETSCII pattern band along the bottom of the screen area
$petY = 830
for ($x = 150; $x -lt 1740; $x += 38) {
  $kind = $rng.Next(0, 4)
  switch ($kind) {
    0 { $pen = New-Object System.Drawing.Pen($liteDim, 3); $g.DrawLine($pen, $x, ($petY + 28), ($x + 28), $petY); $pen.Dispose() }
    1 { $pen = New-Object System.Drawing.Pen($liteDim, 3); $g.DrawLine($pen, $x, $petY, ($x + 28), ($petY + 28)); $pen.Dispose() }
    2 { $b = New-Object System.Drawing.SolidBrush($liteDim); $g.FillRectangle($b, $x, $petY, 14, 14); $g.FillRectangle($b, ($x + 14), ($petY + 14), 14, 14); $b.Dispose() }
    3 { $pen = New-Object System.Drawing.Pen($liteDim, 3); $g.DrawEllipse($pen, $x, $petY, 26, 26); $pen.Dispose() }
  }
}
# faint raster shimmer on the border
for ($y = 0; $y -lt $H; $y += 4) {
  $pen = New-Object System.Drawing.Pen((C 14 0 0 0), 1); $g.DrawLine($pen, 0, $y, $W, $y); $pen.Dispose()
}
Save $bmp $g "c64.png"

# ── WarGames: WOPR map board, great-circle arcs, DEFCON stack ──
$rng = New-Object System.Random(1983)
Get-Random -SetSeed 1983 | Out-Null
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 4 8 14) (C 255 2 4 8)
Glow $g 1150 520 760 (C 20 90 170 255)
$blue = C 210 130 190 255
$blueDim = C 80 90 150 220
# graticule: world board grid, right two-thirds
$gx = 620; $gy = 160; $gw = 1180; $gh = 640
for ($i = 0; $i -le 12; $i++) {
  $pen = New-Object System.Drawing.Pen($blueDim, 1)
  $g.DrawLine($pen, ($gx + [int]($gw * $i / 12)), $gy, ($gx + [int]($gw * $i / 12)), ($gy + $gh)); $pen.Dispose()
}
for ($i = 0; $i -le 6; $i++) {
  $pen = New-Object System.Drawing.Pen($blueDim, 1)
  $g.DrawLine($pen, $gx, ($gy + [int]($gh * $i / 6)), ($gx + $gw), ($gy + [int]($gh * $i / 6))); $pen.Dispose()
}
$pen = New-Object System.Drawing.Pen($blue, 2); $g.DrawRectangle($pen, $gx, $gy, $gw, $gh); $pen.Dispose()
# landmass hints: dot clusters
for ($i = 0; $i -lt 900; $i++) {
  $px = $gx + $rng.Next(30, $gw - 30); $py = $gy + $rng.Next(30, $gh - 30)
  $inCluster = ($px -lt $gx + 420 -and $py -lt $gy + 330) -or ($px -gt $gx + 480 -and $px -lt $gx + 760 -and $py -gt $gy + 60 -and $py -lt $gy + 480) -or ($px -gt $gx + 820 -and $py -lt $gy + 400)
  if ($inCluster -and $rng.NextDouble() -lt 0.75) {
    $b = New-Object System.Drawing.SolidBrush((C $rng.Next(50, 120) 120 180 255))
    $g.FillRectangle($b, $px, $py, 2, 2); $b.Dispose()
  }
}
# great-circle arcs: bezier-ish parabolas between site pairs
foreach ($arc in @(@(720, 640, 1520, 300), @(830, 300, 1620, 560), @(700, 420, 1250, 240), @(980, 700, 1680, 380))) {
  $mx = [int](($arc[0] + $arc[2]) / 2); $my = [math]::Min($arc[1], $arc[3]) - 130
  $path = New-Object System.Drawing.Drawing2D.GraphicsPath
  $path.AddBezier($arc[0], $arc[1], $mx, $my, $mx, $my, $arc[2], $arc[3])
  $pen = New-Object System.Drawing.Pen((C 170 150 210 255), 2); $g.DrawPath($pen, $path); $pen.Dispose(); $path.Dispose()
  foreach ($endp in @(@($arc[0], $arc[1]), @($arc[2], $arc[3]))) {
    $pen = New-Object System.Drawing.Pen($blue, 2); $g.DrawEllipse($pen, ($endp[0] - 7), ($endp[1] - 7), 14, 14); $pen.Dispose()
  }
}
# DEFCON stack, left
for ($i = 0; $i -lt 5; $i++) {
  $dy = 210 + $i * 78
  $active = ($i -eq 2)
  if ($active) {
    $b = New-Object System.Drawing.SolidBrush((C 70 130 190 255)); $g.FillRectangle($b, 170, $dy, 300, 58); $b.Dispose()
  }
  $pen = New-Object System.Drawing.Pen($(if ($active) { $blue } else { $blueDim }), 2)
  $g.DrawRectangle($pen, 170, $dy, 300, 58); $pen.Dispose()
  $b = New-Object System.Drawing.SolidBrush($(if ($active) { $blue } else { $blueDim }))
  $g.FillRectangle($b, 196, ($dy + 24), 170, 10); $b.Dispose()
}
# readout rows bottom
$rowY = 880
while ($rowY -lt 1000) {
  DashRow $g 170 $rowY 1400 $blueDim 6
  $rowY += 24
}
Scanlines $g 26 12
EdgeFade $g "top" 110 120; EdgeFade $g "bottom" 120 130; EdgeFade $g "left" 130 110; EdgeFade $g "right" 130 110
Save $bmp $g "wargames.png"

# ── Macintosh: 1-bit desktop, dithered gray, striped title bar ──
$rng = New-Object System.Random(1984)
Get-Random -SetSeed 1984 | Out-Null
$bmp, $g = New-Canvas
$b = New-Object System.Drawing.SolidBrush((C 255 244 244 238)); $g.FillRectangle($b, 0, 0, $W, $H); $b.Dispose()
# 50% dither desktop pattern
for ($y = 0; $y -lt $H; $y += 2) {
  for ($x = ($y % 4) / 2 * 2; $x -lt $W; $x += 4) {
    $b = New-Object System.Drawing.SolidBrush((C 26 40 40 40))
    $g.FillRectangle($b, $x, $y, 1, 1); $b.Dispose()
  }
}
$ink = C 255 26 26 26
# menu bar
$b = New-Object System.Drawing.SolidBrush((C 255 250 250 246)); $g.FillRectangle($b, 0, 0, $W, 40); $b.Dispose()
$pen = New-Object System.Drawing.Pen($ink, 2); $g.DrawLine($pen, 0, 40, $W, 40); $pen.Dispose()
$mx = 40
foreach ($mw in @(30, 64, 52, 70, 58, 90)) {
  $b = New-Object System.Drawing.SolidBrush((C 210 26 26 26)); $g.FillRectangle($b, $mx, 15, $mw, 11); $b.Dispose()
  $mx += $mw + 42
}
# window, right side: shadow, frame, striped title bar, close box
$wx2 = 1050; $wy2 = 300; $ww2 = 680; $wh2 = 520
$b = New-Object System.Drawing.SolidBrush((C 70 30 30 30)); $g.FillRectangle($b, ($wx2 + 8), ($wy2 + 8), $ww2, $wh2); $b.Dispose()
$b = New-Object System.Drawing.SolidBrush((C 255 250 250 246)); $g.FillRectangle($b, $wx2, $wy2, $ww2, $wh2); $b.Dispose()
$pen = New-Object System.Drawing.Pen($ink, 3); $g.DrawRectangle($pen, $wx2, $wy2, $ww2, $wh2); $pen.Dispose()
for ($ly = $wy2 + 8; $ly -lt $wy2 + 34; $ly += 5) {
  $pen = New-Object System.Drawing.Pen((C 220 26 26 26), 2); $g.DrawLine($pen, ($wx2 + 10), $ly, ($wx2 + $ww2 - 10), $ly); $pen.Dispose()
}
$b = New-Object System.Drawing.SolidBrush((C 255 250 250 246)); $g.FillRectangle($b, ($wx2 + 26), ($wy2 + 6), 30, 30); $g.FillRectangle($b, ($wx2 + 250), ($wy2 + 4), 180, 34); $b.Dispose()
$pen = New-Object System.Drawing.Pen($ink, 2); $g.DrawRectangle($pen, ($wx2 + 30), ($wy2 + 10), 22, 22); $pen.Dispose()
$b = New-Object System.Drawing.SolidBrush((C 220 26 26 26)); $g.FillRectangle($b, ($wx2 + 268), ($wy2 + 15), 144, 12); $b.Dispose()
# window content: doc lines
$pen = New-Object System.Drawing.Pen($ink, 2); $g.DrawLine($pen, $wx2, ($wy2 + 42), ($wx2 + $ww2), ($wy2 + 42)); $pen.Dispose()
$rowY = $wy2 + 80
while ($rowY -lt $wy2 + $wh2 - 60) {
  DashRow $g ($wx2 + 44) $rowY ($ww2 - 120) (C 190 26 26 26) 8
  $rowY += 34
}
# scrollbar with dither
for ($y = $wy2 + 44; $y -lt $wy2 + $wh2 - 2; $y += 2) {
  for ($x = $wx2 + $ww2 - 30 + (($y % 4) / 2 * 2); $x -lt $wx2 + $ww2 - 2; $x += 4) {
    $b = New-Object System.Drawing.SolidBrush((C 90 26 26 26)); $g.FillRectangle($b, $x, $y, 1, 1); $b.Dispose()
  }
}
$pen = New-Object System.Drawing.Pen($ink, 2)
$g.DrawLine($pen, ($wx2 + $ww2 - 32), ($wy2 + 42), ($wx2 + $ww2 - 32), ($wy2 + $wh2))
$g.DrawRectangle($pen, ($wx2 + $ww2 - 30), ($wy2 + 150), 26, 60); $pen.Dispose()
$b = New-Object System.Drawing.SolidBrush((C 255 250 250 246)); $g.FillRectangle($b, ($wx2 + $ww2 - 29), ($wy2 + 151), 25, 58); $b.Dispose()
$pen = New-Object System.Drawing.Pen($ink, 2); $g.DrawRectangle($pen, ($wx2 + $ww2 - 30), ($wy2 + 150), 26, 60); $pen.Dispose()
Save $bmp $g "macintosh.png"

# ── Lumon: severed-floor terminal, drifting numbers, refinement bins ──
$rng = New-Object System.Random(1955)
Get-Random -SetSeed 1955 | Out-Null
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 5 18 30) (C 255 2 9 16)
Glow $g 960 470 900 (C 26 60 200 220)
$cyan = C 220 130 235 235
$cyanDim = C 90 90 190 200
$font = New-Object System.Drawing.Font("Consolas", 17, [System.Drawing.FontStyle]::Bold)
$fontSm = New-Object System.Drawing.Font("Consolas", 13)
# drifting number field with per-digit jitter
for ($row = 0; $row -lt 11; $row++) {
  for ($col = 0; $col -lt 26; $col++) {
    $nx = 200 + $col * 62 + $rng.Next(-8, 9)
    $ny = 210 + $row * 58 + $rng.Next(-10, 11)
    $alpha = $rng.Next(35, 130)
    $b = New-Object System.Drawing.SolidBrush((C $alpha 130 235 235))
    $g.DrawString([string]$rng.Next(0, 10), $(if ($rng.NextDouble() -lt 0.2) { $font } else { $fontSm }), $b, $nx, $ny); $b.Dispose()
  }
}
# one scary cluster: brighter digits inside a selection box
$selX = 1210; $selY = 430
for ($r2 = 0; $r2 -lt 3; $r2++) {
  for ($c2 = 0; $c2 -lt 4; $c2++) {
    $b = New-Object System.Drawing.SolidBrush($cyan)
    $g.DrawString([string]$rng.Next(0, 10), $font, $b, ($selX + $c2 * 46), ($selY + $r2 * 44)); $b.Dispose()
  }
}
$pen = New-Object System.Drawing.Pen($cyan, 2); $g.DrawRectangle($pen, ($selX - 16), ($selY - 12), 210, 156); $pen.Dispose()
Glow $g ($selX + 90) ($selY + 66) 130 (C 60 130 235 235)
# header rule with oval badge
$pen = New-Object System.Drawing.Pen($cyanDim, 2); $g.DrawLine($pen, 160, 150, 1760, 150); $pen.Dispose()
$pen = New-Object System.Drawing.Pen($cyan, 2); $g.DrawEllipse($pen, 1600, 100, 130, 40); $pen.Dispose()
$b = New-Object System.Drawing.SolidBrush($cyanDim); $g.FillRectangle($b, 1626, 116, 78, 8); $b.Dispose()
DashRow $g 160 110 320 $cyanDim 9
# refinement bins along the bottom: five boxes with fill bars
for ($i = 0; $i -lt 5; $i++) {
  $bx = 340 + $i * 260
  $pen = New-Object System.Drawing.Pen($cyan, 2); $g.DrawRectangle($pen, $bx, 900, 180, 64); $pen.Dispose()
  $b = New-Object System.Drawing.SolidBrush($cyanDim); $g.FillRectangle($b, ($bx + 14), 914, 60, 9); $b.Dispose()
  $pen = New-Object System.Drawing.Pen($cyanDim, 1); $g.DrawRectangle($pen, ($bx + 14), 934, 152, 16); $pen.Dispose()
  $b = New-Object System.Drawing.SolidBrush($cyan); $g.FillRectangle($b, ($bx + 16), 936, ([int](148 * $rng.NextDouble())), 13); $b.Dispose()
}
$font.Dispose(); $fontSm.Dispose()
Scanlines $g 28 12
$b = New-Object System.Drawing.SolidBrush((C 8 90 220 235)); $g.FillRectangle($b, 0, 300, $W, 100); $b.Dispose()
EdgeFade $g "top" 110 130; EdgeFade $g "bottom" 110 130; EdgeFade $g "left" 140 120; EdgeFade $g "right" 140 120
Save $bmp $g "lumon.png"

# ── NERV: hex field, MAGI tri-link, warning band, katakana column ──
$rng = New-Object System.Random(1997)
Get-Random -SetSeed 1997 | Out-Null
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 12 6 4) (C 255 5 2 2)
Glow $g 1250 520 700 (C 26 255 120 20)
$org = C 225 255 150 40
$orgDim = C 95 220 120 30
$grn = C 200 90 230 95
# hex grid patch, right-center
$hexR = 46
for ($row = 0; $row -lt 8; $row++) {
  for ($col = 0; $col -lt 9; $col++) {
    $cx3 = 1030 + $col * ($hexR * 1.74) + $(if ($row % 2 -eq 1) { $hexR * 0.87 } else { 0 })
    $cy3 = 240 + $row * ($hexR * 1.5)
    if ($rng.NextDouble() -lt 0.72) {
      $pts = New-Object 'System.Drawing.Point[]' 6
      for ($k = 0; $k -lt 6; $k++) {
        $ang = ($k * 60 + 30) * [math]::PI / 180
        $pts[$k] = New-Object System.Drawing.Point([int]($cx3 + $hexR * 0.92 * [math]::Cos($ang)), [int]($cy3 + $hexR * 0.92 * [math]::Sin($ang)))
      }
      $pen = New-Object System.Drawing.Pen((C $rng.Next(28, 90) 235 130 30), 2)
      $g.DrawPolygon($pen, $pts); $pen.Dispose()
      if ($rng.NextDouble() -lt 0.12) {
        $b = New-Object System.Drawing.SolidBrush((C 55 255 150 40)); $g.FillPolygon($b, $pts); $b.Dispose()
      }
    }
  }
}
# MAGI tri-panel: three boxes linked to a center node
$nodes = @(@(430, 620), @(700, 760), @(430, 900))
$center = @(620, 760)
foreach ($nd in $nodes) {
  $pen = New-Object System.Drawing.Pen($grn, 2)
  $g.DrawLine($pen, ($nd[0] + 70), ($nd[1] + 5), $center[0], $center[1]); $pen.Dispose()
}
foreach ($nd in $nodes) {
  $b = New-Object System.Drawing.SolidBrush((C 235 8 4 3)); $g.FillRectangle($b, ($nd[0] - 80), ($nd[1] - 28), 220, 62); $b.Dispose()
  $pen = New-Object System.Drawing.Pen($grn, 2); $g.DrawRectangle($pen, ($nd[0] - 80), ($nd[1] - 28), 220, 62); $pen.Dispose()
  $b = New-Object System.Drawing.SolidBrush((C 170 90 230 95)); $g.FillRectangle($b, ($nd[0] - 56), ($nd[1] - 6), 130, 10); $b.Dispose()
}
$b = New-Object System.Drawing.SolidBrush($grn); $g.FillEllipse($b, ($center[0] - 10), ($center[1] - 10), 20, 20); $b.Dispose()
# warning band top: diagonal stripes in a framed strip
$bandY = 84
$pen = New-Object System.Drawing.Pen($org, 3)
$g.DrawRectangle($pen, 1060, $bandY, 700, 54); $pen.Dispose()
$clip = New-Object System.Drawing.Rectangle(1062, ($bandY + 2), 697, 51)
$g.SetClip($clip)
for ($x = 1020; $x -lt 1800; $x += 44) {
  $b = New-Object System.Drawing.SolidBrush((C 200 255 150 40))
  $pts2 = New-Object 'System.Drawing.Point[]' 4
  $pts2[0] = New-Object System.Drawing.Point($x, ($bandY + 56))
  $pts2[1] = New-Object System.Drawing.Point(($x + 22), ($bandY + 56))
  $pts2[2] = New-Object System.Drawing.Point(($x + 50), $bandY)
  $pts2[3] = New-Object System.Drawing.Point(($x + 28), $bandY)
  $g.FillPolygon($b, $pts2); $b.Dispose()
}
$g.ResetClip()
# katakana columns, far right, static matrix-like but orange
$font = New-Object System.Drawing.Font("Consolas", 15, [System.Drawing.FontStyle]::Bold)
foreach ($colX in @(1830, 1868)) {
  $colY = 180
  while ($colY -lt 950) {
    $ch = [char](0x30A0 + $rng.Next(0, 96))
    $b = New-Object System.Drawing.SolidBrush((C $rng.Next(50, 140) 255 150 40))
    $g.DrawString($ch, $font, $b, $colX, $colY); $b.Dispose()
    $colY += 34
  }
}
$font.Dispose()
# readout dashes bottom right
$rowY = 950
DashRow $g 1060 $rowY 700 $orgDim 7
DashRow $g 1060 ($rowY + 26) 640 $orgDim 7
EdgeFade $g "top" 100 130; EdgeFade $g "bottom" 110 140; EdgeFade $g "left" 130 120; EdgeFade $g "right" 90 90
Save $bmp $g "nerv.png"

# ── Aperture: clinical white chamber, pictogram tiles, portal dots ──
$rng = New-Object System.Random(2007)
Get-Random -SetSeed 2007 | Out-Null
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 242 242 238) (C 255 228 228 222)
$ink = C 255 48 50 52
$inkMid = C 120 48 50 52
# chamber wall: big rounded panel tiles, faint
for ($row = 0; $row -lt 4; $row++) {
  for ($col = 0; $col -lt 7; $col++) {
    $tx = 60 + $col * 268; $ty = 60 + $row * 252
    $pen = New-Object System.Drawing.Pen((C 26 48 50 52), 2)
    $g.DrawRectangle($pen, $tx, $ty, 248, 232); $pen.Dispose()
  }
}
# pictogram tile row, right-center: outlined squares with crude glyphs
$py2 = 430
foreach ($i in 0..3) {
  $px2 = 1180 + $i * 170
  $pen = New-Object System.Drawing.Pen($ink, 3); $g.DrawRectangle($pen, $px2, $py2, 130, 130); $pen.Dispose()
  switch ($i) {
    0 { # falling figure: dot head + slash body
      $b = New-Object System.Drawing.SolidBrush($ink); $g.FillEllipse($b, ($px2 + 44), ($py2 + 26), 20, 20); $b.Dispose()
      $pen = New-Object System.Drawing.Pen($ink, 8); $g.DrawLine($pen, ($px2 + 56), ($py2 + 50), ($px2 + 78), ($py2 + 100)); $pen.Dispose()
    }
    1 { # cube on hatched shelf
      $pen = New-Object System.Drawing.Pen($ink, 5); $g.DrawRectangle($pen, ($px2 + 38), ($py2 + 36), 54, 54); $pen.Dispose()
      $pen = New-Object System.Drawing.Pen($inkMid, 3); $g.DrawLine($pen, ($px2 + 20), ($py2 + 104), ($px2 + 110), ($py2 + 104)); $pen.Dispose()
    }
    2 { # liquid: three arcs
      $pen = New-Object System.Drawing.Pen($ink, 4)
      foreach ($ay in @(46, 66, 86)) { $g.DrawArc($pen, ($px2 + 30), ($py2 + $ay), 70, 24, 0, 180) }
      $pen.Dispose()
    }
    3 { # hazard triangle
      $pen = New-Object System.Drawing.Pen($ink, 5)
      $tri = New-Object 'System.Drawing.Point[]' 3
      $tri[0] = New-Object System.Drawing.Point(($px2 + 65), ($py2 + 26))
      $tri[1] = New-Object System.Drawing.Point(($px2 + 104), ($py2 + 100))
      $tri[2] = New-Object System.Drawing.Point(($px2 + 26), ($py2 + 100))
      $g.DrawPolygon($pen, $tri); $pen.Dispose()
      $b = New-Object System.Drawing.SolidBrush($ink); $g.FillRectangle($b, ($px2 + 61), ($py2 + 52), 8, 26); $g.FillRectangle($b, ($px2 + 61), ($py2 + 86), 8, 8); $b.Dispose()
    }
  }
}
# portal dot pair: blue and orange ellipse outlines with glows
Glow $g 1320 800 120 (C 70 61 140 232)
Glow $g 1620 800 120 (C 70 255 127 39)
$pen = New-Object System.Drawing.Pen((C 235 45 120 220), 7); $g.DrawEllipse($pen, 1270, 730, 100, 150); $pen.Dispose()
$pen = New-Object System.Drawing.Pen((C 235 240 110 30), 7); $g.DrawEllipse($pen, 1570, 730, 100, 150); $pen.Dispose()
# hazard stripe band along the bottom
$clip = New-Object System.Drawing.Rectangle(0, 1006, $W, 40)
$g.SetClip($clip)
for ($x = -60; $x -lt $W + 60; $x += 56) {
  $b = New-Object System.Drawing.SolidBrush((C 150 48 50 52))
  $pts = New-Object 'System.Drawing.Point[]' 4
  $pts[0] = New-Object System.Drawing.Point($x, 1046); $pts[1] = New-Object System.Drawing.Point(($x + 26), 1046)
  $pts[2] = New-Object System.Drawing.Point(($x + 56), 1006); $pts[3] = New-Object System.Drawing.Point(($x + 30), 1006)
  $g.FillPolygon($b, $pts); $b.Dispose()
}
$g.ResetClip()
Save $bmp $g "aperture.png"

# ── Sheikah: slate stone, glowing rune circle, constellation ──
$rng = New-Object System.Random(2017)
Get-Random -SetSeed 20170 | Out-Null
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 17 25 35) (C 255 9 14 21)
# stone noise
for ($i = 0; $i -lt 2600; $i++) {
  $b = New-Object System.Drawing.SolidBrush((C $rng.Next(6, 16) 140 170 190))
  $g.FillRectangle($b, $rng.Next(0, $W), $rng.Next(0, $H), 1, 1); $b.Dispose()
}
$teal = C 225 105 232 214
$tealDim = C 90 70 180 165
$cx = 1360; $cy = 620
Glow $g $cx $cy 420 (C 40 60 220 200)
# concentric circles
foreach ($rr in @(280, 236, 150, 96)) {
  $pen = New-Object System.Drawing.Pen($(if ($rr -eq 280 -or $rr -eq 96) { $teal } else { $tealDim }), $(if ($rr -eq 280) { 4 } else { 2 }))
  $g.DrawEllipse($pen, ($cx - $rr), ($cy - $rr), (2 * $rr), (2 * $rr)); $pen.Dispose()
}
# triangle fringe pointing outward around the outer ring
for ($i = 0; $i -lt 18; $i++) {
  $ang = ($i / 18.0) * 2 * [math]::PI
  $x1 = $cx + 292 * [math]::Cos($ang); $y1 = $cy + 292 * [math]::Sin($ang)
  $x2 = $cx + 330 * [math]::Cos($ang + 0.06); $y2 = $cy + 330 * [math]::Sin($ang + 0.06)
  $x3 = $cx + 292 * [math]::Cos($ang + 0.12); $y3 = $cy + 292 * [math]::Sin($ang + 0.12)
  $pts = New-Object 'System.Drawing.Point[]' 3
  $pts[0] = New-Object System.Drawing.Point([int]$x1, [int]$y1)
  $pts[1] = New-Object System.Drawing.Point([int]$x2, [int]$y2)
  $pts[2] = New-Object System.Drawing.Point([int]$x3, [int]$y3)
  $b = New-Object System.Drawing.SolidBrush($(if ($i % 3 -eq 0) { $teal } else { $tealDim }))
  $g.FillPolygon($b, $pts); $b.Dispose()
}
# radial ticks between rings
for ($i = 0; $i -lt 36; $i++) {
  $ang = ($i / 36.0) * 2 * [math]::PI
  $x1 = $cx + 160 * [math]::Cos($ang); $y1 = $cy + 160 * [math]::Sin($ang)
  $x2 = $cx + 176 * [math]::Cos($ang); $y2 = $cy + 176 * [math]::Sin($ang)
  $pen = New-Object System.Drawing.Pen($tealDim, 2)
  $g.DrawLine($pen, [int]$x1, [int]$y1, [int]$x2, [int]$y2); $pen.Dispose()
}
# teardrop core: circle + triangle tail, glowing
Glow $g $cx $cy 90 (C 90 105 232 214)
$b = New-Object System.Drawing.SolidBrush($teal); $g.FillEllipse($b, ($cx - 34), ($cy - 20), 68, 68); $b.Dispose()
$tri2 = New-Object 'System.Drawing.Point[]' 3
$tri2[0] = New-Object System.Drawing.Point(($cx - 30), ($cy + 6))
$tri2[1] = New-Object System.Drawing.Point(($cx + 30), ($cy + 6))
$tri2[2] = New-Object System.Drawing.Point($cx, ($cy - 66))
$b = New-Object System.Drawing.SolidBrush($teal); $g.FillPolygon($b, $tri2); $b.Dispose()
$b = New-Object System.Drawing.SolidBrush((C 255 10 16 24)); $g.FillEllipse($b, ($cx - 14), ($cy + 2), 28, 28); $b.Dispose()
# constellation, upper left of terminal-safe zone edge
$stars = @(@(330, 700), @(430, 640), @(560, 690), @(640, 610), @(760, 660), @(700, 780))
foreach ($s in $stars) {
  $b = New-Object System.Drawing.SolidBrush($teal); $g.FillEllipse($b, ($s[0] - 4), ($s[1] - 4), 8, 8); $b.Dispose()
  Glow $g $s[0] $s[1] 26 (C 70 105 232 214)
}
for ($i = 0; $i -lt $stars.Count - 1; $i++) {
  $pen = New-Object System.Drawing.Pen($tealDim, 1)
  $g.DrawLine($pen, $stars[$i][0], $stars[$i][1], $stars[$i + 1][0], $stars[$i + 1][1]); $pen.Dispose()
}
EdgeFade $g "top" 120 110; EdgeFade $g "bottom" 130 130; EdgeFade $g "left" 150 110; EdgeFade $g "right" 120 100
Save $bmp $g "sheikah.png"

# ── Blueprint: cyanotype drafting sheet ──
$rng = New-Object System.Random(1918)
Get-Random -SetSeed 1918 | Out-Null
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 21 63 102) (C 255 14 47 79)
$wt = C 225 235 244 252
$wtMid = C 110 210 228 246
$wtDim = C 45 190 214 240
# drafting grid: minor + major
for ($x = 0; $x -lt $W; $x += 32) {
  $pen = New-Object System.Drawing.Pen((C 18 220 235 250), 1); $g.DrawLine($pen, $x, 0, $x, $H); $pen.Dispose()
}
for ($y = 0; $y -lt $H; $y += 32) {
  $pen = New-Object System.Drawing.Pen((C 18 220 235 250), 1); $g.DrawLine($pen, 0, $y, $W, $y); $pen.Dispose()
}
for ($x = 0; $x -lt $W; $x += 160) {
  $pen = New-Object System.Drawing.Pen((C 34 220 235 250), 1); $g.DrawLine($pen, $x, 0, $x, $H); $pen.Dispose()
}
for ($y = 0; $y -lt $H; $y += 160) {
  $pen = New-Object System.Drawing.Pen((C 34 220 235 250), 1); $g.DrawLine($pen, 0, $y, $W, $y); $pen.Dispose()
}
# part drawing: bracket plate with bolt holes + centerlines
$px3 = 1080; $py3 = 420; $pw3 = 560; $ph3 = 320
$pen = New-Object System.Drawing.Pen($wt, 3); $g.DrawRectangle($pen, $px3, $py3, $pw3, $ph3); $pen.Dispose()
foreach ($hole in @(@(($px3 + 110), ($py3 + 90)), @(($px3 + $pw3 - 110), ($py3 + 90)), @(($px3 + 110), ($py3 + $ph3 - 90)), @(($px3 + $pw3 - 110), ($py3 + $ph3 - 90)))) {
  $pen = New-Object System.Drawing.Pen($wt, 2)
  $g.DrawEllipse($pen, ($hole[0] - 30), ($hole[1] - 30), 60, 60)
  $g.DrawEllipse($pen, ($hole[0] - 12), ($hole[1] - 12), 24, 24); $pen.Dispose()
  # dash-dot centerlines through the hole
  $pen = New-Object System.Drawing.Pen($wtMid, 1)
  $pen.DashStyle = [System.Drawing.Drawing2D.DashStyle]::DashDot
  $g.DrawLine($pen, ($hole[0] - 48), $hole[1], ($hole[0] + 48), $hole[1])
  $g.DrawLine($pen, $hole[0], ($hole[1] - 48), $hole[0], ($hole[1] + 48)); $pen.Dispose()
}
$pen = New-Object System.Drawing.Pen($wtMid, 2); $g.DrawEllipse($pen, ($px3 + $pw3 / 2 - 70), ($py3 + $ph3 / 2 - 70), 140, 140); $pen.Dispose()
# section hatch, lower-left corner of the part
$clip = New-Object System.Drawing.Rectangle($px3, ($py3 + $ph3 - 90), 150, 90)
$g.SetClip($clip)
for ($x = $px3 - 90; $x -lt $px3 + 160; $x += 14) {
  $pen = New-Object System.Drawing.Pen($wtDim, 1); $g.DrawLine($pen, $x, ($py3 + $ph3), ($x + 90), ($py3 + $ph3 - 90)); $pen.Dispose()
}
$g.ResetClip()
# dimension lines: extension + arrows + number dash
$dimY = $py3 + $ph3 + 56
$pen = New-Object System.Drawing.Pen($wtMid, 1)
$g.DrawLine($pen, $px3, ($py3 + $ph3 + 10), $px3, ($dimY + 10))
$g.DrawLine($pen, ($px3 + $pw3), ($py3 + $ph3 + 10), ($px3 + $pw3), ($dimY + 10))
$g.DrawLine($pen, $px3, $dimY, ($px3 + $pw3), $dimY); $pen.Dispose()
foreach ($arr in @(@($px3, 1), @(($px3 + $pw3), -1))) {
  $pts = New-Object 'System.Drawing.Point[]' 3
  $pts[0] = New-Object System.Drawing.Point($arr[0], $dimY)
  $pts[1] = New-Object System.Drawing.Point(($arr[0] + 14 * $arr[1]), ($dimY - 5))
  $pts[2] = New-Object System.Drawing.Point(($arr[0] + 14 * $arr[1]), ($dimY + 5))
  $b = New-Object System.Drawing.SolidBrush($wtMid); $g.FillPolygon($b, $pts); $b.Dispose()
}
$b = New-Object System.Drawing.SolidBrush($wt); $g.FillRectangle($b, ($px3 + $pw3 / 2 - 40), ($dimY - 22), 80, 10); $b.Dispose()
# vertical dimension on the left of the part
$dimX = $px3 - 56
$pen = New-Object System.Drawing.Pen($wtMid, 1)
$g.DrawLine($pen, ($px3 - 10), $py3, ($dimX - 10), $py3)
$g.DrawLine($pen, ($px3 - 10), ($py3 + $ph3), ($dimX - 10), ($py3 + $ph3))
$g.DrawLine($pen, $dimX, $py3, $dimX, ($py3 + $ph3)); $pen.Dispose()
$b = New-Object System.Drawing.SolidBrush($wt); $g.FillRectangle($b, ($dimX - 34), ($py3 + $ph3 / 2 - 5), 10, 60); $b.Dispose()
# title block, bottom right
$tbX = 1420; $tbY = 880
$pen = New-Object System.Drawing.Pen($wt, 3); $g.DrawRectangle($pen, $tbX, $tbY, 400, 150); $pen.Dispose()
$pen = New-Object System.Drawing.Pen($wtMid, 1)
$g.DrawLine($pen, $tbX, ($tbY + 50), ($tbX + 400), ($tbY + 50))
$g.DrawLine($pen, $tbX, ($tbY + 100), ($tbX + 400), ($tbY + 100))
$g.DrawLine($pen, ($tbX + 150), $tbY, ($tbX + 150), ($tbY + 150)); $pen.Dispose()
foreach ($rowOff in @(18, 68, 118)) {
  DashRow $g ($tbX + 20) ($tbY + $rowOff) 110 $wtMid 8
  DashRow $g ($tbX + 170) ($tbY + $rowOff) 200 $wtDim 8
}
Save $bmp $g "blueprint.png"

# ── Redacted: typewritten dossier with black bars and stamps ──
$rng = New-Object System.Random(1963)
Get-Random -SetSeed 1963 | Out-Null
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 239 236 226) (C 255 228 224 210)
for ($i = 0; $i -lt 2400; $i++) {
  $b = New-Object System.Drawing.SolidBrush((C $rng.Next(5, 12) 70 62 48))
  $g.FillRectangle($b, $rng.Next(0, $W), $rng.Next(0, $H), 1, 1); $b.Dispose()
}
$ink = C 230 44 40 34
$inkDim = C 150 44 40 34
$redStamp = C 200 168 52 40
# classification banner top center + bottom center
foreach ($by in @(56, 990)) {
  $pen = New-Object System.Drawing.Pen($redStamp, 3); $g.DrawRectangle($pen, 810, $by, 300, 40); $pen.Dispose()
  $b = New-Object System.Drawing.SolidBrush($redStamp); $g.FillRectangle($b, 840, ($by + 15), 240, 11); $b.Dispose()
}
# typewritten paragraphs with redaction bars, right-hand page area
$rowY = 200
while ($rowY -lt 920) {
  $rowX = 1060
  $total = 720
  if ($rng.NextDouble() -lt 0.16) { $rowY += 26 }   # paragraph breaks
  while ($rowX -lt 1060 + $total) {
    $dw = $rng.Next(24, 90)
    if ($rowX + $dw -gt 1060 + $total) { $dw = 1060 + $total - $rowX }
    if ($rng.NextDouble() -lt 0.22) {
      $b = New-Object System.Drawing.SolidBrush((C 245 20 18 16))
      $g.FillRectangle($b, $rowX, ($rowY - 4), ($dw + 14), 18); $b.Dispose()
      $rowX += $dw + 26
    } else {
      $b = New-Object System.Drawing.SolidBrush($(if ($rng.NextDouble() -lt 0.12) { $ink } else { $inkDim }))
      $g.FillRectangle($b, $rowX, $rowY, $dw, 9); $b.Dispose()
      $rowX += $dw + $rng.Next(10, 20)
    }
  }
  $rowY += 30
}
# rotated oval stamp across the text
$g.TranslateTransform(1430, 520)
$g.RotateTransform(-14)
$pen = New-Object System.Drawing.Pen($redStamp, 4); $g.DrawEllipse($pen, -190, -70, 380, 140); $pen.Dispose()
$pen = New-Object System.Drawing.Pen($redStamp, 2); $g.DrawEllipse($pen, -170, -52, 340, 104); $pen.Dispose()
$b = New-Object System.Drawing.SolidBrush($redStamp); $g.FillRectangle($b, -120, -8, 240, 14); $b.Dispose()
$g.ResetTransform()
# paperclip, top-left of the page area
$pen = New-Object System.Drawing.Pen((C 180 120 116 104), 6)
$g.DrawArc($pen, 1006, 130, 44, 46, 180, 180)
$g.DrawLine($pen, 1006, 152, 1006, 250)
$g.DrawLine($pen, 1050, 152, 1050, 224)
$g.DrawArc($pen, 1014, 224, 36, 40, 0, 180)
$pen.Dispose()
# punched holes on the left edge of the page area
foreach ($hy in @(300, 640)) {
  $b = New-Object System.Drawing.SolidBrush((C 60 70 62 48)); $g.FillEllipse($b, 1002, $hy, 26, 26); $b.Dispose()
  $pen = New-Object System.Drawing.Pen($inkDim, 2); $g.DrawEllipse($pen, 1002, $hy, 26, 26); $pen.Dispose()
}
EdgeFade $g "top" 80 22; EdgeFade $g "bottom" 80 26; EdgeFade $g "left" 100 18; EdgeFade $g "right" 100 20
Save $bmp $g "redacted.png"

# ── Persona-red: jagged star collage, halftone, slashes ──
$rng = New-Object System.Random(2016)
Get-Random -SetSeed 2016 | Out-Null
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 14 5 8) (C 255 6 2 3)
$red = C 255 226 32 54
$cx = 1330; $cy = 600
# jagged star: irregular radii, red
function JaggedStar {
  param($g, $cx4, $cy4, $rMin, $rMax, $points, $color, $seed)
  $r2 = New-Object System.Random($seed)
  $pts = New-Object 'System.Drawing.Point[]' ($points * 2)
  for ($k = 0; $k -lt $points * 2; $k++) {
    $ang = ($k / ($points * 2.0)) * 2 * [math]::PI + $r2.NextDouble() * 0.09
    $rr = if ($k % 2 -eq 0) { $rMax * (0.82 + 0.36 * $r2.NextDouble()) } else { $rMin * (0.7 + 0.5 * $r2.NextDouble()) }
    $pts[$k] = New-Object System.Drawing.Point([int]($cx4 + $rr * [math]::Cos($ang)), [int]($cy4 + $rr * [math]::Sin($ang)))
  }
  $b = New-Object System.Drawing.SolidBrush($color); $g.FillPolygon($b, $pts); $b.Dispose()
}
JaggedStar $g $cx $cy 210 430 14 (C 255 150 16 30) 7
JaggedStar $g $cx $cy 190 390 14 $red 8
JaggedStar $g ($cx - 20) ($cy + 10) 120 250 12 (C 255 246 240 238) 9
JaggedStar $g ($cx - 24) ($cy + 14) 90 190 12 (C 255 16 6 8) 10
# black slashes across the star
foreach ($sl in @(@(880, 240, 1750, 860), @(950, 900, 1700, 300))) {
  $pen = New-Object System.Drawing.Pen((C 255 8 3 4), 26)
  $g.DrawLine($pen, $sl[0], $sl[1], $sl[2], $sl[3]); $pen.Dispose()
}
# halftone dot wedge bottom-left
for ($row = 0; $row -lt 12; $row++) {
  for ($col = 0; $col -lt 26; $col++) {
    $dx = 140 + $col * 30; $dy = 760 + $row * 26
    $sz = [math]::Max(1, 7 - [int](($col + $row) / 5))
    if ($sz -gt 0) {
      $b = New-Object System.Drawing.SolidBrush((C 200 226 32 54))
      $g.FillEllipse($b, $dx, $dy, $sz, $sz); $b.Dispose()
    }
  }
}
# white tag star top right with red core
JaggedStar $g 1710 170 55 110 10 (C 255 246 240 238) 11
JaggedStar $g 1712 172 30 62 10 $red 12
EdgeFade $g "top" 90 120; EdgeFade $g "bottom" 110 140; EdgeFade $g "left" 130 120; EdgeFade $g "right" 90 100
Save $bmp $g "persona.png"

# ── Akira: Neo-Tokyo night, taillight trails, kanji neon column ──
$rng = New-Object System.Random(1988)
Get-Random -SetSeed 1988 | Out-Null
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 14 6 10) (C 255 5 2 4)
# dark city blocks on the horizon with sparse warm windows
$x = 0
while ($x -lt $W) {
  $bw = $rng.Next(90, 240); $h2 = $rng.Next(120, 320)
  $b = New-Object System.Drawing.SolidBrush((C 255 10 5 8))
  $g.FillRectangle($b, $x, (620 - $h2), $bw, $h2); $b.Dispose()
  for ($i = 0; $i -lt [int]($bw * $h2 / 2600); $i++) {
    $b = New-Object System.Drawing.SolidBrush((C $rng.Next(40, 120) 255 120 90))
    $g.FillRectangle($b, ($x + $rng.Next(4, $bw - 4)), (620 - $h2 + $rng.Next(6, $h2 - 6)), 2, 3); $b.Dispose()
  }
  $x += $bw + $rng.Next(4, 30)
}
# taillight trails: sweeping bezier ribbons with layered bloom
foreach ($trail in @(
    @(-100, 900, 700, 660, 1300, 820, 2020, 700, 255, 42, 60),
    @(-100, 980, 800, 840, 1400, 960, 2020, 830, 230, 30, 44),
    @(-100, 840, 500, 700, 1100, 700, 2020, 610, 160, 16, 26))) {
  $path = New-Object System.Drawing.Drawing2D.GraphicsPath
  $path.AddBezier($trail[0], $trail[1], $trail[2], $trail[3], $trail[4], $trail[5], $trail[6], $trail[7])
  foreach ($pass in @(@(30, 30), @(80, 14), @(200, 6), @(255, 2))) {
    $pen = New-Object System.Drawing.Pen((C ([math]::Min($pass[0], $trail[8])) 255 $trail[9] $trail[10]), $pass[1])
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $g.DrawPath($pen, $path); $pen.Dispose()
  }
  $path.Dispose()
}
# white core streak on the main trail
$path = New-Object System.Drawing.Drawing2D.GraphicsPath
$path.AddBezier(-100, 900, 700, 660, 1300, 820, 2020, 700)
$pen = New-Object System.Drawing.Pen((C 200 255 235 225), 1); $g.DrawPath($pen, $path); $pen.Dispose(); $path.Dispose()
# neon sign column, right: vertical CJK glyphs on a dark sign board
$b = New-Object System.Drawing.SolidBrush((C 240 16 6 8)); $g.FillRectangle($b, 1700, 110, 90, 460); $b.Dispose()
$pen = New-Object System.Drawing.Pen((C 200 255 60 70), 3); $g.DrawRectangle($pen, 1700, 110, 90, 460); $pen.Dispose()
Glow $g 1745 340 190 (C 46 255 60 70)
$font = New-Object System.Drawing.Font("Consolas", 34, [System.Drawing.FontStyle]::Bold)
for ($i = 0; $i -lt 6; $i++) {
  $ch = [char](0x4E00 + $rng.Next(0, 0x9FA5 - 0x4E00))
  $b = New-Object System.Drawing.SolidBrush((C $(if ($i -eq 2) { 255 } else { 200 }) 255 84 92))
  $g.DrawString($ch, $font, $b, 1716, (128 + $i * 72)); $b.Dispose()
}
$font.Dispose()
# road glow + grain
Glow $g 960 980 700 (C 26 255 60 70)
for ($i = 0; $i -lt 1500; $i++) {
  $b = New-Object System.Drawing.SolidBrush((C $rng.Next(6, 16) 255 200 190))
  $g.FillRectangle($b, $rng.Next(0, $W), $rng.Next(0, $H), 1, 1); $b.Dispose()
}
EdgeFade $g "top" 130 140; EdgeFade $g "bottom" 110 120; EdgeFade $g "left" 140 120; EdgeFade $g "right" 110 100
Save $bmp $g "akira.png"

# ── Bebop: bounty-card space noir, star chart, tracking lines ──
$rng = New-Object System.Random(1998)
Get-Random -SetSeed 1998 | Out-Null
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 10 15 28) (C 255 5 8 16)
Glow $g 500 900 600 (C 26 232 168 60)      # warm jazz glow bottom-left
# star field
for ($i = 0; $i -lt 420; $i++) {
  $b = New-Object System.Drawing.SolidBrush((C $rng.Next(30, 140) 220 226 240))
  $sz = if ($rng.NextDouble() -lt 0.08) { 2 } else { 1 }
  $g.FillRectangle($b, $rng.Next(0, $W), $rng.Next(0, $H), $sz, $sz); $b.Dispose()
}
$amber = C 230 232 168 60
$amberDim = C 120 200 150 60
$cream = C 220 232 217 176
# dotted route across a faint chart grid, left half
for ($i = 0; $i -le 6; $i++) {
  $pen = New-Object System.Drawing.Pen((C 22 150 170 210), 1)
  $g.DrawLine($pen, 140, (520 + $i * 78), 900, (520 + $i * 78)); $pen.Dispose()
}
for ($i = 0; $i -le 8; $i++) {
  $pen = New-Object System.Drawing.Pen((C 22 150 170 210), 1)
  $g.DrawLine($pen, (140 + $i * 95), 520, (140 + $i * 95), 988); $pen.Dispose()
}
$route = @(@(200, 940), @(360, 830), @(520, 870), @(660, 700), @(820, 640))
for ($i = 0; $i -lt $route.Count - 1; $i++) {
  $x1 = $route[$i][0]; $y1 = $route[$i][1]; $x2 = $route[$i + 1][0]; $y2 = $route[$i + 1][1]
  $steps = 12
  for ($s = 0; $s -lt $steps; $s += 2) {
    $sx = $x1 + ($x2 - $x1) * $s / $steps; $sy = $y1 + ($y2 - $y1) * $s / $steps
    $ex = $x1 + ($x2 - $x1) * ($s + 1) / $steps; $ey = $y1 + ($y2 - $y1) * ($s + 1) / $steps
    $pen = New-Object System.Drawing.Pen($amberDim, 2)
    $g.DrawLine($pen, [int]$sx, [int]$sy, [int]$ex, [int]$ey); $pen.Dispose()
  }
  $pen = New-Object System.Drawing.Pen($amber, 2); $g.DrawEllipse($pen, ($x1 - 5), ($y1 - 5), 10, 10); $pen.Dispose()
}
# ship marker: small triangle at route end
$tri = New-Object 'System.Drawing.Point[]' 3
$tri[0] = New-Object System.Drawing.Point(820, 626)
$tri[1] = New-Object System.Drawing.Point(836, 652)
$tri[2] = New-Object System.Drawing.Point(804, 652)
$b = New-Object System.Drawing.SolidBrush($amber); $g.FillPolygon($b, $tri); $b.Dispose()
# bounty card: rounded TV frame, right side, with starburst behind
$bx = 1150; $by = 240; $bw2 = 560; $bh2 = 480
$star = New-Object 'System.Drawing.Point[]' 16
for ($k = 0; $k -lt 16; $k++) {
  $ang = ($k / 16.0) * 2 * [math]::PI
  $rr = if ($k % 2 -eq 0) { 380 } else { 210 }
  $star[$k] = New-Object System.Drawing.Point([int](1430 + $rr * [math]::Cos($ang)), [int](480 + $rr * 0.72 * [math]::Sin($ang)))
}
$b = New-Object System.Drawing.SolidBrush((C 46 232 168 60)); $g.FillPolygon($b, $star); $b.Dispose()
$path = New-Object System.Drawing.Drawing2D.GraphicsPath
$path.AddArc($bx, $by, 60, 60, 180, 90); $path.AddArc(($bx + $bw2 - 60), $by, 60, 60, 270, 90)
$path.AddArc(($bx + $bw2 - 60), ($by + $bh2 - 60), 60, 60, 0, 90); $path.AddArc($bx, ($by + $bh2 - 60), 60, 60, 90, 90)
$path.CloseFigure()
$b = New-Object System.Drawing.SolidBrush((C 235 12 17 30)); $g.FillPath($b, $path); $b.Dispose()
$pen = New-Object System.Drawing.Pen($amber, 4); $g.DrawPath($pen, $path); $pen.Dispose(); $path.Dispose()
# mugshot box with crosshatch + info dashes
$pen = New-Object System.Drawing.Pen($cream, 2); $g.DrawRectangle($pen, ($bx + 40), ($by + 50), 200, 240); $pen.Dispose()
$clip = New-Object System.Drawing.Rectangle(($bx + 41), ($by + 51), 199, 239)
$g.SetClip($clip)
for ($x = $bx - 220; $x -lt $bx + 260; $x += 16) {
  $pen = New-Object System.Drawing.Pen((C 60 232 217 176), 1)
  $g.DrawLine($pen, $x, ($by + 300), ($x + 240), ($by + 40)); $pen.Dispose()
}
$g.ResetClip()
DashRow $g ($bx + 280) ($by + 70) 230 $cream 12
DashRow $g ($bx + 280) ($by + 120) 200 $amberDim 9
DashRow $g ($bx + 280) ($by + 160) 230 $amberDim 9
DashRow $g ($bx + 280) ($by + 200) 170 $amberDim 9
# big reward figure stand-in
$b = New-Object System.Drawing.SolidBrush($amber); $g.FillRectangle($b, ($bx + 60), ($by + 360), 420, 26); $b.Dispose()
DashRow $g ($bx + 60) ($by + 412) 380 $amberDim 10
# VHS tracking lines
foreach ($ty in @(180, 760)) {
  $b = New-Object System.Drawing.SolidBrush((C 26 232 217 176)); $g.FillRectangle($b, 0, $ty, $W, 5); $b.Dispose()
  $b = New-Object System.Drawing.SolidBrush((C 14 232 217 176)); $g.FillRectangle($b, 0, ($ty + 9), $W, 2); $b.Dispose()
}
EdgeFade $g "top" 120 130; EdgeFade $g "bottom" 120 130; EdgeFade $g "left" 130 110; EdgeFade $g "right" 110 100
Save $bmp $g "bebop.png"

# ── Scouter: green lens HUD, reticle, power readout ──
$rng = New-Object System.Random(1989)
Get-Random -SetSeed 1989 | Out-Null
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 6 14 8) (C 255 3 7 4)
$grn = C 225 110 240 110
$grnDim = C 100 80 190 85
# lens ring, right side, with heavy glow
$cx = 1360; $cy = 560
Glow $g $cx $cy 560 (C 34 90 255 100)
$pen = New-Object System.Drawing.Pen($grn, 5); $g.DrawEllipse($pen, ($cx - 380), ($cy - 380), 760, 760); $pen.Dispose()
$pen = New-Object System.Drawing.Pen($grnDim, 2); $g.DrawEllipse($pen, ($cx - 330), ($cy - 330), 660, 660); $pen.Dispose()
# arc tick scales inside the lens
foreach ($arc in @(@(300, 140, 80), @(260, 200, 60))) {
  for ($i = 0; $i -le 10; $i++) {
    $ang = ($arc[1] + $i * $arc[2] / 10) * [math]::PI / 180
    $x1 = $cx + ($arc[0] - 14) * [math]::Cos($ang); $y1 = $cy + ($arc[0] - 14) * [math]::Sin($ang)
    $x2 = $cx + $arc[0] * [math]::Cos($ang); $y2 = $cy + $arc[0] * [math]::Sin($ang)
    $pen = New-Object System.Drawing.Pen($(if ($i % 5 -eq 0) { $grn } else { $grnDim }), 2)
    $g.DrawLine($pen, [int]$x1, [int]$y1, [int]$x2, [int]$y2); $pen.Dispose()
  }
}
# diamond reticle on a target point, with bracket ticks
$tx = $cx - 90; $ty = $cy + 60
$dia = New-Object 'System.Drawing.Point[]' 4
$dia[0] = New-Object System.Drawing.Point($tx, ($ty - 46))
$dia[1] = New-Object System.Drawing.Point(($tx + 46), $ty)
$dia[2] = New-Object System.Drawing.Point($tx, ($ty + 46))
$dia[3] = New-Object System.Drawing.Point(($tx - 46), $ty)
$pen = New-Object System.Drawing.Pen($grn, 3); $g.DrawPolygon($pen, $dia); $pen.Dispose()
Glow $g $tx $ty 80 (C 70 110 255 120)
$pen = New-Object System.Drawing.Pen($grn, 3)
$g.DrawLine($pen, ($tx - 90), $ty, ($tx - 58), $ty); $g.DrawLine($pen, ($tx + 58), $ty, ($tx + 90), $ty)
$g.DrawLine($pen, $tx, ($ty - 90), $tx, ($ty - 58)); $g.DrawLine($pen, $tx, ($ty + 58), $tx, ($ty + 90))
$pen.Dispose()
# climbing digit readout next to the reticle
$font = New-Object System.Drawing.Font("Consolas", 24, [System.Drawing.FontStyle]::Bold)
$fontSm = New-Object System.Drawing.Font("Consolas", 14)
$b = New-Object System.Drawing.SolidBrush($grn)
$g.DrawString([string]$rng.Next(7000, 9999), $font, $b, ($tx + 110), ($ty - 90)); $b.Dispose()
foreach ($i in 0..3) {
  $b = New-Object System.Drawing.SolidBrush((C $(180 - $i * 40) 110 240 110))
  $g.DrawString([string]$rng.Next(1000, 9999), $fontSm, $b, ($tx + 116), ($ty - 46 + $i * 26)); $b.Dispose()
}
$font.Dispose(); $fontSm.Dispose()
# left data column: small frames + dashes
foreach ($i in 0..2) {
  $fy = 620 + $i * 130
  $pen = New-Object System.Drawing.Pen($grnDim, 2); $g.DrawRectangle($pen, 150, $fy, 300, 92); $pen.Dispose()
  DashRow $g 172 ($fy + 22) 250 $grnDim 8
  DashRow $g 172 ($fy + 52) 220 $(if ($i -eq 0) { $grn } else { $grnDim }) 8
}
# segmented power bar bottom, mostly lit
for ($i = 0; $i -lt 22; $i++) {
  $alpha = if ($i -lt 16) { 220 } else { 60 }
  $b = New-Object System.Drawing.SolidBrush((C $alpha 110 240 110))
  $g.FillRectangle($b, (520 + $i * 40), 960, 30, 22); $b.Dispose()
}
$pen = New-Object System.Drawing.Pen($grnDim, 2); $g.DrawRectangle($pen, 510, 950, 900, 42); $pen.Dispose()
# scanlines
$row = 0
for ($y = 0; $y -lt $H; $y += 3) {
  $pen = New-Object System.Drawing.Pen((C $(if ($row % 2 -eq 0) { 24 } else { 10 }) 0 0 0), 1)
  $g.DrawLine($pen, 0, $y, $W, $y); $pen.Dispose()
  $row++
}
EdgeFade $g "top" 110 120; EdgeFade $g "bottom" 110 120; EdgeFade $g "left" 130 110; EdgeFade $g "right" 100 90
Save $bmp $g "scouter.png"

# ── Backrooms: liminal yellow hallway, fluorescent panels ──
$rng = New-Object System.Random(2019)
Get-Random -SetSeed 2019 | Out-Null
$bmp, $g = New-Canvas
$vpx = 1230; $vpy = 500   # vanishing point
# ceiling / walls / carpet as converging planes
$b = New-Object System.Drawing.SolidBrush((C 255 216 205 138)); $g.FillRectangle($b, 0, 0, $W, $H); $b.Dispose()
# carpet
$carpet = New-Object 'System.Drawing.Point[]' 4
$carpet[0] = New-Object System.Drawing.Point(0, $H)
$carpet[1] = New-Object System.Drawing.Point($W, $H)
$carpet[2] = New-Object System.Drawing.Point(($vpx + 260), ($vpy + 90))
$carpet[3] = New-Object System.Drawing.Point(($vpx - 420), ($vpy + 90))
$b = New-Object System.Drawing.SolidBrush((C 255 148 136 82)); $g.FillPolygon($b, $carpet); $b.Dispose()
# ceiling
$ceil = New-Object 'System.Drawing.Point[]' 4
$ceil[0] = New-Object System.Drawing.Point(0, 0)
$ceil[1] = New-Object System.Drawing.Point($W, 0)
$ceil[2] = New-Object System.Drawing.Point(($vpx + 260), ($vpy - 170))
$ceil[3] = New-Object System.Drawing.Point(($vpx - 420), ($vpy - 170))
$b = New-Object System.Drawing.SolidBrush((C 255 228 219 158)); $g.FillPolygon($b, $ceil); $b.Dispose()
# end wall
$b = New-Object System.Drawing.SolidBrush((C 255 205 193 122))
$g.FillRectangle($b, ($vpx - 420), ($vpy - 170), 680, 260); $b.Dispose()
# wall seams converging to the vanishing point
foreach ($sx in @(60, 420, 800)) {
  $pen = New-Object System.Drawing.Pen((C 60 120 108 60), 2)
  $g.DrawLine($pen, $sx, 0, ($vpx - 420 + [int]($sx * 0.18)), ($vpy - 170)); $pen.Dispose()
  $pen = New-Object System.Drawing.Pen((C 60 120 108 60), 2)
  $g.DrawLine($pen, $sx, $H, ($vpx - 420 + [int]($sx * 0.18)), ($vpy + 90)); $pen.Dispose()
}
foreach ($sx in @(1640, 1820)) {
  $pen = New-Object System.Drawing.Pen((C 50 120 108 60), 2)
  $g.DrawLine($pen, $sx, 0, ($vpx + 260 - [int](($W - $sx) * 0.2)), ($vpy - 170)); $pen.Dispose()
  $pen = New-Object System.Drawing.Pen((C 50 120 108 60), 2)
  $g.DrawLine($pen, $sx, $H, ($vpx + 260 - [int](($W - $sx) * 0.2)), ($vpy + 90)); $pen.Dispose()
}
# baseboards
$pen = New-Object System.Drawing.Pen((C 150 110 100 58), 5)
$g.DrawLine($pen, 0, $H, ($vpx - 420), ($vpy + 90))
$g.DrawLine($pen, $W, $H, ($vpx + 260), ($vpy + 90))
$g.DrawLine($pen, ($vpx - 420), ($vpy + 90), ($vpx + 260), ($vpy + 90))
$pen.Dispose()
# fluorescent ceiling panels shrinking toward the VP, humming glow
foreach ($panel in @(@(240, 40, 420, 110), @(700, 130, 300, 74), @(1010, 230, 210, 48), @(1210, 300, 150, 32))) {
  $px4 = $panel[0]; $py4 = $panel[1]; $pw4 = $panel[2]; $ph4 = $panel[3]
  Glow $g ($px4 + $pw4 / 2) ($py4 + $ph4 / 2) ([int]($pw4 * 0.9)) (C 60 255 250 210)
  $b = New-Object System.Drawing.SolidBrush((C 245 252 248 214)); $g.FillRectangle($b, $px4, $py4, $pw4, $ph4); $b.Dispose()
  $pen = New-Object System.Drawing.Pen((C 120 170 158 96), 2); $g.DrawRectangle($pen, $px4, $py4, $pw4, $ph4); $pen.Dispose()
}
# far dark doorway, unsettling
$b = New-Object System.Drawing.SolidBrush((C 255 52 46 26)); $g.FillRectangle($b, ($vpx + 120), ($vpy - 60), 66, 150); $b.Dispose()
# carpet mottle + wall grain
for ($i = 0; $i -lt 2600; $i++) {
  $gy = $rng.Next(0, $H)
  $alpha = if ($gy -gt $vpy + 90) { $rng.Next(10, 26) } else { $rng.Next(5, 14) }
  $b = New-Object System.Drawing.SolidBrush((C $alpha 80 72 40))
  $g.FillRectangle($b, $rng.Next(0, $W), $gy, 2, 1); $b.Dispose()
}
# sickly vignette
EdgeFade $g "top" 140 90; EdgeFade $g "bottom" 160 110; EdgeFade $g "left" 180 100; EdgeFade $g "right" 160 90
Save $bmp $g "backrooms.png"

# ── Swordfish: multi-window crack den, cyan cascades, wireframe core ──
$rng = New-Object System.Random(2001)
Get-Random -SetSeed 2001 | Out-Null
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 5 11 20) (C 255 2 5 10)
Glow $g 1250 520 700 (C 26 60 200 255)
$cyan = C 210 100 220 255
$cyanDim = C 90 70 170 220
$font = New-Object System.Drawing.Font("Consolas", 13)
# translucent window panes behind everything
foreach ($win in @(@(1040, 130, 560, 380), @(1330, 330, 470, 420), @(120, 560, 420, 380))) {
  $b = New-Object System.Drawing.SolidBrush((C 120 8 16 30)); $g.FillRectangle($b, $win[0], $win[1], $win[2], $win[3]); $b.Dispose()
  $pen = New-Object System.Drawing.Pen($cyanDim, 2); $g.DrawRectangle($pen, $win[0], $win[1], $win[2], $win[3]); $pen.Dispose()
  $b = New-Object System.Drawing.SolidBrush((C 170 10 22 40)); $g.FillRectangle($b, $win[0], $win[1], $win[2], 30); $b.Dispose()
  DashRow $g ($win[0] + 14) ($win[1] + 10) ([int]($win[2] * 0.5)) $cyanDim 8
}
# cascading cipher columns inside the left window and right pane
foreach ($zone in @(@(150, 600, 360, 320), @(1360, 380, 400, 340))) {
  for ($col = 0; $col -lt [int]($zone[2] / 26); $col++) {
    $colX = $zone[0] + $col * 26
    $drop = $rng.Next(3, 12)
    for ($row = 0; $row -lt $drop; $row++) {
      $ch = [char](0x21 + $rng.Next(0, 93))
      $alpha = [int](40 + 180 * ($row / [double]$drop))
      $b = New-Object System.Drawing.SolidBrush((C $alpha 100 220 255))
      $g.DrawString($ch, $font, $b, $colX, ($zone[1] + $row * 24)); $b.Dispose()
    }
  }
}
$font.Dispose()
# central wireframe polyhedron with rotation ghosts
$cx = 1180; $cy = 640
Glow $g $cx $cy 260 (C 46 100 220 255)
foreach ($ghost in @(@(0, 40), @(14, 90), @(28, 210))) {
  $pts = New-Object 'System.Drawing.Point[]' 6
  for ($k = 0; $k -lt 6; $k++) {
    $ang = ($k * 60 + $ghost[0]) * [math]::PI / 180
    $pts[$k] = New-Object System.Drawing.Point([int]($cx + 170 * [math]::Cos($ang)), [int]($cy + 170 * [math]::Sin($ang)))
  }
  $pen = New-Object System.Drawing.Pen((C $ghost[1] 100 220 255), 2)
  $g.DrawPolygon($pen, $pts)
  for ($k = 0; $k -lt 6; $k++) {
    for ($j = $k + 1; $j -lt 6; $j++) { $g.DrawLine($pen, $pts[$k], $pts[$j]) }
  }
  $pen.Dispose()
}
$pen = New-Object System.Drawing.Pen($cyan, 2); $g.DrawEllipse($pen, ($cx - 210), ($cy - 210), 420, 420); $pen.Dispose()
# tick ring
for ($i = 0; $i -lt 36; $i++) {
  $ang = ($i / 36.0) * 2 * [math]::PI
  $x1 = $cx + 218 * [math]::Cos($ang); $y1 = $cy + 218 * [math]::Sin($ang)
  $x2 = $cx + 232 * [math]::Cos($ang); $y2 = $cy + 232 * [math]::Sin($ang)
  $pen = New-Object System.Drawing.Pen($(if ($i % 6 -eq 0) { $cyan } else { $cyanDim }), 2)
  $g.DrawLine($pen, [int]$x1, [int]$y1, [int]$x2, [int]$y2); $pen.Dispose()
}
# progress strip bottom: mostly-lit segments
for ($i = 0; $i -lt 26; $i++) {
  $alpha = if ($i -lt 19) { 210 } else { 50 }
  $b = New-Object System.Drawing.SolidBrush((C $alpha 100 220 255))
  $g.FillRectangle($b, (560 + $i * 32), 968, 24, 16); $b.Dispose()
}
# scanlines
$row = 0
for ($y = 0; $y -lt $H; $y += 3) {
  $pen = New-Object System.Drawing.Pen((C $(if ($row % 2 -eq 0) { 22 } else { 9 }) 0 0 0), 1)
  $g.DrawLine($pen, 0, $y, $W, $y); $pen.Dispose()
  $row++
}
EdgeFade $g "top" 110 120; EdgeFade $g "bottom" 110 120; EdgeFade $g "left" 130 110; EdgeFade $g "right" 110 100
Save $bmp $g "swordfish.png"

# ── Hackers: the data-city — glowing towers on a perspective grid ──
$rng = New-Object System.Random(1995)
Get-Random -SetSeed 1995 | Out-Null
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 10 6 18) (C 255 4 2 8)
$vpy = 600
# perspective grid floor
for ($i = 0; $i -lt 26; $i++) {
  $gx2 = -400 + $i * 110
  $pen = New-Object System.Drawing.Pen((C 46 90 240 170), 1)
  $g.DrawLine($pen, $gx2, $H, (960 + [int](($gx2 - 960) * 0.12)), $vpy); $pen.Dispose()
}
$gy = $vpy
$step = 6
while ($gy -lt $H) {
  $pen = New-Object System.Drawing.Pen((C $([int](20 + 40 * ($gy - $vpy) / 480)) 90 240 170), 1)
  $g.DrawLine($pen, 0, $gy, $W, $gy); $pen.Dispose()
  $step = [int]($step * 1.35) + 2
  $gy += $step
}
# horizon glow
Glow $g 960 $vpy 500 (C 30 120 255 190)
# data towers: colored columns with window ticks, back row then front
$towers = @(
  @(300, 340, 66, 57, 232, 120),     # x, height, width, r, g, b (teal)
  @(520, 500, 84, 255, 77, 216),     # magenta
  @(760, 280, 56, 57, 232, 120),
  @(1050, 560, 96, 255, 150, 40),    # orange
  @(1330, 420, 74, 57, 232, 120),
  @(1560, 620, 100, 255, 77, 216),
  @(1760, 300, 60, 120, 240, 255)    # cyan
)
foreach ($tw in $towers) {
  $tx = $tw[0]; $th2 = $tw[1]; $twd = $tw[2]
  $baseY = 900 + $rng.Next(-30, 40)
  Glow $g ($tx + $twd / 2) $baseY ([int]($twd * 2.2)) (C 60 $tw[3] $tw[4] $tw[5])
  # column: vertical gradient bright at base
  $rect = New-Object System.Drawing.Rectangle($tx, ($baseY - $th2), $twd, $th2)
  $br = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, (C 60 $tw[3] $tw[4] $tw[5]), (C 235 $tw[3] $tw[4] $tw[5]), 90.0)
  $g.FillRectangle($br, $rect); $br.Dispose()
  $pen = New-Object System.Drawing.Pen((C 200 $tw[3] $tw[4] $tw[5]), 2)
  $g.DrawRectangle($pen, $tx, ($baseY - $th2), $twd, $th2); $pen.Dispose()
  # window tick rows in dark
  for ($wy = $baseY - $th2 + 12; $wy -lt $baseY - 10; $wy += 18) {
    $b = New-Object System.Drawing.SolidBrush((C 130 6 3 10))
    $g.FillRectangle($b, ($tx + 8), $wy, ($twd - 16), 5); $b.Dispose()
  }
  # beacon on top
  $b = New-Object System.Drawing.SolidBrush((C 255 $tw[3] $tw[4] $tw[5]))
  $g.FillEllipse($b, ($tx + $twd / 2 - 4), ($baseY - $th2 - 8), 8, 8); $b.Dispose()
  Glow $g ($tx + $twd / 2) ($baseY - $th2 - 4) 26 (C 120 $tw[3] $tw[4] $tw[5])
}
# circuit trace running across the floor between towers
$trace = @(@(120, 1020), @(430, 980), @(700, 1000), @(980, 940), @(1300, 990), @(1700, 950))
for ($i = 0; $i -lt $trace.Count - 1; $i++) {
  $pen = New-Object System.Drawing.Pen((C 170 57 232 120), 3)
  $g.DrawLine($pen, $trace[$i][0], $trace[$i][1], $trace[$i + 1][0], $trace[$i + 1][1]); $pen.Dispose()
  $b = New-Object System.Drawing.SolidBrush((C 230 57 232 120))
  $g.FillEllipse($b, ($trace[$i + 1][0] - 4), ($trace[$i + 1][1] - 4), 8, 8); $b.Dispose()
}
# particles above the city
for ($i = 0; $i -lt 260; $i++) {
  $colors = @(@(57, 232, 120), @(255, 77, 216), @(120, 240, 255))
  $cc = $colors[$rng.Next(0, 3)]
  $b = New-Object System.Drawing.SolidBrush((C $rng.Next(30, 120) $cc[0] $cc[1] $cc[2]))
  $g.FillRectangle($b, $rng.Next(0, $W), $rng.Next(0, $vpy), 2, 2); $b.Dispose()
}
EdgeFade $g "top" 120 130; EdgeFade $g "bottom" 100 110; EdgeFade $g "left" 130 110; EdgeFade $g "right" 110 100
Save $bmp $g "hackers.png"

function Octagon {
  # regular octagon points around a center, optionally rotated
  param($cx3, $cy3, $r, $rotDeg)
  $pts = New-Object 'System.Drawing.Point[]' 8
  for ($k = 0; $k -lt 8; $k++) {
    $ang = (($k * 45) + $rotDeg) * [math]::PI / 180
    $pts[$k] = New-Object System.Drawing.Point([int]($cx3 + $r * [math]::Cos($ang)), [int]($cy3 + $r * [math]::Sin($ang)))
  }
  return , $pts
}
function CutRect {
  # BSG cut-corner rectangle: corners clipped at 45 degrees
  param($x, $y, $rw, $rh, $cut)
  $pts = New-Object 'System.Drawing.Point[]' 8
  $pts[0] = New-Object System.Drawing.Point(($x + $cut), $y)
  $pts[1] = New-Object System.Drawing.Point(($x + $rw - $cut), $y)
  $pts[2] = New-Object System.Drawing.Point(($x + $rw), ($y + $cut))
  $pts[3] = New-Object System.Drawing.Point(($x + $rw), ($y + $rh - $cut))
  $pts[4] = New-Object System.Drawing.Point(($x + $rw - $cut), ($y + $rh))
  $pts[5] = New-Object System.Drawing.Point(($x + $cut), ($y + $rh))
  $pts[6] = New-Object System.Drawing.Point($x, ($y + $rh - $cut))
  $pts[7] = New-Object System.Drawing.Point($x, ($y + $cut))
  return , $pts
}

# ── Galactica: CIC amber gloom, DRADIS octagons, cut-corner paper ──
$rng = New-Object System.Random(2004)
Get-Random -SetSeed 2004 | Out-Null
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 13 10 6) (C 255 6 5 3)
Glow $g 1360 560 520 (C 30 216 168 80)
$amb = C 215 216 168 80
$ambDim = C 95 180 140 70
# DRADIS: concentric octagon rings, alternating rotation
$cx = 1380; $cy = 560
foreach ($ring in @(@(300, 0, 2), @(250, 22, 1), @(190, 0, 1), @(120, 22, 1))) {
  $pen = New-Object System.Drawing.Pen($(if ($ring[0] -eq 300) { $amb } else { $ambDim }), $ring[2])
  $g.DrawPolygon($pen, (Octagon $cx $cy $ring[0] $ring[1])); $pen.Dispose()
}
# bearing spokes
for ($i = 0; $i -lt 8; $i++) {
  $ang = ($i * 45 + 22) * [math]::PI / 180
  $pen = New-Object System.Drawing.Pen((C 55 180 140 70), 1)
  $g.DrawLine($pen, ($cx + [int](60 * [math]::Cos($ang))), ($cy + [int](60 * [math]::Sin($ang))), ($cx + [int](296 * [math]::Cos($ang))), ($cy + [int](296 * [math]::Sin($ang)))); $pen.Dispose()
}
# center marker + blips: friendly triangles, hostile diamonds
$b = New-Object System.Drawing.SolidBrush($amb); $g.FillEllipse($b, ($cx - 6), ($cy - 6), 12, 12); $b.Dispose()
foreach ($blip in @(@(120, -60, $true), @(-150, 40, $true), @(60, 150, $true))) {
  $bx = $cx + $blip[0]; $by = $cy + $blip[1]
  $tri = New-Object 'System.Drawing.Point[]' 3
  $tri[0] = New-Object System.Drawing.Point($bx, ($by - 10))
  $tri[1] = New-Object System.Drawing.Point(($bx + 9), ($by + 7))
  $tri[2] = New-Object System.Drawing.Point(($bx - 9), ($by + 7))
  $pen = New-Object System.Drawing.Pen((C 220 130 220 120), 2); $g.DrawPolygon($pen, $tri); $pen.Dispose()
}
foreach ($blip in @(@(-90, -140), @(200, 90))) {
  $bx = $cx + $blip[0]; $by = $cy + $blip[1]
  $dia = New-Object 'System.Drawing.Point[]' 4
  $dia[0] = New-Object System.Drawing.Point($bx, ($by - 10))
  $dia[1] = New-Object System.Drawing.Point(($bx + 10), $by)
  $dia[2] = New-Object System.Drawing.Point($bx, ($by + 10))
  $dia[3] = New-Object System.Drawing.Point(($bx - 10), $by)
  $pen = New-Object System.Drawing.Pen((C 230 255 90 80), 2); $g.DrawPolygon($pen, $dia); $pen.Dispose()
  Glow $g $bx $by 26 (C 80 255 90 80)
}
# cut-corner paper panels, lower left
foreach ($panel in @(@(150, 620, 420, 200), @(210, 860, 360, 130))) {
  $pts = CutRect $panel[0] $panel[1] $panel[2] $panel[3] 26
  $b = New-Object System.Drawing.SolidBrush((C 26 216 190 130)); $g.FillPolygon($b, $pts); $b.Dispose()
  $pen = New-Object System.Drawing.Pen($ambDim, 2); $g.DrawPolygon($pen, $pts); $pen.Dispose()
  $rowY = $panel[1] + 34
  while ($rowY -lt $panel[1] + $panel[3] - 24) {
    DashRow $g ($panel[0] + 36) $rowY ($panel[2] - 80) $ambDim 7
    $rowY += 30
  }
}
# header band with a red condition tab
$pen = New-Object System.Drawing.Pen($ambDim, 2); $g.DrawLine($pen, 140, 130, 1780, 130); $pen.Dispose()
DashRow $g 150 96 340 $amb 11
$pts = CutRect 1580 84 200 40 12
$b = New-Object System.Drawing.SolidBrush((C 200 200 60 50)); $g.FillPolygon($b, $pts); $b.Dispose()
$b = New-Object System.Drawing.SolidBrush((C 220 255 200 190)); $g.FillRectangle($b, 1614, 98, 130, 10); $b.Dispose()
# scanlines + vignette
$row = 0
for ($y = 0; $y -lt $H; $y += 3) {
  $pen = New-Object System.Drawing.Pen((C $(if ($row % 2 -eq 0) { 20 } else { 8 }) 0 0 0), 1)
  $g.DrawLine($pen, 0, $y, $W, $y); $pen.Dispose()
  $row++
}
EdgeFade $g "top" 110 120; EdgeFade $g "bottom" 120 130; EdgeFade $g "left" 130 110; EdgeFade $g "right" 110 100
Save $bmp $g "galactica.png"

# ── Ski cabin: plank wall, snowy window, fire glow, string lights ──
$rng = New-Object System.Random(7)
Get-Random -SetSeed 7 | Out-Null
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 40 29 20) (C 255 26 18 12)
# plank wall with grain and knots
$plankY = 0
while ($plankY -lt $H) {
  $ph2 = $rng.Next(96, 150)
  $tone = $rng.Next(-8, 9)
  $b = New-Object System.Drawing.SolidBrush((C 255 (46 + $tone) (33 + $tone) (22 + [int]($tone / 2))))
  $g.FillRectangle($b, 0, $plankY, $W, $ph2); $b.Dispose()
  $pen = New-Object System.Drawing.Pen((C 130 18 12 8), 3); $g.DrawLine($pen, 0, ($plankY + $ph2), $W, ($plankY + $ph2)); $pen.Dispose()
  for ($i = 0; $i -lt 5; $i++) {
    $gy2 = $plankY + $rng.Next(12, $ph2 - 12)
    $pen = New-Object System.Drawing.Pen((C $rng.Next(18, 40) 20 14 9), 1)
    $g.DrawLine($pen, $rng.Next(0, $W - 500), $gy2, $rng.Next(0, $W), ($gy2 + $rng.Next(-4, 5))); $pen.Dispose()
  }
  if ($rng.NextDouble() -lt 0.7) {
    $kx = $rng.Next(100, $W - 100); $ky = $plankY + $rng.Next(20, $ph2 - 20)
    $b = New-Object System.Drawing.SolidBrush((C 120 24 16 10)); $g.FillEllipse($b, $kx, $ky, 14, 10); $b.Dispose()
    $pen = New-Object System.Drawing.Pen((C 90 18 12 8), 1); $g.DrawEllipse($pen, ($kx - 3), ($ky - 2), 20, 14); $pen.Dispose()
  }
  $plankY += $ph2
}
# window with snowy night
$wx = 1150; $wy = 220; $ww = 560; $wh = 440
$b = New-Object System.Drawing.SolidBrush((C 255 30 20 14)); $g.FillRectangle($b, ($wx - 26), ($wy - 26), ($ww + 52), ($wh + 52)); $b.Dispose()
# night sky in panes
$rect = New-Object System.Drawing.Rectangle($wx, $wy, $ww, $wh)
$br = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, (C 255 22 34 58), (C 255 40 58 88), 90.0)
$g.FillRectangle($br, $rect); $br.Dispose()
Glow $g ($wx + 430) ($wy + 90) 60 (C 220 235 235 215)
$b = New-Object System.Drawing.SolidBrush((C 255 235 235 215)); $g.FillEllipse($b, ($wx + 405), ($wy + 65), 50, 50); $b.Dispose()
# mountains + pines
$mtn = New-Object 'System.Drawing.Point[]' 5
$mtn[0] = New-Object System.Drawing.Point($wx, ($wy + 300))
$mtn[1] = New-Object System.Drawing.Point(($wx + 170), ($wy + 150))
$mtn[2] = New-Object System.Drawing.Point(($wx + 300), ($wy + 280))
$mtn[3] = New-Object System.Drawing.Point(($wx + 450), ($wy + 170))
$mtn[4] = New-Object System.Drawing.Point(($wx + $ww), ($wy + 300))
$path = New-Object System.Drawing.Drawing2D.GraphicsPath
$path.AddLines($mtn); $path.AddLine(($wx + $ww), ($wy + $wh), $wx, ($wy + $wh)); $path.CloseFigure()
$b = New-Object System.Drawing.SolidBrush((C 255 224 230 238)); $g.FillPath($b, $path); $b.Dispose(); $path.Dispose()
for ($i = 0; $i -lt 12; $i++) {
  $px5 = $wx + 20 + $i * 46 + $rng.Next(-8, 9); $py5 = $wy + $wh - 60 - $rng.Next(0, 40)
  $tri = New-Object 'System.Drawing.Point[]' 3
  $tri[0] = New-Object System.Drawing.Point($px5, ($py5 - 46))
  $tri[1] = New-Object System.Drawing.Point(($px5 + 18), ($py5 + 10))
  $tri[2] = New-Object System.Drawing.Point(($px5 - 18), ($py5 + 10))
  $b = New-Object System.Drawing.SolidBrush((C 255 30 48 42)); $g.FillPolygon($b, $tri); $b.Dispose()
}
# falling snow inside panes
for ($i = 0; $i -lt 160; $i++) {
  $b = New-Object System.Drawing.SolidBrush((C $rng.Next(90, 200) 240 244 250))
  $g.FillEllipse($b, $rng.Next($wx, $wx + $ww), $rng.Next($wy, $wy + $wh), 3, 3); $b.Dispose()
}
# window cross bars + frost
$b = New-Object System.Drawing.SolidBrush((C 255 52 38 26))
$g.FillRectangle($b, ($wx + [int]($ww / 2) - 9), $wy, 18, $wh)
$g.FillRectangle($b, $wx, ($wy + [int]($wh / 2) - 9), $ww, 18); $b.Dispose()
$pen = New-Object System.Drawing.Pen((C 255 58 42 28), 14); $g.DrawRectangle($pen, $wx, $wy, $ww, $wh); $pen.Dispose()
foreach ($corner in @(@($wx, $wy), @(($wx + $ww), $wy), @($wx, ($wy + $wh)), @(($wx + $ww), ($wy + $wh)))) {
  Glow $g $corner[0] $corner[1] 70 (C 60 240 246 252)
}
# fireplace glow + embers, bottom left
Glow $g 300 1030 480 (C 90 255 140 40)
Glow $g 300 1050 260 (C 120 255 180 60)
for ($i = 0; $i -lt 40; $i++) {
  $b = New-Object System.Drawing.SolidBrush((C $rng.Next(60, 200) 255 (120 + $rng.Next(0, 80)) 30))
  $sz = $rng.Next(2, 5)
  $g.FillEllipse($b, (140 + $rng.Next(0, 340)), (760 + $rng.Next(0, 300)), $sz, $sz); $b.Dispose()
}
# string lights across the top: catenary with glowing bulbs
$pen = New-Object System.Drawing.Pen((C 150 16 10 6), 2)
$path = New-Object System.Drawing.Drawing2D.GraphicsPath
$path.AddBezier(60, 90, 500, 190, 1300, 60, 1860, 150)
$g.DrawPath($pen, $path); $pen.Dispose(); $path.Dispose()
$bulbColors = @(@(255, 120, 90), @(255, 200, 90), @(140, 220, 140), @(140, 180, 255))
for ($t = 0.04; $t -lt 1; $t += 0.075) {
  $u = 1 - $t
  $bxp = [int]($u * $u * $u * 60 + 3 * $u * $u * $t * 500 + 3 * $u * $t * $t * 1300 + $t * $t * $t * 1860)
  $byp = [int]($u * $u * $u * 90 + 3 * $u * $u * $t * 190 + 3 * $u * $t * $t * 60 + $t * $t * $t * 150) + 10
  $cc = $bulbColors[$rng.Next(0, 4)]
  Glow $g $bxp $byp 22 (C 110 $cc[0] $cc[1] $cc[2])
  $b = New-Object System.Drawing.SolidBrush((C 235 $cc[0] $cc[1] $cc[2])); $g.FillEllipse($b, ($bxp - 5), ($byp - 5), 10, 12); $b.Dispose()
}
# skis leaning left of the window
foreach ($ski in @(@(980, 300, 930, 1000), @(1030, 290, 1000, 1000))) {
  $pen = New-Object System.Drawing.Pen((C 235 140 40 40), 14)
  $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
  $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
  $g.DrawLine($pen, $ski[0], $ski[1], $ski[2], $ski[3]); $pen.Dispose()
  $pen = New-Object System.Drawing.Pen((C 200 220 210 190), 4)
  $g.DrawLine($pen, ($ski[0] - 2), ($ski[1] + 30), ($ski[2] - 2), ($ski[3] - 40)); $pen.Dispose()
}
EdgeFade $g "top" 120 110; EdgeFade $g "bottom" 130 120; EdgeFade $g "left" 140 100; EdgeFade $g "right" 120 90
Save $bmp $g "skicabin.png"

# ── Rave: laser fans, strobe horizon, speaker stack, haze ──
$rng = New-Object System.Random(303)
Get-Random -SetSeed 303 | Out-Null
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 8 3 12) (C 255 3 1 6)
# smoke haze
Glow $g 500 700 500 (C 26 255 61 232)
Glow $g 1400 640 560 (C 24 62 232 232)
Glow $g 960 400 700 (C 16 182 255 46)
# laser fans from both top corners
$laserCols = @(@(255, 61, 232), @(62, 232, 232), @(182, 255, 46))
foreach ($srcCorner in @(@(-40, 60, 1), @(1960, 40, -1))) {
  for ($i = 0; $i -lt 9; $i++) {
    $cc = $laserCols[($i + $(if ($srcCorner[2] -eq 1) { 0 } else { 1 })) % 3]
    $endX = $srcCorner[0] + $srcCorner[2] * (300 + $i * 210)
    $endY = 1160 - $i * 40
    foreach ($pass in @(@(26, 9), @(90, 3), @(210, 1))) {
      $pen = New-Object System.Drawing.Pen((C $pass[0] $cc[0] $cc[1] $cc[2]), $pass[1])
      $g.DrawLine($pen, $srcCorner[0], $srcCorner[1], $endX, $endY); $pen.Dispose()
    }
  }
  Glow $g $srcCorner[0] $srcCorner[1] 120 (C 130 255 255 255)
}
# strobe horizon bar
Glow $g 960 820 340 (C 60 240 240 255)
$b = New-Object System.Drawing.SolidBrush((C 200 235 235 255)); $g.FillRectangle($b, 240, 816, 1440, 5); $b.Dispose()
# dust particles
for ($i = 0; $i -lt 700; $i++) {
  $cc = $laserCols[$rng.Next(0, 3)]
  $b = New-Object System.Drawing.SolidBrush((C $rng.Next(20, 110) $cc[0] $cc[1] $cc[2]))
  $g.FillRectangle($b, $rng.Next(0, $W), $rng.Next(0, $H), 2, 2); $b.Dispose()
}
# speaker stack silhouette bottom right, cones ringed by faint glow
foreach ($box in @(@(1520, 690, 330, 190), @(1560, 880, 260, 170))) {
  $b = New-Object System.Drawing.SolidBrush((C 250 10 6 14)); $g.FillRectangle($b, $box[0], $box[1], $box[2], $box[3]); $b.Dispose()
  $pen = New-Object System.Drawing.Pen((C 130 90 60 110), 2); $g.DrawRectangle($pen, $box[0], $box[1], $box[2], $box[3]); $pen.Dispose()
  $ccx = $box[0] + [int]($box[2] / 2); $ccy = $box[1] + [int]($box[3] / 2)
  foreach ($rr in @(52, 34, 12)) {
    $pen = New-Object System.Drawing.Pen((C 110 140 100 160), 2)
    $g.DrawEllipse($pen, ($ccx - $rr), ($ccy - $rr), (2 * $rr), (2 * $rr)); $pen.Dispose()
  }
  Glow $g $ccx $ccy 60 (C 40 255 61 232)
}
EdgeFade $g "top" 100 110; EdgeFade $g "bottom" 120 130; EdgeFade $g "left" 120 100; EdgeFade $g "right" 110 100
Save $bmp $g "rave.png"

# ── Datacenter: rack aisle in perspective, LED constellations ──
$rng = New-Object System.Random(42)
Get-Random -SetSeed 42 | Out-Null
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 8 12 17) (C 255 4 6 9)
# ceiling light strip down the aisle + far doorway glow
Glow $g 960 120 420 (C 60 190 220 255)
$b = New-Object System.Drawing.SolidBrush((C 220 210 230 250)); $g.FillRectangle($b, 700, 96, 520, 10); $b.Dispose()
Glow $g 960 540 200 (C 46 150 200 255)
$b = New-Object System.Drawing.SolidBrush((C 90 170 210 250)); $g.FillRectangle($b, 900, 440, 120, 210); $b.Dispose()
# rack walls: stepped panels toward the vanishing point, both sides
$ledCols = @(@(79, 224, 138), @(79, 224, 138), @(79, 224, 138), @(255, 190, 80), @(120, 190, 255), @(255, 90, 90))
foreach ($side in @(1, -1)) {
  $racks = @(@(70, 330, 150, 980), @(430, 300, 350, 900), @(700, 380, 260, 840), @(870, 420, 130, 760))
  foreach ($rk in $racks) {
    $rx = if ($side -eq 1) { $rk[0] } else { $W - $rk[0] - $rk[2] }
    $ry = $rk[1]; $rw2 = $rk[2]; $rb = $rk[3]
    $b = New-Object System.Drawing.SolidBrush((C 255 11 17 23)); $g.FillRectangle($b, $rx, $ry, $rw2, ($rb - $ry)); $b.Dispose()
    $pen = New-Object System.Drawing.Pen((C 90 70 110 140), 2); $g.DrawRectangle($pen, $rx, $ry, $rw2, ($rb - $ry)); $pen.Dispose()
    # unit shelves
    $uy = $ry + 14
    while ($uy -lt $rb - 10) {
      $pen = New-Object System.Drawing.Pen((C 40 70 110 140), 1); $g.DrawLine($pen, $rx, $uy, ($rx + $rw2), $uy); $pen.Dispose()
      # LED dots on this unit
      $dotN = [int]($rw2 / 22)
      for ($d = 0; $d -lt $dotN; $d++) {
        if ($rng.NextDouble() -lt 0.55) {
          $cc = $ledCols[$rng.Next(0, $ledCols.Count)]
          $b = New-Object System.Drawing.SolidBrush((C $rng.Next(120, 240) $cc[0] $cc[1] $cc[2]))
          $g.FillRectangle($b, ($rx + 8 + $d * 22 + $rng.Next(0, 6)), ($uy + $rng.Next(3, 9)), 3, 3); $b.Dispose()
        }
      }
      $uy += [math]::Max(12, [int](($rb - $ry) / 34))
    }
  }
}
# floor: aisle lines + faint reflections
$pen = New-Object System.Drawing.Pen((C 60 100 140 170), 2)
$g.DrawLine($pen, 240, $H, 900, 660); $g.DrawLine($pen, 1680, $H, 1020, 660); $pen.Dispose()
foreach ($ref in @(@(430, 300), @(1140, 240), @(700, 160))) {
  $rect = New-Object System.Drawing.Rectangle($ref[0], 900, $ref[1], 180)
  $br = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, (C 26 120 200 200), (C 0 120 200 200), 90.0)
  $g.FillRectangle($br, $rect); $br.Dispose()
}
EdgeFade $g "top" 100 110; EdgeFade $g "bottom" 110 120; EdgeFade $g "left" 120 110; EdgeFade $g "right" 120 110
Save $bmp $g "datacenter.png"

# ── Sakura: blush sky, blossom branch, drifting petals ──
$rng = New-Object System.Random(325)
Get-Random -SetSeed 325 | Out-Null
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 248 233 238) (C 255 240 214 224)
Glow $g 420 260 420 (C 60 255 246 235)   # soft sun haze
# distant bokeh blobs
for ($i = 0; $i -lt 14; $i++) {
  Glow $g ($rng.Next(0, $W)) ($rng.Next(0, $H)) ($rng.Next(40, 110)) (C $rng.Next(14, 30) 232 150 178)
}
function Blossom {
  param($g, $bx, $by, $scale, $alpha)
  # five petal ellipses around a center dot
  for ($p = 0; $p -lt 5; $p++) {
    $ang = ($p * 72 - 90) * [math]::PI / 180
    $px6 = $bx + [int](7 * $scale * [math]::Cos($ang)); $py6 = $by + [int](7 * $scale * [math]::Sin($ang))
    $b = New-Object System.Drawing.SolidBrush((C $alpha 246 173 196))
    $g.FillEllipse($b, ($px6 - [int](5 * $scale)), ($py6 - [int](5 * $scale)), [int](10 * $scale), [int](10 * $scale)); $b.Dispose()
  }
  $b = New-Object System.Drawing.SolidBrush((C $alpha 214 96 138)); $g.FillEllipse($b, ($bx - [int](2.5 * $scale)), ($by - [int](2.5 * $scale)), [int](5 * $scale), [int](5 * $scale)); $b.Dispose()
}
# branch from the top-right corner: main limb + sub-branches
$branch = New-Object System.Drawing.Drawing2D.GraphicsPath
$branch.AddBezier(1960, 60, 1600, 130, 1380, 260, 1180, 300)
$pen = New-Object System.Drawing.Pen((C 235 88 58 56), 16)
$pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round; $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
$g.DrawPath($pen, $branch); $pen.Dispose(); $branch.Dispose()
foreach ($sub in @(@(1700, 110, 1560, 320, 1500, 420), @(1450, 230, 1330, 420, 1350, 520), @(1250, 290, 1120, 380, 1040, 380))) {
  $path = New-Object System.Drawing.Drawing2D.GraphicsPath
  $path.AddBezier($sub[0], $sub[1], ($sub[0] - 60), ($sub[1] + 90), $sub[2], ($sub[3] - 60), $sub[4], $sub[5])
  $pen = New-Object System.Drawing.Pen((C 225 88 58 56), 7)
  $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round; $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
  $g.DrawPath($pen, $path); $pen.Dispose(); $path.Dispose()
}
# blossom clusters along the limbs
foreach ($cl in @(@(1740, 120, 8), @(1600, 190, 10), @(1480, 260, 9), @(1360, 320, 8), @(1240, 310, 7), @(1520, 400, 7), @(1350, 500, 6), @(1090, 370, 6), @(1660, 300, 6))) {
  for ($i = 0; $i -lt $cl[2]; $i++) {
    Blossom $g ($cl[0] + $rng.Next(-46, 47)) ($cl[1] + $rng.Next(-38, 39)) ((0.8 + $rng.NextDouble() * 1.4)) $rng.Next(150, 240)
  }
}
# drifting petals across the whole sky
for ($i = 0; $i -lt 90; $i++) {
  $px6 = $rng.Next(0, $W); $py6 = $rng.Next(0, $H)
  $sz = $rng.Next(5, 12)
  $g.TranslateTransform($px6, $py6)
  $g.RotateTransform($rng.Next(0, 360))
  $b = New-Object System.Drawing.SolidBrush((C $rng.Next(90, 200) 246 173 196))
  $g.FillEllipse($b, 0, 0, $sz, [int]($sz * 0.55)); $b.Dispose()
  $g.ResetTransform()
}
EdgeFade $g "top" 80 16; EdgeFade $g "bottom" 100 26; EdgeFade $g "left" 100 16; EdgeFade $g "right" 90 14
Save $bmp $g "sakura.png"

# ── Pride: sweeping rainbow ribbon, confetti bokeh ──
$rng = New-Object System.Random(1978)
Get-Random -SetSeed 1978 | Out-Null
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 18 16 26) (C 255 9 8 14)
$stripes = @(@(228, 60, 60), @(245, 140, 40), @(250, 210, 60), @(70, 200, 90), @(70, 130, 240), @(150, 70, 210))
# ribbon: six parallel bezier bands sweeping across the lower half
for ($i = 0; $i -lt 6; $i++) {
  $cc = $stripes[$i]
  $off = $i * 40
  $path = New-Object System.Drawing.Drawing2D.GraphicsPath
  $path.AddBezier(-100, (620 + $off), 560, (420 + $off), 1240, (880 + $off), 2020, (560 + $off))
  foreach ($pass in @(@(30, 66), @(120, 42), @(220, 36))) {
    $pen = New-Object System.Drawing.Pen((C $pass[0] $cc[0] $cc[1] $cc[2]), $pass[1])
    $g.DrawPath($pen, $path); $pen.Dispose()
  }
  $path.Dispose()
}
# soft glows above the ribbon
Glow $g 1450 300 340 (C 26 150 70 210)
Glow $g 500 260 300 (C 22 245 140 40)
# confetti: small rotated rects in stripe colors
for ($i = 0; $i -lt 240; $i++) {
  $cc = $stripes[$rng.Next(0, 6)]
  $g.TranslateTransform($rng.Next(0, $W), $rng.Next(0, $H))
  $g.RotateTransform($rng.Next(0, 360))
  $b = New-Object System.Drawing.SolidBrush((C $rng.Next(50, 160) $cc[0] $cc[1] $cc[2]))
  $g.FillRectangle($b, 0, 0, $rng.Next(4, 9), $rng.Next(3, 6)); $b.Dispose()
  $g.ResetTransform()
}
EdgeFade $g "top" 110 110; EdgeFade $g "bottom" 120 120; EdgeFade $g "left" 120 100; EdgeFade $g "right" 120 100
Save $bmp $g "pride.png"

# ── Valorant-style: cream field, slate shards, signature red slashes ──
$rng = New-Object System.Random(2020)
Get-Random -SetSeed 2020 | Out-Null
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 236 232 225) (C 255 226 221 212)
# paper grain
for ($i = 0; $i -lt 1800; $i++) {
  $b = New-Object System.Drawing.SolidBrush((C $rng.Next(4, 10) 40 42 45))
  $g.FillRectangle($b, $rng.Next(0, $W), $rng.Next(0, $H), 1, 1); $b.Dispose()
}
$slate = C 250 31 35 38
# big angular shard cluster from the right edge
$shard1 = New-Object 'System.Drawing.Point[]' 5
$shard1[0] = New-Object System.Drawing.Point(1140, 1080)
$shard1[1] = New-Object System.Drawing.Point(1560, 260)
$shard1[2] = New-Object System.Drawing.Point(1920, 90)
$shard1[3] = New-Object System.Drawing.Point(1920, 1080)
$shard1[4] = New-Object System.Drawing.Point(1140, 1080)
$b = New-Object System.Drawing.SolidBrush($slate); $g.FillPolygon($b, $shard1); $b.Dispose()
$shard2 = New-Object 'System.Drawing.Point[]' 4
$shard2[0] = New-Object System.Drawing.Point(1300, 1080)
$shard2[1] = New-Object System.Drawing.Point(1690, 60)
$shard2[2] = New-Object System.Drawing.Point(1800, 20)
$shard2[3] = New-Object System.Drawing.Point(1480, 1080)
$b = New-Object System.Drawing.SolidBrush((C 255 24 27 30)); $g.FillPolygon($b, $shard2); $b.Dispose()
# red slashes cutting across the shards
foreach ($sl in @(@(1250, 760, 1920, 420, 22), @(1180, 950, 1920, 640, 10))) {
  $pen = New-Object System.Drawing.Pen((C 245 255 70 85), $sl[4])
  $g.DrawLine($pen, $sl[0], $sl[1], $sl[2], $sl[3]); $pen.Dispose()
}
# thin hatch patch on the cream side
$clip = New-Object System.Drawing.Rectangle(120, 780, 340, 200)
$g.SetClip($clip)
for ($x = 40; $x -lt 560; $x += 18) {
  $pen = New-Object System.Drawing.Pen((C 60 31 35 38), 2)
  $g.DrawLine($pen, $x, 1000, ($x + 200), 760); $pen.Dispose()
}
$g.ResetClip()
$pen = New-Object System.Drawing.Pen((C 160 31 35 38), 2); $g.DrawRectangle($pen, 120, 780, 340, 200); $pen.Dispose()
# crosshair on the slate: white plus with gap
$chx = 1620; $chy = 480
$b = New-Object System.Drawing.SolidBrush((C 240 246 244 240))
$g.FillRectangle($b, ($chx - 3), ($chy - 42), 6, 26); $g.FillRectangle($b, ($chx - 3), ($chy + 16), 6, 26)
$g.FillRectangle($b, ($chx - 42), ($chy - 3), 26, 6); $g.FillRectangle($b, ($chx + 16), ($chy - 3), 26, 6)
$b.Dispose()
# ability diamond row, bottom right on slate
foreach ($i in 0..3) {
  $dx = 1560 + $i * 80; $dy = 950
  $dia = New-Object 'System.Drawing.Point[]' 4
  $dia[0] = New-Object System.Drawing.Point($dx, ($dy - 24))
  $dia[1] = New-Object System.Drawing.Point(($dx + 24), $dy)
  $dia[2] = New-Object System.Drawing.Point($dx, ($dy + 24))
  $dia[3] = New-Object System.Drawing.Point(($dx - 24), $dy)
  if ($i -eq 2) {
    $b = New-Object System.Drawing.SolidBrush((C 245 255 70 85)); $g.FillPolygon($b, $dia); $b.Dispose()
  } else {
    $pen = New-Object System.Drawing.Pen((C 200 236 232 225), 3); $g.DrawPolygon($pen, $dia); $pen.Dispose()
  }
}
# corner brackets top-left
$pen = New-Object System.Drawing.Pen((C 200 31 35 38), 4)
$g.DrawLine($pen, 100, 100, 190, 100); $g.DrawLine($pen, 100, 100, 100, 190)
$g.DrawLine($pen, 100, 640, 100, 550); $g.DrawLine($pen, 100, 640, 190, 640)
$pen.Dispose()
DashRow $g 130 140 300 (C 200 31 35 38) 14
DashRow $g 130 190 220 (C 120 31 35 38) 9
Save $bmp $g "valorant.png"

# ── CS-style: radar, killfeed, crosshair, HUD bars ──
$rng = New-Object System.Random(2012)
Get-Random -SetSeed 2012 | Out-Null
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 16 20 27) (C 255 8 10 15)
Glow $g 960 540 800 (C 14 222 155 53)
$orange = C 220 222 155 53
$blue = C 210 120 170 240
$pale = C 170 200 210 225
# radar, top-left: rounded square, rings, sweep wedge, dots
$rx = 150; $ry = 120; $rs = 330
$b = New-Object System.Drawing.SolidBrush((C 140 10 14 20)); $g.FillRectangle($b, $rx, $ry, $rs, $rs); $b.Dispose()
$pen = New-Object System.Drawing.Pen($pale, 2); $g.DrawRectangle($pen, $rx, $ry, $rs, $rs); $pen.Dispose()
$rcx = $rx + [int]($rs / 2); $rcy = $ry + [int]($rs / 2)
foreach ($rr in @(140, 95, 50)) {
  $pen = New-Object System.Drawing.Pen((C 70 200 210 225), 1)
  $g.DrawEllipse($pen, ($rcx - $rr), ($rcy - $rr), (2 * $rr), (2 * $rr)); $pen.Dispose()
}
$pen = New-Object System.Drawing.Pen((C 70 200 210 225), 1)
$g.DrawLine($pen, $rcx, $ry, $rcx, ($ry + $rs)); $g.DrawLine($pen, $rx, $rcy, ($rx + $rs), $rcy); $pen.Dispose()
$path = New-Object System.Drawing.Drawing2D.GraphicsPath
$path.AddPie(($rcx - 140), ($rcy - 140), 280, 280, -90, 40)
$br = New-Object System.Drawing.Drawing2D.PathGradientBrush($path)
$br.CenterColor = (C 60 200 210 225); $br.SurroundColors = @((C 0 200 210 225))
$g.FillPath($br, $path); $br.Dispose(); $path.Dispose()
foreach ($dot in @(@(-60, 30, $blue), @(20, -40, $blue), @(70, 80, $orange), @(-30, 100, $orange), @(90, -90, $orange))) {
  $cc = $dot[2]
  $b = New-Object System.Drawing.SolidBrush($cc); $g.FillEllipse($b, ($rcx + $dot[0] - 5), ($rcy + $dot[1] - 5), 10, 10); $b.Dispose()
}
# killfeed rows, top-right
for ($i = 0; $i -lt 3; $i++) {
  $ky = 130 + $i * 52
  $kw = 420 - $i * 30
  $b = New-Object System.Drawing.SolidBrush((C 110 10 14 20)); $g.FillRectangle($b, (1820 - $kw), $ky, $kw, 38); $b.Dispose()
  $b = New-Object System.Drawing.SolidBrush($(if ($i -eq 1) { $orange } else { $blue }))
  $g.FillRectangle($b, (1836 - $kw), ($ky + 14), 90, 10); $b.Dispose()
  $b = New-Object System.Drawing.SolidBrush($pale); $g.FillRectangle($b, (1836 - $kw + 110), ($ky + 12), 52, 14); $b.Dispose()
  $b = New-Object System.Drawing.SolidBrush($(if ($i -eq 1) { $blue } else { $orange }))
  $g.FillRectangle($b, (1836 - $kw + 180), ($ky + 14), 110, 10); $b.Dispose()
}
# crosshair, center-right: classic green cross with gap + dot
$chx = 1240; $chy = 620
$b = New-Object System.Drawing.SolidBrush((C 235 90 240 90))
$g.FillRectangle($b, ($chx - 2), ($chy - 34), 5, 20); $g.FillRectangle($b, ($chx - 2), ($chy + 14), 5, 20)
$g.FillRectangle($b, ($chx - 34), ($chy - 2), 20, 5); $g.FillRectangle($b, ($chx + 14), ($chy - 2), 20, 5)
$b.Dispose()
Glow $g $chx $chy 60 (C 40 90 240 90)
# bottom HUD: health/armor left, ammo right
$b = New-Object System.Drawing.SolidBrush((C 130 10 14 20)); $g.FillRectangle($b, 140, 950, 480, 70); $g.FillRectangle($b, 1300, 950, 480, 70); $b.Dispose()
$b = New-Object System.Drawing.SolidBrush($pale)
$g.FillRectangle($b, 170, 972, 26, 26); $g.FillRectangle($b, 400, 972, 26, 26); $b.Dispose()
$b = New-Object System.Drawing.SolidBrush((C 220 240 245 250)); $g.FillRectangle($b, 214, 976, 120, 18); $g.FillRectangle($b, 444, 976, 120, 18); $b.Dispose()
$b = New-Object System.Drawing.SolidBrush((C 220 240 245 250)); $g.FillRectangle($b, 1560, 976, 90, 18); $b.Dispose()
$b = New-Object System.Drawing.SolidBrush((C 120 200 210 225)); $g.FillRectangle($b, 1660, 976, 60, 18); $b.Dispose()
# bomb code ticks
foreach ($i in 0..6) {
  $b = New-Object System.Drawing.SolidBrush((C $(if ($i -lt 5) { 200 } else { 60 }) 222 155 53))
  $g.FillRectangle($b, (860 + $i * 30), 980, 20, 10); $b.Dispose()
}
EdgeFade $g "top" 110 110; EdgeFade $g "bottom" 110 110; EdgeFade $g "left" 120 100; EdgeFade $g "right" 120 100
Save $bmp $g "csgo.png"

# ── Dead by Daylight-style: fog, bare trees, campfire, skill check ──
$rng = New-Object System.Random(2016)
Get-Random -SetSeed 20160 | Out-Null
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 12 10 14) (C 255 5 4 7)
# cold fog layers
Glow $g 500 800 600 (C 22 90 110 120)
Glow $g 1400 700 700 (C 18 80 95 110)
Glow $g 960 300 800 (C 12 70 80 100)
# bare tree silhouettes: recursive-ish branching strokes
function Branch {
  # NOTE: typed params are required - an untyped $ang binds a bare
  # negative literal as a switch and concatenates the recursive values.
  param($g, [int]$x, [int]$y, [double]$ang, [double]$len, [int]$depth)
  if ($depth -le 0 -or $len -lt 12) { return }
  $x2 = $x + [int]($len * [math]::Sin($ang))
  $y2 = $y - [int]($len * [math]::Cos($ang))
  $pen = New-Object System.Drawing.Pen((C 235 8 6 10), ([math]::Max(2, $depth * 2)))
  $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
  $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
  $g.DrawLine($pen, $x, $y, $x2, $y2); $pen.Dispose()
  $r2 = New-Object System.Random(([int]($x * 7 + $y * 13 + $depth)))
  Branch $g $x2 $y2 ($ang - 0.28 - $r2.NextDouble() * 0.3) ([int]($len * 0.72)) ($depth - 1)
  Branch $g $x2 $y2 ($ang + 0.24 + $r2.NextDouble() * 0.3) ([int]($len * 0.68)) ($depth - 1)
}
Branch $g 260 1080 (-0.1) 240 6
Branch $g 1700 1080 (0.12) 270 6
Branch $g 1080 1080 (0.05) 180 5
# campfire, bottom-left: logs, flame, embers, warm glow
Glow $g 420 950 320 (C 90 255 150 50)
Glow $g 420 960 160 (C 140 255 190 80)
foreach ($log in @(@(340, 990, 500, 1020), @(350, 1020, 490, 985))) {
  $pen = New-Object System.Drawing.Pen((C 245 30 20 14), 16)
  $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
  $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
  $g.DrawLine($pen, $log[0], $log[1], $log[2], $log[3]); $pen.Dispose()
}
$flame = New-Object 'System.Drawing.Point[]' 6
$flame[0] = New-Object System.Drawing.Point(390, 985)
$flame[1] = New-Object System.Drawing.Point(405, 905)
$flame[2] = New-Object System.Drawing.Point(420, 940)
$flame[3] = New-Object System.Drawing.Point(438, 880)
$flame[4] = New-Object System.Drawing.Point(455, 930)
$flame[5] = New-Object System.Drawing.Point(465, 985)
$b = New-Object System.Drawing.SolidBrush((C 220 255 170 60)); $g.FillPolygon($b, $flame); $b.Dispose()
$b = New-Object System.Drawing.SolidBrush((C 240 255 220 120)); $g.FillEllipse($b, 405, 935, 40, 48); $b.Dispose()
for ($i = 0; $i -lt 26; $i++) {
  $b = New-Object System.Drawing.SolidBrush((C $rng.Next(80, 220) 255 (150 + $rng.Next(0, 70)) 50))
  $g.FillEllipse($b, (360 + $rng.Next(0, 130)), (700 + $rng.Next(0, 240)), 3, 3); $b.Dispose()
}
# skill check, right-center: ring, success zone arc, needle
$scx = 1430; $scy = 470
Glow $g $scx $scy 150 (C 40 240 240 245)
$pen = New-Object System.Drawing.Pen((C 230 235 232 238), 5); $g.DrawEllipse($pen, ($scx - 110), ($scy - 110), 220, 220); $pen.Dispose()
$pen = New-Object System.Drawing.Pen((C 250 250 250 252), 9); $g.DrawArc($pen, ($scx - 110), ($scy - 110), 220, 220, -70, 42); $pen.Dispose()
$nAng = -20 * [math]::PI / 180
$pen = New-Object System.Drawing.Pen((C 245 226 60 68), 5)
$g.DrawLine($pen, $scx, $scy, ($scx + [int](118 * [math]::Cos($nAng))), ($scy + [int](118 * [math]::Sin($nAng)))); $pen.Dispose()
$b = New-Object System.Drawing.SolidBrush((C 245 226 60 68)); $g.FillEllipse($b, ($scx - 7), ($scy - 7), 14, 14); $b.Dispose()
# claw scratch marks, upper right: three jagged red slashes
foreach ($off in @(0, 44, 88)) {
  $path = New-Object System.Drawing.Drawing2D.GraphicsPath
  $path.AddLine((1610 + $off), 120, (1660 + $off), 240)
  $path.AddLine((1660 + $off), 240, (1645 + $off), 250)
  $path.AddLine((1645 + $off), 250, (1690 + $off), 380)
  $pen = New-Object System.Drawing.Pen((C 200 190 40 48), 9)
  $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
  $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
  $g.DrawPath($pen, $path); $pen.Dispose(); $path.Dispose()
  Glow $g (1650 + $off) 250 60 (C 40 190 40 48)
}
EdgeFade $g "top" 140 150; EdgeFade $g "bottom" 130 140; EdgeFade $g "left" 150 130; EdgeFade $g "right" 130 120
Save $bmp $g "dbd.png"

# ── Library: game-library shelf UI, slate blue, capsule cards ──
$rng = New-Object System.Random(2003)
Get-Random -SetSeed 2003 | Out-Null
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 27 40 56) (C 255 16 23 33)
Glow $g 1300 300 620 (C 26 102 192 244)
$sky = C 220 102 192 244
$skyDim = C 110 80 150 190
$panel = C 255 42 71 94
# left nav column with a selected row
$b = New-Object System.Drawing.SolidBrush((C 200 23 34 47)); $g.FillRectangle($b, 90, 120, 300, 840); $b.Dispose()
for ($i = 0; $i -lt 9; $i++) {
  $ny = 160 + $i * 88
  if ($i -eq 2) {
    $b = New-Object System.Drawing.SolidBrush($panel); $g.FillRectangle($b, 90, ($ny - 14), 300, 60); $b.Dispose()
    $b = New-Object System.Drawing.SolidBrush($sky); $g.FillRectangle($b, 90, ($ny - 14), 5, 60); $b.Dispose()
  }
  $b = New-Object System.Drawing.SolidBrush((C 90 200 220 235)); $g.FillEllipse($b, 122, ($ny + 2), 24, 24); $b.Dispose()
  $b = New-Object System.Drawing.SolidBrush($(if ($i -eq 2) { $sky } else { $skyDim }))
  $g.FillRectangle($b, 162, ($ny + 8), $rng.Next(110, 190), 11); $b.Dispose()
}
# capsule card grid
for ($row = 0; $row -lt 3; $row++) {
  for ($col = 0; $col -lt 4; $col++) {
    $cx3 = 470 + $col * 350; $cy3 = 180 + $row * 280
    $rect = New-Object System.Drawing.Rectangle($cx3, $cy3, 310, 220)
    $tint = @(@(64, 96, 140), @(96, 72, 128), @(56, 108, 108), @(120, 84, 72))[($row + $col) % 4]
    $br = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, (C 235 $tint[0] $tint[1] $tint[2]), (C 235 ([int]($tint[0] * 0.45)) ([int]($tint[1] * 0.45)) ([int]($tint[2] * 0.5))), 90.0)
    $g.FillRectangle($br, $rect); $br.Dispose()
    $pen = New-Object System.Drawing.Pen((C 60 140 180 220), 2); $g.DrawRectangle($pen, $cx3, $cy3, 310, 220); $pen.Dispose()
    # title plate at the card foot
    $b = New-Object System.Drawing.SolidBrush((C 190 12 18 26)); $g.FillRectangle($b, $cx3, ($cy3 + 168), 310, 52); $b.Dispose()
    $b = New-Object System.Drawing.SolidBrush((C 200 200 220 235)); $g.FillRectangle($b, ($cx3 + 20), ($cy3 + 188), $rng.Next(120, 220), 12); $b.Dispose()
    # a couple of cards show a play arrow
    if (($row + $col) % 5 -eq 0) {
      $tri = New-Object 'System.Drawing.Point[]' 3
      $tri[0] = New-Object System.Drawing.Point(($cx3 + 138), ($cy3 + 62))
      $tri[1] = New-Object System.Drawing.Point(($cx3 + 138), ($cy3 + 118))
      $tri[2] = New-Object System.Drawing.Point(($cx3 + 186), ($cy3 + 90))
      $b = New-Object System.Drawing.SolidBrush((C 200 210 235 250)); $g.FillPolygon($b, $tri); $b.Dispose()
    }
  }
}
# download progress bar along the bottom
$b = New-Object System.Drawing.SolidBrush((C 200 23 34 47)); $g.FillRectangle($b, 470, 980, 1360, 56); $b.Dispose()
$b = New-Object System.Drawing.SolidBrush((C 90 60 110 150)); $g.FillRectangle($b, 500, 1000, 1180, 16); $b.Dispose()
$rect = New-Object System.Drawing.Rectangle(500, 1000, 780, 16)
$br = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, (C 240 60 150 220), (C 240 120 210 250), 0.0)
$g.FillRectangle($br, $rect); $br.Dispose()
EdgeFade $g "top" 110 110; EdgeFade $g "bottom" 110 110; EdgeFade $g "left" 120 100; EdgeFade $g "right" 120 100
Save $bmp $g "library.png"

# ── Blade: energy-green dashboard, orb, angled blade panels ──
$rng = New-Object System.Random(2001)
Get-Random -SetSeed 20010 | Out-Null
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 8 16 10) (C 255 3 7 4)
$grn = C 225 118 224 60
$grnDim = C 100 80 170 50
# radial energy burst behind the orb
$ocx = 1350; $ocy = 560
Glow $g $ocx $ocy 520 (C 40 16 124 16)
for ($i = 0; $i -lt 48; $i++) {
  $ang = ($i / 48.0) * 2 * [math]::PI
  $r1 = 210 + $rng.Next(0, 40); $r2 = $r1 + $rng.Next(90, 260)
  $pen = New-Object System.Drawing.Pen((C $rng.Next(14, 46) 118 224 60), 2)
  $g.DrawLine($pen, ($ocx + [int]($r1 * [math]::Cos($ang))), ($ocy + [int]($r1 * [math]::Sin($ang))), ($ocx + [int]($r2 * [math]::Cos($ang))), ($ocy + [int]($r2 * [math]::Sin($ang)))); $pen.Dispose()
}
# the orb: filled ring with a bright inner arc
Glow $g $ocx $ocy 230 (C 70 118 224 60)
$pen = New-Object System.Drawing.Pen((C 245 150 240 90), 14); $g.DrawEllipse($pen, ($ocx - 180), ($ocy - 180), 360, 360); $pen.Dispose()
$pen = New-Object System.Drawing.Pen((C 200 16 124 16), 26); $g.DrawEllipse($pen, ($ocx - 150), ($ocy - 150), 300, 300); $pen.Dispose()
$pen = New-Object System.Drawing.Pen((C 255 220 255 200), 5); $g.DrawArc($pen, ($ocx - 180), ($ocy - 180), 360, 360, 200, 90); $pen.Dispose()
# blade panels: angled parallelogram tabs, left
foreach ($i in 0..3) {
  $by = 240 + $i * 150
  $pts = New-Object 'System.Drawing.Point[]' 4
  $pts[0] = New-Object System.Drawing.Point(120, $by)
  $pts[1] = New-Object System.Drawing.Point(640, ($by - 34))
  $pts[2] = New-Object System.Drawing.Point(640, ($by + 84))
  $pts[3] = New-Object System.Drawing.Point(120, ($by + 118))
  $b = New-Object System.Drawing.SolidBrush($(if ($i -eq 1) { C 210 22 68 26 } else { C 150 12 26 14 }))
  $g.FillPolygon($b, $pts); $b.Dispose()
  $pen = New-Object System.Drawing.Pen($(if ($i -eq 1) { $grn } else { $grnDim }), 2); $g.DrawPolygon($pen, $pts); $pen.Dispose()
  $b = New-Object System.Drawing.SolidBrush($(if ($i -eq 1) { $grn } else { $grnDim }))
  $g.FillRectangle($b, 170, ($by + 36), $rng.Next(180, 320), 12); $b.Dispose()
}
# achievement toast, top right
$b = New-Object System.Drawing.SolidBrush((C 220 10 22 12)); $g.FillRectangle($b, 1420, 110, 400, 96); $b.Dispose()
$pen = New-Object System.Drawing.Pen($grn, 3); $g.DrawRectangle($pen, 1420, 110, 400, 96); $pen.Dispose()
$b = New-Object System.Drawing.SolidBrush($grn); $g.FillEllipse($b, 1444, 134, 48, 48); $b.Dispose()
$b = New-Object System.Drawing.SolidBrush((C 200 210 245 190)); $g.FillRectangle($b, 1512, 140, 250, 12); $b.Dispose()
$b = New-Object System.Drawing.SolidBrush($grnDim); $g.FillRectangle($b, 1512, 166, 170, 10); $b.Dispose()
EdgeFade $g "top" 110 120; EdgeFade $g "bottom" 120 130; EdgeFade $g "left" 120 100; EdgeFade $g "right" 110 100
Save $bmp $g "blade.png"

# ── Cartridge: red/cream console-era light theme, cart + pixels ──
$rng = New-Object System.Random(1985)
Get-Random -SetSeed 1985 | Out-Null
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 246 240 232) (C 255 236 228 218)
$red = C 255 214 30 42
$ink = C 255 44 40 44
# soft red band across the top
$b = New-Object System.Drawing.SolidBrush((C 255 214 30 42)); $g.FillRectangle($b, 0, 0, $W, 96); $b.Dispose()
$b = New-Object System.Drawing.SolidBrush((C 60 255 255 255)); $g.FillRectangle($b, 0, 96, $W, 10); $b.Dispose()
# the cartridge: body, label, ridged top, contact fingers
$cx4 = 1180; $cy4 = 300; $cw = 520; $ch2 = 480
$b = New-Object System.Drawing.SolidBrush((C 40 44 40 44)); $g.FillRectangle($b, ($cx4 + 12), ($cy4 + 14), $cw, $ch2); $b.Dispose()
$b = New-Object System.Drawing.SolidBrush((C 255 218 210 200)); $g.FillRectangle($b, $cx4, $cy4, $cw, $ch2); $b.Dispose()
$pen = New-Object System.Drawing.Pen($ink, 4); $g.DrawRectangle($pen, $cx4, $cy4, $cw, $ch2); $pen.Dispose()
# ridges along the top of the shell
for ($i = 0; $i -lt 7; $i++) {
  $b = New-Object System.Drawing.SolidBrush((C 120 44 40 44))
  $g.FillRectangle($b, ($cx4 + 30 + $i * 70), ($cy4 + 18), 40, 14); $b.Dispose()
}
# label
$b = New-Object System.Drawing.SolidBrush((C 255 250 246 238)); $g.FillRectangle($b, ($cx4 + 42), ($cy4 + 62), ($cw - 84), 250); $b.Dispose()
$pen = New-Object System.Drawing.Pen($ink, 3); $g.DrawRectangle($pen, ($cx4 + 42), ($cy4 + 62), ($cw - 84), 250); $pen.Dispose()
$b = New-Object System.Drawing.SolidBrush($red); $g.FillRectangle($b, ($cx4 + 42), ($cy4 + 62), ($cw - 84), 46); $b.Dispose()
$b = New-Object System.Drawing.SolidBrush((C 255 250 246 238)); $g.FillRectangle($b, ($cx4 + 70), ($cy4 + 78), 200, 14); $b.Dispose()
# pixel sprite on the label
$sprite = @(
  "..XX..",
  ".XXXX.",
  "XX..XX",
  "XXXXXX",
  ".X..X.",
  "X.XX.X"
)
for ($r = 0; $r -lt $sprite.Count; $r++) {
  for ($c2 = 0; $c2 -lt $sprite[$r].Length; $c2++) {
    if ($sprite[$r][$c2] -eq 'X') {
      $b = New-Object System.Drawing.SolidBrush($(if ($r -lt 3) { $red } else { $ink }))
      $g.FillRectangle($b, ($cx4 + 96 + $c2 * 26), ($cy4 + 140 + $r * 26), 24, 24); $b.Dispose()
    }
  }
}
DashRow $g ($cx4 + 300) ($cy4 + 160) 150 (C 170 44 40 44) 11
DashRow $g ($cx4 + 300) ($cy4 + 196) 130 (C 120 44 40 44) 9
# contact fingers at the cart foot
for ($i = 0; $i -lt 14; $i++) {
  $b = New-Object System.Drawing.SolidBrush((C 200 196 160 60))
  $g.FillRectangle($b, ($cx4 + 40 + $i * 32), ($cy4 + $ch2 - 92), 22, 74); $b.Dispose()
}
# floating pixel blocks on the cream field
foreach ($blk in @(@(220, 620, 5), @(420, 760, 4), @(300, 880, 6), @(620, 640, 4), @(760, 860, 5))) {
  for ($i = 0; $i -lt $blk[2]; $i++) {
    $cc = @($red, (C 255 60 140 220), (C 255 250 190 40), (C 255 60 170 90))[$rng.Next(0, 4)]
    $b = New-Object System.Drawing.SolidBrush((C 200 $cc.R $cc.G $cc.B))
    $g.FillRectangle($b, ($blk[0] + $rng.Next(0, 140)), ($blk[1] + $rng.Next(0, 120)), 26, 26); $b.Dispose()
  }
}
# d-pad + two buttons, lower left
$b = New-Object System.Drawing.SolidBrush($ink)
$g.FillRectangle($b, 250, 330, 44, 132); $g.FillRectangle($b, 206, 374, 132, 44); $b.Dispose()
foreach ($btn in @(@(470, 400), @(560, 370))) {
  $b = New-Object System.Drawing.SolidBrush($red); $g.FillEllipse($b, $btn[0], $btn[1], 62, 62); $b.Dispose()
  $pen = New-Object System.Drawing.Pen($ink, 3); $g.DrawEllipse($pen, $btn[0], $btn[1], 62, 62); $pen.Dispose()
}
Save $bmp $g "cartridge.png"

# ── Polygon: deep blue low-poly field with geometric glyphs ──
$rng = New-Object System.Random(1994)
Get-Random -SetSeed 1994 | Out-Null
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 6 18 54) (C 255 2 7 24)
Glow $g 1300 520 660 (C 34 0 112 209)
# low-poly wireframe terrain across the lower half
$cols = 14; $rows = 7
$pts = New-Object 'object[,]' ($rows + 1), ($cols + 1)
for ($r = 0; $r -le $rows; $r++) {
  for ($c2 = 0; $c2 -le $cols; $c2++) {
    $px = [int](-100 + $c2 * (2120 / $cols))
    $py = [int](620 + $r * 70 + $rng.Next(-26, 27) - $r * 4)
    $pts[$r, $c2] = @($px, $py)
  }
}
for ($r = 0; $r -lt $rows; $r++) {
  for ($c2 = 0; $c2 -lt $cols; $c2++) {
    $a = $pts[$r, $c2]; $b2 = $pts[$r, ($c2 + 1)]; $d = $pts[($r + 1), $c2]
    $alpha = [int](30 + 90 * ($r / [double]$rows))
    $pen = New-Object System.Drawing.Pen((C $alpha 90 170 255), 1)
    $g.DrawLine($pen, $a[0], $a[1], $b2[0], $b2[1])
    $g.DrawLine($pen, $a[0], $a[1], $d[0], $d[1])
    $g.DrawLine($pen, $b2[0], $b2[1], $d[0], $d[1]); $pen.Dispose()
    if ($rng.NextDouble() -lt 0.06) {
      $tri = New-Object 'System.Drawing.Point[]' 3
      $tri[0] = New-Object System.Drawing.Point($a[0], $a[1])
      $tri[1] = New-Object System.Drawing.Point($b2[0], $b2[1])
      $tri[2] = New-Object System.Drawing.Point($d[0], $d[1])
      $br2 = New-Object System.Drawing.SolidBrush((C 40 80 170 255)); $g.FillPolygon($br2, $tri); $br2.Dispose()
    }
  }
}
# four geometric glyphs in a row (basic shapes, no brand arrangement)
$gy2 = 300
$pen = New-Object System.Drawing.Pen((C 235 150 200 255), 7)
$tri = New-Object 'System.Drawing.Point[]' 3
$tri[0] = New-Object System.Drawing.Point(1160, ($gy2 - 40)); $tri[1] = New-Object System.Drawing.Point(1200, ($gy2 + 34)); $tri[2] = New-Object System.Drawing.Point(1120, ($gy2 + 34))
$g.DrawPolygon($pen, $tri)
$g.DrawEllipse($pen, 1280, ($gy2 - 38), 76, 76)
$g.DrawLine($pen, 1450, ($gy2 - 34), 1520, ($gy2 + 36)); $g.DrawLine($pen, 1520, ($gy2 - 34), 1450, ($gy2 + 36))
$g.DrawRectangle($pen, 1620, ($gy2 - 36), 74, 74)
$pen.Dispose()
foreach ($glyph in @(@(1160, $gy2), @(1318, $gy2), @(1485, $gy2), @(1657, $gy2))) {
  Glow $g $glyph[0] $glyph[1] 90 (C 40 150 200 255)
}
# starfield above the terrain
for ($i = 0; $i -lt 320; $i++) {
  $b = New-Object System.Drawing.SolidBrush((C $rng.Next(30, 130) 200 220 255))
  $g.FillRectangle($b, $rng.Next(0, $W), $rng.Next(0, 600), 2, 2); $b.Dispose()
}
EdgeFade $g "top" 110 120; EdgeFade $g "bottom" 110 120; EdgeFade $g "left" 120 100; EdgeFade $g "right" 110 100
Save $bmp $g "polygon.png"

# ── Nightclub: disco ball, light cones, dance floor, bottle shelf ──
$rng = New-Object System.Random(1977)
Get-Random -SetSeed 1977 | Out-Null
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 16 6 24) (C 255 6 2 10)
$clubCols = @(@(255, 70, 180), @(120, 90, 255), @(60, 220, 220), @(255, 170, 60))
# light cones from the ceiling
foreach ($cone in @(@(560, 0, 300, 760), @(1180, 0, 260, 820), @(1620, 0, 240, 700))) {
  $cc = $clubCols[$rng.Next(0, 4)]
  $pts = New-Object 'System.Drawing.Point[]' 3
  $pts[0] = New-Object System.Drawing.Point($cone[0], $cone[1])
  $pts[1] = New-Object System.Drawing.Point(($cone[0] - $cone[2]), $cone[3])
  $pts[2] = New-Object System.Drawing.Point(($cone[0] + $cone[2]), $cone[3])
  $b = New-Object System.Drawing.SolidBrush((C 26 $cc[0] $cc[1] $cc[2])); $g.FillPolygon($b, $pts); $b.Dispose()
  Glow $g $cone[0] ($cone[1] + 40) 130 (C 70 $cc[0] $cc[1] $cc[2])
}
# dance floor: perspective tile grid with lit squares
$fy = 720
for ($r = 0; $r -lt 7; $r++) {
  $ty = $fy + [int]([math]::Pow($r, 1.7) * 12)
  $th = [int](14 + [math]::Pow($r, 1.6) * 5)
  $shrink = 1 - 0.1 * (6 - $r)
  for ($c2 = 0; $c2 -lt 12; $c2++) {
    $spread = 200 + $r * 150
    $tx = 960 - $spread + [int]($c2 * ($spread * 2 / 12))
    $tw = [int](($spread * 2 / 12) - 6)
    $cc = $clubCols[($r + $c2) % 4]
    $alpha = if (($r + $c2) % 3 -eq 0) { $rng.Next(90, 190) } else { $rng.Next(18, 50) }
    $b = New-Object System.Drawing.SolidBrush((C $alpha $cc[0] $cc[1] $cc[2]))
    $g.FillRectangle($b, $tx, $ty, $tw, $th); $b.Dispose()
  }
}
# disco ball: facet grid on a sphere + scattered light dots
$dcx = 960; $dcy = 220; $dr = 110
Glow $g $dcx $dcy 260 (C 60 220 220 255)
$b = New-Object System.Drawing.SolidBrush((C 255 40 44 60)); $g.FillEllipse($b, ($dcx - $dr), ($dcy - $dr), (2 * $dr), (2 * $dr)); $b.Dispose()
for ($fy2 = -$dr; $fy2 -lt $dr; $fy2 += 18) {
  $halfW = [int]([math]::Sqrt([math]::Max(0, $dr * $dr - $fy2 * $fy2)))
  for ($fx2 = -$halfW; $fx2 -lt $halfW; $fx2 += 18) {
    $cc = if ($rng.NextDouble() -lt 0.24) { $clubCols[$rng.Next(0, 4)] } else { @(210, 220, 240) }
    $b = New-Object System.Drawing.SolidBrush((C $rng.Next(70, 230) $cc[0] $cc[1] $cc[2]))
    $g.FillRectangle($b, ($dcx + $fx2 + 2), ($dcy + $fy2 + 2), 15, 15); $b.Dispose()
  }
}
$pen = New-Object System.Drawing.Pen((C 120 12 6 18), 3); $g.DrawLine($pen, $dcx, 0, $dcx, ($dcy - $dr)); $pen.Dispose()
# speckles thrown by the ball
for ($i = 0; $i -lt 320; $i++) {
  $cc = if ($rng.NextDouble() -lt 0.3) { $clubCols[$rng.Next(0, 4)] } else { @(220, 226, 245) }
  $b = New-Object System.Drawing.SolidBrush((C $rng.Next(30, 150) $cc[0] $cc[1] $cc[2]))
  $sz = $rng.Next(3, 8)
  $g.FillEllipse($b, $rng.Next(0, $W), $rng.Next(0, 760), $sz, $sz); $b.Dispose()
}
# backlit bottle shelf, left wall
$b = New-Object System.Drawing.SolidBrush((C 220 10 4 16)); $g.FillRectangle($b, 60, 430, 330, 300); $b.Dispose()
foreach ($shelfY in @(500, 620)) {
  Glow $g 220 ($shelfY + 10) 190 (C 46 120 90 255)
  for ($i = 0; $i -lt 9; $i++) {
    $cc = $clubCols[$rng.Next(0, 4)]
    $bh = $rng.Next(50, 84)
    $b = New-Object System.Drawing.SolidBrush((C 200 $cc[0] $cc[1] $cc[2]))
    $g.FillRectangle($b, (86 + $i * 34), ($shelfY + 70 - $bh), 18, $bh); $b.Dispose()
    $b = New-Object System.Drawing.SolidBrush((C 220 $cc[0] $cc[1] $cc[2]))
    $g.FillRectangle($b, (92 + $i * 34), ($shelfY + 70 - $bh - 14), 6, 14); $b.Dispose()
  }
  $b = New-Object System.Drawing.SolidBrush((C 235 26 14 34)); $g.FillRectangle($b, 60, ($shelfY + 70), 330, 12); $b.Dispose()
}
EdgeFade $g "top" 100 110; EdgeFade $g "bottom" 120 130; EdgeFade $g "left" 110 90; EdgeFade $g "right" 120 110
Save $bmp $g "nightclub.png"

# ── Speakeasy: warm bar, backlit bottles, pendant lamps, glass ──
$rng = New-Object System.Random(1929)
Get-Random -SetSeed 1929 | Out-Null
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 34 22 15) (C 255 18 11 8)
# back wall panel + warm wash
Glow $g 1150 420 640 (C 60 255 170 70)
$b = New-Object System.Drawing.SolidBrush((C 90 60 34 20)); $g.FillRectangle($b, 0, 0, $W, 700); $b.Dispose()
# bottle shelves with backlight
foreach ($shelfY in @(250, 430)) {
  $rect = New-Object System.Drawing.Rectangle(760, ($shelfY - 30), 1060, 150)
  $br = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, (C 70 255 190 100), (C 10 255 150 60), 90.0)
  $g.FillRectangle($br, $rect); $br.Dispose()
  for ($i = 0; $i -lt 20; $i++) {
    $bx = 790 + $i * 52
    $bh = $rng.Next(70, 118)
    $tone = @(@(196, 128, 52), @(150, 96, 48), @(96, 74, 40), @(210, 170, 90), @(120, 60, 44))[$rng.Next(0, 5)]
    $b = New-Object System.Drawing.SolidBrush((C 235 $tone[0] $tone[1] $tone[2]))
    $g.FillRectangle($b, $bx, ($shelfY + 100 - $bh), 30, $bh); $b.Dispose()
    $b = New-Object System.Drawing.SolidBrush((C 220 $tone[0] $tone[1] $tone[2]))
    $g.FillRectangle($b, ($bx + 10), ($shelfY + 100 - $bh - 24), 10, 24); $b.Dispose()
    # highlight down one edge of the glass
    $b = New-Object System.Drawing.SolidBrush((C 90 255 230 190))
    $g.FillRectangle($b, ($bx + 4), ($shelfY + 106 - $bh), 4, ($bh - 10)); $b.Dispose()
  }
  # shelf plank
  $b = New-Object System.Drawing.SolidBrush((C 255 52 32 20)); $g.FillRectangle($b, 760, ($shelfY + 100), 1060, 18); $b.Dispose()
  $b = New-Object System.Drawing.SolidBrush((C 70 120 80 50)); $g.FillRectangle($b, 760, ($shelfY + 100), 1060, 4); $b.Dispose()
}
# pendant lamps
foreach ($lamp in @(@(430, 210), @(760, 170), @(1180, 200))) {
  $pen = New-Object System.Drawing.Pen((C 200 24 14 10), 3); $g.DrawLine($pen, $lamp[0], 0, $lamp[0], $lamp[1]); $pen.Dispose()
  Glow $g $lamp[0] ($lamp[1] + 40) 210 (C 80 255 180 90)
  $shade = New-Object 'System.Drawing.Point[]' 4
  $shade[0] = New-Object System.Drawing.Point(($lamp[0] - 22), $lamp[1])
  $shade[1] = New-Object System.Drawing.Point(($lamp[0] + 22), $lamp[1])
  $shade[2] = New-Object System.Drawing.Point(($lamp[0] + 58), ($lamp[1] + 56))
  $shade[3] = New-Object System.Drawing.Point(($lamp[0] - 58), ($lamp[1] + 56))
  $b = New-Object System.Drawing.SolidBrush((C 255 46 28 18)); $g.FillPolygon($b, $shade); $b.Dispose()
  $b = New-Object System.Drawing.SolidBrush((C 245 255 214 140)); $g.FillEllipse($b, ($lamp[0] - 20), ($lamp[1] + 44), 40, 22); $b.Dispose()
}
# bar counter: wood top with grain and a warm reflection strip
$rect = New-Object System.Drawing.Rectangle(0, 720, $W, 360)
$br = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, (C 255 74 44 26), (C 255 40 24 15), 90.0)
$g.FillRectangle($br, $rect); $br.Dispose()
$b = New-Object System.Drawing.SolidBrush((C 120 190 130 70)); $g.FillRectangle($b, 0, 720, $W, 8); $b.Dispose()
for ($i = 0; $i -lt 90; $i++) {
  $gy3 = 740 + $rng.Next(0, 320)
  $pen = New-Object System.Drawing.Pen((C $rng.Next(10, 30) 20 10 6), 1)
  $g.DrawLine($pen, $rng.Next(0, $W - 400), $gy3, ($rng.Next(0, $W)), ($gy3 + $rng.Next(-3, 4))); $pen.Dispose()
}
# tumbler with ice + amber pour, on the counter
$gx3 = 420; $gy4 = 790
Glow $g ($gx3 + 55) ($gy4 + 90) 150 (C 70 255 170 70)
$b = New-Object System.Drawing.SolidBrush((C 120 236 210 180)); $g.FillRectangle($b, $gx3, $gy4, 110, 170); $b.Dispose()
$b = New-Object System.Drawing.SolidBrush((C 220 198 118 40)); $g.FillRectangle($b, $gx3, ($gy4 + 66), 110, 104); $b.Dispose()
foreach ($ice in @(@(14, 78), @(56, 96), @(30, 118))) {
  $b = New-Object System.Drawing.SolidBrush((C 140 246 232 210))
  $g.FillRectangle($b, ($gx3 + $ice[0]), ($gy4 + $ice[1]), 38, 34); $b.Dispose()
}
$pen = New-Object System.Drawing.Pen((C 200 246 226 200), 3); $g.DrawRectangle($pen, $gx3, $gy4, 110, 170); $pen.Dispose()
$b = New-Object System.Drawing.SolidBrush((C 90 255 240 220)); $g.FillRectangle($b, ($gx3 + 12), ($gy4 + 10), 8, 150); $b.Dispose()
EdgeFade $g "top" 120 120; EdgeFade $g "bottom" 120 120; EdgeFade $g "left" 130 110; EdgeFade $g "right" 120 100
Save $bmp $g "speakeasy.png"

function RoundRect {
  param($x, $y, $rw, $rh, $r)
  $path = New-Object System.Drawing.Drawing2D.GraphicsPath
  $path.AddArc($x, $y, (2 * $r), (2 * $r), 180, 90)
  $path.AddArc(($x + $rw - 2 * $r), $y, (2 * $r), (2 * $r), 270, 90)
  $path.AddArc(($x + $rw - 2 * $r), ($y + $rh - 2 * $r), (2 * $r), (2 * $r), 0, 90)
  $path.AddArc($x, ($y + $rh - 2 * $r), (2 * $r), (2 * $r), 90, 90)
  $path.CloseFigure()
  return $path
}
function Bevel {
  # Win9x 3D border: light top/left, dark bottom/right
  param($g, $x, $y, $rw, $rh, $light, $dark, $thick)
  for ($i = 0; $i -lt $thick; $i++) {
    $pen = New-Object System.Drawing.Pen($light, 1)
    $g.DrawLine($pen, ($x + $i), ($y + $i), ($x + $rw - $i), ($y + $i))
    $g.DrawLine($pen, ($x + $i), ($y + $i), ($x + $i), ($y + $rh - $i)); $pen.Dispose()
    $pen = New-Object System.Drawing.Pen($dark, 1)
    $g.DrawLine($pen, ($x + $rw - $i), ($y + $i), ($x + $rw - $i), ($y + $rh - $i))
    $g.DrawLine($pen, ($x + $i), ($y + $rh - $i), ($x + $rw - $i), ($y + $rh - $i)); $pen.Dispose()
  }
}

# ── Penguin: tiling WM layout, status bar, package output, mascot ──
$rng = New-Object System.Random(1991)
Get-Random -SetSeed 1991 | Out-Null
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 18 20 26) (C 255 10 11 15)
$amber = C 225 232 160 60
$amberDim = C 110 190 130 55
$paneBg = C 235 22 25 32
# status bar: workspace pills + right-side info
$b = New-Object System.Drawing.SolidBrush((C 255 26 29 37)); $g.FillRectangle($b, 60, 60, 1800, 48); $b.Dispose()
foreach ($i in 0..5) {
  $wx = 80 + $i * 54
  if ($i -eq 1) {
    $b = New-Object System.Drawing.SolidBrush($amber); $g.FillRectangle($b, $wx, 68, 42, 32); $b.Dispose()
    $b = New-Object System.Drawing.SolidBrush((C 255 20 22 28)); $g.FillRectangle($b, ($wx + 16), 80, 10, 10); $b.Dispose()
  } else {
    $pen = New-Object System.Drawing.Pen($amberDim, 2); $g.DrawRectangle($pen, $wx, 68, 42, 32); $pen.Dispose()
    $b = New-Object System.Drawing.SolidBrush($amberDim); $g.FillRectangle($b, ($wx + 16), 80, 10, 10); $b.Dispose()
  }
}
DashRow $g 1420 78 400 $amberDim 10
# tiling panes with gaps; one focused with an accent border
foreach ($pane in @(@(60, 140, 880, 520, $true), @(970, 140, 890, 250, $false), @(970, 420, 890, 240, $false), @(60, 690, 560, 330, $false), @(650, 690, 1210, 330, $false))) {
  $b = New-Object System.Drawing.SolidBrush($paneBg); $g.FillRectangle($b, $pane[0], $pane[1], $pane[2], $pane[3]); $b.Dispose()
  $pen = New-Object System.Drawing.Pen($(if ($pane[4]) { $amber } else { C 90 70 78 92 }), $(if ($pane[4]) { 3 } else { 2 }))
  $g.DrawRectangle($pen, $pane[0], $pane[1], $pane[2], $pane[3]); $pen.Dispose()
  # prompt-ish content rows
  $rowY = $pane[1] + 26
  while ($rowY -lt $pane[1] + $pane[3] - 22) {
    $b = New-Object System.Drawing.SolidBrush($(if ($rng.NextDouble() -lt 0.2) { $amber } else { C 70 150 165 190 }))
    $g.FillRectangle($b, ($pane[0] + 22), $rowY, 14, 9); $b.Dispose()
    DashRow $g ($pane[0] + 48) $rowY ($pane[2] - 110) (C $(if ($rng.NextDouble() -lt 0.15) { 150 } else { 60 }) 150 165 190) 9
    $rowY += 26
  }
}
# package-install progress bars in the focused pane
foreach ($i in 0..2) {
  $py = 560 + $i * 30
  $pen = New-Object System.Drawing.Pen($amberDim, 1); $g.DrawRectangle($pen, 100, $py, 500, 16); $pen.Dispose()
  $b = New-Object System.Drawing.SolidBrush($amber); $g.FillRectangle($b, 102, ($py + 2), ([int](496 * $rng.NextDouble())), 13); $b.Dispose()
}
# penguin mascot silhouette, bottom-right pane
$px = 1560; $py2 = 790
$b = New-Object System.Drawing.SolidBrush((C 250 16 17 22))
$g.FillEllipse($b, ($px - 90), ($py2 - 130), 180, 220)      # body
$g.FillEllipse($b, ($px - 62), ($py2 - 210), 124, 116)      # head
$b.Dispose()
$b = New-Object System.Drawing.SolidBrush((C 250 236 238 242))
$g.FillEllipse($b, ($px - 62), ($py2 - 100), 124, 172)      # belly
$g.FillEllipse($b, ($px - 44), ($py2 - 178), 88, 76)        # face
$b.Dispose()
$b = New-Object System.Drawing.SolidBrush((C 255 22 24 30))
$g.FillEllipse($b, ($px - 30), ($py2 - 166), 18, 22); $g.FillEllipse($b, ($px + 12), ($py2 - 166), 18, 22)
$b.Dispose()
$b = New-Object System.Drawing.SolidBrush((C 255 240 170 40))
$beak = New-Object 'System.Drawing.Point[]' 3
$beak[0] = New-Object System.Drawing.Point(($px - 22), ($py2 - 132))
$beak[1] = New-Object System.Drawing.Point(($px + 22), ($py2 - 132))
$beak[2] = New-Object System.Drawing.Point($px, ($py2 - 106))
$g.FillPolygon($b, $beak)
$g.FillEllipse($b, ($px - 74), ($py2 + 72), 62, 26); $g.FillEllipse($b, ($px + 12), ($py2 + 72), 62, 26)
$b.Dispose()
EdgeFade $g "top" 90 90; EdgeFade $g "bottom" 100 100; EdgeFade $g "left" 110 90; EdgeFade $g "right" 110 90
Save $bmp $g "penguin.png"

# ── Cupertino: gradient wallpaper, translucent window, dock ──
$rng = New-Object System.Random(2020)
Get-Random -SetSeed 20200 | Out-Null
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 26 16 48) (C 255 10 8 26)
# blurred colour blobs
foreach ($blob in @(@(420, 300, 520, 236, 82, 255), @(1300, 240, 620, 255, 96, 150), @(1600, 820, 560, 96, 120, 255), @(700, 900, 600, 180, 70, 220))) {
  Glow $g $blob[0] $blob[1] $blob[2] (C 90 $blob[3] $blob[4] $blob[5])
}
# menu bar
$b = New-Object System.Drawing.SolidBrush((C 90 250 250 255)); $g.FillRectangle($b, 0, 0, $W, 40); $b.Dispose()
$mx = 40
foreach ($mw in @(26, 60, 48, 54, 62)) {
  $b = New-Object System.Drawing.SolidBrush((C 150 245 245 255)); $g.FillRectangle($b, $mx, 15, $mw, 10); $b.Dispose()
  $mx += $mw + 34
}
foreach ($i in 0..3) {
  $b = New-Object System.Drawing.SolidBrush((C 150 245 245 255)); $g.FillRectangle($b, (1660 + $i * 60), 15, 34, 10); $b.Dispose()
}
# translucent window with traffic lights + sidebar
$path = RoundRect 980 220 800 560 22
$b = New-Object System.Drawing.SolidBrush((C 150 30 26 48)); $g.FillPath($b, $path); $b.Dispose()
$pen = New-Object System.Drawing.Pen((C 90 255 255 255), 2); $g.DrawPath($pen, $path); $pen.Dispose(); $path.Dispose()
$path = RoundRect 980 220 800 56 22
$b = New-Object System.Drawing.SolidBrush((C 110 255 255 255)); $g.FillPath($b, $path); $b.Dispose(); $path.Dispose()
foreach ($light in @(@(1014, 255, 92, 88), @(1046, 255, 190, 78), @(1078, 60, 200, 90))) {
  $b = New-Object System.Drawing.SolidBrush((C 250 $light[1] $light[2] $light[3]))
  $g.FillEllipse($b, $light[0], 238, 20, 20); $b.Dispose()
}
$b = New-Object System.Drawing.SolidBrush((C 80 255 255 255)); $g.FillRectangle($b, 980, 276, 220, 504); $b.Dispose()
for ($i = 0; $i -lt 8; $i++) {
  $sy = 300 + $i * 44
  if ($i -eq 2) {
    $path = RoundRect 996 ($sy - 8) 188 34 10
    $b = New-Object System.Drawing.SolidBrush((C 140 120 150 255)); $g.FillPath($b, $path); $b.Dispose(); $path.Dispose()
  }
  $b = New-Object System.Drawing.SolidBrush((C 190 240 242 250)); $g.FillEllipse($b, 1010, $sy, 16, 16); $b.Dispose()
  $b = New-Object System.Drawing.SolidBrush((C 170 235 238 248)); $g.FillRectangle($b, 1036, ($sy + 3), $rng.Next(60, 130), 10); $b.Dispose()
}
$rowY = 310
while ($rowY -lt 740) {
  DashRow $g 1240 $rowY 480 (C 120 240 242 250) 10
  $rowY += 34
}
# dock
$path = RoundRect 620 960 680 90 24
$b = New-Object System.Drawing.SolidBrush((C 120 255 255 255)); $g.FillPath($b, $path); $b.Dispose()
$pen = New-Object System.Drawing.Pen((C 70 255 255 255), 2); $g.DrawPath($pen, $path); $pen.Dispose(); $path.Dispose()
$dockCols = @(@(90, 140, 255), @(255, 120, 90), @(90, 210, 140), @(255, 190, 80), @(180, 120, 255), @(90, 200, 240), @(240, 110, 170))
for ($i = 0; $i -lt 7; $i++) {
  $cc = $dockCols[$i]
  $path = RoundRect (650 + $i * 90) 978 62 62 16
  $b = New-Object System.Drawing.SolidBrush((C 235 $cc[0] $cc[1] $cc[2])); $g.FillPath($b, $path); $b.Dispose(); $path.Dispose()
}
Save $bmp $g "cupertino.png"

# ── Material: dark surfaces, elevated cards, FAB, chips ──
$rng = New-Object System.Random(2014)
Get-Random -SetSeed 2014 | Out-Null
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 18 20 19) (C 255 11 13 12)
$grn = C 235 61 220 132
$surf = C 255 30 34 32
# app bar
$b = New-Object System.Drawing.SolidBrush((C 255 26 30 28)); $g.FillRectangle($b, 0, 0, $W, 96); $b.Dispose()
$b = New-Object System.Drawing.SolidBrush((C 210 224 232 228)); $g.FillRectangle($b, 60, 44, 34, 5)
$g.FillRectangle($b, 60, 56, 34, 5); $g.FillRectangle($b, 60, 32, 34, 5); $b.Dispose()
$b = New-Object System.Drawing.SolidBrush((C 200 224 232 228)); $g.FillRectangle($b, 130, 40, 220, 14); $b.Dispose()
$b = New-Object System.Drawing.SolidBrush($grn); $g.FillEllipse($b, 1820, 34, 30, 30); $b.Dispose()
# chip row
foreach ($i in 0..4) {
  $cx5 = 70 + $i * 190
  $path = RoundRect $cx5 140 160 48 24
  if ($i -eq 1) {
    $b = New-Object System.Drawing.SolidBrush((C 190 61 220 132)); $g.FillPath($b, $path); $b.Dispose()
  } else {
    $pen = New-Object System.Drawing.Pen((C 120 120 140 130), 2); $g.DrawPath($pen, $path); $pen.Dispose()
  }
  $path.Dispose()
  $b = New-Object System.Drawing.SolidBrush($(if ($i -eq 1) { C 230 18 26 22 } else { C 150 200 216 208 }))
  $g.FillRectangle($b, ($cx5 + 34), 158, 92, 11); $b.Dispose()
}
# elevated cards with shadows
foreach ($card in @(@(70, 240, 560, 300), @(680, 240, 560, 300), @(1290, 240, 560, 300), @(70, 580, 860, 320), @(980, 580, 870, 320))) {
  $path = RoundRect ($card[0] + 6) ($card[1] + 10) $card[2] $card[3] 22
  $b = New-Object System.Drawing.SolidBrush((C 70 0 0 0)); $g.FillPath($b, $path); $b.Dispose(); $path.Dispose()
  $path = RoundRect $card[0] $card[1] $card[2] $card[3] 22
  $b = New-Object System.Drawing.SolidBrush($surf); $g.FillPath($b, $path); $b.Dispose(); $path.Dispose()
  # media strip in the card's own tint
  $tint = @(@(61, 220, 132), @(96, 165, 250), @(250, 180, 90), @(200, 120, 250), @(250, 120, 140))[$rng.Next(0, 5)]
  $path = RoundRect ($card[0] + 20) ($card[1] + 20) ($card[2] - 40) 92 14
  $b = New-Object System.Drawing.SolidBrush((C 130 $tint[0] $tint[1] $tint[2])); $g.FillPath($b, $path); $b.Dispose(); $path.Dispose()
  $b = New-Object System.Drawing.SolidBrush((C 210 226 234 230)); $g.FillRectangle($b, ($card[0] + 24), ($card[1] + 136), ([int]($card[2] * 0.5)), 13); $b.Dispose()
  $rowY = $card[1] + 172
  while ($rowY -lt $card[1] + $card[3] - 56) {
    DashRow $g ($card[0] + 24) $rowY ($card[2] - 70) (C 110 180 196 190) 9
    $rowY += 28
  }
  # text button pair
  $b = New-Object System.Drawing.SolidBrush($grn)
  $g.FillRectangle($b, ($card[0] + 24), ($card[1] + $card[3] - 40), 76, 11)
  $g.FillRectangle($b, ($card[0] + 124), ($card[1] + $card[3] - 40), 60, 11); $b.Dispose()
}
# FAB with shadow
Glow $g 1770 950 90 (C 60 61 220 132)
$b = New-Object System.Drawing.SolidBrush((C 90 0 0 0)); $g.FillEllipse($b, 1712, 902, 116, 116); $b.Dispose()
$b = New-Object System.Drawing.SolidBrush($grn); $g.FillEllipse($b, 1706, 894, 116, 116); $b.Dispose()
$b = New-Object System.Drawing.SolidBrush((C 255 16 22 18))
$g.FillRectangle($b, 1757, 928, 14, 48); $g.FillRectangle($b, 1740, 945, 48, 14); $b.Dispose()
Save $bmp $g "material.png"

# ── Chicago: teal desktop, beveled gray window, taskbar ──
$rng = New-Object System.Random(1998)
Get-Random -SetSeed 1998 | Out-Null
$bmp, $g = New-Canvas
$b = New-Object System.Drawing.SolidBrush((C 255 0 128 128)); $g.FillRectangle($b, 0, 0, $W, $H); $b.Dispose()
$gray = C 255 192 192 192
$white = C 255 255 255 255
$dgray = C 255 128 128 128
$black = C 255 0 0 0
# desktop icons, top-left
foreach ($i in 0..2) {
  $iy = 60 + $i * 150
  $b = New-Object System.Drawing.SolidBrush((C 255 224 224 224)); $g.FillRectangle($b, 70, $iy, 64, 56); $b.Dispose()
  Bevel $g 70 $iy 64 56 $white $dgray 2
  $b = New-Object System.Drawing.SolidBrush((C 255 0 0 160)); $g.FillRectangle($b, 78, ($iy + 10), 48, 12); $b.Dispose()
  $b = New-Object System.Drawing.SolidBrush($white); $g.FillRectangle($b, 62, ($iy + 68), 80, 10); $b.Dispose()
}
# main window
$wx2 = 620; $wy2 = 180; $ww2 = 1120; $wh2 = 660
$b = New-Object System.Drawing.SolidBrush($gray); $g.FillRectangle($b, $wx2, $wy2, $ww2, $wh2); $b.Dispose()
Bevel $g $wx2 $wy2 $ww2 $wh2 $white $black 2
# title bar gradient navy -> light blue
$rect = New-Object System.Drawing.Rectangle(($wx2 + 4), ($wy2 + 4), ($ww2 - 8), 40)
$br = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, (C 255 0 0 128), (C 255 16 132 208), 0.0)
$g.FillRectangle($br, $rect); $br.Dispose()
$b = New-Object System.Drawing.SolidBrush($white); $g.FillRectangle($b, ($wx2 + 44), ($wy2 + 18), 240, 12); $b.Dispose()
$b = New-Object System.Drawing.SolidBrush((C 255 224 224 0)); $g.FillRectangle($b, ($wx2 + 14), ($wy2 + 14), 20, 20); $b.Dispose()
foreach ($i in 0..2) {
  $bx2 = $wx2 + $ww2 - 40 - (2 - $i) * 34
  $b = New-Object System.Drawing.SolidBrush($gray); $g.FillRectangle($b, $bx2, ($wy2 + 10), 28, 26); $b.Dispose()
  Bevel $g $bx2 ($wy2 + 10) 28 26 $white $black 2
  $b = New-Object System.Drawing.SolidBrush($black); $g.FillRectangle($b, ($bx2 + 8), ($wy2 + 28), 12, 3); $b.Dispose()
}
# menu strip
$mx2 = $wx2 + 14
foreach ($mw in @(38, 42, 52, 44, 40)) {
  $b = New-Object System.Drawing.SolidBrush($black); $g.FillRectangle($b, $mx2, ($wy2 + 56), $mw, 10); $b.Dispose()
  $mx2 += $mw + 26
}
# sunken content well with list rows
$b = New-Object System.Drawing.SolidBrush($white); $g.FillRectangle($b, ($wx2 + 16), ($wy2 + 84), ($ww2 - 32), ($wh2 - 110)); $b.Dispose()
Bevel $g ($wx2 + 16) ($wy2 + 84) ($ww2 - 32) ($wh2 - 110) $dgray $white 2
for ($i = 0; $i -lt 14; $i++) {
  $ly = $wy2 + 104 + $i * 36
  if ($i -eq 3) {
    $b = New-Object System.Drawing.SolidBrush((C 255 0 0 128)); $g.FillRectangle($b, ($wx2 + 22), ($ly - 6), ($ww2 - 44), 30); $b.Dispose()
  }
  $b = New-Object System.Drawing.SolidBrush((C 255 224 224 96)); $g.FillRectangle($b, ($wx2 + 36), $ly, 24, 20); $b.Dispose()
  $b = New-Object System.Drawing.SolidBrush($(if ($i -eq 3) { $white } else { $black }))
  $g.FillRectangle($b, ($wx2 + 74), ($ly + 5), $rng.Next(150, 420), 11); $b.Dispose()
}
# taskbar with start button + tasks + clock
$b = New-Object System.Drawing.SolidBrush($gray); $g.FillRectangle($b, 0, ($H - 56), $W, 56); $b.Dispose()
Bevel $g 0 ($H - 56) ($W - 1) 55 $white $dgray 2
$b = New-Object System.Drawing.SolidBrush($gray); $g.FillRectangle($b, 8, ($H - 48), 130, 40); $b.Dispose()
Bevel $g 8 ($H - 48) 130 40 $white $black 2
foreach ($sq in @(@(20, 0, 0, 200), @(38, 200, 0, 0), @(20, 0, 140, 0), @(38, 200, 180, 0))) {
  $b = New-Object System.Drawing.SolidBrush((C 255 $sq[1] $sq[2] $sq[3]))
  $g.FillRectangle($b, $sq[0], ($H - 42 + $(if ($sq[0] -eq 20) { 0 } else { 0 })), 14, 14); $b.Dispose()
}
$b = New-Object System.Drawing.SolidBrush((C 255 0 0 200)); $g.FillRectangle($b, 20, ($H - 42), 14, 14); $b.Dispose()
$b = New-Object System.Drawing.SolidBrush((C 255 200 0 0)); $g.FillRectangle($b, 36, ($H - 42), 14, 14); $b.Dispose()
$b = New-Object System.Drawing.SolidBrush((C 255 0 140 0)); $g.FillRectangle($b, 20, ($H - 26), 14, 14); $b.Dispose()
$b = New-Object System.Drawing.SolidBrush((C 255 210 180 0)); $g.FillRectangle($b, 36, ($H - 26), 14, 14); $b.Dispose()
$b = New-Object System.Drawing.SolidBrush($black); $g.FillRectangle($b, 62, ($H - 34), 60, 12); $b.Dispose()
foreach ($i in 0..2) {
  $tx = 160 + $i * 220
  $b = New-Object System.Drawing.SolidBrush($gray); $g.FillRectangle($b, $tx, ($H - 48), 200, 40); $b.Dispose()
  Bevel $g $tx ($H - 48) 200 40 $(if ($i -eq 0) { $dgray } else { $white }) $(if ($i -eq 0) { $white } else { $black }) 2
  $b = New-Object System.Drawing.SolidBrush($black); $g.FillRectangle($b, ($tx + 16), ($H - 34), 120, 11); $b.Dispose()
}
$b = New-Object System.Drawing.SolidBrush($gray); $g.FillRectangle($b, ($W - 150), ($H - 48), 140, 40); $b.Dispose()
Bevel $g ($W - 150) ($H - 48) 140 40 $dgray $white 2
$b = New-Object System.Drawing.SolidBrush($black); $g.FillRectangle($b, ($W - 120), ($H - 34), 80, 12); $b.Dispose()
Save $bmp $g "chicago.png"

# ── Aero: blue gradient wallpaper, glass window, glass taskbar ──
$rng = New-Object System.Random(2009)
Get-Random -SetSeed 2009 | Out-Null
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 12 46 96) (C 255 4 16 44)
Glow $g 960 460 900 (C 60 90 180 255)
Glow $g 400 820 520 (C 40 60 140 230)
# light ribbons across the wallpaper
foreach ($rib in @(@(-100, 700, 600, 380, 1300, 760, 2020, 520, 60), @(-100, 860, 700, 620, 1400, 900, 2020, 700, 40))) {
  $path = New-Object System.Drawing.Drawing2D.GraphicsPath
  $path.AddBezier($rib[0], $rib[1], $rib[2], $rib[3], $rib[4], $rib[5], $rib[6], $rib[7])
  foreach ($pass in @(@(($rib[8] / 3), 60), @(($rib[8] / 2), 24), @($rib[8], 6))) {
    $pen = New-Object System.Drawing.Pen((C ([int]$pass[0]) 150 210 255), $pass[1])
    $g.DrawPath($pen, $path); $pen.Dispose()
  }
  $path.Dispose()
}
# glass window
$path = RoundRect 560 200 900 620 16
$b = New-Object System.Drawing.SolidBrush((C 90 200 225 255)); $g.FillPath($b, $path); $b.Dispose()
$pen = New-Object System.Drawing.Pen((C 170 235 245 255), 3); $g.DrawPath($pen, $path); $pen.Dispose(); $path.Dispose()
Glow $g 1010 500 420 (C 26 150 210 255)
# glass title bar with a highlight sheen
$path = RoundRect 560 200 900 74 16
$b = New-Object System.Drawing.SolidBrush((C 110 230 242 255)); $g.FillPath($b, $path); $b.Dispose(); $path.Dispose()
$b = New-Object System.Drawing.SolidBrush((C 70 255 255 255)); $g.FillRectangle($b, 570, 210, 880, 26); $b.Dispose()
# window buttons: rounded, red close
foreach ($i in 0..2) {
  $bx3 = 1290 + $i * 52
  $path = RoundRect $bx3 214 44 34 8
  $b = New-Object System.Drawing.SolidBrush($(if ($i -eq 2) { C 220 220 60 60 } else { C 120 240 250 255 }))
  $g.FillPath($b, $path); $b.Dispose()
  $pen = New-Object System.Drawing.Pen((C 150 255 255 255), 2); $g.DrawPath($pen, $path); $pen.Dispose(); $path.Dispose()
}
$b = New-Object System.Drawing.SolidBrush((C 220 255 255 255)); $g.FillRectangle($b, 600, 228, 240, 12); $b.Dispose()
# content: white pane with list
$b = New-Object System.Drawing.SolidBrush((C 210 250 252 255)); $g.FillRectangle($b, 580, 292, 860, 512); $b.Dispose()
$b = New-Object System.Drawing.SolidBrush((C 120 210 232 250)); $g.FillRectangle($b, 580, 292, 230, 512); $b.Dispose()
for ($i = 0; $i -lt 9; $i++) {
  $sy2 = 320 + $i * 52
  $b = New-Object System.Drawing.SolidBrush((C 190 60 120 200)); $g.FillEllipse($b, 604, $sy2, 20, 20); $b.Dispose()
  $b = New-Object System.Drawing.SolidBrush((C 170 40 70 120)); $g.FillRectangle($b, 636, ($sy2 + 5), $rng.Next(70, 150), 11); $b.Dispose()
}
$rowY = 330
while ($rowY -lt 780) {
  DashRow $g 840 $rowY 560 (C 140 40 70 120) 10
  $rowY += 36
}
# glass taskbar with rounded icon buttons
$b = New-Object System.Drawing.SolidBrush((C 120 180 215 255)); $g.FillRectangle($b, 0, ($H - 80), $W, 80); $b.Dispose()
$b = New-Object System.Drawing.SolidBrush((C 80 255 255 255)); $g.FillRectangle($b, 0, ($H - 80), $W, 26); $b.Dispose()
Glow $g 90 ($H - 40) 90 (C 120 120 200 255)
$b = New-Object System.Drawing.SolidBrush((C 210 60 130 220)); $g.FillEllipse($b, 44, ($H - 68), 56, 56); $b.Dispose()
$b = New-Object System.Drawing.SolidBrush((C 220 240 250 255)); $g.FillEllipse($b, 58, ($H - 54), 28, 28); $b.Dispose()
$taskCols = @(@(90, 170, 250), @(250, 190, 80), @(120, 220, 140), @(250, 130, 120), @(190, 140, 250))
for ($i = 0; $i -lt 5; $i++) {
  $cc = $taskCols[$i]
  $path = RoundRect (150 + $i * 78) ($H - 66) 58 52 10
  $b = New-Object System.Drawing.SolidBrush((C 110 255 255 255)); $g.FillPath($b, $path); $b.Dispose()
  $pen = New-Object System.Drawing.Pen((C 90 255 255 255), 2); $g.DrawPath($pen, $path); $pen.Dispose(); $path.Dispose()
  $b = New-Object System.Drawing.SolidBrush((C 230 $cc[0] $cc[1] $cc[2])); $g.FillRectangle($b, (164 + $i * 78), ($H - 54), 30, 30); $b.Dispose()
}
Save $bmp $g "aero.png"

# ── Fluent: flat dark, accent blue, tile grid, thin taskbar ──
$rng = New-Object System.Random(2015)
Get-Random -SetSeed 2015 | Out-Null
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 16 20 26) (C 255 10 13 17)
Glow $g 1500 300 700 (C 30 0 120 212)
$acc = C 255 0 120 212
# tile grid: flat colored squares of two sizes
$tiles = @(
  @(1080, 200, 200, 200, 0, 120, 212), @(1300, 200, 200, 200, 16, 137, 62),
  @(1520, 200, 420, 200, 202, 80, 16), @(1080, 420, 420, 200, 92, 45, 145),
  @(1520, 420, 200, 200, 0, 153, 188), @(1740, 420, 200, 200, 202, 24, 60),
  @(1080, 640, 200, 200, 16, 124, 16), @(1300, 640, 420, 200, 0, 99, 177),
  @(1740, 640, 200, 200, 122, 117, 116)
)
foreach ($t in $tiles) {
  $b = New-Object System.Drawing.SolidBrush((C 235 $t[4] $t[5] $t[6]))
  $g.FillRectangle($b, $t[0], $t[1], ($t[2] - 8), ($t[3] - 8)); $b.Dispose()
  # glyph block + label bar inside the tile
  $b = New-Object System.Drawing.SolidBrush((C 200 250 252 255))
  $g.FillRectangle($b, ($t[0] + 32), ($t[1] + 40), 52, 52); $b.Dispose()
  $b = New-Object System.Drawing.SolidBrush((C 170 250 252 255))
  $g.FillRectangle($b, ($t[0] + 24), ($t[3] + $t[1] - 46), ([int](($t[2] - 8) * 0.5)), 11); $b.Dispose()
}
# start-panel column on the left of the tiles
$b = New-Object System.Drawing.SolidBrush((C 235 24 28 34)); $g.FillRectangle($b, 720, 200, 340, 640); $b.Dispose()
for ($i = 0; $i -lt 11; $i++) {
  $ly2 = 226 + $i * 56
  if ($i -eq 4) {
    $b = New-Object System.Drawing.SolidBrush((C 90 0 120 212)); $g.FillRectangle($b, 720, ($ly2 - 10), 340, 46); $b.Dispose()
    $b = New-Object System.Drawing.SolidBrush($acc); $g.FillRectangle($b, 720, ($ly2 - 10), 4, 46); $b.Dispose()
  }
  $b = New-Object System.Drawing.SolidBrush((C 190 220 228 236)); $g.FillRectangle($b, 748, $ly2, 22, 22); $b.Dispose()
  $b = New-Object System.Drawing.SolidBrush((C 160 210 220 230)); $g.FillRectangle($b, 786, ($ly2 + 6), $rng.Next(90, 220), 11); $b.Dispose()
}
# flat window, left
$b = New-Object System.Drawing.SolidBrush((C 240 32 36 42)); $g.FillRectangle($b, 90, 200, 560, 640); $b.Dispose()
$pen = New-Object System.Drawing.Pen((C 90 90 100 115), 1); $g.DrawRectangle($pen, 90, 200, 560, 640); $pen.Dispose()
$b = New-Object System.Drawing.SolidBrush((C 255 26 30 36)); $g.FillRectangle($b, 90, 200, 560, 48); $b.Dispose()
$b = New-Object System.Drawing.SolidBrush((C 200 220 228 236)); $g.FillRectangle($b, 116, 218, 180, 12); $b.Dispose()
foreach ($i in 0..2) {
  $b = New-Object System.Drawing.SolidBrush($(if ($i -eq 2) { C 230 232 17 35 } else { C 150 200 210 220 }))
  $g.FillRectangle($b, (520 + $i * 40), 218, 14, 12); $b.Dispose()
}
$rowY = 280
while ($rowY -lt 800) {
  DashRow $g 118 $rowY 480 (C 120 180 195 210) 10
  $rowY += 34
}
# thin taskbar with centered-ish icons and accent underline
$b = New-Object System.Drawing.SolidBrush((C 250 20 24 30)); $g.FillRectangle($b, 0, ($H - 60), $W, 60); $b.Dispose()
$pen = New-Object System.Drawing.Pen((C 60 90 100 115), 1); $g.DrawLine($pen, 0, ($H - 60), $W, ($H - 60)); $pen.Dispose()
$taskCols2 = @(@(0, 120, 212), @(16, 137, 62), @(202, 80, 16), @(92, 45, 145), @(0, 153, 188), @(202, 24, 60))
for ($i = 0; $i -lt 6; $i++) {
  $cc = $taskCols2[$i]
  $tx2 = 760 + $i * 72
  $b = New-Object System.Drawing.SolidBrush((C 235 $cc[0] $cc[1] $cc[2])); $g.FillRectangle($b, $tx2, ($H - 46), 32, 32); $b.Dispose()
  if ($i -eq 1) {
    $b = New-Object System.Drawing.SolidBrush($acc); $g.FillRectangle($b, ($tx2 + 4), ($H - 10), 24, 3); $b.Dispose()
  }
}
$b = New-Object System.Drawing.SolidBrush((C 180 210 220 230)); $g.FillRectangle($b, ($W - 150), ($H - 40), 90, 12); $b.Dispose()
Save $bmp $g "fluent.png"

# ── DOS: black screen, DIR listing, blue TUI panel with shadow ──
$rng = New-Object System.Random(1981)
Get-Random -SetSeed 1981 | Out-Null
$bmp, $g = New-Canvas
$b = New-Object System.Drawing.SolidBrush((C 255 0 0 0)); $g.FillRectangle($b, 0, 0, $W, $H); $b.Dispose()
Glow $g 960 520 900 (C 12 170 170 170)
$gray = C 215 170 170 170
$grayDim = C 120 130 130 130
$white = C 240 236 236 236
$cell = 20   # character cell width for the fake text grid

function TextRow {
  # Fake monospace text: fixed-width cell blocks, so it reads as DOS text.
  param($g, $x, $y, $cells, $color, $gaps)
  $cx2 = $x
  $i = 0
  while ($i -lt $cells) {
    $runLen = Get-Random -Minimum 2 -Maximum 9
    if ($i + $runLen -gt $cells) { $runLen = $cells - $i }
    $b2 = New-Object System.Drawing.SolidBrush($color)
    $g.FillRectangle($b2, ($x + $i * $cell), $y, ($runLen * $cell - 5), 12); $b2.Dispose()
    $i += $runLen + $(if ($gaps) { Get-Random -Minimum 1 -Maximum 3 } else { 1 })
  }
}

# header: volume label + directory line
TextRow $g 120 90 22 $gray $true
TextRow $g 120 122 18 $gray $true
TextRow $g 120 170 16 $gray $true

# DIR listing: NAME EXT <DIR>/size DATE TIME columns
$rowY = 220
for ($i = 0; $i -lt 20; $i++) {
  $isDir = $rng.NextDouble() -lt 0.3
  # name column (8 chars)
  $b = New-Object System.Drawing.SolidBrush($white)
  $g.FillRectangle($b, 120, $rowY, ($rng.Next(4, 9) * $cell - 5), 12); $b.Dispose()
  # extension column (3 chars)
  if (-not $isDir) {
    $b = New-Object System.Drawing.SolidBrush($gray)
    $g.FillRectangle($b, 300, $rowY, (3 * $cell - 5), 12); $b.Dispose()
  }
  # <DIR> marker or byte size, right-aligned-ish
  if ($isDir) {
    $b = New-Object System.Drawing.SolidBrush($gray)
    $g.FillRectangle($b, 400, $rowY, (5 * $cell - 5), 12); $b.Dispose()
  } else {
    $sw = $rng.Next(3, 8) * $cell - 5
    $b = New-Object System.Drawing.SolidBrush($gray)
    $g.FillRectangle($b, (560 - $sw), $rowY, $sw, 12); $b.Dispose()
  }
  # date + time columns
  $b = New-Object System.Drawing.SolidBrush($grayDim)
  $g.FillRectangle($b, 620, $rowY, (8 * $cell - 5), 12)
  $g.FillRectangle($b, 810, $rowY, (6 * $cell - 5), 12); $b.Dispose()
  $rowY += 30
}
# summary lines + prompt with block cursor
TextRow $g 120 ($rowY + 24) 26 $gray $true
TextRow $g 120 ($rowY + 54) 24 $gray $true
$b = New-Object System.Drawing.SolidBrush($white)
$g.FillRectangle($b, 120, ($rowY + 104), (4 * $cell - 5), 12); $b.Dispose()
$b = New-Object System.Drawing.SolidBrush($white)
$g.FillRectangle($b, (120 + 4 * $cell + 8), ($rowY + 96), 16, 26); $b.Dispose()

# blue TUI panel, right side: double-line border, title, menu, shadow
$px = 1150; $py = 260; $pw = 660; $ph = 520
$b = New-Object System.Drawing.SolidBrush((C 160 0 0 0)); $g.FillRectangle($b, ($px + 14), ($py + 16), $pw, $ph); $b.Dispose()
$b = New-Object System.Drawing.SolidBrush((C 255 0 0 168)); $g.FillRectangle($b, $px, $py, $pw, $ph); $b.Dispose()
# double-line border drawn as two inset rectangles
$pen = New-Object System.Drawing.Pen((C 255 200 200 200), 3); $g.DrawRectangle($pen, ($px + 10), ($py + 10), ($pw - 20), ($ph - 20)); $pen.Dispose()
$pen = New-Object System.Drawing.Pen((C 255 200 200 200), 2); $g.DrawRectangle($pen, ($px + 18), ($py + 18), ($pw - 36), ($ph - 36)); $pen.Dispose()
# title plate centred on the top border
$b = New-Object System.Drawing.SolidBrush((C 255 0 0 168)); $g.FillRectangle($b, ($px + 200), ($py + 2), 260, 32); $b.Dispose()
$b = New-Object System.Drawing.SolidBrush((C 255 236 236 236)); $g.FillRectangle($b, ($px + 232), ($py + 12), 196, 13); $b.Dispose()
# menu rows, one highlighted (inverse: light bar, dark text)
for ($i = 0; $i -lt 7; $i++) {
  $my = $py + 80 + $i * 46
  if ($i -eq 2) {
    $b = New-Object System.Drawing.SolidBrush((C 255 200 200 200)); $g.FillRectangle($b, ($px + 30), ($my - 8), ($pw - 60), 32); $b.Dispose()
    $b = New-Object System.Drawing.SolidBrush((C 255 0 0 168)); $g.FillRectangle($b, ($px + 52), $my, ($rng.Next(9, 16) * $cell), 13); $b.Dispose()
  } else {
    $b = New-Object System.Drawing.SolidBrush((C 255 96 216 216)); $g.FillRectangle($b, ($px + 52), $my, $cell, 13); $b.Dispose()
    $b = New-Object System.Drawing.SolidBrush((C 235 200 200 200)); $g.FillRectangle($b, ($px + 52 + $cell + 8), $my, ($rng.Next(8, 18) * $cell), 13); $b.Dispose()
  }
}
# status strip at the panel foot
$b = New-Object System.Drawing.SolidBrush((C 255 0 168 168)); $g.FillRectangle($b, ($px + 30), ($py + $ph - 60), ($pw - 60), 30); $b.Dispose()
foreach ($i in 0..3) {
  $b = New-Object System.Drawing.SolidBrush((C 255 0 0 0)); $g.FillRectangle($b, ($px + 50 + $i * 150), ($py + $ph - 52), 60, 13); $b.Dispose()
  $b = New-Object System.Drawing.SolidBrush((C 255 236 236 236)); $g.FillRectangle($b, ($px + 118 + $i * 150), ($py + $ph - 52), 40, 13); $b.Dispose()
}
# faint CRT scanlines
for ($y = 0; $y -lt $H; $y += 3) {
  $pen = New-Object System.Drawing.Pen((C 22 0 0 0), 1); $g.DrawLine($pen, 0, $y, $W, $y); $pen.Dispose()
}
EdgeFade $g "top" 100 90; EdgeFade $g "bottom" 110 100; EdgeFade $g "left" 120 90; EdgeFade $g "right" 110 80
Save $bmp $g "dos.png"

function Spark {
  # tapered four/eight-point spark: thin diamond arms from a centre
  param($g, $cx3, $cy3, $r, $arms, $color)
  $b = New-Object System.Drawing.SolidBrush($color)
  for ($k = 0; $k -lt $arms; $k++) {
    $ang = ($k / [double]$arms) * 2 * [math]::PI
    $wid = $r * 0.16
    $pts = New-Object 'System.Drawing.Point[]' 4
    $pts[0] = New-Object System.Drawing.Point([int]($cx3 + $r * [math]::Cos($ang)), [int]($cy3 + $r * [math]::Sin($ang)))
    $pts[1] = New-Object System.Drawing.Point([int]($cx3 + $wid * [math]::Cos($ang + 1.5708)), [int]($cy3 + $wid * [math]::Sin($ang + 1.5708)))
    $pts[2] = New-Object System.Drawing.Point([int]($cx3 - $r * 0.16 * [math]::Cos($ang)), [int]($cy3 - $r * 0.16 * [math]::Sin($ang)))
    $pts[3] = New-Object System.Drawing.Point([int]($cx3 + $wid * [math]::Cos($ang - 1.5708)), [int]($cy3 + $wid * [math]::Sin($ang - 1.5708)))
    $g.FillPolygon($b, $pts)
  }
  $b.Dispose()
}

# ── Coral: warm cream paper, clay arcs, spark motif ──
$rng = New-Object System.Random(2023)
Get-Random -SetSeed 2023 | Out-Null
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 242 240 233) (C 255 232 228 218)
# soft clay washes
Glow $g 1420 320 620 (C 46 217 119 87)
Glow $g 420 820 560 (C 30 200 140 110)
Glow $g 1000 560 700 (C 16 217 119 87)
# concentric arc ribbons, upper right
foreach ($rr in @(560, 470, 380, 300)) {
  $pen = New-Object System.Drawing.Pen((C $(if ($rr -eq 470) { 150 } else { 70 }) 217 119 87), $(if ($rr -eq 470) { 22 } else { 12 }))
  $g.DrawArc($pen, (1480 - $rr), (300 - $rr), (2 * $rr), (2 * $rr), 118, 118); $pen.Dispose()
}
# big spark, right of centre
Spark $g 1330 620 210 8 (C 210 217 119 87)
Spark $g 1330 620 96 4 (C 235 190 92 64)
# small sparks scattered
foreach ($s in @(@(360, 300, 42), @(700, 880, 34), @(980, 240, 28), @(560, 620, 24), @(1700, 860, 38))) {
  Spark $g $s[0] $s[1] $s[2] 4 (C 130 217 119 87)
}
# paper grain
for ($i = 0; $i -lt 2600; $i++) {
  $b = New-Object System.Drawing.SolidBrush((C $rng.Next(5, 13) 90 74 58))
  $g.FillRectangle($b, $rng.Next(0, $W), $rng.Next(0, $H), 1, 1); $b.Dispose()
}
EdgeFade $g "top" 90 18; EdgeFade $g "bottom" 100 24; EdgeFade $g "left" 110 16; EdgeFade $g "right" 100 16
Save $bmp $g "coral.png"

# ── Monochrome: near-black, thin white lattice knot, one accent dot ──
$rng = New-Object System.Random(2022)
Get-Random -SetSeed 2022 | Out-Null
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 10 10 10) (C 255 5 5 5)
Glow $g 1360 540 620 (C 14 255 255 255)
# interlocking rounded-square lattice, rotated
$g.TranslateTransform(1360, 540)
$g.RotateTransform(15)
for ($ring = 0; $ring -lt 6; $ring++) {
  $r = 90 + $ring * 78
  $pen = New-Object System.Drawing.Pen((C $(140 - $ring * 16) 240 240 240), 2)
  $path = RoundRect (-$r) (-$r) (2 * $r) (2 * $r) ([int]($r * 0.55))
  $g.DrawPath($pen, $path); $pen.Dispose(); $path.Dispose()
}
# radial hairlines through the lattice
for ($k = 0; $k -lt 12; $k++) {
  $ang = ($k / 12.0) * 2 * [math]::PI
  $pen = New-Object System.Drawing.Pen((C 48 235 235 235), 1)
  $g.DrawLine($pen, [int](90 * [math]::Cos($ang)), [int](90 * [math]::Sin($ang)), [int](510 * [math]::Cos($ang)), [int](510 * [math]::Sin($ang))); $pen.Dispose()
}
$g.ResetTransform()
# single accent dot
$b = New-Object System.Drawing.SolidBrush((C 240 245 245 245)); $g.FillEllipse($b, 1348, 528, 24, 24); $b.Dispose()
Glow $g 1360 540 90 (C 60 255 255 255)
# hairline rule + label dashes, top left
$pen = New-Object System.Drawing.Pen((C 90 220 220 220), 1); $g.DrawLine($pen, 140, 180, 780, 180); $pen.Dispose()
DashRow $g 140 140 300 (C 150 235 235 235) 10
DashRow $g 140 210 220 (C 70 200 200 200) 8
Save $bmp $g "monochrome.png"

# ── Git: commit graph with branch lanes, merges, tags ──
$rng = New-Object System.Random(2005)
Get-Random -SetSeed 2005 | Out-Null
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 20 23 28) (C 255 12 14 18)
$laneCols = @(@(240, 80, 51), @(88, 166, 255), @(63, 185, 80), @(210, 153, 34), @(188, 140, 255))
$laneX = @(320, 430, 540, 650, 760)
$rowStep = 46
$rows = 21
# lane spines
for ($l = 0; $l -lt 5; $l++) {
  $cc = $laneCols[$l]
  $top = 150 + $(if ($l -eq 0) { 0 } else { $rng.Next(2, 7) * $rowStep })
  $bot = 150 + ($rows - 1 - $(if ($l -eq 0) { 0 } else { $rng.Next(0, 4) })) * $rowStep
  $pen = New-Object System.Drawing.Pen((C 200 $cc[0] $cc[1] $cc[2]), 4)
  $g.DrawLine($pen, $laneX[$l], $top, $laneX[$l], $bot); $pen.Dispose()
  # fork off lane 0 and merge back
  if ($l -gt 0) {
    $pen = New-Object System.Drawing.Pen((C 200 $cc[0] $cc[1] $cc[2]), 4)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddBezier($laneX[0], ($top - $rowStep), $laneX[0], $top, $laneX[$l], ($top - $rowStep), $laneX[$l], $top)
    $g.DrawPath($pen, $path); $path.Dispose()
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddBezier($laneX[$l], $bot, $laneX[$l], ($bot + $rowStep), $laneX[0], $bot, $laneX[0], ($bot + $rowStep))
    $g.DrawPath($pen, $path); $path.Dispose(); $pen.Dispose()
  }
}
# commit dots + subject lines
for ($r = 0; $r -lt $rows; $r++) {
  $ry = 150 + $r * $rowStep
  $l = $rng.Next(0, 5)
  if ($laneX[$l] -eq $null) { $l = 0 }
  $cc = $laneCols[$l]
  $b = New-Object System.Drawing.SolidBrush((C 255 18 21 26)); $g.FillEllipse($b, ($laneX[$l] - 11), ($ry - 11), 22, 22); $b.Dispose()
  $pen = New-Object System.Drawing.Pen((C 255 $cc[0] $cc[1] $cc[2]), 4); $g.DrawEllipse($pen, ($laneX[$l] - 9), ($ry - 9), 18, 18); $pen.Dispose()
  # short hash + subject
  $b = New-Object System.Drawing.SolidBrush((C 170 210 160 90)); $g.FillRectangle($b, 860, ($ry - 5), 90, 11); $b.Dispose()
  DashRow $g 980 ($ry - 5) $rng.Next(320, 760) (C 130 190 205 220) 11
  # occasional tag / branch label chip
  if ($rng.NextDouble() -lt 0.22) {
    $tw = $rng.Next(90, 170)
    $path = RoundRect 1760 ($ry - 14) $tw 28 10
    $b = New-Object System.Drawing.SolidBrush((C 60 $cc[0] $cc[1] $cc[2])); $g.FillPath($b, $path); $b.Dispose()
    $pen = New-Object System.Drawing.Pen((C 200 $cc[0] $cc[1] $cc[2]), 2); $g.DrawPath($pen, $path); $pen.Dispose(); $path.Dispose()
    $b = New-Object System.Drawing.SolidBrush((C 200 $cc[0] $cc[1] $cc[2])); $g.FillRectangle($b, 1782, ($ry - 5), ($tw - 44), 11); $b.Dispose()
  }
}
# HEAD marker diamond on the newest commit
$dia = New-Object 'System.Drawing.Point[]' 4
$dia[0] = New-Object System.Drawing.Point(220, 150); $dia[1] = New-Object System.Drawing.Point(250, 172)
$dia[2] = New-Object System.Drawing.Point(220, 194); $dia[3] = New-Object System.Drawing.Point(190, 172)
$b = New-Object System.Drawing.SolidBrush((C 230 240 80 51)); $g.FillPolygon($b, $dia); $b.Dispose()
EdgeFade $g "top" 100 100; EdgeFade $g "bottom" 110 110; EdgeFade $g "left" 120 90; EdgeFade $g "right" 110 90
Save $bmp $g "git.png"

# ── Circuit: PCB solder mask, gold traces, pads, ICs, silkscreen ──
$rng = New-Object System.Random(1969)
Get-Random -SetSeed 1969 | Out-Null
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 12 40 26) (C 255 7 26 17)
$gold = C 235 198 156 62
$goldDim = C 120 168 132 54
$silk = C 150 226 232 226
# routed traces with 45-degree bends
for ($i = 0; $i -lt 42; $i++) {
  $sx = $rng.Next(0, $W); $sy = $rng.Next(0, $H)
  $pen = New-Object System.Drawing.Pen($(if ($rng.NextDouble() -lt 0.3) { $gold } else { $goldDim }), $rng.Next(3, 6))
  $px = $sx; $py = $sy
  for ($seg = 0; $seg -lt $rng.Next(2, 6); $seg++) {
    $len = $rng.Next(80, 260)
    $dir = $rng.Next(0, 4)
    $nx = $px + $(switch ($dir) { 0 { $len } 1 { -$len } 2 { $len } 3 { -$len } })
    $ny = $py + $(switch ($dir) { 0 { 0 } 1 { 0 } 2 { $len } 3 { $len } })
    $g.DrawLine($pen, $px, $py, $nx, $ny)
    $px = $nx; $py = $ny
  }
  $pen.Dispose()
}
# vias / pads
for ($i = 0; $i -lt 70; $i++) {
  $vx = $rng.Next(40, $W - 40); $vy = $rng.Next(40, $H - 40)
  $b = New-Object System.Drawing.SolidBrush($gold); $g.FillEllipse($b, $vx, $vy, 18, 18); $b.Dispose()
  $b = New-Object System.Drawing.SolidBrush((C 255 9 30 20)); $g.FillEllipse($b, ($vx + 6), ($vy + 6), 6, 6); $b.Dispose()
}
# ICs with pin rows and silkscreen outline
foreach ($ic in @(@(1180, 300, 380, 220), @(320, 640, 300, 170), @(1420, 720, 260, 150))) {
  $b = New-Object System.Drawing.SolidBrush((C 250 18 20 22)); $g.FillRectangle($b, $ic[0], $ic[1], $ic[2], $ic[3]); $b.Dispose()
  $pen = New-Object System.Drawing.Pen($silk, 2); $g.DrawRectangle($pen, ($ic[0] - 10), ($ic[1] - 10), ($ic[2] + 20), ($ic[3] + 20)); $pen.Dispose()
  # pin-1 dot + notch
  $b = New-Object System.Drawing.SolidBrush($silk); $g.FillEllipse($b, ($ic[0] + 16), ($ic[1] + 16), 16, 16); $b.Dispose()
  $pins = [int]($ic[2] / 34)
  for ($p = 0; $p -lt $pins; $p++) {
    $b = New-Object System.Drawing.SolidBrush($gold)
    $g.FillRectangle($b, ($ic[0] + 16 + $p * 34), ($ic[1] - 22), 18, 24)
    $g.FillRectangle($b, ($ic[0] + 16 + $p * 34), ($ic[1] + $ic[3] - 2), 18, 24); $b.Dispose()
  }
  DashRow $g ($ic[0] + 50) ($ic[1] + 70) ($ic[2] - 100) $silk 12
  DashRow $g ($ic[0] + 50) ($ic[1] + 104) ($ic[2] - 140) (C 90 226 232 226) 9
}
# silkscreen designators
for ($i = 0; $i -lt 16; $i++) {
  $b = New-Object System.Drawing.SolidBrush((C 90 226 232 226))
  $g.FillRectangle($b, $rng.Next(60, $W - 120), $rng.Next(60, $H - 60), $rng.Next(30, 64), 9); $b.Dispose()
}
EdgeFade $g "top" 110 100; EdgeFade $g "bottom" 110 100; EdgeFade $g "left" 120 90; EdgeFade $g "right" 120 90
Save $bmp $g "circuit.png"

# ── Whiteboard: marker boxes, arrows, sticky notes, eraser smudge ──
$rng = New-Object System.Random(101)
Get-Random -SetSeed 101 | Out-Null
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 250 250 248) (C 255 240 240 238)
# eraser smudges
foreach ($sm in @(@(500, 300, 420, 120), @(1300, 800, 500, 90))) {
  $b = New-Object System.Drawing.SolidBrush((C 26 120 130 140))
  $g.FillEllipse($b, $sm[0], $sm[1], $sm[2], $sm[3]); $b.Dispose()
}
$mk = @(@(40, 70, 180), @(200, 60, 60), @(40, 140, 70), @(40, 40, 44))
# boxes with hand-drawn wobble (double stroke, slight offset)
$boxes = @(@(180, 200, 300, 160, 0), @(640, 180, 300, 160, 1), @(1120, 240, 320, 170, 2), @(400, 520, 300, 150, 3), @(900, 560, 340, 170, 0), @(1420, 620, 300, 160, 1))
foreach ($bx in $boxes) {
  $cc = $mk[$bx[4]]
  foreach ($off in @(0, 2)) {
    $pen = New-Object System.Drawing.Pen((C $(if ($off -eq 0) { 210 } else { 90 }) $cc[0] $cc[1] $cc[2]), 4)
    $g.DrawRectangle($pen, ($bx[0] + $off), ($bx[1] + $off + $rng.Next(-1, 2)), $bx[2], $bx[3]); $pen.Dispose()
  }
  DashRow $g ($bx[0] + 26) ($bx[1] + 44) ($bx[2] - 60) (C 190 $cc[0] $cc[1] $cc[2]) 12
  DashRow $g ($bx[0] + 26) ($bx[1] + 82) ($bx[2] - 100) (C 130 $cc[0] $cc[1] $cc[2]) 9
}
# arrows between boxes, with heads
foreach ($ar in @(@(480, 280, 640, 260, 0), @(940, 260, 1120, 320, 1), @(700, 600, 900, 640, 2), @(1280, 410, 1420, 620, 3), @(330, 360, 400, 520, 0))) {
  $cc = $mk[$ar[4]]
  $pen = New-Object System.Drawing.Pen((C 200 $cc[0] $cc[1] $cc[2]), 4)
  $g.DrawLine($pen, $ar[0], $ar[1], $ar[2], $ar[3]); $pen.Dispose()
  $ang = [math]::Atan2(($ar[3] - $ar[1]), ($ar[2] - $ar[0]))
  $head = New-Object 'System.Drawing.Point[]' 3
  $head[0] = New-Object System.Drawing.Point($ar[2], $ar[3])
  $head[1] = New-Object System.Drawing.Point([int]($ar[2] - 24 * [math]::Cos($ang - 0.4)), [int]($ar[3] - 24 * [math]::Sin($ang - 0.4)))
  $head[2] = New-Object System.Drawing.Point([int]($ar[2] - 24 * [math]::Cos($ang + 0.4)), [int]($ar[3] - 24 * [math]::Sin($ang + 0.4)))
  $b = New-Object System.Drawing.SolidBrush((C 220 $cc[0] $cc[1] $cc[2])); $g.FillPolygon($b, $head); $b.Dispose()
}
# sticky notes with a slight rotation and shadow
foreach ($st in @(@(1560, 200, 250, 240, 5), @(200, 760, 230, 210, -6), @(1180, 840, 240, 220, 3))) {
  $g.TranslateTransform($st[0], $st[1])
  $g.RotateTransform($st[4])
  $b = New-Object System.Drawing.SolidBrush((C 50 90 90 90)); $g.FillRectangle($b, 8, 10, $st[2], $st[3]); $b.Dispose()
  $cc = @(@(250, 226, 120), @(250, 170, 190), @(180, 226, 250))[$rng.Next(0, 3)]
  $b = New-Object System.Drawing.SolidBrush((C 255 $cc[0] $cc[1] $cc[2])); $g.FillRectangle($b, 0, 0, $st[2], $st[3]); $b.Dispose()
  for ($r = 0; $r -lt 5; $r++) {
    DashRow $g 22 (34 + $r * 34) ($st[2] - 50) (C 150 60 56 50) 9
  }
  $g.ResetTransform()
}
Save $bmp $g "whiteboard.png"

# ── Kernel panic: red banner, stack trace, hex dump, registers ──
$rng = New-Object System.Random(13)
Get-Random -SetSeed 13 | Out-Null
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 14 3 3) (C 255 6 1 1)
Glow $g 960 200 800 (C 30 255 40 40)
$red = C 225 255 70 70
$redDim = C 110 200 60 60
$pale = C 190 240 200 200
# banner
$b = New-Object System.Drawing.SolidBrush((C 235 170 20 20)); $g.FillRectangle($b, 0, 90, $W, 76); $b.Dispose()
$b = New-Object System.Drawing.SolidBrush((C 250 255 235 235)); $g.FillRectangle($b, 140, 118, 520, 20); $b.Dispose()
$b = New-Object System.Drawing.SolidBrush((C 180 255 210 210)); $g.FillRectangle($b, 700, 120, 300, 16); $b.Dispose()
# stack trace: indented frames with addresses
$rowY = 230
for ($i = 0; $i -lt 13; $i++) {
  $ind = 140 + ($i % 4) * 40
  $b = New-Object System.Drawing.SolidBrush($redDim); $g.FillRectangle($b, $ind, $rowY, 150, 12); $b.Dispose()
  DashRow $g ($ind + 180) $rowY $rng.Next(280, 620) $(if ($i -eq 2) { $red } else { $pale }) 12
  $rowY += 34
}
# hex dump grid, right
$hx = 1150; $hy = 250
for ($r = 0; $r -lt 14; $r++) {
  $b = New-Object System.Drawing.SolidBrush($redDim); $g.FillRectangle($b, $hx, ($hy + $r * 32), 110, 11); $b.Dispose()
  for ($c2 = 0; $c2 -lt 12; $c2++) {
    $b = New-Object System.Drawing.SolidBrush((C $rng.Next(70, 190) 235 190 190))
    $g.FillRectangle($b, ($hx + 140 + $c2 * 44), ($hy + $r * 32), 30, 11); $b.Dispose()
  }
}
# register table, bottom left
$b = New-Object System.Drawing.SolidBrush((C 60 255 60 60)); $g.FillRectangle($b, 140, 740, 700, 230); $b.Dispose()
$pen = New-Object System.Drawing.Pen($redDim, 2); $g.DrawRectangle($pen, 140, 740, 700, 230); $pen.Dispose()
for ($r = 0; $r -lt 5; $r++) {
  for ($c2 = 0; $c2 -lt 3; $c2++) {
    $rx = 170 + $c2 * 230; $ry = 770 + $r * 40
    $b = New-Object System.Drawing.SolidBrush($red); $g.FillRectangle($b, $rx, $ry, 54, 11); $b.Dispose()
    $b = New-Object System.Drawing.SolidBrush($pale); $g.FillRectangle($b, ($rx + 64), $ry, 120, 11); $b.Dispose()
  }
}
EdgeFade $g "top" 90 90; EdgeFade $g "bottom" 110 110; EdgeFade $g "left" 120 90; EdgeFade $g "right" 110 90
Save $bmp $g "panic.png"

# ── E-Ink: grayscale page, margins, page number, no colour ──
$rng = New-Object System.Random(7)
Get-Random -SetSeed 77 | Out-Null
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 238 237 233) (C 255 228 227 222)
# page sheet with a soft edge
$b = New-Object System.Drawing.SolidBrush((C 40 120 120 116)); $g.FillRectangle($b, 1096, 96, 700, 900); $b.Dispose()
$b = New-Object System.Drawing.SolidBrush((C 255 246 245 241)); $g.FillRectangle($b, 1090, 90, 700, 900); $b.Dispose()
$pen = New-Object System.Drawing.Pen((C 60 120 120 116), 1); $g.DrawRectangle($pen, 1090, 90, 700, 900); $pen.Dispose()
# running head + rule
$b = New-Object System.Drawing.SolidBrush((C 120 90 90 88)); $g.FillRectangle($b, 1140, 140, 180, 10); $b.Dispose()
$pen = New-Object System.Drawing.Pen((C 70 120 120 116), 1); $g.DrawLine($pen, 1140, 168, 1740, 168); $pen.Dispose()
# body text: justified paragraphs
$rowY = 210
$para = 0
while ($rowY -lt 900) {
  $indent = if ($para -eq 0) { 30 } else { 0 }
  DashRow $g (1140 + $indent) $rowY (560 - $indent) (C 200 58 58 56) 11
  $rowY += 30
  $para++
  if ($para -gt $rng.Next(5, 10)) { $para = 0; $rowY += 18 }
}
# page number
$b = New-Object System.Drawing.SolidBrush((C 140 90 90 88)); $g.FillRectangle($b, 1400, 940, 60, 10); $b.Dispose()
# progress bar at the foot of the screen
$pen = New-Object System.Drawing.Pen((C 90 120 120 116), 1); $g.DrawRectangle($pen, 1090, 1020, 700, 12); $pen.Dispose()
$b = New-Object System.Drawing.SolidBrush((C 170 90 90 88)); $g.FillRectangle($b, 1091, 1021, 430, 11); $b.Dispose()
# left column: a second, dimmer page for depth
$b = New-Object System.Drawing.SolidBrush((C 90 246 245 241)); $g.FillRectangle($b, 130, 150, 620, 800); $b.Dispose()
$rowY = 200
while ($rowY -lt 900) {
  DashRow $g 170 $rowY 520 (C 60 58 58 56) 10
  $rowY += 30
}
# paper grain
for ($i = 0; $i -lt 2200; $i++) {
  $b = New-Object System.Drawing.SolidBrush((C $rng.Next(5, 12) 70 70 68))
  $g.FillRectangle($b, $rng.Next(0, $W), $rng.Next(0, $H), 1, 1); $b.Dispose()
}
Save $bmp $g "eink.png"

# ── Punch card: beige card stock, punched holes, column numbering ──
$rng = New-Object System.Random(1928)
Get-Random -SetSeed 1928 | Out-Null
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 232 223 198) (C 255 222 212 185)
$ink = C 255 60 54 42
$inkDim = C 120 60 54 42
# the card: full-bleed with a clipped top-left corner
$cardPts = New-Object 'System.Drawing.Point[]' 5
$cardPts[0] = New-Object System.Drawing.Point(70, 150)
$cardPts[1] = New-Object System.Drawing.Point(1850, 150)
$cardPts[2] = New-Object System.Drawing.Point(1850, 930)
$cardPts[3] = New-Object System.Drawing.Point(70, 930)
$cardPts[4] = New-Object System.Drawing.Point(70, 200)
$b = New-Object System.Drawing.SolidBrush((C 60 90 80 60)); $g.FillPolygon($b, $cardPts); $b.Dispose()
$corner = New-Object 'System.Drawing.Point[]' 5
$corner[0] = New-Object System.Drawing.Point(120, 140)
$corner[1] = New-Object System.Drawing.Point(1840, 140)
$corner[2] = New-Object System.Drawing.Point(1840, 920)
$corner[3] = New-Object System.Drawing.Point(60, 920)
$corner[4] = New-Object System.Drawing.Point(60, 196)
$b = New-Object System.Drawing.SolidBrush((C 255 240 232 208)); $g.FillPolygon($b, $corner); $b.Dispose()
$pen = New-Object System.Drawing.Pen($inkDim, 2); $g.DrawPolygon($pen, $corner); $pen.Dispose()
# printed row digits down the left, column numbers along the top
for ($r = 0; $r -lt 12; $r++) {
  $b = New-Object System.Drawing.SolidBrush($inkDim)
  $g.FillRectangle($b, 84, (250 + $r * 56), 18, 12); $b.Dispose()
}
# punched holes: 12 rows x 40 columns, sparse
for ($col = 0; $col -lt 40; $col++) {
  $cx3 = 150 + $col * 42
  # column number strip
  $b = New-Object System.Drawing.SolidBrush((C 70 60 54 42))
  $g.FillRectangle($b, ($cx3 + 4), 190, 20, 9); $b.Dispose()
  for ($r = 0; $r -lt 12; $r++) {
    if ($rng.NextDouble() -lt 0.17) {
      $hy = 246 + $r * 56
      $b = New-Object System.Drawing.SolidBrush((C 255 44 38 30)); $g.FillRectangle($b, $cx3, $hy, 26, 34); $b.Dispose()
      $b = New-Object System.Drawing.SolidBrush((C 60 255 250 235)); $g.FillRectangle($b, ($cx3 + 2), ($hy + 2), 22, 5); $b.Dispose()
    } else {
      $pen = New-Object System.Drawing.Pen((C 26 60 54 42), 1)
      $g.DrawRectangle($pen, $cx3, (246 + $r * 56), 26, 34); $pen.Dispose()
    }
  }
}
# interpreted text printed along the card's top edge
DashRow $g 150 158 900 (C 190 60 54 42) 12
EdgeFade $g "top" 80 20; EdgeFade $g "bottom" 90 24; EdgeFade $g "left" 100 16; EdgeFade $g "right" 100 16
Save $bmp $g "punchcard.png"

# ── Mainframe: 3270 green screen, rigid field grid, status line ──
$rng = New-Object System.Random(3270)
Get-Random -SetSeed 3270 | Out-Null
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 0 20 0) (C 255 0 10 0)
Glow $g 960 500 900 (C 20 60 255 60)
$grn = C 225 60 240 60
$grnDim = C 110 40 170 40
$wht = C 220 220 240 220
$cyan = C 200 90 230 230
$cell = 22
# title line + underline rule
DashRow $g 160 120 520 $wht 13
$pen = New-Object System.Drawing.Pen($grnDim, 2); $g.DrawLine($pen, 160, 158, 1760, 158); $pen.Dispose()
# rigid label/value field pairs in two columns
for ($col = 0; $col -lt 2; $col++) {
  for ($r = 0; $r -lt 14; $r++) {
    $fx = 180 + $col * 800
    $fy = 210 + $r * 44
    # protected label (dim green)
    $b = New-Object System.Drawing.SolidBrush($grnDim)
    $g.FillRectangle($b, $fx, $fy, ($rng.Next(5, 10) * $cell), 13); $b.Dispose()
    # unprotected input field: underscored run in bright green or cyan
    $vw = $rng.Next(6, 14) * $cell
    $b = New-Object System.Drawing.SolidBrush($(if ($rng.NextDouble() -lt 0.25) { $cyan } else { $grn }))
    $g.FillRectangle($b, ($fx + 260), $fy, $vw, 13); $b.Dispose()
    $pen = New-Object System.Drawing.Pen((C 60 40 170 40), 1)
    $g.DrawLine($pen, ($fx + 260), ($fy + 20), ($fx + 260 + 14 * $cell), ($fy + 20)); $pen.Dispose()
  }
}
# block cursor sitting in a field
$b = New-Object System.Drawing.SolidBrush($grn); $g.FillRectangle($b, 700, 386, 18, 24); $b.Dispose()
# status line: position indicator + PF key legend
$pen = New-Object System.Drawing.Pen($grnDim, 2); $g.DrawLine($pen, 160, 900, 1760, 900); $pen.Dispose()
$b = New-Object System.Drawing.SolidBrush($wht); $g.FillRectangle($b, 160, 926, 90, 13); $b.Dispose()
foreach ($i in 0..5) {
  $b = New-Object System.Drawing.SolidBrush($cyan); $g.FillRectangle($b, (330 + $i * 230), 926, 44, 13); $b.Dispose()
  $b = New-Object System.Drawing.SolidBrush($grnDim); $g.FillRectangle($b, (384 + $i * 230), 926, 130, 13); $b.Dispose()
}
# faint scanlines
for ($y = 0; $y -lt $H; $y += 3) {
  $pen = New-Object System.Drawing.Pen((C 26 0 0 0), 1); $g.DrawLine($pen, 0, $y, $W, $y); $pen.Dispose()
}
EdgeFade $g "top" 100 100; EdgeFade $g "bottom" 100 100; EdgeFade $g "left" 120 90; EdgeFade $g "right" 120 90
Save $bmp $g "mainframe.png"

# ── Rubber duck: soft yellow, one duck, ripples, bubbles ──
$rng = New-Object System.Random(42)
Get-Random -SetSeed 424 | Out-Null
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 253 244 214) (C 255 246 232 190)
Glow $g 1380 560 520 (C 50 255 205 90)
# water band with ripple ellipses
$b = New-Object System.Drawing.SolidBrush((C 90 120 190 210)); $g.FillRectangle($b, 0, 760, $W, 320); $b.Dispose()
foreach ($rip in @(@(1380, 800, 520, 90), @(1380, 800, 380, 66), @(1380, 800, 250, 44), @(700, 880, 300, 54), @(420, 960, 220, 40))) {
  $pen = New-Object System.Drawing.Pen((C 90 90 160 190), 3)
  $g.DrawEllipse($pen, ($rip[0] - $rip[2]), ($rip[1] - $rip[3]), (2 * $rip[2]), (2 * $rip[3])); $pen.Dispose()
}
# the duck: body, head, beak, eye, wing
$dx = 1380; $dy = 700
$b = New-Object System.Drawing.SolidBrush((C 255 250 196 40))
$g.FillEllipse($b, ($dx - 200), ($dy - 60), 400, 210)          # body
$g.FillEllipse($b, ($dx + 20), ($dy - 230), 210, 200)          # head
# tail wedge
$tail = New-Object 'System.Drawing.Point[]' 3
$tail[0] = New-Object System.Drawing.Point(($dx - 190), ($dy - 20))
$tail[1] = New-Object System.Drawing.Point(($dx - 300), ($dy - 120))
$tail[2] = New-Object System.Drawing.Point(($dx - 150), ($dy + 20))
$g.FillPolygon($b, $tail)
$b.Dispose()
# wing
$b = New-Object System.Drawing.SolidBrush((C 255 238 176 26)); $g.FillEllipse($b, ($dx - 130), ($dy - 20), 210, 130); $b.Dispose()
$pen = New-Object System.Drawing.Pen((C 160 205 145 20), 4); $g.DrawEllipse($pen, ($dx - 130), ($dy - 20), 210, 130); $pen.Dispose()
# beak
$b = New-Object System.Drawing.SolidBrush((C 255 240 140 40))
$beak = New-Object 'System.Drawing.Point[]' 4
$beak[0] = New-Object System.Drawing.Point(($dx + 205), ($dy - 150))
$beak[1] = New-Object System.Drawing.Point(($dx + 320), ($dy - 132))
$beak[2] = New-Object System.Drawing.Point(($dx + 318), ($dy - 104))
$beak[3] = New-Object System.Drawing.Point(($dx + 200), ($dy - 96))
$g.FillPolygon($b, $beak); $b.Dispose()
$pen = New-Object System.Drawing.Pen((C 150 200 100 20), 3); $g.DrawLine($pen, ($dx + 214), ($dy - 122), ($dx + 316), ($dy - 118)); $pen.Dispose()
# eye
$b = New-Object System.Drawing.SolidBrush((C 255 255 255 255)); $g.FillEllipse($b, ($dx + 108), ($dy - 190), 52, 52); $b.Dispose()
$b = New-Object System.Drawing.SolidBrush((C 255 40 34 26)); $g.FillEllipse($b, ($dx + 124), ($dy - 176), 26, 26); $b.Dispose()
$b = New-Object System.Drawing.SolidBrush((C 255 255 255 255)); $g.FillEllipse($b, ($dx + 130), ($dy - 172), 9, 9); $b.Dispose()
# bubbles
for ($i = 0; $i -lt 26; $i++) {
  $sz = $rng.Next(10, 40)
  $pen = New-Object System.Drawing.Pen((C $rng.Next(50, 130) 255 255 255), 3)
  $g.DrawEllipse($pen, $rng.Next(120, 1200), $rng.Next(200, 900), $sz, $sz); $pen.Dispose()
}
EdgeFade $g "top" 80 18; EdgeFade $g "bottom" 90 26; EdgeFade $g "left" 100 16; EdgeFade $g "right" 100 16
Save $bmp $g "duck.png"

# ── Zenburn: almost nothing — soft muted bands, low contrast ──
$rng = New-Object System.Random(2003)
Get-Random -SetSeed 20033 | Out-Null
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 68 68 68) (C 255 54 54 54)
foreach ($blob in @(@(500, 300, 560, 140, 160, 140), @(1400, 420, 620, 130, 145, 130), @(900, 860, 700, 150, 140, 120), @(1700, 900, 480, 130, 150, 150))) {
  Glow $g $blob[0] $blob[1] $blob[2] (C 30 $blob[3] $blob[4] $blob[5])
}
# very soft horizontal bands
for ($i = 0; $i -lt 7; $i++) {
  $by = 120 + $i * 140
  $rect = New-Object System.Drawing.Rectangle(0, $by, $W, 70)
  $br = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, (C 0 220 220 200), (C 12 220 220 200), 90.0)
  $g.FillRectangle($br, $rect); $br.Dispose()
}
# grain
for ($i = 0; $i -lt 3000; $i++) {
  $b = New-Object System.Drawing.SolidBrush((C $rng.Next(5, 14) 220 220 200))
  $g.FillRectangle($b, $rng.Next(0, $W), $rng.Next(0, $H), 1, 1); $b.Dispose()
}
EdgeFade $g "top" 140 60; EdgeFade $g "bottom" 140 60; EdgeFade $g "left" 160 50; EdgeFade $g "right" 160 50
Save $bmp $g "zenburn.png"

# ── Containers: deep blue, stacked boxes, whale silhouette, waves ──
$rng = New-Object System.Random(2013)
Get-Random -SetSeed 2013 | Out-Null
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 10 40 66) (C 255 5 22 38)
Glow $g 1200 460 700 (C 30 36 150 237)
$blue = C 225 36 150 237
$blueLite = C 200 120 200 250
# wave lines across the lower third
foreach ($wy in @(820, 880, 940, 1000)) {
  $path = New-Object System.Drawing.Drawing2D.GraphicsPath
  $path.AddBezier(-100, $wy, 400, ($wy - 40), 1000, ($wy + 40), 2020, ($wy - 20))
  $pen = New-Object System.Drawing.Pen((C 60 90 180 240), 3); $g.DrawPath($pen, $path); $pen.Dispose(); $path.Dispose()
}
# whale silhouette carrying the stack
$whale = New-Object System.Drawing.Drawing2D.GraphicsPath
$whale.AddBezier(520, 760, 700, 640, 1500, 640, 1660, 740)
$whale.AddBezier(1660, 740, 1700, 770, 1660, 800, 1560, 812)
$whale.AddLine(1560, 812, 640, 812)
$whale.AddBezier(640, 812, 540, 812, 500, 790, 520, 760)
$b = New-Object System.Drawing.SolidBrush((C 190 22 96 160)); $g.FillPath($b, $whale); $b.Dispose()
$pen = New-Object System.Drawing.Pen($blue, 3); $g.DrawPath($pen, $whale); $pen.Dispose(); $whale.Dispose()
# tail fluke
$fluke = New-Object 'System.Drawing.Point[]' 4
$fluke[0] = New-Object System.Drawing.Point(520, 760)
$fluke[1] = New-Object System.Drawing.Point(410, 660)
$fluke[2] = New-Object System.Drawing.Point(440, 780)
$fluke[3] = New-Object System.Drawing.Point(360, 800)
$b = New-Object System.Drawing.SolidBrush((C 190 22 96 160)); $g.FillPolygon($b, $fluke); $b.Dispose()
$pen = New-Object System.Drawing.Pen($blue, 3); $g.DrawPolygon($pen, $fluke); $pen.Dispose()
# spout
foreach ($sp in @(@(1560, 620, 40), @(1600, 560, 30), @(1540, 540, 22))) {
  $pen = New-Object System.Drawing.Pen((C 120 140 210 250), 4)
  $g.DrawEllipse($pen, $sp[0], $sp[1], $sp[2], $sp[2]); $pen.Dispose()
}
# eye
$b = New-Object System.Drawing.SolidBrush((C 235 210 235 255)); $g.FillEllipse($b, 1580, 700, 22, 22); $b.Dispose()
# stacked containers on the back: rows of rounded boxes with lid stripes
$stack = @(@(640, 560, 5), @(700, 470, 4), @(760, 380, 3), @(820, 290, 2))
foreach ($row in $stack) {
  for ($i = 0; $i -lt $row[2]; $i++) {
    $bx = $row[0] + $i * 190
    $path = RoundRect $bx $row[1] 170 88 10
    $cc = @(@(36, 150, 237), @(60, 180, 250), @(28, 120, 200), @(90, 200, 255))[($i + $row[2]) % 4]
    $b = New-Object System.Drawing.SolidBrush((C 235 $cc[0] $cc[1] $cc[2])); $g.FillPath($b, $path); $b.Dispose()
    $pen = New-Object System.Drawing.Pen((C 200 12 60 110), 2); $g.DrawPath($pen, $path); $pen.Dispose(); $path.Dispose()
    # corrugation lines
    for ($k = 0; $k -lt 6; $k++) {
      $pen = New-Object System.Drawing.Pen((C 70 10 50 90), 3)
      $g.DrawLine($pen, ($bx + 20 + $k * 26), ($row[1] + 12), ($bx + 20 + $k * 26), ($row[1] + 76)); $pen.Dispose()
    }
  }
}
EdgeFade $g "top" 110 110; EdgeFade $g "bottom" 110 110; EdgeFade $g "left" 120 100; EdgeFade $g "right" 120 100
Save $bmp $g "containers.png"

# ── Helm: heptagon wheel, node hexes, pod dots, links ──
$rng = New-Object System.Random(2014)
Get-Random -SetSeed 20144 | Out-Null
$bmp, $g = New-Canvas
Fill-Vertical $g (C 255 12 26 62) (C 255 6 14 36)
Glow $g 1330 540 640 (C 34 50 108 229)
$k8 = C 230 90 150 250
$k8Dim = C 100 60 110 200
# the wheel: heptagon with seven spokes and a hub
$cx = 1330; $cy = 540; $r = 330
$hept = New-Object 'System.Drawing.Point[]' 7
for ($k = 0; $k -lt 7; $k++) {
  $ang = ($k / 7.0) * 2 * [math]::PI - [math]::PI / 2
  $hept[$k] = New-Object System.Drawing.Point([int]($cx + $r * [math]::Cos($ang)), [int]($cy + $r * [math]::Sin($ang)))
}
$b = New-Object System.Drawing.SolidBrush((C 40 50 108 229)); $g.FillPolygon($b, $hept); $b.Dispose()
$pen = New-Object System.Drawing.Pen($k8, 8); $g.DrawPolygon($pen, $hept); $pen.Dispose()
for ($k = 0; $k -lt 7; $k++) {
  $ang = ($k / 7.0) * 2 * [math]::PI - [math]::PI / 2 + 0.449
  $pen = New-Object System.Drawing.Pen($k8, 12)
  $g.DrawLine($pen, ($cx + [int](70 * [math]::Cos($ang))), ($cy + [int](70 * [math]::Sin($ang))), ($cx + [int](250 * [math]::Cos($ang))), ($cy + [int](250 * [math]::Sin($ang)))); $pen.Dispose()
}
$pen = New-Object System.Drawing.Pen($k8, 10); $g.DrawEllipse($pen, ($cx - 78), ($cy - 78), 156, 156); $pen.Dispose()
# node hexes around the wheel, linked to it
foreach ($nd in @(@(360, 300), @(300, 700), @(700, 880), @(760, 220))) {
  $pen = New-Object System.Drawing.Pen($k8Dim, 2)
  $g.DrawLine($pen, $nd[0], $nd[1], $cx, $cy); $pen.Dispose()
  $hex = New-Object 'System.Drawing.Point[]' 6
  for ($k = 0; $k -lt 6; $k++) {
    $ang = ($k * 60 + 30) * [math]::PI / 180
    $hex[$k] = New-Object System.Drawing.Point([int]($nd[0] + 96 * [math]::Cos($ang)), [int]($nd[1] + 96 * [math]::Sin($ang)))
  }
  $b = New-Object System.Drawing.SolidBrush((C 200 10 22 52)); $g.FillPolygon($b, $hex); $b.Dispose()
  $pen = New-Object System.Drawing.Pen($k8, 4); $g.DrawPolygon($pen, $hex); $pen.Dispose()
  # pods inside each node
  for ($p = 0; $p -lt 4; $p++) {
    $b = New-Object System.Drawing.SolidBrush((C $(if ($rng.NextDouble() -lt 0.3) { 90 } else { 220 }) 90 150 250))
    $g.FillEllipse($b, ($nd[0] - 44 + ($p % 2) * 52), ($nd[1] - 30 + [int]($p / 2) * 46), 32, 32); $b.Dispose()
  }
}
EdgeFade $g "top" 110 110; EdgeFade $g "bottom" 110 110; EdgeFade $g "left" 120 100; EdgeFade $g "right" 120 100
Save $bmp $g "helm.png"

"done -> $out"
