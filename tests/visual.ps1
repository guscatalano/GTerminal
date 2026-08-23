# Visual tests: drive a real window through things you can only judge by
# looking, and record each scene as a video.
#
#   npm run test:visual              -> docs/visual/*.avi + *.gif
#   npm run test:visual -- -Only cmd -> just that scene
#   npm run test:visual -- -Yes      -> skip the countdown (unattended)
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
  [string]$Only = ""
)
$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
$exe = Join-Path $repo "src-tauri\target\debug\gterminal.exe"
if (-not (Test-Path $exe)) { Write-Error "build first: cargo build in src-tauri" }

$failures = @()
function Pass { param($n) Write-Host "PASS $n" -ForegroundColor Green }
function Fail { param($n, $d) $script:failures += "${n}: $d"; Write-Host "FAIL ${n}: $d" -ForegroundColor Red }

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
$scenes = @("pwsh", "paste", "cmd", "tray")
if (-not $Only) {
  $bad = 0
  foreach ($s in $scenes) {
    Write-Host ""
    Write-Host "── scene: $s ──" -ForegroundColor Cyan
    & pwsh -NoProfile -File $PSCommandPath -Yes -Only $s
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

$savedClipboard = try { Get-Clipboard -Raw } catch { "" }
$RECW = 1280; $RECH = 800
$outDir = Join-Path $repo "docs\visual"
New-Item -ItemType Directory -Force $outDir | Out-Null

function Start-App {
  param([string]$config)
  Remove-Item "$scratch\GTerminal" -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force "$scratch\GTerminal" | Out-Null
  Set-Content "$scratch\GTerminal\config.json" $config
  $app = Start-Process -FilePath $exe -PassThru
  $hwnd = [IntPtr]::Zero
  foreach ($i in 1..60) {
    Start-Sleep -Milliseconds 500
    $app.Refresh()
    if ($app.MainWindowHandle -ne 0) { $hwnd = $app.MainWindowHandle; break }
  }
  if ($hwnd -eq [IntPtr]::Zero) { throw "the window never appeared" }
  $ours = @($app.Id) + @(
    Get-Process gterminal -ErrorAction SilentlyContinue |
      Where-Object { $_.Id -ne $app.Id -and $_.StartTime -ge $app.StartTime.AddSeconds(-2) } |
      Select-Object -ExpandProperty Id
  )
  Set-Content $pidFile -Value $ours
  # Pin the size and record a canvas to match, so the busiest state is
  # captured 1:1. Terminal text does not survive being scaled down.
  [void]$U::SetWindowPos($hwnd, [IntPtr]::Zero, 100, 60, $RECW, $RECH, 0x0004)
  Start-Sleep -Seconds 5
  Focus-Pane $hwnd
  [pscustomobject]@{ App = $app; Hwnd = $hwnd; Pids = $ours }
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
  }
  if ($U::IsWindowVisible($ctx.Hwnd)) { Pass "pwsh scene: the window came through it" }
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
    Set-Clip "echo `"first pasted line`"`necho `"second pasted line`"`necho `"third pasted line`"" $ph
    Key 0x56 @([byte]$VK_CTRL)      # Ctrl+V — the warning should appear
    Start-Sleep -Seconds 6          # dwell on the dialog: it is the point
    Key $VK_RETURN                  # confirm
    Start-Sleep -Seconds 5
    # And a small paste, which must go straight in with no dialog.
    Set-Clip 'echo "a short paste"' $ph
    Key 0x56 @([byte]$VK_CTRL)
    Start-Sleep -Seconds 2
    Key $VK_RETURN
    Start-Sleep -Seconds 4
  }
  if ($U::IsWindowVisible($ctx.Hwnd)) { Pass "paste scene: the window came through it" }
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
  }
  if ($U::IsWindowVisible($ctx.Hwnd)) { Pass "cmd scene: the window came through it" }
  else { Fail "cmd" "the window did not survive the scene" }
  Stop-App $ctx
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
    # Close slides it out to the tray; the hotkey brings it back.
    [void]$U::PostMessage($h, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
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
  }
  if ($hidOk) { Pass "close hides the window and leaves the app running" }
  else { Fail "tray" "close did not hide the window" }
  if ($backOk) { Pass "the summon hotkey brings the window back" }
  else { Fail "tray" "the window did not come back from the tray" }
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
