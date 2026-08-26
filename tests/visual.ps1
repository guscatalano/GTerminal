# Visual tests: drive a real window through things you can only judge by
# looking, and record each scene as a video.
#
#   npm run test:visual               -> docs/visual/*.avi + *.gif
#   npm run test:visual -- -Only cmd  -> just that scene
#   npm run test:visual -- -Yes       -> skip the countdown (unattended)
#   npm run test:visual -- -Force     -> run even if the machine is in use
#   npm run test:visual -- -Exe path  -> a binary built somewhere else
#
# It refuses to start if the keyboard or mouse was touched in the last two
# minutes, because it types into whatever is in front.
#
# Not part of `npm test`: it opens windows, types into them, and takes a
# couple of minutes. It is meant to be watched.
#
# Isolated the way the other suites are — its own LOCALAPPDATA, so its
# daemon, sessions and config never touch the ones you are using. The
# hotkey it claims is deliberately obscure so it cannot fight yours. The
# clipboard is saved and put back, since that one is genuinely shared.
param(
  [switch]$Yes,
  # Run even though someone is using the machine. The scenes are still
  # going to type into their work; this only says you know that.
  [switch]$Force,
  [string]$Only = "",
  [string]$Exe = ""
)
$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
# -Exe runs a binary built somewhere else. Needed when a copy of the app
# is already running from target\debug: Windows locks the file, so cargo
# cannot replace it, and you would silently keep testing the old one.
$exe = if ($Exe) { $Exe } else { Join-Path $repo "src-tauri\target\debug\gterminal.exe" }
if (-not (Test-Path $exe)) { Write-Error "build first: cargo build in src-tauri" }

# Tauri bakes dist\ into the exe when cargo compiles, not when vite
# builds. An exe older than the bundle is running last week's frontend,
# and every assertion about the UI is then meaningless — this cost a
# whole mutation check that "passed" against code it never contained.
$bundle = Get-ChildItem (Join-Path $repo "dist") -Filter *.js -Recurse -ErrorAction SilentlyContinue |
  Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($bundle -and $bundle.LastWriteTime -gt (Get-Item $exe).LastWriteTime) {
  Write-Host "WARNING: $exe predates dist\$($bundle.Name) — run cargo build, or you are testing stale UI code." -ForegroundColor Yellow
}
# A dev-profile binary from plain `cargo build` does not carry the UI at
# all: tauri.conf.json points it at devUrl, so it loads the frontend from
# the vite dev server. With no server listening the window comes up blank
# and every scene fails for a reason that has nothing to do with the app.
# `npm run tauri build -- --debug --no-bundle` embeds it instead.
if (-not (Get-NetTCPConnection -State Listen -LocalPort 1420 -ErrorAction SilentlyContinue)) {
  Write-Host "  note: nothing is serving on :1420. If this binary came from plain 'cargo build'," -ForegroundColor DarkYellow
  Write-Host "        its window will be blank — use a 'tauri build --debug' binary via -Exe." -ForegroundColor DarkYellow
}

Add-Type -AssemblyName System.Drawing
$failures = @()
function Pass { param($n) Write-Host "PASS $n" -ForegroundColor Green }
function Fail { param($n, $d) $script:failures += "${n}: $d"; Write-Host "FAIL ${n}: $d" -ForegroundColor Red }

# A countdown only protects someone who is watching this terminal. Ask
# Windows when the keyboard or mouse was last touched instead: if the
# answer is "just now", someone is working, and taking the foreground for
# two minutes would type test commands into whatever they have open. -Yes
# means unattended, which is a promise about the runner, not about the
# machine — so it does not get to skip this. -Force does.
#
# The gate itself lives in lib/attended.ps1 so that one-off probes share
# it rather than each quietly going without.
. "$PSScriptRoot\lib\attended.ps1"
Assert-Unattended -Force:$Force -What "The visual suite"
# The app this suite starts inherits our console state, including whether
# Ctrl+C is ignored - and with it ignored, nothing any scene starts can be
# interrupted. See tests/lib/attended.ps1.
$null = Enable-CtrlCHandling

# A locked workstation cannot be driven, and fails in a way that reads as
# a broken app. Synthetic keystrokes go to the secure desktop while
# PrintWindow still captures the window perfectly, so every scene reports
# the same thing: the window is there, and nothing you typed ever ran.
# That is indistinguishable from a terminal that draws but ignores input,
# which is a real bug this suite exists to catch - so it has to say which
# one it is looking at rather than leaving someone to guess.
if (Get-Process LogonUI -ErrorAction SilentlyContinue) {
  Write-Host "The workstation is locked. Synthetic input goes to the lock screen," -ForegroundColor Red
  Write-Host "so every scene here would fail for a reason that is not the app's." -ForegroundColor Red
  Write-Host "Sign in and run it again." -ForegroundColor Red
  exit 2
}

# This test takes the foreground and types into whatever has focus. If
# someone is using the machine, their typing lands in the recording and
# the test's keystrokes land in their work — both ruined, with no warning
# beyond a window jumping to the front. So: say so, and give them time.
if (-not $Yes) {
  Write-Host ""
  Write-Host "  This takes over the keyboard and the foreground window for a" -ForegroundColor Yellow
  Write-Host "  couple of minutes, and uses the clipboard (saved and put back)." -ForegroundColor Yellow
  Write-Host "  Do not use the machine while it runs." -ForegroundColor Yellow
  Write-Host ""
  foreach ($s in 5..1) {
    Write-Host "`r  starting in $s - press Ctrl+C to cancel " -NoNewline -ForegroundColor Yellow
    Start-Sleep -Seconds 1
  }
  Write-Host "`r  starting                                   "
}

# Each scene runs in its own process.
#
# Run back to back in one process, the tray scene failed to summon every
# time, while passing on its own — through five different theories
# (polling, retries, a private hotkey, leftover processes, stuck
# modifiers), none of which held. Whatever accumulates across four app
# launches and thousands of synthetic keystrokes in a single session, a
# fresh process does not inherit it. Isolation is cheaper than the next
# five theories, and scenes are independent by nature anyway.
$scenes = @("pwsh", "paste", "cmd", "switch", "restore", "restore-none", "restore-zero", "restore-again", "copy", "hover", "clipboard", "cliphist", "tui", "multiwindow", "twowindows", "preview", "movetab", "lastfocused", "vim", "copilot", "copilot-mcp", "ctrlc", "altscreen", "tui-bg", "decrqm", "tray")
if (-not $Only) {
  $bad = 0
  foreach ($s in $scenes) {
    Write-Host ""
    Write-Host "── scene: $s ──" -ForegroundColor Cyan
    # -Force on the child: the idle check already ran here, and by now the
    # only thing touching the keyboard is this test.
    & pwsh -NoProfile -File $PSCommandPath -Yes -Force -Only $s -Exe $exe
    if ($LASTEXITCODE -ne 0) { $bad++ }
  }
  Write-Host ""
  Get-ChildItem (Join-Path $repo "docs\visual") -Filter *.avi -ErrorAction SilentlyContinue |
    ForEach-Object { "  {0,-14} {1,6:n1} MB" -f $_.Name, ($_.Length / 1MB) }
  if ($bad) { Write-Host "$bad scene(s) failed" -ForegroundColor Red; exit 1 }
  "all visual tests passed"
  exit 0
}

$sig = @'
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll")] public static extern short VkKeyScan(char ch);
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr e);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool GetLayeredWindowAttributes(IntPtr h, out uint key, out byte alpha, out uint flags);
[DllImport("user32.dll", EntryPoint="GetWindowLongPtrW")] public static extern IntPtr GetWindowLongPtr(IntPtr h, int index);
[DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr l);
[DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr h, out int procId);
public delegate bool EnumWindowsProc(IntPtr h, IntPtr l);
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct RECT { public int L,T,R,B; }
'@
$U = (Add-Type -MemberDefinition $sig -Name Vis -Namespace GTerm -PassThru) |
  Where-Object { $_.Name -eq 'Vis' }

# keybd_event reaches the webview when the window has focus — unlike
# SendKeys, which never arrives. That is what makes it possible to show
# the terminal being used rather than just being resized.
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
  param([string]$text, $perKeyMs = 40)
  foreach ($ch in $text.ToCharArray()) {
    $scan = $U::VkKeyScan($ch)
    if ($scan -eq -1) { continue }
    $mods = @()
    if ($scan -band 0x100) { $mods += [byte]0x10 }   # shift
    Key ([byte]($scan -band 0xff)) $mods 18
    Start-Sleep -Milliseconds $perKeyMs
  }
}
function Run-Cmd { param([string]$text, $settle = 2) Send-Text $text; Key 0x0D; Start-Sleep -Seconds $settle }

# Force every modifier up. Typing quotes, parentheses and pipes presses
# Shift hundreds of times, and one missed key-up leaves it logically held
# for the rest of the session — after which Ctrl+Alt+F8 is delivered as
# Ctrl+Alt+Shift+F8 and matches no registered hotkey at all. The symptom
# is a summon that works alone and fails after other scenes, which reads
# as flakiness in the app rather than in the keyboard state.
function Release-Modifiers {
  foreach ($vk in 0x10, 0x11, 0x12, 0x5B, 0x5C, 0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5) {
    $U::keybd_event([byte]$vk, 0, 2, [UIntPtr]::Zero)
  }
  Start-Sleep -Milliseconds 200
}

# Focusing the window is not the same as focusing the terminal inside
# it. Most shortcuts — Ctrl+V among them — are handled by xterm's key
# handler, which only sees keys when the pane has focus; with only
# SetForegroundWindow they go nowhere and the scene records an untouched
# prompt. A click in the middle of the terminal is what actually puts
# focus where the keys are read.
# A click at a point inside the window, in window coordinates.
function Drag {
  param($hwnd, $x1, $y1, $x2, $y2)
  $r = New-Object 'GTerm.Vis+RECT'
  [void]$U::GetWindowRect($hwnd, [ref]$r)
  [void]$U::SetCursorPos(($r.L + $x1), ($r.T + $y1))
  Start-Sleep -Milliseconds 120
  $U::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
  # Moved in steps: one jump to the end looks like a click to a terminal
  # that tracks selection by mousemove.
  foreach ($i in 1..8) {
    $x = $x1 + [int](($x2 - $x1) * $i / 8)
    [void]$U::SetCursorPos(($r.L + $x), ($r.T + $y2))
    Start-Sleep -Milliseconds 60
  }
  $U::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 300
}

# What the window is actually showing, not what it was sent.
#
# Every other assertion in these suites is about bytes: what reached the
# shell, what the daemon holds. A window can be given a correct frame and
# fail to put it on screen — which is what "stuck on old output" was —
# and no byte-level test can see that. PrintWindow renders the window's
# own content, so this works without the window being in front.
# Every window a process has on screen. Process.MainWindowHandle only
# ever names one, which is no use to a test about there being two.
function Wait-Drawn {
  # Waits until the window stops looking like $baseline, and hands back
  # the frame it stopped on. A fixed sleep was wrong in both directions:
  # twelve seconds was plenty for a warm start here and not enough for a
  # cold one on a runner, where a freshly installed CLI took longer and
  # the scene recorded an empty screen as "it never drew".
  param($hwnd, $baseline, [int]$timeoutSec = 75, [double]$floor = 0.01)
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $frame = Capture-Window $hwnd
  while ($sw.Elapsed.TotalSeconds -lt $timeoutSec) {
    if ((Frame-Diff $baseline $frame) -gt $floor) { break }
    Start-Sleep -Seconds 2
    $frame.Dispose()
    $frame = Capture-Window $hwnd
  }
  $script:LastDrawWait = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
  $frame
}

function Click-Effective {
  # Clicks, then checks the screen changed, and clicks again if it did
  # not. Returns whether it ever took.
  #
  # Every restore scene clicks fixed coordinates after a fixed wait, and
  # on a slow runner the dialog is not up yet when the wait expires. The
  # click lands on nothing, the scene carries on, and the *next* click -
  # aimed at a button whose label depends on the first one having worked -
  # does something entirely different. That is how "None, then Restore 0"
  # became "Restore 5", reported as five sessions coming back when the app
  # had done exactly what it was told.
  param($hwnd, [int]$x, [int]$y, [int]$tries = 3, [double]$floor = 0.001, [int]$settleMs = 1200)
  for ($i = 1; $i -le $tries; $i++) {
    $before = Capture-Window $hwnd
    Click $hwnd $x $y
    Start-Sleep -Milliseconds $settleMs
    $after = Capture-Window $hwnd
    $moved = Frame-Diff $before $after -IgnoreBottom 40
    $before.Dispose(); $after.Dispose()
    if ($moved -gt $floor) { $script:LastClickTries = $i; return $true }
  }
  $script:LastClickTries = $tries
  $false
}

function Wait-Settled {
  # Waits until the window stops changing on its own, and hands back the
  # frame it settled on.
  #
  # Drawing is not instant, and a program that has started painting is
  # not finished painting. A control frame taken three seconds after the
  # first pixel moved caught a cold-starting TUI mid-paint and measured
  # 8.32% of the screen changing with nobody touching it - more than any
  # keystroke moved - so every input comparison then failed against its
  # own noise. Measure once it is quiet, or do not measure.
  param($hwnd, [int]$timeoutSec = 45, [double]$quiet = 0.004, [int]$settleMs = 1500)
  $script:LastSettled = $true
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $prev = Capture-Window $hwnd
  while ($sw.Elapsed.TotalSeconds -lt $timeoutSec) {
    Start-Sleep -Milliseconds $settleMs
    $now = Capture-Window $hwnd
    $moved = Frame-Diff $prev $now -IgnoreBottom 40
    $prev.Dispose()
    $prev = $now
    if ($moved -le $quiet) { $script:LastSettled = $true; break }
    $script:LastSettled = $false
  }
  $script:LastSettleWait = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
  $prev
}

function App-Windows {
  param([int]$procId)
  $found = New-Object System.Collections.ArrayList
  $cb = [GTerm.Vis+EnumWindowsProc]{
    param($h, $l)
    if ($U::IsWindowVisible($h)) {
      $owner = 0
      [void]$U::GetWindowThreadProcessId($h, [ref]$owner)
      if ($owner -eq $procId) {
        $r = New-Object 'GTerm.Vis+RECT'
        [void]$U::GetWindowRect($h, [ref]$r)
        # Tooltips and other incidental windows are tiny; a terminal is not.
        if (($r.R - $r.L) -gt 300) { [void]$found.Add($h) }
      }
    }
    return $true
  }
  [void]$U::EnumWindows($cb, [IntPtr]::Zero)
  , @($found)
}

function Capture-Window {
  param($hwnd)
  $r = New-Object 'GTerm.Vis+RECT'
  [void]$U::GetWindowRect($hwnd, [ref]$r)
  $w = $r.R - $r.L
  $h = $r.B - $r.T
  $bmp = New-Object System.Drawing.Bitmap($w, $h)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $dc = $g.GetHdc()
  [void]$U::PrintWindow($hwnd, $dc, 2)   # PW_RENDERFULLCONTENT
  $g.ReleaseHdc($dc)
  $g.Dispose()
  $bmp
}

