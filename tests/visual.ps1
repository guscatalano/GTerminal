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
$scenes = @("pwsh", "paste", "cmd", "switch", "restore", "restore-none", "restore-zero", "restore-again", "copy", "hover", "clipboard", "cliphist", "tui", "tray")
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
  param($a, $b, $step = 8, $tolerance = 24)
  $w = [Math]::Min($a.Width, $b.Width)
  $h = [Math]::Min($a.Height, $b.Height)
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
  param([int]$count, [string]$config)
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
    $ids += ($rd.ReadLine() | ConvertFrom-Json).id
    $c.Close()
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
    Send-Text 'echo this should never run'
    Start-Sleep -Seconds 1
    Key 0x43 @([byte]$VK_CTRL)      # Ctrl+C
    Start-Sleep -Seconds 2
    Run-Cmd 'echo still alive' 3
    $script:cmdOut = Transcripts
  }
  if ($cmdOut -match "1235") { Pass "cmd: set /a is evaluated, not just echoed" }
  else { Fail "cmd" "set /a 1234+1 never produced 1235" }
  # Ctrl+C must abandon the line rather than run it. cmd would print the
  # text if it ran, so its absence is the assertion - paired with a
  # command afterwards, or "absent" would also be true of a dead shell.
  if ($cmdOut -notmatch "this should never run") { Pass "and Ctrl+C abandons a half-typed line" }
  else { Fail "cmd" "the abandoned line ran anyway" }
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
    Start-Sleep -Seconds 2
    Click ($sh) 100 47                             # first row, on its label
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
    if ($t3 -match "XXTOP") { Pass "and survives a click on a sidebar row" }
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
  Record-Scene "restore-zero" 26 $ctx4 {
    Start-Sleep -Seconds 4
    Click $hw4 798 556             # None — unticks every row
    Start-Sleep -Seconds 2
    Click $hw4 895 556             # the button, now reading "Restore 0"
    Start-Sleep -Seconds 10
  }
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
