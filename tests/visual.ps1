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
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll")] public static extern short VkKeyScan(char ch);
'@
$U = (Add-Type -MemberDefinition $sig -Name Vis -Namespace GTerm -PassThru) |
  Where-Object { $_.Name -eq 'Vis' }

# keybd_event reaches the webview when the window has focus — unlike
# SendKeys, which never arrives. That is what makes it possible to show
# the terminal actually being used rather than just being resized.
function Key {
  param([byte]$vk, [byte[]]$mods = @(), $holdMs = 25)
  foreach ($m in $mods) { $U::keybd_event($m, 0, 0, [UIntPtr]::Zero) }
  $U::keybd_event($vk, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds $holdMs
  $U::keybd_event($vk, 0, 2, [UIntPtr]::Zero)
  foreach ($m in $mods) { $U::keybd_event($m, 0, 2, [UIntPtr]::Zero) }
  Start-Sleep -Milliseconds $holdMs
}
function Send-Text {
  param([string]$text, $perKeyMs = 45)
  foreach ($ch in $text.ToCharArray()) {
    $scan = $U::VkKeyScan($ch)
    if ($scan -eq -1) { continue }
    $vk = [byte]($scan -band 0xff)
    $mods = @()
    if ($scan -band 0x100) { $mods += [byte]0x10 }   # shift
    Key $vk $mods 20
    Start-Sleep -Milliseconds $perKeyMs
  }
}
$VK_RETURN = 0x0D; $VK_CTRL = 0x11; $VK_SHIFT = 0x10; $VK_ALT = 0x12; $VK_ESC = 0x1B

# A run that dies partway leaves its app behind, and that app keeps the
# global hotkey registered — so the *next* run fails at the summon step
# for a reason that has nothing to do with the code. Each run records the
# pids it started; the next one clears them out first.
#
# Only pids this test wrote down are ever touched. There is no reliable
# way to read another process's environment from PowerShell, so guessing
# which gterminal.exe belongs to a test would risk killing a window the
# user is working in — not a trade worth making for tidiness.
$scratch = Join-Path $env:TEMP "gterminal-visual-test"
$pidFile = Join-Path $env:TEMP "gterminal-visual-pids.txt"
if (Test-Path $pidFile) {
  foreach ($old in (Get-Content $pidFile)) {
    $p = Get-Process -Id ([int]$old) -ErrorAction SilentlyContinue
    if ($p -and $p.ProcessName -eq "gterminal") {
      Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
      "cleaned up a leftover process from a previous run (pid $($p.Id))"
    }
  }
  Start-Sleep -Seconds 1
}

$env:LOCALAPPDATA = $scratch
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
# Write down what we started, including the daemon the app spawned, so a
# crash from here on is cleaned up by the next run rather than left to
# hold the hotkey.
$ourPids = @($app.Id) + @(
  Get-Process gterminal -ErrorAction SilentlyContinue |
    Where-Object { $_.Id -ne $app.Id -and $_.StartTime -ge $app.StartTime.AddSeconds(-2) } |
    Select-Object -ExpandProperty Id
)
Set-Content $pidFile -Value $ourPids
Start-Sleep -Seconds 6      # let the shell reach its first prompt

$frames = Join-Path $env:TEMP "gterm-visual-frames"
$rec = Start-Process pwsh -PassThru -WindowStyle Hidden -ArgumentList @(
  "-NoProfile", "-File", (Join-Path $repo "tools\record-window.ps1"),
  "-ProcessId", $app.Id, "-Seconds", "38", "-Fps", "10", "-Scale", "0.6", "-Out", $frames
)
Start-Sleep -Seconds 2
[void]$U::SetForegroundWindow($hwnd)
Start-Sleep -Milliseconds 800

# ── a command runs, and its output comes back ──
Send-Text "echo hello from a visual test"
Key $VK_RETURN
Start-Sleep -Seconds 2

# ── a failing command, so the block marks have something to mark ──
Send-Text "cmd /c exit 3"
Key $VK_RETURN
Start-Sleep -Seconds 2

# ── split the pane: Ctrl+Shift+D ──
Key 0x44 @([byte]$VK_CTRL, [byte]$VK_SHIFT)   # D
Start-Sleep -Seconds 3
Send-Text "echo second pane"
Key $VK_RETURN
Start-Sleep -Seconds 2

# ── arrange mode: Ctrl+Shift+A, then leave it ──
Key 0x41 @([byte]$VK_CTRL, [byte]$VK_SHIFT)   # A
Start-Sleep -Seconds 3
Key $VK_ESC
Start-Sleep -Seconds 1

# ── find in the terminal: Ctrl+F, type, escape ──
Key 0x46 @([byte]$VK_CTRL)                    # F
Start-Sleep -Milliseconds 800
Send-Text "hello"
Start-Sleep -Seconds 2
Key $VK_ESC
Start-Sleep -Seconds 1

# ── resize: the fit path, which decides how many rows the shell gets ──
[void]$U::SetWindowPos($hwnd, [IntPtr]::Zero, 120, 120, 900, 560, 0x0004)
Start-Sleep -Seconds 2
[void]$U::SetWindowPos($hwnd, [IntPtr]::Zero, 120, 120, 1240, 780, 0x0004)
Start-Sleep -Seconds 2
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

Start-Sleep -Seconds 3
$rec.WaitForExit()

# ── encode ──
$outDir = Join-Path $repo "docs\visual"
New-Item -ItemType Directory -Force $outDir | Out-Null
$avi = Join-Path $outDir "window.avi"
$gif = Join-Path $outDir "window.gif"
node (Join-Path $repo "tools\make-avi.mjs") $frames $avi
node (Join-Path $repo "tools\make-gif.mjs") $frames $gif

# ── cleanup: the app first, then whatever daemon it started ──
try { Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue } catch {}
Start-Sleep -Seconds 1
foreach ($id in $ourPids) {
  Stop-Process -Id ([int]$id) -Force -ErrorAction SilentlyContinue
}
Remove-Item $frames -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$env:LOCALAPPDATA\GTerminal" -Recurse -Force -ErrorAction SilentlyContinue

if ($failures.Count) {
  $failures | ForEach-Object { Write-Host "FAIL $_" -ForegroundColor Red }
  exit 1
}
"all visual tests passed"
"  video: $avi"
"  gif:   $gif"
exit 0