# The fraction of sampled pixels that differ. Sampled rather than
# exhaustive because a 1280x800 comparison pixel by pixel through
# GetPixel takes longer than the thing being measured; every eighth
# pixel is far more than enough to tell a full-screen repaint from a
# blinking cursor.
function Frame-Diff {
  # IgnoreBottom trims rows off the bottom of the comparison. The status
  # bar lives there and carries a clock, CPU and memory, all of which move
  # on their own every second. Left in, it lends every comparison a small
  # constant change that has nothing to do with what was being tested -
  # enough to pass an assertion about a few letters appearing on screen
  # whether or not they appeared.
  param($a, $b, $step = 8, $tolerance = 24, [int]$IgnoreBottom = 0)
  $w = [Math]::Min($a.Width, $b.Width)
  $h = [Math]::Min($a.Height, $b.Height) - $IgnoreBottom
  if ($h -lt 1) { return 0.0 }
  $diff = 0
  $total = 0
  for ($y = 0; $y -lt $h; $y += $step) {
    for ($x = 0; $x -lt $w; $x += $step) {
      $pa = $a.GetPixel($x, $y)
      $pb = $b.GetPixel($x, $y)
      $total++
      $d = [Math]::Abs($pa.R - $pb.R) + [Math]::Abs($pa.G - $pb.G) + [Math]::Abs($pa.B - $pb.B)
      if ($d -gt $tolerance) { $diff++ }
    }
  }
  if ($total -eq 0) { 0.0 } else { [double]$diff / $total }
}

# What reached the shells, from the daemon's own transcripts. The only
# honest answer to "did the paste arrive": the screen shows the same text
# whether it was pasted, typed, or echoed by something else.
function Transcripts {
  $logs = @(Get-ChildItem "$scratch\GTerminal\history" -Filter *.log -ErrorAction SilentlyContinue)
  ($logs | ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n"
}

function Move-Pointer {
  param($hwnd, $x, $y)
  $r = New-Object 'GTerm.Vis+RECT'
  [void]$U::GetWindowRect($hwnd, [ref]$r)
  [void]$U::SetCursorPos(($r.L + $x), ($r.T + $y))
}

function Right-Click {
  param($hwnd, $x, $y)
  $r = New-Object 'GTerm.Vis+RECT'
  [void]$U::GetWindowRect($hwnd, [ref]$r)
  [void]$U::SetCursorPos(($r.L + $x), ($r.T + $y))
  Start-Sleep -Milliseconds 150
  $U::mouse_event(0x0008, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 60
  $U::mouse_event(0x0010, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 400
}

function Click {
  param($hwnd, $x, $y)
  $r = New-Object 'GTerm.Vis+RECT'
  [void]$U::GetWindowRect($hwnd, [ref]$r)
  [void]$U::SetCursorPos(($r.L + $x), ($r.T + $y))
  Start-Sleep -Milliseconds 120
  $U::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 50
  $U::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 350
}

function Focus-Pane {
  param($hwnd)
  [void]$U::SetForegroundWindow($hwnd)
  Start-Sleep -Milliseconds 500
  $r = New-Object 'GTerm.Vis+RECT'
  [void]$U::GetWindowRect($hwnd, [ref]$r)
  $cx = [int]([math]::Round(($r.L + $r.R) * 0.5))
  $cy = [int]([math]::Round(($r.T + $r.B) * 0.5))
  [void]$U::SetCursorPos($cx, $cy)
  Start-Sleep -Milliseconds 150
  $U::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)   # left down
  Start-Sleep -Milliseconds 60
  $U::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)   # left up
  Start-Sleep -Milliseconds 500
}

# Set-Clipboard opens a window of its own to take ownership of the
# clipboard, which takes the foreground with it — so the keystrokes that
# follow land in this console instead of the app under test, and the
# scene records an untouched prompt. Always hand focus back.
function Set-Clip {
  param([string]$text, $hwnd)
  Set-Clipboard -Value $text
  Start-Sleep -Milliseconds 400
  Focus-Pane $hwnd
}
$VK_RETURN=0x0D; $VK_CTRL=0x11; $VK_SHIFT=0x10; $VK_ESC=0x1B

$scratch = Join-Path $env:TEMP "gterminal-visual-test"
$pidFile = Join-Path $env:TEMP "gterminal-visual-pids.txt"
# A run that dies partway leaves its app alive holding the global hotkey,
# which makes the *next* run fail at the summon step for a reason that has
# nothing to do with the code. Only pids this test wrote down are touched:
# guessing which gterminal.exe belongs to a test risks killing a window
# someone is working in.
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
# Redirecting LOCALAPPDATA moves the daemon, sessions and config, but not
# the WebView2 store: Tauri asks the OS for the known folder, so
# localStorage stayed in the real %LOCALAPPDATA%\com.gus.gterminal — every
# run reading and writing the sidebar state, tab widths and badges of the
# app you actually use. This variable is read by the WebView2 loader
# itself and does move it. It also makes runs deterministic: scenes now
# start from a known UI state instead of inheriting the last run's.
$env:WEBVIEW2_USER_DATA_FOLDER = Join-Path $scratch "webview2"
# Every scene starts its own app, and one scene's leftover would make the
# next scene's launch hand over and exit - the app would never appear,
# for a reason that has nothing to do with what the scene is testing.
$env:GTERMINAL_ALLOW_MULTI = "1"

$savedClipboard = try { Get-Clipboard -Raw } catch { "" }
$RECW = 1280; $RECH = 800
$outDir = Join-Path $repo "docs\visual"
New-Item -ItemType Directory -Force $outDir | Out-Null

function Start-App {
  param([string]$config)
  Remove-Item "$scratch\GTerminal" -Recurse -Force -ErrorAction SilentlyContinue
  # The WebView2 store goes too, so every scene starts from the same UI
  # state. Without this a scene that toggles the sidebar leaves it on for
  # the next run, and a coordinate that worked yesterday clicks into the
  # terminal today.
  Remove-Item $env:WEBVIEW2_USER_DATA_FOLDER -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force "$scratch\GTerminal" | Out-Null
  Set-Content "$scratch\GTerminal\config.json" $config
  $app = Start-Process -FilePath $exe -PassThru
  $hwnd = [IntPtr]::Zero
  foreach ($i in 1..60) {
    Start-Sleep -Milliseconds 500
    $app.Refresh()
    # A handle can exist before the window has been sized — on the first
    # run against a fresh WebView2 store that window is briefly 16x16, and
    # anything clicked by coordinate then lands nowhere.
    if ($app.MainWindowHandle -ne 0) {
      $probe = New-Object 'GTerm.Vis+RECT'
      [void]$U::GetWindowRect($app.MainWindowHandle, [ref]$probe)
      if (($probe.R - $probe.L) -gt 200) { $hwnd = $app.MainWindowHandle; break }
    }
  }
  if ($hwnd -eq [IntPtr]::Zero) { throw "the window never appeared" }
  # Find the daemon by asking which process is listening on the port it
  # wrote, not by guessing from start times. The daemon can come up a
  # second or two after the app, so a time window misses it — and a
  # missed daemon is never cleaned up, which is how a few dozen of them
  # accumulate over an afternoon of test runs.
  $ours = @($app.Id)
  foreach ($i in 1..20) {
    Start-Sleep -Milliseconds 300
    $pf = Join-Path $scratch "GTerminal\daemon.port"
    if (-not (Test-Path $pf)) { continue }
    $prt = 0
    if (-not [int]::TryParse((Get-Content $pf -Raw).Trim(), [ref]$prt)) { continue }
    $own = Get-NetTCPConnection -State Listen -LocalPort $prt -ErrorAction SilentlyContinue |
      Select-Object -First 1 -ExpandProperty OwningProcess
    if ($own) { $ours += [int]$own; break }
  }
  Set-Content $pidFile -Value $ours
  # Pin the size and record a canvas to match, so the busiest state is
  # captured 1:1. Terminal text does not survive being scaled down.
  [void]$U::SetWindowPos($hwnd, [IntPtr]::Zero, 100, 60, $RECW, $RECH, 0x0004)
  Start-Sleep -Seconds 5
  Focus-Pane $hwnd
  [pscustomobject]@{ App = $app; Hwnd = $hwnd; Pids = $ours }
}

# Ask the scratch daemon what it is holding. "Was this session restored?"
# is not a question a screenshot can answer — restoring means *attaching*,
# and only the daemon knows who is attached. Every restore assertion below
# goes through here rather than through pixels.
function Daemon-Sessions {
  $pf = Join-Path $scratch "GTerminal\daemon.port"
  if (-not (Test-Path $pf)) { return @() }
  $port = 0
  if (-not [int]::TryParse((Get-Content $pf -Raw).Trim(), [ref]$port)) { return @() }
  try {
    $c = [System.Net.Sockets.TcpClient]::new("127.0.0.1", $port)
    $w = [System.IO.StreamWriter]::new($c.GetStream()); $w.NewLine = "`n"; $w.AutoFlush = $true
    $rd = [System.IO.StreamReader]::new($c.GetStream())
    $w.WriteLine('{"cmd":"list"}')
    $line = $rd.ReadLine()
    $c.Close()
    return @(($line | ConvertFrom-Json).sessions)
  } catch { return @() }
}

# Sessions for a restore scene to find: a daemon of its own, started before
# the window exists, with N shells already in it.
function Seed-Daemon {
  param([int]$count, [string]$config, [switch]$Typed)
  Remove-Item "$scratch\GTerminal" -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item $env:WEBVIEW2_USER_DATA_FOLDER -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force "$scratch\GTerminal" | Out-Null
  Set-Content "$scratch\GTerminal\config.json" $config
  $d = Start-Process -FilePath $exe -ArgumentList "--daemon" -WindowStyle Hidden -PassThru
  foreach ($i in 1..40) {
    Start-Sleep -Milliseconds 200
    if (Test-Path "$scratch\GTerminal\daemon.port") { break }
  }
  Start-Sleep -Milliseconds 400
  $port = [int](Get-Content "$scratch\GTerminal\daemon.port" -Raw).Trim()
  $ids = @()
  foreach ($i in 1..$count) {
    $c = [System.Net.Sockets.TcpClient]::new("127.0.0.1", $port)
    $w = [System.IO.StreamWriter]::new($c.GetStream()); $w.NewLine = "`n"; $w.AutoFlush = $true
    $rd = [System.IO.StreamReader]::new($c.GetStream())
    $w.WriteLine('{"cmd":"create","cols":100,"rows":30}')
    $newId = ($rd.ReadLine() | ConvertFrom-Json).id
    $ids += $newId
    $c.Close()
    # A session nobody ever typed into is discarded when the daemon
    # restarts - deliberately, so husks do not pile up. A scene that
    # needs its sessions to survive a restart has to use them.
    if ($Typed) {
      $t = [System.Net.Sockets.TcpClient]::new("127.0.0.1", $port)
      $tw = [System.IO.StreamWriter]::new($t.GetStream()); $tw.NewLine = "`n"; $tw.AutoFlush = $true
      $trd = [System.IO.StreamReader]::new($t.GetStream())
      $tw.WriteLine("{""cmd"":""attach"",""id"":$newId}")
      $null = $trd.ReadLine()
      $tw.WriteLine('{"cmd":"write","data":"\u001b[1;1R"}')
      Start-Sleep -Seconds 3
      $tw.WriteLine('{"cmd":"write","data":"echo seeded-' + $newId + '\r"}')
      Start-Sleep -Seconds 2
      $tw.WriteLine('{"cmd":"detach"}')
      Start-Sleep -Milliseconds 300
      $t.Close()
    }
  }
  [pscustomobject]@{ Daemon = $d; Port = $port; Ids = $ids }
}

# Launch the window against a profile that is already seeded — Start-App
# wipes it, which would take the sessions the scene is about with it.
function Start-AppSeeded {
  param($seed)
  $app = Start-Process -FilePath $exe -PassThru
  $hwnd = [IntPtr]::Zero
  foreach ($i in 1..60) {
    Start-Sleep -Milliseconds 400
    $app.Refresh()
    if ($app.MainWindowHandle -ne 0) {
      $probe = New-Object 'GTerm.Vis+RECT'
      [void]$U::GetWindowRect($app.MainWindowHandle, [ref]$probe)
      if (($probe.R - $probe.L) -gt 200) { $hwnd = $app.MainWindowHandle; break }
    }
  }
  if ($hwnd -eq [IntPtr]::Zero) { throw "the window never appeared" }
  $pids = @($app.Id, $seed.Daemon.Id)
  Set-Content $pidFile -Value $pids
  [void]$U::SetWindowPos($hwnd, [IntPtr]::Zero, 100, 60, $RECW, $RECH, 0x0004)
  Start-Sleep -Seconds 2
  [void]$U::SetForegroundWindow($hwnd)
  [pscustomobject]@{ App = $app; Hwnd = $hwnd; Pids = $pids }
}

function Stop-App {
  param($ctx)
  foreach ($id in $ctx.Pids) { Stop-Process -Id ([int]$id) -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Seconds 1
  # A survivor here keeps its global hotkey registered, and the next
  # scene's registration then fails silently — which shows up much later
  # as "the window did not come back" and looks like a bug in summoning.
  $left = @(Get-Process gterminal -ErrorAction SilentlyContinue |
    Where-Object { $ctx.Pids -contains $_.Id })
  if ($left.Count) {
    Write-Host "  note: $($left.Count) process(es) from that scene did not exit" -ForegroundColor DarkYellow
    foreach ($p in $left) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 1
  }
}

function Record-Scene {
  param([string]$name, [int]$seconds, $ctx, [scriptblock]$body)
  $frames = Join-Path $env:TEMP "gterm-visual-frames"
  $rec = Start-Process pwsh -PassThru -WindowStyle Hidden -ArgumentList @(
    "-NoProfile", "-File", (Join-Path $repo "tools\record-window.ps1"),
    "-ProcessId", $ctx.App.Id, "-Seconds", $seconds, "-Fps", "10",
    "-Width", $RECW, "-Height", $RECH, "-Quality", "94", "-Out", $frames
  )
  Start-Sleep -Seconds 1
  & $body
  $rec.WaitForExit()
  $avi = Join-Path $outDir "$name.avi"
  node (Join-Path $repo "tools\make-avi.mjs") $frames $avi
  # The GIF is the paste-into-a-message version: at native size a GIF
  # would be tens of megabytes, since it stores every frame whole.
  node (Join-Path $repo "tools\make-gif.mjs") $frames (Join-Path $outDir "$name.gif") --scale=0.5 --every=2
  Remove-Item $frames -Recurse -Force -ErrorAction SilentlyContinue
}

$baseCfg = '"grace_minutes":5,"prediction":"off","summon_hotkey":"Control+Alt+F9","close_action":"hide","bell":"none"'

# ══ scene: powershell ══════════════════════════════════════════════════
if (-not $Only -or $Only -eq "pwsh") {
  $ctx = Start-App "{$baseCfg,`"default_shell`":`"pwsh`"}"
  Record-Scene "pwsh" 44 $ctx {
    # Quoted: echo is Write-Output, so unquoted words print one per line.
    Run-Cmd 'echo "hello from a visual test"' 2
    # A pipeline with real formatted output, not a toy string.
    Run-Cmd 'Get-ChildItem | Select-Object -First 4 Name, Length' 3
    # A failure, so the command-block mark has something to mark.
    Run-Cmd 'cmd /c exit 3' 2
    # Arithmetic, so the output shares no text with what was typed: the
    # only way to tell "the command ran" from "the characters appeared".
    Run-Cmd 'echo (6*7)' 2
    # Multi-line: a for loop typed across two lines with a continuation.
    Run-Cmd '1..3 | ForEach-Object { "line $_" }' 3
    # Split, use the new pane, arrange, leave.
    Key 0x44 @([byte]$VK_CTRL, [byte]$VK_SHIFT)   # Ctrl+Shift+D
    Start-Sleep -Seconds 3
    Run-Cmd 'echo "second pane"' 2
    Key 0x41 @([byte]$VK_CTRL, [byte]$VK_SHIFT)   # Ctrl+Shift+A: arrange
    Start-Sleep -Seconds 3
    Key $VK_ESC
    Start-Sleep -Seconds 1
    # Find.
    Key 0x46 @([byte]$VK_CTRL)                    # Ctrl+F
    Start-Sleep -Milliseconds 700
    Send-Text "line"
    Start-Sleep -Seconds 2
    Key $VK_ESC
    Start-Sleep -Seconds 2
    $script:pwshOut = Transcripts
  }
  # The scene was only ever asserting that a window existed. What it is
  # actually for is that a shell ran what it was given: 42 from an
  # expression that was never typed, a loop that produced three lines,
  # and a second pane that is its own live session rather than a picture
  # of one.
  if ($pwshOut -match "42") { Pass "pwsh: a typed expression is evaluated, not just echoed" }
  else { Fail "pwsh" "6*7 never produced 42 - the command did not run" }
  if (($pwshOut -match "line 1") -and ($pwshOut -match "line 3")) { Pass "and a loop runs to completion" }
  else { Fail "pwsh" "the ForEach-Object loop did not produce its lines" }
  if ($pwshOut -match "second pane") { Pass "and a split pane is a live shell of its own" }
  else { Fail "pwsh" "the second pane never ran anything" }
  if ($U::IsWindowVisible($ctx.Hwnd)) { Pass "and the window came through it" }
  else { Fail "pwsh" "the window did not survive the scene" }
  Stop-App $ctx
}

# ══ scene: pasting ═════════════════════════════════════════════════════
# The paste warning is the only real protection against a multi-line
# paste running itself, since PSReadLine has no bracketed paste. Worth
# seeing rather than just asserting.
if (-not $Only -or $Only -eq "paste") {
  $ctx = Start-App "{$baseCfg,`"default_shell`":`"pwsh`",`"paste_warn`":true,`"paste_warn_lines`":3}"
  $ph = $ctx.Hwnd
  Record-Scene "paste" 30 $ctx {
    Run-Cmd 'echo paste-scene-ready' 2
    Set-Clip "echo `"first pasted line`"`necho `"second pasted line`"`necho `"third pasted line`"" $ph
    Key 0x56 @([byte]$VK_CTRL)      # Ctrl+V — the warning should appear
    Start-Sleep -Seconds 6          # dwell on the dialog: it is the point
    # Nothing may have reached the shell yet. This is the whole point of
    # the warning: three lines pasted into PSReadLine, which has no
    # bracketed paste, would otherwise be three commands already run.
    $script:beforeConfirm = Transcripts
    Key $VK_RETURN                  # confirm
    Start-Sleep -Seconds 6
    $script:afterConfirm = Transcripts
    # And a small paste, which must go straight in with no dialog.
    Set-Clip 'echo "a short paste"' $ph
    Key 0x56 @([byte]$VK_CTRL)
    Start-Sleep -Seconds 2
    Key $VK_RETURN
    Start-Sleep -Seconds 5
    $script:afterShort = Transcripts
  }
  if ($beforeConfirm -notmatch "first pasted line") { Pass "a multi-line paste waits for the warning" }
  else { Fail "paste-warn" "the paste reached the shell before it was confirmed" }
  if ($afterConfirm -match "first pasted line" -and
      $afterConfirm -match "second pasted line" -and
      $afterConfirm -match "third pasted line") {
    Pass "and all three lines arrive once it is confirmed"
  } else { Fail "paste-warn" "the confirmed paste did not arrive in full" }
  # Ctrl+V itself: the clipboard is read by the app now rather than by the
  # webview, and this is the path that exercises it.
  if ($afterShort -match "a short paste") { Pass "a short paste goes straight in on Ctrl+V" }
  else { Fail "paste-short" "the short paste never reached the shell" }
  if ($U::IsWindowVisible($ctx.Hwnd)) { Pass "and the window came through it" }
  else { Fail "paste" "the window did not survive the scene" }
  Stop-App $ctx
}

