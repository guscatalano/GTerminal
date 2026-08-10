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
# ── the spire: tall thin tower right of center, rings on its crown ──
GradRect $g 1222 470 34 ($H - 470) (C 255 21 14 38) (C 255 9 7 18)
$pen = New-Object System.Drawing.Pen((C 80 120 200 235), 1)
$g.DrawLine($pen, 1222, 470, 1222, 760); $pen.Dispose()
GradRect $g 1214 610 50 26 (C 255 15 10 28) (C 255 11 8 22)
$pen = New-Object System.Drawing.Pen((C 255 9 6 17), 3); $g.DrawLine($pen, 1239, 470, 1239, 420); $pen.Dispose()
$b = New-Object System.Drawing.SolidBrush((C 240 255 90 95)); $g.FillEllipse($b, 1236, 414, 6, 6); $b.Dispose()
Glow $g 1239 417 24 (C 60 255 55 70)
NeonOval $g (1239 - 66) (505 - 14) 132 28 20 235 255
NeonOval $g (1239 - 84) (534 - 17) 168 34 20 235 255
NeonOval $g (1239 - 102) (565 - 20) 204 40 20 235 255

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

"done -> $out"
