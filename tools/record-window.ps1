# Record a window to raw frames, for make-gif.mjs to turn into a GIF.
#
# PrintWindow with PW_RENDERFULLCONTENT, which is the only capture that
# works on a WebView2 window — it renders the window's own content rather
# than reading the screen, so it does not matter what is on top of it, and
# nothing of the user's desktop is ever in frame.
#
#   pwsh -File tools/record-window.ps1 -ProcessId 1234 -Seconds 6 -Fps 8
#
# Frames land in the output folder as BGRA, with meta.json describing
# them. Raw rather than PNG so the encoder does not need a PNG decoder.
param(
  [int]$ProcessId = 0,
  [string]$Title = "GTerminal",
  [double]$Seconds = 6,
  [int]$Fps = 8,
  [double]$Scale = 1.0,
  # Canvas size. Leave at 0 to take it from the window at start-up; set it
  # when the window will grow during the recording, so the biggest state
  # is captured 1:1 instead of being shrunk to fit a canvas sized for the
  # smallest one.
  [int]$Width = 0,
  [int]$Height = 0,
  [int]$Quality = 92,
  [string]$Out = "$env:TEMP\gterm-recording"
)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

$sig = @'
[DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint f);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct RECT { public int L,T,R,B; }
'@
$types = Add-Type -MemberDefinition $sig -Name Rec -Namespace GTerm -PassThru
$U = $types | Where-Object { $_.Name -eq 'Rec' }

function Get-Target {
  if ($ProcessId -gt 0) {
    $p = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
  } else {
    $p = Get-Process -ErrorAction SilentlyContinue |
      Where-Object { $_.MainWindowTitle -eq $Title } | Select-Object -First 1
  }
  if (-not $p -or $p.MainWindowHandle -eq 0) { return [IntPtr]::Zero }
  $p.MainWindowHandle
}

$hwnd = Get-Target
if ($hwnd -eq [IntPtr]::Zero) { Write-Error "no window found (pid=$ProcessId title=$Title)" }

$r = New-Object 'GTerm.Rec+RECT'
[void]$U::GetWindowRect($hwnd, [ref]$r)
# The canvas is fixed for the whole recording — every frame of a GIF or a
# video has to be the same size — but the window is not: it gets resized,
# hidden and restored. So the window is measured every frame and drawn
# scaled to fit, centred, rather than assumed to stay the size it started.
# Getting this wrong looks like torn, doubled frames rather than an error.
$canvasW = if ($Width -gt 0) { $Width } else { [int]([math]::Round(($r.R - $r.L) * $Scale)) }
$canvasH = if ($Height -gt 0) { $Height } else { [int]([math]::Round(($r.B - $r.T) * $Scale)) }
if ($canvasW % 2) { $canvasW-- }; if ($canvasH % 2) { $canvasH-- }
$w = $canvasW; $h = $canvasH

Remove-Item $Out -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $Out | Out-Null

$delayMs = [int](1000 / $Fps)
$total = [int]($Seconds * $Fps)
$canvas = New-Object System.Drawing.Bitmap $canvasW, $canvasH
$gCanvas = [System.Drawing.Graphics]::FromImage($canvas)
$gCanvas.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$backdrop = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(18, 18, 20))
$rect = New-Object System.Drawing.Rectangle 0, 0, $canvasW, $canvasH
$jpeg = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
  Where-Object { $_.MimeType -eq 'image/jpeg' }
$jpegParams = New-Object System.Drawing.Imaging.EncoderParameters 1
$jpegParams.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter(
  [System.Drawing.Imaging.Encoder]::Quality, [int64]$Quality)

$src = $null; $gSrc = $null; $srcW = 0; $srcH = 0
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$kept = 0
for ($i = 0; $i -lt $total; $i++) {
  $due = $i * $delayMs
  while ($sw.ElapsedMilliseconds -lt $due) { Start-Sleep -Milliseconds 2 }

  [void]$U::GetWindowRect($hwnd, [ref]$r)
  $ww = $r.R - $r.L; $wh = $r.B - $r.T
  $gCanvas.FillRectangle($backdrop, $rect)

  if ($ww -gt 0 -and $wh -gt 0 -and $U::IsWindowVisible($hwnd)) {
    if ($ww -ne $srcW -or $wh -ne $srcH) {
      if ($gSrc) { $gSrc.Dispose() }; if ($src) { $src.Dispose() }
      $src = New-Object System.Drawing.Bitmap $ww, $wh
      $gSrc = [System.Drawing.Graphics]::FromImage($src)
      $srcW = $ww; $srcH = $wh
    }
    $dc = $gSrc.GetHdc()
    $ok = $U::PrintWindow($hwnd, $dc, 2)   # 2 = PW_RENDERFULLCONTENT
    $gSrc.ReleaseHdc($dc)
    if ($ok) {
      # Fit inside the canvas, keeping the window's own aspect, so a
      # resize reads as the window changing shape rather than the
      # recording jumping.
      $k = [math]::Min($canvasW / $ww, $canvasH / $wh)
      $dw = [int]($ww * $k); $dh = [int]($wh * $k)
      $gCanvas.DrawImage($src, [int](($canvasW - $dw) / 2), [int](($canvasH - $dh) / 2), $dw, $dh)
    }
  }

  $data = $canvas.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
                           [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $bytes = New-Object byte[] ($data.Stride * $canvasH)
  [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
  $canvas.UnlockBits($data)
  [System.IO.File]::WriteAllBytes((Join-Path $Out ("frame-{0:d4}.bgra" -f $kept)), $bytes)
  # A JPEG of the same frame, for the AVI muxer. Cheap here, and it saves
  # the encoder from needing a JPEG encoder of its own.
  $canvas.Save((Join-Path $Out ("frame-{0:d4}.jpg" -f $kept)), $jpeg, $jpegParams)
  $kept++
}
if ($gSrc) { $gSrc.Dispose() }; if ($src) { $src.Dispose() }
$gCanvas.Dispose(); $canvas.Dispose(); $backdrop.Dispose()

@{ width = $w; height = $h; stride = $w * 4; frames = $kept; delayMs = $delayMs } |
  ConvertTo-Json | Set-Content (Join-Path $Out "meta.json")
"recorded $kept frames of ${w}x${h} at ${Fps}fps -> $Out"