# ══ scene: cmd ═════════════════════════════════════════════════════════
# cmd is a different line editor with different echo and its own idea of
# Ctrl+C, and it is the shell most likely to be broken by a change made
# while looking at PowerShell.
if (-not $Only -or $Only -eq "cmd") {
  $ctx = Start-App "{$baseCfg,`"default_shell`":`"cmd`"}"
  Record-Scene "cmd" 30 $ctx {
    Run-Cmd 'echo hello from cmd' 2
    Run-Cmd 'dir /b' 3
    Run-Cmd 'set /a 1234+1' 2
    # A command that does not exist: cmd's error, and a block mark.
    Run-Cmd 'nosuchcommand-xyz' 2
    # Ctrl+C on a half-typed line: it must be abandoned, not run.
    #
    # Arithmetic, because the transcript holds the *echo* of whatever was
    # typed as well as anything it printed. "echo this should never run"
    # is in the transcript either way, so its presence proves nothing;
    # 24681 can only be there if the line ran.
    Send-Text 'set /a 24680+1'
    Start-Sleep -Seconds 1
    Key 0x43 @([byte]$VK_CTRL)      # Ctrl+C
    Start-Sleep -Seconds 1
    Key $VK_RETURN                  # Enter on what must now be an empty line
    Start-Sleep -Seconds 2
    Run-Cmd 'echo still alive' 3
    $script:cmdOut = Transcripts
  }
  if ($cmdOut -match "1235") { Pass "cmd: set /a is evaluated, not just echoed" }
  else { Fail "cmd" "set /a 1234+1 never produced 1235" }
  # The sum is the assertion: absent means the line never ran. Paired
  # with a command afterwards, since "absent" is also true of a shell
  # that died.
  if ($cmdOut -notmatch "24681") { Pass "and Ctrl+C abandons a half-typed line" }
  else { Fail "cmd" "the abandoned line ran anyway - 24681 is in the transcript" }
  if ($cmdOut -match "still alive") { Pass "and the shell still works afterwards" }
  else { Fail "cmd" "the shell was unusable after Ctrl+C" }
  if ($U::IsWindowVisible($ctx.Hwnd)) { Pass "and the window came through it" }
  else { Fail "cmd" "the window did not survive the scene" }
  Stop-App $ctx
}

# ══ scene: switching tabs ══════════════════════════════════════════════
# Clicking a tab and typing straight away used to drop the first
# character: the browser focuses the clicked element after setActive has
# already focused the terminal, so the terminal lost focus for a frame.
# Asserted against the transcript rather than the screen — what reached
# the shell is the question, and a screenshot cannot answer it.
if (-not $Only -or $Only -eq "switch") {
  $ctx = Start-App "{$baseCfg,`"default_shell`":`"pwsh`",`"history_days`":7}"
  $sh = $ctx.Hwnd
  Record-Scene "switch" 42 $ctx {
    Run-Cmd 'echo "first tab"' 2
    Key 0x54 @([byte]$VK_CTRL, [byte]$VK_SHIFT)    # Ctrl+Shift+T
    Start-Sleep -Seconds 5
    Run-Cmd 'echo "second tab"' 2
    # Back to the first tab by clicking it, then type at once. The strip
    # runs along the top with the sidebar off, so the first tab sits just
    # right of the toolbar buttons.
    Click ($sh) 120 33
    Send-Text "echo ZZTOP"
    Key $VK_RETURN
    Start-Sleep -Seconds 3
    # And with the keyboard, which never had the problem.
    Key 0x09 @([byte]$VK_CTRL)                     # Ctrl+Tab
    Send-Text "echo YYTOP"
    Key $VK_RETURN
    Start-Sleep -Seconds 3
    # The sidebar is where the lost keystroke was actually reported: its
    # rows are plain divs, and the tab bar is display:none while it is on,
    # so this is a different click path from the one above, not a repeat.
    Key 0x42 @([byte]$VK_CTRL, [byte]$VK_SHIFT)    # Ctrl+Shift+B
    # Wait for the sidebar to finish opening rather than for two seconds.
    # A click that lands before it is there goes to the terminal instead,
    # and the marker typed afterwards arrives in whichever session was
    # already focused - reported as the sidebar row never being reached,
    # which is true but is the test's doing.
    $null = Wait-Settled ($sh) 20
    $script:sideClicked = Click-Effective ($sh) 100 47    # first row, on its label
    Send-Text "echo XXTOP"
    Key $VK_RETURN
    Start-Sleep -Seconds 3
  }
  # The transcripts are the evidence — what reached the shell, not what
  # was drawn. Each session has its own, so the marker landing in the
  # *first* tab's transcript also proves the click switched tabs at all;
  # a click that missed would leave it in the second tab's, and a test
  # that only searched every file would pass either way.
  $logs = @(Get-ChildItem "$scratch\GTerminal\history" -Filter *.log -ErrorAction SilentlyContinue)
  $texts = @{}
  foreach ($l in $logs) { $texts[$l.FullName] = (Get-Content $l.FullName -Raw) }
  # Which marker landed in which transcript, so a failure says where the
  # keystrokes went rather than only that they went missing.
  foreach ($k in $texts.Keys) {
    $marks = @("first tab", "second tab", "ZZTOP", "ZTOP", "YYTOP", "YTOP", "XXTOP", "XTOP") |
      Where-Object { $texts[$k] -match [regex]::Escape($_) }
    Write-Host ("  transcript {0}: {1}" -f (Split-Path $k -Leaf), ($marks -join ", ")) -ForegroundColor DarkGray
  }
  $firstTab = $texts.Keys | Where-Object { $texts[$_] -match "first tab" } | Select-Object -First 1
  if (-not $firstTab) {
    Fail "switch" "no transcript for the first tab — the scene did not run as expected"
  } else {
    $t = $texts[$firstTab]
    if ($t -match "ZZTOP") { Pass "the first keystroke survives a click-to-switch" }
    elseif ($t -match "ZTOP") { Fail "switch-click" "the leading Z was dropped after clicking the tab" }
    else { Fail "switch-click" "the marker never reached the tab that was clicked" }
    # Ctrl+Tab moved on to the other tab, so its marker belongs there.
    $secondTab = $texts.Keys | Where-Object { $texts[$_] -match "second tab" } | Select-Object -First 1
    $t2 = if ($secondTab) { $texts[$secondTab] } else { "" }
    if ($t2 -match "YYTOP") { Pass "and survives Ctrl+Tab" }
    elseif ($t2 -match "YTOP") { Fail "switch-key" "the leading Y was dropped after Ctrl+Tab" }
    else { Fail "switch-key" "the Ctrl+Tab marker never arrived" }
    # The sidebar click sent focus back to the first tab, so re-read it.
    $t3 = Get-Content $firstTab -Raw
    if (-not $sideClicked) { Fail "switch-side" "the sidebar row never took a click - the marker below proves nothing" }
    elseif ($t3 -match "XXTOP") { Pass "and survives a click on a sidebar row" }
    elseif ($t3 -match "XTOP") { Fail "switch-side" "the leading X was dropped after clicking the sidebar" }
    else { Fail "switch-side" "the sidebar marker never reached the row that was clicked" }
  }
  Stop-App $ctx
}

# ══ scene: the restore prompt ══════════════════════════════════════════
# Past a few sessions, start-up asks which to bring back. Seeded by
# making sessions in the scratch daemon before the window ever opens.
if (-not $Only -or $Only -eq "restore") {
  $cfg = "{$baseCfg,`"restore_prompt`":true,`"restore_prompt_at`":3}"
  $seed = Seed-Daemon 6 $cfg
  $ctx2 = Start-AppSeeded $seed
  $hw = $ctx2.Hwnd
  Record-Scene "restore" 30 $ctx2 {
    Start-Sleep -Seconds 4          # dwell on the question: it is the point
    Key $VK_RETURN                  # Enter restores everything ticked
    Start-Sleep -Seconds 12         # the spinner, then six tabs
  }
  $now = Daemon-Sessions
  $attached = @($now | Where-Object { $seed.Ids -contains $_.id -and $_.attached })
  if ($attached.Count -eq 6) { Pass "Enter restores all six, and all six actually attach" }
  else { Fail "restore-all" "expected 6 attached, got $($attached.Count)" }
  if ($U::IsWindowVisible($hw)) { Pass "and the window is still up afterwards" }
  else { Fail "restore-all" "the window did not survive the restore" }

  # Closing several tabs should put every one of them in "Closing soon" —
  # the reported symptom was that only one of them landed there. Driven by
  # keyboard (Ctrl+Shift+W twice arms and then closes) so it does not
  # depend on where a close button happens to be drawn.
  foreach ($i in 1..3) {
    Key 0x57 @([byte]$VK_CTRL, [byte]$VK_SHIFT)
    Start-Sleep -Milliseconds 300
    Key 0x57 @([byte]$VK_CTRL, [byte]$VK_SHIFT)
    Start-Sleep -Seconds 2
  }
  Start-Sleep -Seconds 2
  $after = Daemon-Sessions
  $closing = @($after | Where-Object { $seed.Ids -contains $_.id -and $_.expires_ms })
  if ($closing.Count -eq 3) { Pass "closing three tabs puts all three in Closing soon" }
  else { Fail "close-three" "expected 3 closing, got $($closing.Count)" }
  if ($U::IsWindowVisible($hw)) { Pass "and the window stays visible with tabs left" }
  else { Fail "close-three" "the window disappeared while three tabs were still open" }
  Stop-App $ctx2
}

# ══ scene: restoring nothing ═══════════════════════════════════════════
# "Restore 0 still restored them", reported twice. A screenshot cannot
# settle it — restoring means *attaching*, so the daemon is the witness.
# Escape is the gesture under test: it used to restore everything, which
# is the opposite of what waving a dialog away should do.
if (-not $Only -or $Only -eq "restore-none") {
  $cfg = "{$baseCfg,`"restore_prompt`":true,`"restore_prompt_at`":3}"
  $seed = Seed-Daemon 5 $cfg
  $ctx3 = Start-AppSeeded $seed
  $hw3 = $ctx3.Hwnd
  Record-Scene "restore-none" 26 $ctx3 {
    Start-Sleep -Seconds 4
    Key $VK_ESC                     # Escape opens none
    Start-Sleep -Seconds 6
    # One fresh tab is what you are left with. Closing it used to take the
    # whole window with it — close means hide — stranding five sessions
    # behind a window that looked like it had crashed.
    Key 0x57 @([byte]$VK_CTRL, [byte]$VK_SHIFT)
    Start-Sleep -Milliseconds 300
    Key 0x57 @([byte]$VK_CTRL, [byte]$VK_SHIFT)
    Start-Sleep -Seconds 5
  }
  $now3 = Daemon-Sessions
  $wrongly = @($now3 | Where-Object { $seed.Ids -contains $_.id -and $_.attached })
  if ($wrongly.Count -eq 0) { Pass "Escape restores none of them" }
  else { Fail "restore-none" "$($wrongly.Count) session(s) were restored anyway" }
  $survived = @($now3 | Where-Object { $seed.Ids -contains $_.id })
  if ($survived.Count -eq 5) { Pass "and the five it skipped are still there to come back to" }
  else { Fail "restore-none" "only $($survived.Count) of 5 skipped sessions survived" }
  if ($U::IsWindowVisible($hw3)) { Pass "closing the last tab keeps the window, with sessions left" }
  else { Fail "close-last" "the window vanished, stranding the other sessions" }
  Stop-App $ctx3
}

