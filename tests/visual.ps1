# Visual test: drives a real window through things you can only judge by
# looking, and records the whole run as a GIF.
#
#   npm run test:visual        -> docs/visual/window.gif
#
# Not part of `npm test`: it opens a window, takes over a global hotkey
# for a moment, and takes about half a minute. It is meant to be watched.
#
# Isolated the same way the other suites are — its own LOCALAPPDATA, so
# its daemon, sessions and config never touch the ones you are using. The
# hotkey it claims is deliberately obscure so it cannot fight the one your
# own window has registered.
$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
$exe = Join-Path $repo "src-tauri\target\debug\gterminal.exe"
if (-not (Test-Path $exe)) { Write-Error "build first: cargo build in src-tauri" }

$failures = @()
function Pass { param($n) "PASS $n" }
function Fail { param($n, $d) $script:failures += "${n}: $d" }

$sig = @'
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
'@
$U = (Add-Type -MemberDefinition $sig -Name Vis -Namespace GTerm -PassThru) |
  Where-Object { $_.Name -eq 'Vis' }

$env:LOCALAPPDATA = Join-Path $env:TEMP "gterminal-visual-test"
New-Item -ItemType Directory -Force $env:LOCALAPPDATA | Out-Null
Remove-Item "$env:LOCALAPPDATA\GTerminal" -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force "$env:LOCALAPPDATA\GTerminal" | Out-Null
# Ctrl+Alt+F9: nobody's default, so the test cannot steal the hotkey from
# a window the user is actually using.
Set-Content "$env:LOCALAPPDATA\GTerminal\config.json" `
  '{"grace_minutes":5,"prediction":"off","summon_hotkey":"Control+Alt+F9","close_action":"hide","bell":"none"}'

$app = Start-Process -FilePath $exe -PassThru
$hwnd = [IntPtr]::Zero
foreach ($i in 1..60) {
  Start-Sleep -Milliseconds 500
  $app.Refresh()
  if ($app.MainWindowHandle -ne 0) { $hwnd = $app.MainWindowHandle; break }
}
if ($hwnd -eq [IntPtr]::Zero) { Write-Error "the window never appeared" }
Pass "the window opened"
Start-Sleep -Seconds 6      # let the shell reach its first prompt

$frames = Join-Path $env:TEMP "gterm-visual-frames"
$rec = Start-Process pwsh -PassThru -WindowStyle Hidden -ArgumentList @(
  "-NoProfile", "-File", (Join-Path $repo "tools\record-window.ps1"),
  "-ProcessId", $app.Id, "-Seconds", "20", "-Fps", "6", "-Scale", "0.5", "-Out", $frames
)
Start-Sleep -Seconds 2

# ── resize: the fit path, which decides how many rows the shell gets ──
[void]$U::SetWindowPos($hwnd, [IntPtr]::Zero, 120, 120, 900, 560, 0x0004)
Start-Sleep -Seconds 3
[void]$U::SetWindowPos($hwnd, [IntPtr]::Zero, 120, 120, 1240, 780, 0x0004)
Start-Sleep -Seconds 3
if ($U::IsWindowVisible($hwnd)) { Pass "the window survives being resized" }
else { Fail "resize" "the window vanished during resize" }

# ── close hides to the tray rather than ending the process ──
[void]$U::PostMessage($hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
Start-Sleep -Seconds 3
$app.Refresh()
$alive = $null -ne (Get-Process -Id $app.Id -ErrorAction SilentlyContinue)
if ($alive -and -not $U::IsWindowVisible($hwnd)) { Pass "close hides the window and leaves the app running" }
else { Fail "close-to-tray" "alive=$alive visible=$($U::IsWindowVisible($hwnd))" }

# ── the summon hotkey brings it back from the tray ──
# Global hotkeys go through the OS input queue, so unlike keystrokes
# aimed at the webview these can actually be driven from a test.
$U::keybd_event(0x11, 0, 0, [UIntPtr]::Zero)   # Ctrl down
$U::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)   # Alt down
$U::keybd_event(0x78, 0, 0, [UIntPtr]::Zero)   # F9 down
Start-Sleep -Milliseconds 80
$U::keybd_event(0x78, 0, 2, [UIntPtr]::Zero)
$U::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
$U::keybd_event(0x11, 0, 2, [UIntPtr]::Zero)
Start-Sleep -Seconds 3
if ($U::IsWindowVisible($hwnd)) { Pass "the summon hotkey brings the window back" }
else { Fail "summon" "the window did not come back from the tray" }

Start-Sleep -Seconds 4
$rec.WaitForExit()

# ── encode ──
$outDir = Join-Path $repo "docs\visual"
New-Item -ItemType Directory -Force $outDir | Out-Null
$gif = Join-Path $outDir "window.gif"
node (Join-Path $repo "tools\make-gif.mjs") $frames $gif

# ── cleanup: the app first, then whatever daemon it started ──
try { Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue } catch {}
Start-Sleep -Seconds 1
Get-CimInstance Win32_Process -Filter "Name='gterminal.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -like "*--daemon*" -and $_.ProcessId -ne $app.Id } |
  ForEach-Object {
    # only the daemon this test started: it is the one whose port file
    # lives under the scratch LOCALAPPDATA
    if ((Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue).StartTime -gt $app.StartTime.AddSeconds(-5)) {
      Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
  }
Remove-Item $frames -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$env:LOCALAPPDATA\GTerminal" -Recurse -Force -ErrorAction SilentlyContinue

if ($failures.Count) {
  $failures | ForEach-Object { Write-Host "FAIL $_" -ForegroundColor Red }
  exit 1
}
"all visual tests passed - recording: $gif"
exit 0
