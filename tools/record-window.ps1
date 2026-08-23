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
  [double]$Scale = 0.5,
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
$fullW = $r.R - $r.L; $fullH = $r.B - $r.T
$w = [int]([math]::Round($fullW * $Scale)); $h = [int]([math]::Round($fullH * $Scale))
# GIF frames are indexed; even dimensions keep the scaler simple.
if ($w % 2) { $w-- }; if ($h % 2) { $h-- }

Remove-Item $Out -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $Out | Out-Null

$delayMs = [int](1000 / $Fps)
$total = [int]($Seconds * $Fps)
$full = New-Object System.Drawing.Bitmap $fullW, $fullH
$small = New-Object System.Drawing.Bitmap $w, $h
$gFull = [System.Drawing.Graphics]::FromImage($full)
$gSmall = [System.Drawing.Graphics]::FromImage($small)
$gSmall.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$rect = New-Object System.Drawing.Rectangle 0, 0, $w, $h

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$kept = 0
for ($i = 0; $i -lt $total; $i++) {
  $due = $i * $delayMs
  while ($sw.ElapsedMilliseconds -lt $due) { Start-Sleep -Milliseconds 2 }
  $dc = $gFull.GetHdc()
  $ok = $U::PrintWindow($hwnd, $dc, 2)   # 2 = PW_RENDERFULLCONTENT
  $gFull.ReleaseHdc($dc)
  if (-not $ok) { continue }
  $gSmall.DrawImage($full, 0, 0, $w, $h)
  $data = $small.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
                          [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $bytes = New-Object byte[] ($data.Stride * $h)
  [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
  $small.UnlockBits($data)
  [System.IO.File]::WriteAllBytes((Join-Path $Out ("frame-{0:d4}.bgra" -f $kept)), $bytes)
  $kept++
}
$gSmall.Dispose(); $gFull.Dispose(); $small.Dispose(); $full.Dispose()

@{ width = $w; height = $h; stride = $w * 4; frames = $kept; delayMs = $delayMs } |
  ConvertTo-Json | Set-Content (Join-Path $Out "meta.json")
"recorded $kept frames of ${w}x${h} at ${Fps}fps -> $Out"