# ══ scene: the None button ═════════════════════════════════════════════
# Escape is not the only way to decline, and it is not the way most people
# do it: "None", then the button that now reads "Restore 0". Reported as
# still restoring everything after the Escape path was fixed — a fix to
# one gesture says nothing about the other, and this is the gesture the
# report was actually about.
if (-not $Only -or $Only -eq "restore-zero") {
  $cfg = "{$baseCfg,`"restore_prompt`":true,`"restore_prompt_at`":3}"
  $seed = Seed-Daemon 5 $cfg
  $ctx4 = Start-AppSeeded $seed
  $hw4 = $ctx4.Hwnd
  Record-Scene "restore-zero" 40 $ctx4 {
    # Wait for the dialog to be up and still, rather than for four
    # seconds and a hope. The second click below aims at a button whose
    # label depends on the first click having landed, so a missed first
    # click does not fail here - it quietly presses "Restore 5".
    $null = Wait-Settled $hw4 30
    $script:zeroNone = Click-Effective $hw4 798 556    # None - unticks every row
    Start-Sleep -Seconds 1
    $script:zeroGo = Click-Effective $hw4 895 556      # the button, now "Restore 0"
    Start-Sleep -Seconds 10
  }
  if (-not $zeroNone) { Fail "restore-zero" "the None button never took - nothing below this was tested" }
  if (-not $zeroGo) { Fail "restore-zero" "the Restore button never took - nothing below this was tested" }
  $now4 = Daemon-Sessions
  $back = @($now4 | Where-Object { $seed.Ids -contains $_.id -and $_.attached })
  if ($back.Count -eq 0) { Pass "None then Restore 0 restores nothing" }
  else { Fail "restore-zero" "$($back.Count) of 5 came back anyway" }
  $kept = @($now4 | Where-Object { $seed.Ids -contains $_.id })
  if ($kept.Count -eq 5) { Pass "and all five are still waiting in the daemon" }
  else { Fail "restore-zero" "only $($kept.Count) of 5 survived being declined" }
  Stop-App $ctx4
}

# ══ scene: declining on a *second* run ═════════════════════════════════
# The scenes above all decline on a virgin profile, where there is no
# saved tab order and no saved pane layouts. Real use never looks like
# that: by the time the question is worth asking you have started the app
# before, and boot walks the saved layouts to rebuild split tabs. If that
# walk does not respect the choice, declining restores everything anyway —
# and a first-run test would never see it.
if (-not $Only -or $Only -eq "restore-again") {
  $cfg = "{$baseCfg,`"restore_prompt`":true,`"restore_prompt_at`":3}"
  $seed = Seed-Daemon 5 $cfg
  # First run: take them all, which is what writes the order and layouts.
  $first = Start-AppSeeded $seed
  Start-Sleep -Seconds 4
  Key $VK_RETURN
  Start-Sleep -Seconds 14
  $tookAll = @(Daemon-Sessions | Where-Object { $seed.Ids -contains $_.id -and $_.attached })
  if ($tookAll.Count -eq 5) { Pass "first run restores all five" }
  else { Fail "restore-again" "first run attached $($tookAll.Count) of 5" }
  Stop-App $first
  Start-Sleep -Seconds 3

  # Second run against the same profile — saved order and layouts intact.
  $ctx5 = Start-AppSeeded $seed
  $hw5 = $ctx5.Hwnd
  Record-Scene "restore-again" 26 $ctx5 {
    Start-Sleep -Seconds 4
    Click $hw5 798 556             # None
    Start-Sleep -Seconds 2
    Click $hw5 895 556             # Restore 0
    Start-Sleep -Seconds 10
  }
  $now5 = Daemon-Sessions
  $again = @($now5 | Where-Object { $seed.Ids -contains $_.id -and $_.attached })
  if ($again.Count -eq 0) { Pass "declining on a second run still restores nothing" }
  else { Fail "restore-again" "$($again.Count) of 5 came back from the saved layout" }
  Stop-App $ctx5
}

# ══ scene: copy from the right-click menu ══════════════════════════════
# Select something, right-click *away* from it, and "Copy" has to still be
# there. xterm drops the selection on a mousedown outside it and the menu
# is built from the contextmenu event that follows, so the item vanished
# at exactly the moment someone reached for it. Asserted through the
# clipboard: what the menu actually copied, not what the menu looked like.
if (-not $Only -or $Only -eq "copy") {
  $ctx6 = Start-App "{$baseCfg,`"default_shell`":`"pwsh`"}"
  $h6 = $ctx6.Hwnd
  Set-Clipboard -Value "clipboard-before-the-test"
  Record-Scene "copy" 26 $ctx6 {
    Run-Cmd 'echo COPYME-1234567890' 3
    # Drag across the output line, then right-click somewhere else.
    Drag ($h6) 20 62 320 62
    Start-Sleep -Milliseconds 600
    Right-Click ($h6) 600 300
    Start-Sleep -Seconds 1
    # First item in the menu, which is Copy whenever there is a selection.
    Click ($h6) 640 312
    Start-Sleep -Seconds 2
    $script:copied1 = try { Get-Clipboard -Raw } catch { "" }
    # Copying must not clear the selection, so the same gesture again -
    # with nothing re-selected - has to copy the same text. That is the
    # only way to ask "is it still selected?" from out here.
    Set-Clipboard -Value "sentinel-between-copies"
    Start-Sleep -Milliseconds 400
    Right-Click ($h6) 600 300
    Start-Sleep -Seconds 1
    Click ($h6) 640 312
    Start-Sleep -Seconds 2
    $script:copied2 = try { Get-Clipboard -Raw } catch { "" }
  }
  if ($copied1 -match "COPYME-1234567890") { Pass "right-clicking away from a selection still offers Copy" }
  elseif ($copied1 -match "clipboard-before-the-test") { Fail "copy" "the menu had no Copy to click - the clipboard never changed" }
  else { Fail "copy" "something else was copied: $($copied1 -replace '\s+', ' ')" }
  if ($copied2 -match "COPYME-1234567890") { Pass "and the selection survives copying, so it can be copied again" }
  elseif ($copied2 -match "sentinel-between-copies") { Fail "copy" "the selection was gone after copying - no Copy on the second menu" }
  else { Fail "copy" "the second copy took something else: $($copied2 -replace '\s+', ' ')" }
  Stop-App $ctx6
}

# ══ scene: hovering a menu item does not choose it ═════════════════════
# Reported: "if you hover over Paste it pastes, you need to actually click
# on it". Nothing fires on hover — but the menu is placed at the pointer,
# so its first row appears under the cursor and a stray release lands on
# it. Asserted against the transcript: what reached the shell, which is
# the only thing that matters here.
if (-not $Only -or $Only -eq "hover") {
  $ctx7 = Start-App "{$baseCfg,`"default_shell`":`"pwsh`",`"history_days`":7}"
  $h7 = $ctx7.Hwnd
  Set-Clipboard -Value "PASTED-BY-ACCIDENT"
  Record-Scene "hover" 24 $ctx7 {
    Run-Cmd 'echo hover-scene-ready' 2
    Right-Click ($h7) 500 260
    Start-Sleep -Seconds 1
    # Move across the rows, pausing on each — a menu that acts on hover
    # pastes here, and one that acts on a stray release does too.
    foreach ($dy in 12, 26, 40, 54) {
      Move-Pointer ($h7) 560 (260 + $dy)
      Start-Sleep -Milliseconds 500
    }
    Start-Sleep -Seconds 2
    # Escape puts the menu away without choosing anything.
    Key $VK_ESC
    Start-Sleep -Seconds 2
  }
  $logs = @(Get-ChildItem "$scratch\GTerminal\history" -Filter *.log -ErrorAction SilentlyContinue)
  $all = ($logs | ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n"
  if ($all -notmatch "PASTED-BY-ACCIDENT") { Pass "hovering the menu pastes nothing" }
  else { Fail "hover" "the clipboard reached the shell without anyone clicking Paste" }
  if ($all -match "hover-scene-ready") { Pass "and the session was live throughout" }
  else { Fail "hover" "the scene never got a working shell, so it proves nothing" }
  Stop-App $ctx7
}

# ══ scene: a full-screen program actually redrawing ════════════════════
# The gap this closes: everything else here asserts on bytes, and the
# bytes were fine. A window can be handed a correct frame and never put
# it on screen — reported as "Agency gets stuck on old output, when it
# redraws the whole screen it doesn't do it" — and only pixels can tell.
#
# The fixture alternates full-screen fills on the alternate screen, which
# is how Claude Code, Agency, Hermes, vim and lazygit all draw. A repaint
# that does not reach the screen leaves the previous colour there, so the
# assertion is simply: the window looks different between frames.
if (-not $Only -or $Only -eq "tui") {
  $ctx8 = Start-App "{$baseCfg,`"default_shell`":`"pwsh`"}"
  $h8 = $ctx8.Hwnd
  $fixture = Join-Path $repo "tests\fixtures\tui.ps1"
  Record-Scene "tui" 30 $ctx8 {
    Run-Cmd 'echo before-the-tui' 2
    $script:shotShell = Capture-Window $h8
    Run-Cmd "& '$fixture' -Frames 3 -Ms 2600" 0
    Start-Sleep -Milliseconds 1400          # into the first frame
    $script:shotA = Capture-Window $h8
    Start-Sleep -Milliseconds 2600          # into the second
    $script:shotB = Capture-Window $h8
    Start-Sleep -Milliseconds 2600          # into the third
    $script:shotC = Capture-Window $h8
    Start-Sleep -Seconds 4                  # it leaves the alt screen
    $script:shotAfter = Capture-Window $h8
  }
  # Painted at all: the alternate screen replaced the shell.
  $d1 = Frame-Diff $shotShell $shotA
  if ($d1 -gt 0.30) { Pass "a full-screen program takes over the screen" }
  else { Fail "tui" ("the screen barely changed when the program started ({0:p0})" -f $d1) }
  # And redrew: frame two must not look like frame one. This is the one
  # that fails when a redraw is composed but never presented.
  $d2 = Frame-Diff $shotA $shotB
  if ($d2 -gt 0.30) { Pass "and each redraw reaches the screen" }
  else { Fail "tui" ("frame 2 looks like frame 1 ({0:p0} changed) - the redraw did not appear" -f $d2) }
  $d3 = Frame-Diff $shotB $shotC
  if ($d3 -gt 0.30) { Pass "and keeps reaching it, frame after frame" }
  else { Fail "tui" ("frame 3 looks like frame 2 ({0:p0} changed)" -f $d3) }
  # Leaving the alternate screen puts the shell back, rather than
  # stranding the last frame on screen.
  $d4 = Frame-Diff $shotC $shotAfter
  if ($d4 -gt 0.30) { Pass "and the shell comes back when it exits" }
  else { Fail "tui" ("the last frame stayed on screen after it exited ({0:p0} changed)" -f $d4) }
  Write-Host ("  changed: start {0:p0}, frame2 {1:p0}, frame3 {2:p0}, exit {3:p0}" -f $d1, $d2, $d3, $d4) -ForegroundColor DarkGray
  # Keep the frames when they disagree with expectations: "0% changed" is
  # true of a screen that never redrew and of a program that never ran,
  # and the pictures are the only thing that tells them apart.
  if ($d1 -le 0.30 -or $d2 -le 0.30) {
    $dump = Join-Path $outDir "tui-frames"
    New-Item -ItemType Directory -Force $dump | Out-Null
    $shotShell.Save((Join-Path $dump "0-shell.png"), [System.Drawing.Imaging.ImageFormat]::Png)
    $shotA.Save((Join-Path $dump "1-frame.png"), [System.Drawing.Imaging.ImageFormat]::Png)
    $shotB.Save((Join-Path $dump "2-frame.png"), [System.Drawing.Imaging.ImageFormat]::Png)
    $shotC.Save((Join-Path $dump "3-frame.png"), [System.Drawing.Imaging.ImageFormat]::Png)
    $shotAfter.Save((Join-Path $dump "4-after.png"), [System.Drawing.Imaging.ImageFormat]::Png)
    Write-Host "  frames saved to $dump" -ForegroundColor DarkGray
  }
  foreach ($b in $shotShell, $shotA, $shotB, $shotC, $shotAfter) { $b.Dispose() }
  Stop-App $ctx8
}

# ══ scene: the clipboard, by keyboard ══════════════════════════════════
# Copy and paste no longer go through navigator.clipboard - the app reads
# and writes the clipboard itself - and nothing exercised that. The menu
# paths have the copy scene; these are the keys, and they are the ones
# people actually use.
#
# A round trip, both halves asserted against something outside the app:
# the Windows clipboard for the copy, the session transcript for the
# paste. Neither can be satisfied by the screen merely looking right.
if (-not $Only -or $Only -eq "clipboard") {
  $ctx9 = Start-App "{$baseCfg,`"default_shell`":`"pwsh`"}"
  $h9 = $ctx9.Hwnd
  Set-Clipboard -Value "nothing-copied-yet"
  Record-Scene "clipboard" 28 $ctx9 {
    Run-Cmd 'echo COPYKEY-24680' 3
    # Select the output line, then copy it with the keyboard.
    Drag ($h9) 20 62 320 62
    Start-Sleep -Milliseconds 600
    Key 0x43 @([byte]$VK_CTRL, [byte]$VK_SHIFT)   # Ctrl+Shift+C
    Start-Sleep -Seconds 2
    $script:copiedByKey = try { Get-Clipboard -Raw } catch { "" }
    # Now the other direction, with something the shell has never seen.
    Set-Clip 'echo PASTEKEY-13579' $h9
    Key 0x56 @([byte]$VK_CTRL, [byte]$VK_SHIFT)   # Ctrl+Shift+V
    Start-Sleep -Seconds 2
    Key $VK_RETURN
    Start-Sleep -Seconds 4
    $script:pastedByKey = Transcripts
  }
  if ($copiedByKey -match "COPYKEY-24680") { Pass "Ctrl+Shift+C puts the selection on the clipboard" }
  elseif ($copiedByKey -match "nothing-copied-yet") { Fail "clip-copy" "the clipboard never changed - nothing was copied" }
  else { Fail "clip-copy" "something else was copied: $($copiedByKey -replace '\s+', ' ')" }
  if ($pastedByKey -match "PASTEKEY-13579") { Pass "and Ctrl+Shift+V pastes into the shell" }
  else { Fail "clip-paste" "the pasted text never reached the shell" }
  Stop-App $ctx9
}

# ══ scene: the clipboard history viewer ═══════════════════════════════
# The third clipboard path, and the last one with no test: right-click →
# "Clipboard history…" → Paste on an entry. It goes through pasteText
# with its own source, and like the others it now reads the clipboard
# through the app rather than the webview.
#
# Coordinates are derived rather than measured: the panel is 560px wide
# and centred, the row's buttons sit at its right edge. The viewer is
# photographed regardless, so a click that misses can be corrected from
# the picture instead of from a guess.
if (-not $Only -or $Only -eq "cliphist") {
  $ctx10 = Start-App "{$baseCfg,`"default_shell`":`"pwsh`"}"
  $h10 = $ctx10.Hwnd
  Record-Scene "cliphist" 30 $ctx10 {
    Run-Cmd 'echo cliphist-ready' 2
    # One entry only. With several, the menu grows "Paste: older" rows and
    # every coordinate below moves - so the older-entry case is not
    # covered here, deliberately.
    Set-Clip 'echo HISTPASTE-97531' $h10
    # No selection, so the menu is: Paste, separator, Clipboard history…,
    # Select all. Rows are 28px apart and a separator adds 8.
    Right-Click ($h10) 500 260
    Start-Sleep -Seconds 1
    Click ($h10) 560 316                 # "Clipboard history…"
    Start-Sleep -Seconds 2
    $script:viewer = Capture-Window $h10
    Click ($h10) 882 386                 # first row's Paste button
    Start-Sleep -Seconds 2
    Key $VK_RETURN
    Start-Sleep -Seconds 4
    $script:histOut = Transcripts
  }
  if ($histOut -match "HISTPASTE-97531") { Pass "pasting from the clipboard history reaches the shell" }
  else { Fail "cliphist" "nothing arrived - the viewer may not have opened, or Paste was not where it was clicked" }
  $dump = Join-Path $outDir "clip-frames"
  New-Item -ItemType Directory -Force $dump | Out-Null
  $viewer.Save((Join-Path $dump "viewer.png"), [System.Drawing.Imaging.ImageFormat]::Png)
  $viewer.Dispose()
  Write-Host "  viewer saved to $dump" -ForegroundColor DarkGray
  Stop-App $ctx10
}

# ══ scene: a second window ═════════════════════════════════════════════
# The failure this is about is the one that made single-instance
# necessary: two windows sharing one localStorage, both writing the same
# tab order and pane layouts, last save winning. Opening a second window
# must leave the first one's tabs exactly where they were - including
# after the second window closes, which is when the old arrangement did
# its damage.
#
# Sessions are the other half. The daemon allows one attacher and honours
# the newest, so a second window that restored everything would take the
# first window's terminals. It must not.
if (-not $Only -or $Only -eq "multiwindow") {
  $ctx11 = Start-App "{$baseCfg,`"default_shell`":`"pwsh`",`"history_days`":7}"
  $h11 = $ctx11.Hwnd
  Record-Scene "multiwindow" 40 $ctx11 {
    Run-Cmd 'echo WINDOW-ONE-4242' 3
    Key 0x4E @([byte]$VK_CTRL, [byte]$VK_SHIFT)     # Ctrl+Shift+N
    Start-Sleep -Seconds 8
    $script:wins = App-Windows $ctx11.App.Id
    # The new window has focus; type into it.
    Run-Cmd 'echo WINDOW-TWO-8686' 3
    $script:bothOpen = Transcripts
    $script:sessionsWhileTwo = Daemon-Sessions
    # Close the second window. The first must be untouched by it.
    $second = @($wins | Where-Object { $_ -ne $h11 })
    if ($second.Count) { [void]$U::PostMessage($second[0], 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) }
    Start-Sleep -Seconds 5
    $script:afterClose = App-Windows $ctx11.App.Id
    # And the first window still works: its tab is still its tab.
    [void]$U::SetForegroundWindow($h11)
    Start-Sleep -Milliseconds 800
    Focus-Pane $h11
    Run-Cmd 'echo FIRST-STILL-WORKS' 3
    $script:finalOut = Transcripts
  }
  if ($wins.Count -ge 2) { Pass "Ctrl+Shift+N opens a second window" }
  else { Fail "multiwindow" "only $($wins.Count) window(s) after Ctrl+Shift+N" }
  # Two windows, two sessions - not one session shown twice, which is what
  # would happen if the second window adopted what the first already had.
  $attached = @($sessionsWhileTwo | Where-Object { $_.attached })
  if ($attached.Count -ge 2) { Pass "and it runs a session of its own" }
  else { Fail "multiwindow" "$($attached.Count) attached session(s) with two windows open" }
  if (($bothOpen -match "WINDOW-ONE-4242") -and ($bothOpen -match "WINDOW-TWO-8686")) {
    Pass "and both windows reach a shell"
  } else { Fail "multiwindow" "one of the two windows never ran anything" }
  if ($afterClose.Count -eq 1) { Pass "closing the second leaves one window" }
  else { Fail "multiwindow" "$($afterClose.Count) window(s) after closing the second" }
  if ($finalOut -match "FIRST-STILL-WORKS") { Pass "and the first window still has its terminal" }
  else { Fail "multiwindow" "the first window stopped working once the second had been and gone" }
  # A second window that opens and then does nothing looks the same from
  # out here as one that never loaded its page. Photograph every window
  # the app has, so the difference is visible.
  $dump = Join-Path $outDir "window-frames"
  New-Item -ItemType Directory -Force $dump | Out-Null
  $i = 0
  foreach ($w in (App-Windows $ctx11.App.Id)) {
    $shot = Capture-Window $w
    $shot.Save((Join-Path $dump "window-$i.png"), [System.Drawing.Imaging.ImageFormat]::Png)
    $shot.Dispose()
    Write-Host ("  window {0}: handle {1}" -f $i, $w) -ForegroundColor DarkGray
    $i++
  }
  Write-Host "  windows saved to $dump" -ForegroundColor DarkGray
  Stop-App $ctx11
}

# ══ scene: two windows keep their own tabs ════════════════════════════
# The multiwindow scene proves a second window works. This one proves the
# first one is not damaged by it, which is the failure the whole design is
# about: two windows sharing one localStorage, both writing the same tab
# order, last save winning.
#
# Asserted through the daemon, because "what is in this window" is not a
# question a screenshot answers: four attached sessions with two windows
# open, and exactly the original one attached after the second window has
# been and gone.
if (-not $Only -or $Only -eq "twowindows") {
  $ctx12 = Start-App "{$baseCfg,`"default_shell`":`"pwsh`"}"
  $h12 = $ctx12.Hwnd
  Record-Scene "twowindows" 40 $ctx12 {
    Run-Cmd 'echo first-window-tab' 3
    $script:beforeIds = @((Daemon-Sessions | Where-Object { $_.attached }).id)
    Key 0x4E @([byte]$VK_CTRL, [byte]$VK_SHIFT)     # Ctrl+Shift+N
    Start-Sleep -Seconds 9
    # Two more tabs, in the second window.
    Key 0x54 @([byte]$VK_CTRL, [byte]$VK_SHIFT)
    Start-Sleep -Seconds 5
    Key 0x54 @([byte]$VK_CTRL, [byte]$VK_SHIFT)
    Start-Sleep -Seconds 5
    $script:whileTwo = Daemon-Sessions
    $script:winsNow = App-Windows $ctx12.App.Id
    $second = @($winsNow | Where-Object { $_ -ne $h12 })
    if ($second.Count) { [void]$U::PostMessage($second[0], 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) }
    Start-Sleep -Seconds 8
    $script:afterOne = Daemon-Sessions
    $script:winsAfter = App-Windows $ctx12.App.Id
  }
  if ($winsAfter.Count -eq 1) { Pass "the second window closes" }
  else { Fail "twowindows" "$($winsAfter.Count) window(s) still open after closing the second" }
  $attachedTwo = @($whileTwo | Where-Object { $_.attached })
  if ($attachedTwo.Count -ge 4) { Pass "two windows hold four sessions between them" }
  else { Fail "twowindows" "only $($attachedTwo.Count) attached with two windows and four tabs" }
  # The first window's own session, still its own: not adopted by the
  # second window, and not closed when the second window went.
  $stillMine = @($afterOne | Where-Object { $_.attached })
  if ($stillMine.Count -eq 1) { Pass "and one is left attached when the second window closes" }
  else { Fail "twowindows" "$($stillMine.Count) attached after closing the second window" }
  if ($beforeIds.Count -and $stillMine.Count -eq 1 -and $stillMine[0].id -eq $beforeIds[0]) {
    Pass "and it is the same session the first window started with"
  } else { Fail "twowindows" "the first window ended up on a different session" }
  # The second window's sessions are detached, not destroyed - closing a
  # window is not closing its terminals.
  $survivors = @($afterOne | Where-Object { -not $_.attached -and $_.alive })
  if ($survivors.Count -ge 2) { Pass "and the closed window's terminals are still running" }
  else { Fail "twowindows" "the second window took its sessions down with it" }
  Stop-App $ctx12
}

# ══ scene: reading an ended session does not revive it ════════════════
# Clicking a session whose shell is gone shows its output read-only and
# offers a shell. The promise worth testing is the restraint: looking at
# one must not start a process, because attaching is what resurrects it
# and a list you click through would start a shell for every glance.
if (-not $Only -or $Only -eq "preview") {
  $cfg = "{$baseCfg,`"restore_prompt`":true,`"restore_prompt_at`":1}"
  $seed = Seed-Daemon 2 $cfg -Typed
  # Checkpoints flush every few seconds, and "was this ever typed into" is
  # part of them. Killing the daemon before that lands loses the fact, and
  # the sessions are discarded on the way back as ones nobody used.
  Start-Sleep -Seconds 7
  # Kill the daemon outright: its sessions persist as checkpoints and come
  # back as ended ones, which is how they arise in the first place.
  Stop-Process -Id $seed.Daemon.Id -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 2
  Write-Host ("  checkpoints: {0}" -f ((Get-ChildItem "$scratch\GTerminal\sessions" -Filter *.json -ErrorAction SilentlyContinue | ForEach-Object { $_.Name + "=" + ((Get-Content $_.FullName -Raw | ConvertFrom-Json).saw_input) }) -join " ")) -ForegroundColor DarkGray
  $ctx13 = Start-AppSeeded $seed
  $h13 = $ctx13.Hwnd
  Record-Scene "preview" 30 $ctx13 {
    Start-Sleep -Seconds 5
    Key $VK_ESC                       # restore none: leave them ended
    Start-Sleep -Seconds 6
    Key 0x42 @([byte]$VK_CTRL, [byte]$VK_SHIFT)   # sidebar
    Start-Sleep -Seconds 2
    Click ($h13) 100 47               # the first ended session
    Start-Sleep -Seconds 4
    $script:afterClick = Daemon-Sessions
  }
  Write-Host ("  seeded ids: {0}" -f ($seed.Ids -join ",")) -ForegroundColor DarkGray
  Write-Host ("  daemon now: {0}" -f (($afterClick | ForEach-Object { "$($_.id)(alive=$($_.alive),att=$($_.attached))" }) -join " ")) -ForegroundColor DarkGray
  $revived = @($afterClick | Where-Object { $seed.Ids -contains $_.id -and $_.alive })
  if ($revived.Count -eq 0) { Pass "opening an ended session does not start a shell" }
  else { Fail "preview" "$($revived.Count) ended session(s) were resurrected just by being opened" }
  $kept = @($afterClick | Where-Object { $seed.Ids -contains $_.id })
  if ($kept.Count -eq 2) { Pass "and both are still there to reopen" }
  else { Fail "preview" "only $($kept.Count) of 2 ended sessions survived being looked at" }
  Stop-App $ctx13
}

# ══ scene: moving a tab to another window ═════════════════════════════
# A drag would be the obvious gesture and is not available: two webviews
# share no drag context, so it is a menu command. Underneath, the daemon
# does the work - the target window attaches, the newest attach wins, and
# the window that had it is told and drops the tab.
#
# The assertion is that the session survives the journey and is still
# usable at the other end, which is the only part that matters.
if (-not $Only -or $Only -eq "movetab") {
  $ctx14 = Start-App "{$baseCfg,`"default_shell`":`"pwsh`",`"history_days`":7}"
  $h14 = $ctx14.Hwnd
  Record-Scene "movetab" 40 $ctx14 {
    Run-Cmd 'echo MOVER-13579' 3
    $script:moverId = @((Daemon-Sessions | Where-Object { $_.attached }).id)[0]
    Key 0x4E @([byte]$VK_CTRL, [byte]$VK_SHIFT)     # a second window
    Start-Sleep -Seconds 9
    # Back to the first window, and move its tab across.
    [void]$U::SetForegroundWindow($h14)
    Start-Sleep -Seconds 1
    Focus-Pane $h14
    Start-Sleep -Milliseconds 500
    Right-Click ($h14) 120 33                       # the tab itself
    Start-Sleep -Seconds 1
    $script:tabMenuShot = Capture-Window $h14
    # Rename tab, Suggest title…, Move to Window 2 - measured from a
    # capture of the menu rather than counted from the source, which is
    # how the click landed on Set badge… the first time.
    Click ($h14) 200 108
    Start-Sleep -Seconds 5
    $script:afterMove = Daemon-Sessions
    $script:windowsNow = App-Windows $ctx14.App.Id
  }
  Write-Host ("  moved id {0}; daemon: {1}" -f $moverId, (($afterMove | ForEach-Object { "$($_.id)(att=$($_.attached))" }) -join " ")) -ForegroundColor DarkGray
  $moved = @($afterMove | Where-Object { $_.id -eq $moverId -and $_.attached -and $_.alive })
  if ($moved.Count -eq 1) { Pass "the moved session is still alive and open" }
  else { Fail "movetab" "the session did not survive being moved" }
  # The window that lost it opens a fresh one rather than sitting empty,
  # so a move that happened leaves three sessions where there were two.
  # Without this the assertions above are also true of a move that never
  # happened at all.
  if ($afterMove.Count -ge 3) { Pass "and the window it left has a terminal of its own again" }
  else {
    Fail "movetab" "still $($afterMove.Count) sessions - the move did not happen"
    $dump = Join-Path $outDir "menu-frames"
    New-Item -ItemType Directory -Force $dump | Out-Null
    $tabMenuShot.Save((Join-Path $dump "tab-menu.png"), [System.Drawing.Imaging.ImageFormat]::Png)
    Write-Host "  tab menu saved to $dump" -ForegroundColor DarkGray
  }
  $tabMenuShot.Dispose()
  Stop-App $ctx14
}

# ══ scene: the hotkey means the window you were last in ═══════════════
# With one window "the window" is a fact. With two it is a choice, and the
# answer that needs no explaining is the one you were last using.
if (-not $Only -or $Only -eq "lastfocused") {
  $lfCfg = $baseCfg.Replace("Control+Alt+F9", "Control+Alt+F7")
  $ctx15 = Start-App "{$lfCfg,`"default_shell`":`"pwsh`"}"
  $h15 = $ctx15.Hwnd
  Record-Scene "lastfocused" 34 $ctx15 {
    Run-Cmd 'echo lastfocused-ready' 2
    Key 0x4E @([byte]$VK_CTRL, [byte]$VK_SHIFT)
    Start-Sleep -Seconds 9
    $script:lfWins = App-Windows $ctx15.App.Id
    $lfSecond = @($lfWins | Where-Object { $_ -ne $h15 })
    # Focus the *first* window last, so it is the one the hotkey means.
    [void]$U::SetForegroundWindow($h15)
    Start-Sleep -Seconds 2
    Release-Modifiers
    $U::keybd_event(0x11,0,0,[UIntPtr]::Zero)
    $U::keybd_event(0x12,0,0,[UIntPtr]::Zero)
    $U::keybd_event(0x76,0,0,[UIntPtr]::Zero)       # Ctrl+Alt+F7
    Start-Sleep -Milliseconds 80
    $U::keybd_event(0x76,0,2,[UIntPtr]::Zero)
    $U::keybd_event(0x12,0,2,[UIntPtr]::Zero)
    $U::keybd_event(0x11,0,2,[UIntPtr]::Zero)
    Start-Sleep -Seconds 4
    $script:firstHidden = -not $U::IsWindowVisible($h15)
    $script:secondStillUp = if ($lfSecond.Count) { $U::IsWindowVisible($lfSecond[0]) } else { $false }
  }
  if ($lfWins.Count -ge 2) { Pass "two windows to choose between" }
  else { Fail "lastfocused" "the second window never opened" }
  if ($firstHidden) { Pass "the hotkey puts away the window you were last in" }
  else { Fail "lastfocused" "the hotkey did not hide the focused window" }
  if ($secondStillUp) { Pass "and leaves the other one alone" }
  else { Fail "lastfocused" "it took the other window with it" }
  Stop-App $ctx15
}

# == scene: a real full-screen program =================================
# The tui scene uses a fixture: sequences this project chose to send. This
# one runs vim, which chooses its own - a different terminfo path, its own
# ideas about the alternate screen and about redrawing. It is the closest
# thing to the report that started this ("it gets stuck on old output")
# that can be run without installing anything.
#
# Skipped rather than failed where vim is absent: a machine without Git
# for Windows is not a broken terminal.
if (-not $Only -or $Only -eq "vim") {
  $vim = "C:\Program Files\Git\usr\bin\vim.exe"
  if (-not (Test-Path $vim)) {
    Write-Host "  note: vim not installed, skipping the real-TUI scene" -ForegroundColor DarkYellow
  } else {
    $ctx16 = Start-App "{$baseCfg,`"default_shell`":`"pwsh`"}"
    $h16 = $ctx16.Hwnd
    Record-Scene "vim" 34 $ctx16 {
      Run-Cmd 'echo before-vim' 2
      $script:vimShell = Capture-Window $h16
      # -u NONE: no config, so this tests the terminal rather than
      # whatever plugins happen to be installed.
      Run-Cmd "& '$vim' -u NONE -N" 0
      Start-Sleep -Seconds 6
      $script:vimOpen = Capture-Window $h16
      Send-Text "i"
      Start-Sleep -Milliseconds 400
      foreach ($n in 1..12) {
        Send-Text "VIMLINE-$n is here"
        Key $VK_RETURN
        Start-Sleep -Milliseconds 120
      }
      Start-Sleep -Seconds 2
      $script:vimTyped = Capture-Window $h16
      Key $VK_ESC
      Start-Sleep -Milliseconds 400
      Send-Text ":q!"
      Key $VK_RETURN
      Start-Sleep -Seconds 4
      $script:vimGone = Capture-Window $h16
      $script:vimOut = Transcripts
    }
    # Thresholds are much lower here than in the fixture scene, and that
    # is not a weaker test - it is the same test of a different picture.
    # The fixture fills every cell, so a redraw moves 80% of the pixels;
    # vim is thin text on black and moves about 2%. A screen that did not
    # redraw at all sits near zero, which is what these separate.
    $floor = 0.01
    $d1 = Frame-Diff $vimShell $vimOpen
    if ($d1 -gt $floor) { Pass "vim takes the screen" }
    else { Fail "vim" ("the screen barely changed when vim started ({0:p1})" -f $d1) }
    $d2 = Frame-Diff $vimOpen $vimTyped
    if ($d2 -gt $floor) { Pass "and its redraws land as you type" }
    else { Fail "vim" ("typing into vim changed nothing on screen ({0:p1}) - the reported symptom" -f $d2) }
    $d3 = Frame-Diff $vimTyped $vimGone
    if ($d3 -gt $floor) { Pass "and the shell has its screen back after :q" }
    else { Fail "vim" ("vim's last frame is still on screen after it exited ({0:p1})" -f $d3) }
    # And what actually crossed the wire, which no threshold can fudge:
    # vim drew the last line, and put the screen back on the way out.
    # Not asserted: that vim's text appears in the transcript. It does
    # not, and that is not a fault - ConPTY keeps its own screen and emits
    # its own redraw, so what reaches the transcript is ConPTY's rendering
    # rather than the characters vim wrote. Twelve lines were plainly on
    # screen while none of them were in the byte stream. The pixels are
    # the evidence here; the bytes cannot be.
    if ($vimOut -match "\?1049l") { Pass "and it left the alternate screen behind it" }
    else { Fail "vim" "the alternate screen was never left" }
    Write-Host ("  changed: start {0:p1}, typing {1:p1}, exit {2:p1}" -f $d1, $d2, $d3) -ForegroundColor DarkGray
    if ($d1 -le $floor -or $d2 -le $floor -or $d3 -le $floor) {
      $dump = Join-Path $outDir "vim-frames"
      New-Item -ItemType Directory -Force $dump | Out-Null
      $vimShell.Save((Join-Path $dump "0-shell.png"), [System.Drawing.Imaging.ImageFormat]::Png)
      $vimOpen.Save((Join-Path $dump "1-open.png"), [System.Drawing.Imaging.ImageFormat]::Png)
      $vimTyped.Save((Join-Path $dump "2-typed.png"), [System.Drawing.Imaging.ImageFormat]::Png)
      $vimGone.Save((Join-Path $dump "3-gone.png"), [System.Drawing.Imaging.ImageFormat]::Png)
      Write-Host "  frames saved to $dump" -ForegroundColor DarkGray
    }
    foreach ($b in $vimShell, $vimOpen, $vimTyped, $vimGone) { $b.Dispose() }
    Stop-App $ctx16
  }
}

# == scene: GitHub Copilot CLI ==========================================
# The program the report was about is one of these: an agent CLI that owns
# the screen and repaints it. vim proves the terminal can do full-screen
# redraws at all; this proves it for the shape of program actually named,
# a Node TUI with dialogs, a composer and a status line of its own.
#
# Signing in is not needed to test drawing, and is not attempted: what
# arrives first is a dialog either way, and dialogs repaint. Skipped where
# it is not installed, since a machine without it is not a broken terminal.
if (-not $Only -or $Only -eq "copilot") {
  $copilot = (Get-Command copilot -ErrorAction SilentlyContinue).Source
  if (-not $copilot) {
    Write-Host "  note: copilot CLI not installed, skipping" -ForegroundColor DarkYellow
  } else {
    # History on: what a real agent TUI's bytes look like after ConPTY has
    # been through them is the evidence for every question this scene was
    # written to answer, and it costs nothing to keep.
    $skipCopilot = $false
    $ctx17 = Start-App "{$baseCfg,`"default_shell`":`"pwsh`",`"history_days`":7}"
    $h17 = $ctx17.Hwnd
    Record-Scene "copilot" 60 $ctx17 {
      Run-Cmd 'echo before-copilot' 2
      $script:cpShell = Capture-Window $h17
      Run-Cmd "& '$copilot'" 0
      $script:cpStarted = Wait-Drawn $h17 $cpShell 75
      $script:cpDrawWait = $script:LastDrawWait
      # Started drawing is not finished drawing. Everything below compares
      # frames against each other, so it has to begin from a still screen.
      $script:cpSettled = Wait-Settled $h17 45
      $script:cpSettleWait = $script:LastSettleWait
      $script:cpDidSettle = $script:LastSettled
      # A control frame over the same span as the keystroke below gets,
      # so the two are comparable. Whatever the screen does on its own it
      # does here too, and input has to beat it.
      Start-Sleep -Seconds 2
      $script:cpIdle = Capture-Window $h17
      # It opens on a folder-trust dialog, which takes arrows and Enter
      # and ignores letters, so drive it the way it asks to be driven.
      Key 0x28                        # Down
      Start-Sleep -Seconds 2
      $script:cpArrow = Capture-Window $h17
      # Back to the first option before pressing anything. Down left the
      # highlight on "Yes, and remember this folder for future sessions",
      # and a test has no business making a lasting change to what the
      # user's own copilot trusts. The first option is this session only.
      Key 0x26                        # Up
      Start-Sleep -Seconds 1
      Key $VK_RETURN
      Start-Sleep -Seconds 5
      $script:cpOpen = Capture-Window $h17
      # Type, but never submit: Enter would send a request on the user's
      # account. Letters appearing in the composer are a redraw too, and
      # only reachable on a machine that is signed in.
      Send-Text "hello"
      Start-Sleep -Seconds 3
      $script:cpTyped = Capture-Window $h17
      Key 0x43 @([byte]$VK_CTRL)
      Start-Sleep -Seconds 1
      Key 0x43 @([byte]$VK_CTRL)
      Start-Sleep -Seconds 5
      $script:cpGone = Capture-Window $h17
    }
    # A real program's text moves a small share of the pixels - vim's
    # twelve lines came to 2% - so the fixture scene's thresholds do not
    # belong here. The status bar is excluded from every comparison
    # because its clock and CPU readout move on their own.
    $floor = 0.001
    $idle  = Frame-Diff $cpSettled $cpIdle -IgnoreBottom 40
    $c1 = Frame-Diff $cpShell $cpStarted
    # Signed out, copilot prints a line and exits rather than opening a
    # UI at all, so there is nothing here to test and a runner would fail
    # on the absence of a program rather than on this terminal.
    #
    # The transcript decides that, not the pixels. "Few pixels changed"
    # is exactly what the reported bug looks like too, so skipping on it
    # would hide the thing this scene exists to catch. Entering the
    # alternate screen is the divide: those bytes arriving and no picture
    # appearing is our bug, and is asserted; those bytes never arriving
    # means no full-screen program ever ran, which is not ours to fail.
    $screenTaken = (Transcripts) -match [regex]::Escape("$([char]27)[?1049h")
    if (-not $screenTaken) {
      Write-Host "  note: copilot never opened a full-screen UI (not signed in) - nothing for this scene to test" -ForegroundColor DarkYellow
      $skipCopilot = $true
    }
    if ($skipCopilot) { }
    elseif ($c1 -gt 0.01) { Pass "copilot takes the screen" }
    else { Fail "copilot" ("the screen barely changed when it started ({0:p1}), though it did enter the alternate screen" -f $c1) }
    # Either kind of input counts, and both are reported. Which one moves
    # the screen depends on what is up: a dialog takes arrows and ignores
    # letters, a prompt does the reverse, and which of the two you get
    # depends on whether the machine is signed in. Asserting on the arrow
    # alone failed a runner where copilot was drawing perfectly well and
    # simply had a text field up rather than a menu. What this scene is
    # about is whether input repaints the screen at all.
    $c2 = Frame-Diff $cpIdle $cpArrow -IgnoreBottom 40
    $c4 = Frame-Diff $cpOpen $cpTyped -IgnoreBottom 40
    $moved = [Math]::Max($c2, $c4)
    # A screen that never stops moving cannot be measured this way, and
    # is also not the fault being looked for: the report is a screen stuck
    # on old output, and this is the opposite of stuck. Say so and stop,
    # rather than failing a working terminal against its own animation.
    if (-not $cpDidSettle -and -not $skipCopilot) {
      Write-Host ("  note: the screen never went still ({0:p2} of it kept moving on its own), so input cannot be measured against it here" -f $idle) -ForegroundColor DarkYellow
      $skipCopilot = $true
    }
    if ($skipCopilot) { }
    elseif ($moved -gt $floor -and $moved -gt $idle) {
      Pass ("and repaints when you drive it ({0})" -f $(if ($c2 -ge $c4) { "arrows" } else { "letters" }))
    }
    else { Fail "copilot" ("neither an arrow nor typing changed the screen (arrow {0:p2}, letters {1:p2}, idle {2:p2}) - this is the reported symptom" -f $c2, $c4, $idle) }
    # Letters reaching a composer prove the machine is signed in, which is
    # what makes the screen before it a folder-trust dialog and Enter an
    # answer to it. A signed-out runner gets a login screen instead, where
    # Enter means something else entirely, so both of these are asserted
    # only on the machine where they mean what they say - and reported
    # either way, so a silent skip cannot pass for a pass.
    $c3 = Frame-Diff $cpArrow $cpOpen -IgnoreBottom 40
    $signedIn = -not $skipCopilot -and $c4 -gt $floor -and $c4 -gt $idle -and $c2 -gt $idle
    if ($signedIn) {
      Pass "and letters land in its composer"
      if ($c3 -gt $floor -and $c3 -gt $idle) { Pass "and redraws the screen behind a dismissed dialog" }
      else { Fail "copilot" ("the dialog left no trace of being answered ({0:p2})" -f $c3) }
    } elseif (-not $skipCopilot) {
      # Both numbers, and no claim about which. On a signed-out runner
      # letters moved 6.5% of the screen while arrows moved nothing, and
      # an earlier version of this note called that "no composer to type
      # into" - which read as a failure to draw when it was the opposite.
      Write-Host ("  note: signed-out layout (arrow {0:p2}, letters {1:p2}) - the dialog and composer checks need an account, so they are skipped" -f $c2, $c4) -ForegroundColor DarkYellow
    }
    # What a real TUI's control sequences look like after ConPTY has been
    # through them. Printed, never asserted - it is a diagnostic, and the
    # interesting reading is synchronized output (mode 2026): xterm.js
    # pauses all drawing on ?2026h and only resumes on ?2026l or after a
    # one-second timeout, so a stream carrying opens without closes would
    # look exactly like a screen stuck on old output with laggy typing.
    $esc = [char]27
    $t17 = Transcripts
    $bsu = ([regex]::Matches($t17, [regex]::Escape("$esc[?2026h"))).Count
    $esu = ([regex]::Matches($t17, [regex]::Escape("$esc[?2026l"))).Count
    $alt = ([regex]::Matches($t17, [regex]::Escape("$esc[?1049h"))).Count
    Write-Host ("  sequences: {0} chars, sync-output open x{1} close x{2}, alt-screen enter x{3}" -f $t17.Length, $bsu, $esu, $alt) -ForegroundColor DarkGray
    Write-Host ("  drew after {0}s, settled after a further {1}s" -f $cpDrawWait, $cpSettleWait) -ForegroundColor DarkGray
    Write-Host ("  changed: start {0:p1}, idle {1:p2}, arrow {2:p2}, dialog {3:p2}, letters {4:p2}, exit {5:p1}" -f $c1, $idle, $c2, $c3, $c4, (Frame-Diff $cpTyped $cpGone -IgnoreBottom 40)) -ForegroundColor DarkGray
    if (-not $skipCopilot -and ($c1 -le 0.01 -or $c2 -le $idle -or ($signedIn -and $c3 -le $idle))) {
      $dump = Join-Path $outDir "copilot-frames"
      New-Item -ItemType Directory -Force $dump | Out-Null
      $i = 0
      foreach ($f in $cpShell, $cpStarted, $cpSettled, $cpIdle, $cpArrow, $cpOpen, $cpTyped, $cpGone) {
        $f.Save((Join-Path $dump "$i.png"), [System.Drawing.Imaging.ImageFormat]::Png); $i++
      }
      Write-Host "  frames saved to $dump" -ForegroundColor DarkGray
    }
    foreach ($b in $cpShell, $cpStarted, $cpSettled, $cpIdle, $cpArrow, $cpOpen, $cpTyped, $cpGone) { $b.Dispose() }
    Stop-App $ctx17
  }
}

# == scene: an agent CLI that sets up before it draws ===================
# The report says agency "gets stuck on old output, like when it redraws
# the entire screen it doesn't do it", and that it sets things up - MCP
# servers - before that redraw. That startup is a suspect worth its own
# scene, because it is the one moment a TUI is not the only thing writing
# to the terminal: it has a screen up while child processes it does not
# control are still starting, and those children write to the same pty.
#
# tests/fixtures/mcp-slow.mjs plays that part deliberately badly - slow to
# answer initialize, and chatty on stderr while the host draws. What is
# under test is the redraw that comes after it: does the screen catch up
# once setup finishes, and does it still repaint afterwards.
if (-not $Only -or $Only -eq "copilot-mcp") {
  $copilot = (Get-Command copilot -ErrorAction SilentlyContinue).Source
  if (-not $copilot) {
    Write-Host "  note: copilot CLI not installed, skipping" -ForegroundColor DarkYellow
  } else {
    # A launcher rather than a typed command line: the config is nested
    # JSON, and Send-Text types it one VkKeyScan at a time, which is both
    # slow and layout-dependent. A file is neither.
    # Char 92 is a backslash and char 47 a forward slash. Spelling them
    # out avoids a quoted backslash, which is a regex escape here and has
    # been mangled by more than one layer on the way into this file.
    $mcpFixture = (Resolve-Path (Join-Path $PSScriptRoot "fixtures/mcp-slow.mjs")).Path.Replace([char]92, [char]47)
    $mcpJson = '{"mcpServers":{"slow":{"command":"node","args":["' + $mcpFixture + '"]}}}'
    $launcher = Join-Path $scratch "run-copilot-mcp.ps1"
    @(
      '$env:MCP_SLOW_MS = "6000"'
      "& '$copilot' --additional-mcp-config '$mcpJson'"
    ) | Set-Content -Path $launcher -Encoding UTF8
    $skipMcp = $false
    $ctx18 = Start-App "{$baseCfg,`"default_shell`":`"pwsh`",`"history_days`":7}"
    $h18 = $ctx18.Hwnd
    Record-Scene "copilot-mcp" 70 $ctx18 {
      Run-Cmd 'echo before-copilot-mcp' 2
      $script:mcShell = Capture-Window $h18
      Run-Cmd "& '$launcher'" 0
      # Nothing starts until the folder-trust dialog is answered - the
      # first attempt at this scene measured a stretch of time in which
      # copilot was correctly waiting for a keypress, and read the
      # stillness as the bug. Answer it, then measure.
      $null = Wait-Drawn $h18 $mcShell 75
      $script:mcTrust = Wait-Settled $h18 45
      Key $VK_RETURN                  # first option: this session only
      # Mid-setup: the server has not answered initialize yet.
      Start-Sleep -Seconds 3
      $script:mcDuring = Capture-Window $h18
      # Well past it, with everything the children wrote already on screen.
      Start-Sleep -Seconds 15
      $script:mcAfter = Capture-Window $h18
      Start-Sleep -Seconds 3
      $script:mcIdle = Capture-Window $h18
      # Letters, not arrows. The dialog is gone by now and what is up is
      # the composer, where arrows move a cursor through empty text and
      # change nothing on screen - inert by design, and it read as a
      # freeze until the frames were looked at. Never submitted.
      Send-Text "hello"
      Start-Sleep -Seconds 3
      $script:mcTyped = Capture-Window $h18
      Key 0x43 @([byte]$VK_CTRL)
      Start-Sleep -Seconds 1
      Key 0x43 @([byte]$VK_CTRL)
      Start-Sleep -Seconds 4
    }
    $floor = 0.001
    $idle = Frame-Diff $mcAfter $mcIdle -IgnoreBottom 40
    $m1 = Frame-Diff $mcShell $mcTrust
    # As in the scene above: no alternate screen means no full-screen
    # program ran here, which is a signed-out machine rather than a fault.
    if (-not ((Transcripts) -match [regex]::Escape("$([char]27)[?1049h"))) {
      Write-Host "  note: copilot never opened a full-screen UI (not signed in) - nothing for this scene to test" -ForegroundColor DarkYellow
      $skipMcp = $true
    }
    if ($skipMcp) { }
    elseif ($m1 -gt 0.01) { Pass "an agent CLI with MCP servers takes the screen while they start" }
    else { Fail "copilot-mcp" ("nothing was drawn during setup ({0:p1}), though it did enter the alternate screen" -f $m1) }
    # Trust answered to finished screen, with a slow child starting
    # underneath it the whole time. Not measured from the mid-setup frame:
    # copilot does not wait for its servers before drawing, so that frame
    # already matched the finished one and the comparison said nothing.
    $m2 = Frame-Diff $mcTrust $mcAfter -IgnoreBottom 40
    if ($skipMcp) { }
    elseif ($m2 -gt $floor -and $m2 -gt $idle) { Pass "and draws its way to a finished screen while they start" }
    else { Fail "copilot-mcp" ("the screen never moved past setup ({0:p2} against {1:p2} idle) - this is the reported symptom" -f $m2, $idle) }
    $m3 = Frame-Diff $mcIdle $mcTyped -IgnoreBottom 40
    if ($skipMcp) { }
    elseif ($m3 -gt $floor -and $m3 -gt $idle) { Pass "and it still repaints on input afterwards" }
    else { Fail "copilot-mcp" ("input stopped repainting after setup ({0:p2}) - this is the reported symptom" -f $m3) }
    # Reported, not asserted: whether the server's stderr survived in the
    # transcript. It is written straight into someone else's alternate
    # screen, and ConPTY re-renders over it, so its absence says nothing.
    # Reports the transcript size alongside the match, because "no" on its
    # own is unreadable: it means the same thing whether the server's
    # stderr was kept out of the terminal or no transcript was recorded at
    # all. The first time this printed, it was the second.
    $t18 = Transcripts
    $noise = "{0} chars, mcp-slow x{1}" -f $t18.Length, ([regex]::Matches($t18, "mcp-slow")).Count
    Write-Host ("  changed: setup {0:p1}, draw {1:p2}, idle {2:p2}, input {3:p2}; server noise in transcript: {4}" -f $m1, $m2, $idle, $m3, $noise) -ForegroundColor DarkGray
    # Mirrors the assertions above exactly. An earlier version did not,
    # and a failing run saved nothing to look at.
    if (-not $skipMcp -and ($m1 -le 0.01 -or -not ($m2 -gt $floor -and $m2 -gt $idle) -or -not ($m3 -gt $floor -and $m3 -gt $idle))) {
      $dump = Join-Path $outDir "copilot-mcp-frames"
      New-Item -ItemType Directory -Force $dump | Out-Null
      $i = 0
      foreach ($f in $mcShell, $mcTrust, $mcDuring, $mcAfter, $mcIdle, $mcTyped) {
        $f.Save((Join-Path $dump "$i.png"), [System.Drawing.Imaging.ImageFormat]::Png); $i++
      }
      Write-Host "  frames saved to $dump" -ForegroundColor DarkGray
    }
    foreach ($b in $mcShell, $mcTrust, $mcDuring, $mcAfter, $mcIdle, $mcTyped) { $b.Dispose() }
    Stop-App $ctx18
  }
}

# == scene: Ctrl+C against a running command ============================
# The key experts hit most, and the one thing this project could not test
# until now. The daemon-level suite writes the same byte down the same
# socket and never interrupts anything, on any shell, on any version -
# while pressing the key in a real window interrupts both a cmdlet and a
# native program on the same machine, minutes apart. Nothing in between
# explains it: the window's Ctrl+C is term.onData to write_session to
# Request::Write, and the daemon writes it straight to the pty.
#
# So it is tested here, where it works, by pressing the actual key.
#
# The timing is the assertion. A thirty-second sleep is started, the key
# is pressed three seconds in, and an arithmetic command is typed straight
# after. If the interrupt landed, its answer is in the transcript within
# seconds. If it did not, the shell is still sleeping and the typed line
# sits in the buffer until long after this scene has finished looking -
# so the answer being there means the command really was interrupted.
if (-not $Only -or $Only -eq "ctrlc") {
  $ctx19 = Start-App "{$baseCfg,`"default_shell`":`"pwsh`",`"history_days`":7}"
  $h19 = $ctx19.Hwnd
  Record-Scene "ctrlc" 45 $ctx19 {
    Run-Cmd 'echo ctrlc-scene-ready' 3
    # First: does the key reach the terminal at all? At an idle prompt
    # PSReadLine cancels the half-typed line and draws a fresh one, which
    # is visible in the transcript. Without this, a failure below cannot
    # tell "the interrupt did nothing" from "the keystroke never arrived",
    # and a synthetic Ctrl+C is not obviously the same as a real one.
    Send-Text "ctrlc-abandoned-line"
    Start-Sleep -Seconds 1
    Key 0x43 @([byte]$VK_CTRL)
    Start-Sleep -Seconds 2
    Run-Cmd 'echo (86420+1)' 3
    Start-Sleep -Seconds 1
    $script:afterPrompt = Transcripts
    # A cmdlet: interrupted by the shell's own handler.
    Run-Cmd 'Start-Sleep -Seconds 30' 0
    Start-Sleep -Seconds 3
    Key 0x43 @([byte]$VK_CTRL)
    Start-Sleep -Seconds 2
    Run-Cmd 'echo (24680+1)' 3
    Start-Sleep -Seconds 1
    $script:afterCmdlet = Transcripts
    # A native program, which is interrupted by a different path: the
    # console sends it the event rather than the shell handling it.
    Run-Cmd 'ping -n 30 127.0.0.1' 0
    Start-Sleep -Seconds 3
    Key 0x43 @([byte]$VK_CTRL)
    Start-Sleep -Seconds 2
    Run-Cmd 'echo (13570+1)' 3
    Start-Sleep -Seconds 1
    $script:afterNative = Transcripts
  }
  # 24681 rather than a word: its digits appear nowhere in what was typed,
  # so finding it proves a command ran rather than that keystrokes echoed.
  # What the shell actually did with the key, so a failure says whether it
  # never arrived or arrived and did nothing.
  $tailC = ($afterCmdlet -replace "[`r`n]", " ")
  Write-Host ("  after the interrupt: ...{0}" -f $tailC.Substring([Math]::Max(0, $tailC.Length - 220))) -ForegroundColor DarkGray
  # 86421 can only appear if the abandoned line was cancelled and the
  # shell took a new one - proof the keystroke arrived.
  if ($afterPrompt -match "86421") { Pass "the key reaches the terminal: Ctrl+C abandons a half-typed line" }
  else { Fail "ctrlc" "a synthetic Ctrl+C never reached the terminal - everything below is untested" }
  if ($afterCmdlet -match "24681") { Pass "Ctrl+C interrupts a running cmdlet and the prompt comes back" }
  else { Fail "ctrlc" "the shell was still sleeping - nothing typed after the interrupt ran" }
  if ($afterNative -match "13571") { Pass "and interrupts a native program too" }
  else { Fail "ctrlc" "ping was still running - nothing typed after the interrupt ran" }
  # Guards against the scene passing for the wrong reason: the setup line
  # has to be there, or the shell never ran anything and the two checks
  # above were looking at an empty transcript.
  if ($afterCmdlet -match "ctrlc-scene-ready") { Pass "and the session was live throughout" }
  else { Fail "ctrlc" "no transcript for this scene - it did not run as expected" }
  Stop-App $ctx19
}

# == scene: the three ways to ask for the alternate screen ==============
# Suggested as a cause for a program that runs but whose redraws never
# land, and worth testing rather than arguing about: every full-screen
# thing this suite covers - vim, copilot, the fixture - asks with ?1049h,
# so the older spellings have never been exercised here at all. A terminal
# that honours one and ignores another looks exactly like the report: the
# program is running, the screen never becomes the program's.
if (-not $Only -or $Only -eq "altscreen") {
  $ctx20 = Start-App "{$baseCfg,`"default_shell`":`"pwsh`",`"history_days`":7}"
  $h20 = $ctx20.Hwnd
  $fixture = (Resolve-Path (Join-Path $PSScriptRoot "fixtures/altscreen.ps1")).Path
  Record-Scene "altscreen" 40 $ctx20 {
    Run-Cmd 'echo altscreen-scene-ready' 2
    $script:asShell = Capture-Window $h20
    Run-Cmd "& '$fixture'" 0
    Start-Sleep -Seconds 2
    $script:as47 = Capture-Window $h20        # inside ?47h
    Start-Sleep -Seconds 4
    $script:as1047 = Capture-Window $h20      # inside ?1047h
    Start-Sleep -Seconds 4
    $script:as1049 = Capture-Window $h20      # inside ?1049h
    Start-Sleep -Seconds 5
    $script:asAfter = Capture-Window $h20     # back to the shell
    $script:asOut = Transcripts
  }
  # A screen filled with colour moves most of the pixels, so these are the
  # fixture's own thresholds rather than the ones a text program needs.
  foreach ($v in @(@("47", $as47), @("1047", $as1047), @("1049", $as1049))) {
    $moved = Frame-Diff $asShell $v[1] -IgnoreBottom 40
    if ($moved -gt 0.2) { Pass ("the screen becomes the program's with ?$($v[0])h ({0:p0})" -f $moved) }
    else { Fail "altscreen" ("?$($v[0])h did not take the screen ({0:p1} changed) - a program using this spelling would look stuck" -f $moved) }
  }
  $backAgain = Frame-Diff $as1049 $asAfter -IgnoreBottom 40
  if ($backAgain -gt 0.2) { Pass "and the shell has its screen back at the end" }
  else { Fail "altscreen" ("the last alternate screen was never left ({0:p1})" -f $backAgain) }
  if ($asOut -match "ALTSCREEN-FIXTURE-DONE") { Pass "and the fixture ran to completion" }
  else { Fail "altscreen" "the fixture did not finish - the frames above prove nothing" }
  Write-Host ("  changed: ?47h {0:p0}, ?1047h {1:p0}, ?1049h {2:p0}, back {3:p0}" -f (Frame-Diff $asShell $as47 -IgnoreBottom 40), (Frame-Diff $asShell $as1047 -IgnoreBottom 40), (Frame-Diff $asShell $as1049 -IgnoreBottom 40), $backAgain) -ForegroundColor DarkGray
  foreach ($b in $asShell, $as47, $as1047, $as1049, $asAfter) { $b.Dispose() }
  Stop-App $ctx20
}

# == scene: the same full-screen program, on the other renderer =========
# Everything above runs the WebGL renderer, because the default theme has
# no background image. A theme with one - which is what the reported
# machine runs - makes the app dispose WebGL and fall back to the DOM
# renderer, and that path has never drawn a full-screen program in any
# test here.
#
# It is the difference that fits the report best: a program that takes the
# screen with ?1049h and then repaints, where the repaints never land. The
# sequence is not the suspect - it is covered three ways already - but the
# renderer underneath it was never looked at.
if (-not $Only -or $Only -eq "tui-bg") {
  $ctx21 = Start-App "{$baseCfg,`"default_shell`":`"pwsh`",`"theme`":`"bladerunner`"}"
  $h21 = $ctx21.Hwnd
  $fixture = Join-Path $repo "tests\fixtures\tui.ps1"
  Record-Scene "tui-bg" 32 $ctx21 {
    Run-Cmd 'echo before-the-tui-bg' 2
    $script:bgShell = Capture-Window $h21
    Run-Cmd "& '$fixture' -Frames 3 -Ms 2600" 0
    Start-Sleep -Milliseconds 1400
    $script:bgA = Capture-Window $h21
    Start-Sleep -Milliseconds 2600
    $script:bgB = Capture-Window $h21
    Start-Sleep -Milliseconds 2600
    $script:bgC = Capture-Window $h21
    Start-Sleep -Seconds 4
    $script:bgAfter = Capture-Window $h21
  }
  # Lower thresholds than the WebGL scene: a background image shows
  # through the terminal, so a screen of colour fills moves less of it.
  $e1 = Frame-Diff $bgShell $bgA
  if ($e1 -gt 0.20) { Pass "a full-screen program takes the screen on the DOM renderer too" }
  else { Fail "tui-bg" ("the screen barely changed when the program started ({0:p0})" -f $e1) }
  $e2 = Frame-Diff $bgA $bgB
  if ($e2 -gt 0.20) { Pass "and each redraw reaches it" }
  else { Fail "tui-bg" ("frame 2 looks like frame 1 ({0:p0} changed) - this is the reported symptom, on the renderer the report came from" -f $e2) }
  $e3 = Frame-Diff $bgB $bgC
  if ($e3 -gt 0.20) { Pass "and keeps reaching it, frame after frame" }
  else { Fail "tui-bg" ("frame 3 looks like frame 2 ({0:p0} changed)" -f $e3) }
  $e4 = Frame-Diff $bgC $bgAfter
  if ($e4 -gt 0.20) { Pass "and the shell comes back when it exits" }
  else { Fail "tui-bg" ("the last frame stayed on screen after it exited ({0:p0})" -f $e4) }
  Write-Host ("  changed: start {0:p0}, frame2 {1:p0}, frame3 {2:p0}, exit {3:p0}" -f $e1, $e2, $e3, $e4) -ForegroundColor DarkGray
  if ($e1 -le 0.20 -or $e2 -le 0.20 -or $e3 -le 0.20) {
    $dump = Join-Path $outDir "tui-bg-frames"
    New-Item -ItemType Directory -Force $dump | Out-Null
    $i = 0
    foreach ($f in $bgShell, $bgA, $bgB, $bgC, $bgAfter) {
      $f.Save((Join-Path $dump "$i.png"), [System.Drawing.Imaging.ImageFormat]::Png); $i++
    }
    Write-Host "  frames saved to $dump" -ForegroundColor DarkGray
  }
  foreach ($b in $bgShell, $bgA, $bgB, $bgC, $bgAfter) { $b.Dispose() }
  Stop-App $ctx21
}

# == scene: what this terminal answers when asked about a mode ==========
# DECRQM is how a program decides whether to use a feature, and a wrong
# answer is worse than no answer: told yes, it commits to something the
# terminal will not honour and its frames can stop appearing while
# everything else looks fine. Raised as a candidate for exactly that
# report, and nothing here had ever looked at a single reply.
#
# The replies travel from the terminal towards the program, which is the
# one direction transcripts do not record, so the fixture reads them and
# prints them back into its own output.
if (-not $Only -or $Only -eq "decrqm") {
  $ctx22 = Start-App "{$baseCfg,`"default_shell`":`"pwsh`",`"history_days`":7,`"log_level`":`"debug`"}"
  $h22 = $ctx22.Hwnd
  $fixture = Join-Path $repo "tests\fixtures\decrqm.ps1"
  Record-Scene "decrqm" 30 $ctx22 {
    Run-Cmd 'echo decrqm-scene-ready' 2
    Run-Cmd "& '$fixture'" 0
    Start-Sleep -Seconds 8
    $script:rqmOut = Transcripts
  }
  foreach ($line in ($rqmOut -split "`n" | Where-Object { $_ -match "DECRQM " })) {
    Write-Host ("  " + ($line.Trim() -replace "`r", "")) -ForegroundColor DarkGray
  }
  # The ANSI form, with no "?" - the half the console host may pass
  # through to the terminal's own handler, which is where a crash was
  # reported. The question is not what it answers but whether drawing
  # survives being asked: a handler that throws takes the rest of the
  # parser's chunk with it, so a paint issued in the same write is lost
  # while the program believes it drew.
  $ansiFixture = Join-Path $repo "tests/fixtures/decrqm-ansi.ps1"
  $script:beforeAnsi = Capture-Window $h22
  Run-Cmd "& '$ansiFixture'" 0
  # Four queries at 600ms each, then the query-plus-paint write. Five
  # seconds lands inside the paint rather than after it.
  Start-Sleep -Seconds 5
  $script:duringAnsi = Capture-Window $h22
  Start-Sleep -Seconds 10
  $rqmOut = Transcripts
  foreach ($line in ($rqmOut -split "`n" | Where-Object { $_ -match "ANSI-DECRQM " })) {
    Write-Host ("  " + ($line.Trim() -replace "`r", "")) -ForegroundColor DarkGray
  }
  $painted = Frame-Diff $beforeAnsi $duringAnsi -IgnoreBottom 40
  if ($painted -gt 0.2) { Pass ("a paint issued in the same write as a mode query still reaches the screen ({0:p0})" -f $painted) }
  else { Fail "decrqm" ("nothing was drawn after the query ({0:p1}) - a handler that throws takes the rest of the write with it, which is what a crash in this code looks like" -f $painted) }
  # And the window's own log, which is where such a crash surfaces.
  $uiLog = Join-Path $scratch "GTerminal/ui.log"
  if (Test-Path $uiLog) {
    $errs = @(Get-Content $uiLog | Where-Object { $_ -match "is not defined|TypeError|ReferenceError" })
    if ($errs.Count -eq 0) { Pass "and the window logged no scripting error while being asked" }
    else {
      Fail "decrqm" "the window logged an error: $($errs[0])"
      $errs | Select-Object -First 3 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    }
  } else {
    Write-Host "  note: no ui.log written, so nothing could be checked in it" -ForegroundColor DarkYellow
  }
  foreach ($b in $beforeAnsi, $duringAnsi) { $b.Dispose() }
  if ($rqmOut -match "DECRQM-FIXTURE-DONE") { Pass "the fixture asked every question and survived the answers" }
  else { Fail "decrqm" "the fixture did not finish - a reply may have hung it" }
  # A reply at all, for a mode the terminal implements. Silence here is
  # its own failure: a program waiting on an answer that never comes is
  # one of the ways a screen ends up stuck.
  if ($rqmOut -match "alternate-screen \(1049\) -> <ESC>") { Pass "and answers about the alternate screen" }
  else { Fail "decrqm" "no reply to a DECRQM for 1049 - a program waiting on one would hang" }
  # The one that matters for redraws. xterm.js pauses all drawing between
  # ?2026h and ?2026l, so claiming support for a mode whose sequences do
  # not survive the pty is how frames stop landing.
  $sync = ($rqmOut -split "`n" | Where-Object { $_ -match "synchronized-output" }) -join " "
  Write-Host ("  synchronized output: {0}" -f ($sync.Trim() -replace "`r", "")) -ForegroundColor DarkGray
  if ($sync -match "-> <ESC>") {
    # 2 means "reset", 1 "set", 3/4 permanently so; 0 means "not
    # recognised". Anything but 0 is a promise the pty has to keep.
    if ($sync -match "2026;0") { Pass "and does not claim synchronized output it cannot deliver" }
    else { Fail "decrqm" "this terminal claims synchronized output ($($sync.Trim())), but ?2026h and ?2026l do not survive ConPTY - a program taking that promise would pause a second per frame" }
  } else {
    Pass "and says nothing about synchronized output, which promises nothing"
  }
  Stop-App $ctx22
}

# ══ scene: tray ════════════════════════════════════════════════════════
if (-not $Only -or $Only -eq "tray") {
  # Its own hotkey: if anything from an earlier scene is still alive and
  # holding Ctrl+Alt+F9, this scene's registration would fail silently
  # and look like summoning is broken.
  $trayCfg = $baseCfg.Replace("Control+Alt+F9", "Control+Alt+F8")
  $ctx = Start-App "{$trayCfg,`"default_shell`":`"pwsh`"}"
  $h = $ctx.Hwnd
  Record-Scene "tray" 26 $ctx {
    Run-Cmd 'echo "watch this go away"' 2
    # Resize: the fit path, which decides how many rows the shell gets.
    [void]$U::SetWindowPos($h, [IntPtr]::Zero, 100, 60, 980, 620, 0x0004)
    Start-Sleep -Seconds 2
    [void]$U::SetWindowPos($h, [IntPtr]::Zero, 100, 60, $RECW, $RECH, 0x0004)
    Start-Sleep -Seconds 2
    # Close fades it out to the tray; the hotkey brings it back. The fade
    # is layered-window alpha, so it can be measured rather than watched:
    # sample while it goes. A window that jumps straight from opaque to
    # gone is the jank this replaced — one sample at 255 and the next at
    # nothing, with no ramp in between.
    $script:fadeSteps = @()
    [void]$U::PostMessage($h, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
    foreach ($i in 1..60) {
      $k = 0; $a = [byte]0; $f = 0
      if ($U::GetLayeredWindowAttributes($h, [ref]$k, [ref]$a, [ref]$f)) {
        $script:fadeSteps += [int]$a
      }
      if (-not $U::IsWindowVisible($h)) { break }
      Start-Sleep -Milliseconds 8
    }
    Start-Sleep -Seconds 3
    $script:hidOk = -not $U::IsWindowVisible($h)
    Release-Modifiers
    $U::keybd_event(0x11,0,0,[UIntPtr]::Zero)
    $U::keybd_event(0x12,0,0,[UIntPtr]::Zero)
    $U::keybd_event(0x77,0,0,[UIntPtr]::Zero)
    Start-Sleep -Milliseconds 80
    $U::keybd_event(0x77,0,2,[UIntPtr]::Zero)
    $U::keybd_event(0x12,0,2,[UIntPtr]::Zero)
    $U::keybd_event(0x11,0,2,[UIntPtr]::Zero)
    # Poll rather than sample once, and press again halfway. A single
    # check turns a slow summon into a failure indistinguishable from a
    # broken one — and this scene runs last, after two video encodes have
    # had the CPU, so slow is the normal case here rather than the odd one.
    $script:backOk = $false
    foreach ($i in 1..30) {
      Start-Sleep -Milliseconds 400
      if ($U::IsWindowVisible($h)) { $script:backOk = $true; break }
      if ($i -eq 12) {
        $U::keybd_event(0x11,0,0,[UIntPtr]::Zero)
        $U::keybd_event(0x12,0,0,[UIntPtr]::Zero)
        $U::keybd_event(0x77,0,0,[UIntPtr]::Zero)
        Start-Sleep -Milliseconds 80
        $U::keybd_event(0x77,0,2,[UIntPtr]::Zero)
        $U::keybd_event(0x12,0,2,[UIntPtr]::Zero)
        $U::keybd_event(0x11,0,2,[UIntPtr]::Zero)
      }
    }
    Start-Sleep -Seconds 2
    # And away again on *one* press, with the window in front. This used
    # to take two: the toggle asked Tauri whether the window was focused,
    # which answers for the window while the keyboard focus is in the
    # WebView2 child, so a window plainly in front called itself unfocused
    # and the first press re-summoned it instead of hiding it.
    $script:onePress = $false
    if ($script:backOk) {
      [void]$U::SetForegroundWindow($h)
      Start-Sleep -Milliseconds 600
      Release-Modifiers
      $U::keybd_event(0x11,0,0,[UIntPtr]::Zero)
      $U::keybd_event(0x12,0,0,[UIntPtr]::Zero)
      $U::keybd_event(0x77,0,0,[UIntPtr]::Zero)
      Start-Sleep -Milliseconds 80
      $U::keybd_event(0x77,0,2,[UIntPtr]::Zero)
      $U::keybd_event(0x12,0,2,[UIntPtr]::Zero)
      $U::keybd_event(0x11,0,2,[UIntPtr]::Zero)
      foreach ($i in 1..20) {
        Start-Sleep -Milliseconds 250
        if (-not $U::IsWindowVisible($h)) { $script:onePress = $true; break }
      }
    }
    Start-Sleep -Seconds 1
  }
  if ($hidOk) { Pass "close hides the window and leaves the app running" }
  else { Fail "tray" "close did not hide the window" }
  if ($backOk) { Pass "the summon hotkey brings the window back" }
  else { Fail "tray" "the window did not come back from the tray" }
  if ($onePress) { Pass "and puts it away again on one press, not two" }
  else { Fail "tray" "the hotkey did not hide the window it had just summoned" }
  # Three or more distinct levels on the way down is a fade; one or two is
  # the window blinking out, which is what this replaced.
  $levels = @($fadeSteps | Select-Object -Unique)
  Write-Host "  alpha while hiding: $($fadeSteps -join ' ')" -ForegroundColor DarkGray
  if ($levels.Count -ge 3) { Pass "the window fades out rather than blinking away" }
  else { Fail "fade" "only $($levels.Count) alpha level(s) seen on the way out: $($fadeSteps -join ',')" }
  $backwards = $false
  for ($i = 1; $i -lt $fadeSteps.Count; $i++) {
    if ($fadeSteps[$i] -gt $fadeSteps[$i - 1]) { $backwards = $true }
  }
  if (-not $backwards) { Pass "and only ever gets fainter" }
  else { Fail "fade" "the fade brightened part way through: $($fadeSteps -join ',')" }
  # Left transparent, the window would come back invisible — worse than
  # having no animation at all, and only visible on the *next* summon.
  $k = 0; $a = [byte]0; $f = 0
  $known = $U::GetLayeredWindowAttributes($h, [ref]$k, [ref]$a, [ref]$f)
  if (-not $known -or $a -eq 255) { Pass "and is fully opaque again once it is back" }
  else { Fail "fade" "the window came back at alpha $a" }
  # And not still layered. WS_EX_LAYERED is how the fade is drawn, but a
  # layered WebView2 window is composited down a slower path — left set,
  # it charges every later keystroke and every full-screen redraw for an
  # animation that finished. Reported as typing lag, and as a full-screen
  # program stuck on old output.
  $WS_EX_LAYERED = [IntPtr]0x00080000
  $ex = $U::GetWindowLongPtr($h, -20)   # GWL_EXSTYLE
  if (([int64]$ex -band [int64]$WS_EX_LAYERED) -eq 0) { Pass "and is not left layered afterwards" }
  else { Fail "fade" "the window is still WS_EX_LAYERED after the fade" }
  Stop-App $ctx
}

# ── cleanup ──
if ($savedClipboard) { Set-Clipboard -Value $savedClipboard }
Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
Remove-Item "$scratch\GTerminal" -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Get-ChildItem $outDir -Filter *.avi | ForEach-Object {
  "  {0,-14} {1,6:n1} MB" -f $_.Name, ($_.Length / 1MB)
}
if ($failures.Count) { exit 1 }
"all visual tests passed"
exit 0
