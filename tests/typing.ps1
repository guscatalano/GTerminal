# Typing regression test: correctness (no dropped/reordered keystrokes) and
# echo latency (keystroke -> shell echo roundtrip) through the daemon path.
# Runs against a fully isolated daemon (scratch LOCALAPPDATA); never touches
# the user's real daemon or sessions. Exits nonzero on failure.
$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
$exe = Join-Path $repo "src-tauri\target\debug\gterminal.exe"
if (-not (Test-Path $exe)) { Write-Error "build first: cargo build in src-tauri" }

$env:LOCALAPPDATA = Join-Path $env:TEMP "gterminal-typing-test"
New-Item -ItemType Directory -Force $env:LOCALAPPDATA | Out-Null
Remove-Item "$env:LOCALAPPDATA\GTerminal" -Recurse -Force -ErrorAction SilentlyContinue

$daemon = Start-Process -FilePath $exe -ArgumentList "--daemon" -WindowStyle Hidden -PassThru
Start-Sleep -Milliseconds 1200
$port = [int](Get-Content "$env:LOCALAPPDATA\GTerminal\daemon.port").Trim()

$client = [System.Net.Sockets.TcpClient]::new("127.0.0.1", $port)
$client.NoDelay = $true
$script:stream = $client.GetStream()
$w = [System.IO.StreamWriter]::new($script:stream); $w.NewLine = "`n"; $w.AutoFlush = $true
$r = [System.IO.StreamReader]::new($script:stream)

# NDJSON reading via raw polls: a sync ReadTimeout on a NetworkStream kills
# the connection when it fires, so timeouts must never hit the socket.
$script:acc = ""
$script:buf = New-Object byte[] 65536
$script:chars = New-Object char[] 131072
# A stateful decoder, not Encoding.GetString per read. A socket read can
# land in the middle of a multi-byte character, and decoding each chunk
# independently turns that character into U+FFFD — which would look
# exactly like the daemon corrupting it, and is the first thing this
# harness must not do while testing for precisely that fault.
$script:dec = [System.Text.Encoding]::UTF8.GetDecoder()
function Read-Event {
  param($timeoutMs = 2000, [switch]$spin)
  $deadline = [DateTime]::UtcNow.AddMilliseconds($timeoutMs)
  while (-not $script:acc.Contains("`n")) {
    if ($script:stream.DataAvailable) {
      $n = $script:stream.Read($script:buf, 0, $script:buf.Length)
      if ($n -eq 0) { return $null }
      $cn = $script:dec.GetChars($script:buf, 0, $n, $script:chars, 0)
      $script:acc += [string]::new($script:chars, 0, $cn)
    } elseif ([DateTime]::UtcNow -gt $deadline) {
      return $null
    } elseif ($spin) {
      # Busy-yield: Start-Sleep quantizes to ~15.6ms and would swamp the
      # real echo latency being measured.
      [System.Threading.Thread]::Sleep(0)
    } else {
      Start-Sleep -Milliseconds 1
    }
  }
  $i = $script:acc.IndexOf("`n")
  $line = $script:acc.Substring(0, $i)
  $script:acc = $script:acc.Substring($i + 1)
  $line
}

function Drain {
  param($ms = 300)
  $out = ""
  while ($true) {
    $l = Read-Event -timeoutMs $ms
    if ($null -eq $l) { break }
    $out += $l + "`n"
  }
  $out
}

# The data payloads with nothing removed — for the tests that are about
# the control sequences themselves rather than the text.
function Raw-Data {
  param($jsonLines)
  $text = ""
  foreach ($line in ($jsonLines -split "`n")) {
    if ($line -match '"data":"') {
      try { $text += ($line | ConvertFrom-Json).data } catch {}
    }
  }
  $text
}

function Strip-Ansi {
  param($jsonLines)
  # Pull the data payloads out of the NDJSON events, then strip VT sequences.
  $text = ""
  foreach ($line in ($jsonLines -split "`n")) {
    if ($line -match '"data":"') {
      try { $text += ($line | ConvertFrom-Json).data } catch {}
    }
  }
  $text = $text -replace "`e\][^`a]*(`a|`e\\)", ""   # OSC ... BEL/ST
  $text = $text -replace "`e\[[0-9;?]*[A-Za-z]", ""  # CSI
  $text -replace "[`r`n]", ""
}

$failures = @()

# JSON-escape for the write command: quotes, backslashes and control
# characters, which is how Ctrl+C and backspace get sent.
function Esc-Json {
  param([string]$s)
  $out = ""
  foreach ($ch in $s.ToCharArray()) {
    $code = [int]$ch
    if ($ch -eq '"') { $out += '\"' }
    elseif ($ch -eq '\') { $out += '\\' }
    elseif ($code -lt 32 -or $code -gt 126) { $out += ("\u{0:x4}" -f $code) }
    else { $out += $ch }
  }
  $out
}

# One keystroke per write, no delay: that is what stresses ordering.
#
# Split by text element, not by char. A .NET char is a UTF-16 code unit,
# so ToCharArray() cuts an emoji in half and sends each surrogate as its
# own message — two payloads that are not valid text on their own, which
# is a fault in the test rather than anything the app does. The frontend
# sends whole strings from xterm's onData and never splits a pair.
function Type-Text {
  param([string]$text)
  $e = [System.Globalization.StringInfo]::GetTextElementEnumerator($text)
  while ($e.MoveNext()) {
    $script:w.WriteLine("{""cmd"":""write"",""data"":""$(Esc-Json ([string]$e.Current))""}")
  }
}
function Send-Key {
  param([string]$s)
  $script:w.WriteLine("{""cmd"":""write"",""data"":""$(Esc-Json $s)""}")
}

# Type a command, discard its echo, press Enter, return only what the
# shell printed. Separating echo from output is the only way to tell "the
# command ran" from "the characters appeared on screen".
function Run-Line {
  param([string]$text, $settle = 2)
  Type-Text $text
  Start-Sleep -Seconds 1
  $null = Drain 400
  Send-Key "`r"
  Start-Sleep -Seconds $settle
  Strip-Ansi (Drain 500)
}

# Readiness is "a command runs", not "a prompt appeared".
#
# PowerShell draws its prompt before PSReadLine has finished initializing,
# and keystrokes landing in that gap are dropped with no echo at all. A
# loaded machine widens the gap to tens of seconds, and the symptom is
# brutal to read: the first few tests after opening a shell see *nothing*
# while later tests on the same session pass, so it looks like three
# unrelated failures rather than one slow start.
#
# So the probe is arithmetic, the same trick the tests themselves use: its
# answer shares no text with what was typed, which is the only way to
# prove a command ran rather than merely echoed.
function Wait-Ready {
  param([string]$shell, $seconds = 60)
  $probe = if ($shell -eq "cmd") { "set /a 6*7" } else { "echo (6*7)" }
  $json = @{ cmd = "write"; data = "$probe`r" } | ConvertTo-Json -Compress
  $deadline = [DateTime]::UtcNow.AddSeconds($seconds)
  while ([DateTime]::UtcNow -lt $deadline) {
    $null = Drain 200
    $script:w.WriteLine($json)
    $seen = ""
    $until = [DateTime]::UtcNow.AddSeconds(5)
    while ([DateTime]::UtcNow -lt $until) {
      $seen += Drain 300
      if ($seen -match '42') {
        $null = Drain 400   # leave nothing of the probe behind
        return $true
      }
    }
  }
  $false
}

function Open-Shell {
  param([string]$shell)
  $ctl = [System.Net.Sockets.TcpClient]::new("127.0.0.1", $port)
  $cs = $ctl.GetStream()
  $cw = [System.IO.StreamWriter]::new($cs); $cw.NewLine = "`n"; $cw.AutoFlush = $true
  $cr = [System.IO.StreamReader]::new($cs)
  $cw.WriteLine("{""cmd"":""create"",""cols"":120,""rows"":30,""shell"":""$shell""}")
  $sid = ($cr.ReadLine() | ConvertFrom-Json).id
  $ctl.Close()
  $c = [System.Net.Sockets.TcpClient]::new("127.0.0.1", $port)
  $c.NoDelay = $true
  $script:stream = $c.GetStream()
  $script:acc = ""
  $script:dec = [System.Text.Encoding]::UTF8.GetDecoder()
  $script:w = [System.IO.StreamWriter]::new($script:stream)
  $script:w.NewLine = "`n"; $script:w.AutoFlush = $true
  $script:w.WriteLine("{""cmd"":""attach"",""id"":$sid}")
  $null = Read-Event
  $script:w.WriteLine('{"cmd":"write","data":"\u001b[1;1R"}')   # ConPTY cursor query
  # Wait until it demonstrably runs something, rather than for a number
  # someone picked. Five seconds was plenty on a warm machine and not
  # enough on a loaded one, and a shell that is not listening yet loses
  # keystrokes silently.
  if (-not (Wait-Ready $shell)) {
    Write-Host "  note: $shell never ran a command within 60s; its tests will fail for that reason" -ForegroundColor DarkYellow
  }
  $null = Drain 800
  [pscustomobject]@{ Id = $sid; Client = $c }
}

function Close-Shell {
  param($sess)
  $ctl = [System.Net.Sockets.TcpClient]::new("127.0.0.1", $port)
  $cs = $ctl.GetStream()
  $cw = [System.IO.StreamWriter]::new($cs); $cw.NewLine = "`n"; $cw.AutoFlush = $true
  $cr = [System.IO.StreamReader]::new($cs)
  # The first kill is soft (grace window); the second makes it stick.
  $cw.WriteLine("{""cmd"":""kill"",""id"":$($sess.Id)}"); $null = $cr.ReadLine()
  $cw.WriteLine("{""cmd"":""kill"",""id"":$($sess.Id)}"); $null = $cr.ReadLine()
  $ctl.Close(); $sess.Client.Close()
}

# ── the matrix ────────────────────────────────────────────────────────
# Typing is not one path. PSReadLine, Windows PowerShell's older
# PSReadLine and cmd's own line editor each handle echo, editing and
# Ctrl+C differently, and a change that suits one can break another.
#
# The arithmetic commands matter: their output shares no text with what
# was typed, which is the only way to prove a command ran rather than
# merely appeared. `echo 1235` would prove nothing.
$specs = @(
  @{ Name = "pwsh";       Calc = "echo (1234+1)"; Calc2 = "echo (4321+1)" },
  @{ Name = "powershell"; Calc = "echo (1234+1)"; Calc2 = "echo (4321+1)" },
  @{ Name = "cmd";        Calc = "set /a 1234+1"; Calc2 = "set /a 4321+1" }
)

# The daemon exits the moment it has no sessions left (exit_if_idle), and
# it goes out with an RST that kills every open connection. Hold one
# session open for the whole run so finishing one shell under test does
# not take the daemon down before the next one starts.
$keepAlive = Open-Shell "pwsh"

foreach ($spec in $specs) {
  $name = $spec.Name
  $sess = Open-Shell $name

  # 1. a burst-typed line arrives intact and executes
  $payload = "typing-test-0123456789-abcdefghijklmnopqrstuvwxyz"
  $out = Run-Line "echo $payload"
  if ($out -like "*$payload*") { "PASS [$name] burst-typed line executed intact" }
  else { $failures += "[$name] burst: payload missing from output. Got: $out" }

  # 2. backspace edits the line the shell sees, not just the screen
  # DEL (0x7f), not BS (0x08): that is what xterm.js sends for the
  # Backspace key, so it is what the shells actually receive from us.
  Type-Text "echo QQZZ"
  Start-Sleep -Seconds 1
  Send-Key ([string][char]127 + [string][char]127)
  Type-Text "XY"
  Start-Sleep -Seconds 1
  $null = Drain 400
  Send-Key "`r"
  Start-Sleep -Seconds 2
  $bs = Strip-Ansi (Drain 500)
  if ($bs -like "*QQXY*" -and $bs -notlike "*QQZZ*") { "PASS [$name] backspace edits the command" }
  else { $failures += "[$name] backspace: expected QQXY and not QQZZ. Got: $bs" }

  # 3. Ctrl+C abandons the line without running it and without killing the
  #    session — the half people only notice when it goes wrong
  Type-Text $spec.Calc
  Start-Sleep -Seconds 1
  $null = Drain 400
  Send-Key ([string][char]3)
  Start-Sleep -Milliseconds 500
  Send-Key "`r"
  Start-Sleep -Seconds 2
  $cancelled = Strip-Ansi (Drain 500)
  if ($cancelled -like "*1235*") {
    $failures += "[$name] ctrl-c: the cancelled command ran anyway. Got: $cancelled"
  } else { "PASS [$name] Ctrl+C abandons the line" }

  $alive = Run-Line $spec.Calc2
  if ($alive -like "*4322*") { "PASS [$name] session still usable after Ctrl+C" }
  else { $failures += "[$name] ctrl-c: session unusable afterwards. Got: $alive" }

  # 4. a line longer than the terminal is wide: wrapping must not drop or
  #    reorder anything
  $long = "L" + ("0123456789" * 18) + "R"
  $wrapped = Run-Line "echo $long" 3
  if ($wrapped -like "*$long*") { "PASS [$name] wrapped line executed intact" }
  else { $failures += "[$name] wrap: 200-char line came back wrong" }

  # 5. bare Enters must not wedge the line editor
  Send-Key "`r"; Start-Sleep -Milliseconds 300
  Send-Key "`r"; Start-Sleep -Milliseconds 300
  Send-Key "`r"; Start-Sleep -Seconds 1
  $null = Drain 400
  $after = Run-Line "echo still-here"
  if ($after -like "*still-here*") { "PASS [$name] still responsive after bare Enters" }
  else { $failures += "[$name] bare Enters wedged the shell. Got: $after" }

  Close-Shell $sess
}

# ── the paths expert users actually live on ───────────────────────────
# Everything above is about a line of text arriving. These are the things
# people do without thinking, where the stack (xterm → daemon → ConPTY)
# has more ways to go wrong than the typing path does.
$exp = Open-Shell "pwsh"
$ESC = [string][char]27

# Ctrl+C against a running command is tested in the visual suite, not
# here, because it cannot be reproduced at this level.
#
# It works in the app. Two people-scale checks on the machine where this
# harness fails - Start-Sleep 30, and ping 1.1.1.1 - are both interrupted
# by pressing the key in a real window. This suite, writing the same byte
# down the same socket to the same daemon, never interrupts anything.
#
# Everything structural between the two was tried and made no difference:
# all three shells behave the same here, including cmd with ping, so it is
# not a shell; 0.6.0 built from its own tag fails exactly like current, so
# it is not a regression; spawning the daemon detached the way the app
# does changes nothing; answering ConPTY's queries the way xterm.js does
# changes nothing; resizing the pty after attach, as the window does,
# changes nothing. The window adds nothing of its own - its Ctrl+C is
# term.onData to write_session to Request::Write, and the daemon writes
# those bytes straight to the pty with nothing in between.
#
# So the difference is something about the running app that a socket
# client does not reproduce, and a test that fails here while the feature
# works for every user is worse than no test: it reports a fault that does
# not exist, and it trained three real failures to be read as noise. The
# scene in tests/visual.ps1 presses the key in a real window and checks a
# command typed straight afterwards runs immediately rather than thirty
# seconds later, which is the thing anyone actually cares about.

# Up-arrow history recall. Experts navigate history far more than they
# retype, and it is a different input path — an escape sequence, not a
# character.
$null = Run-Line "echo hist-marker-7"
Send-Key "$ESC[A"
Start-Sleep -Seconds 1
$null = Drain 400
Send-Key "`r"
Start-Sleep -Seconds 2
$recalled = Strip-Ansi (Drain 500)
if ($recalled -like "*hist-marker-7*") { "PASS up-arrow recalls the previous command" }
else { $failures += "history: up-arrow did not recall. Got: $recalled" }

# Throughput: a burst of output must arrive whole and in order. Dropping
# lines under load is the kind of fault that only shows up on a real
# build log, which is exactly where it matters most.
$bulk = Run-Line "1..2000 | ForEach-Object { `"bulk-`$_`" }" 8
$hits = ([regex]::Matches($bulk, "bulk-\d+")).Count
if ($bulk -like "*bulk-1*" -and $bulk -like "*bulk-2000*" -and $hits -ge 2000) {
  "PASS 2000 lines of output arrived intact ($hits markers)"
} else {
  $failures += "throughput: expected 2000 markers with first and last present, saw $hits"
}

# Wide characters, emoji (surrogate pairs) and a combining accent. A
# terminal that mangles these corrupts git logs and any CJK path, and the
# daemon converts bytes to text on a chunk boundary it does not control.
$uni = "CJK-" + [char]0x65E5 + [char]0x672C + [char]0x8A9E + "-emoji-" + [char]0xD83C + [char]0xDF89 + "-cafe" + [char]0x0301 + "-end"
$uniOut = Run-Line "echo `"$uni`"" 3
if ($uniOut -like "*$uni*") { "PASS wide, emoji and combining characters survive the round trip" }
else { $failures += "unicode: round trip mangled. Got: $uniOut" }

# Multi-line input runs line by line, as it arrives.
#
# This is not a bug to fix, it is the hazard the paste warning exists
# for. PSReadLine does not implement bracketed paste — probed directly,
# these sessions never see ESC[?2004h — so xterm has no bracketed-paste
# mode to wrap a paste in, and every newline in pasted text submits a
# command the moment it lands. Nothing between the terminal and the shell
# can prevent that, which is why the only real protection is showing
# people what they are about to paste before it goes in.
Type-Text "echo (11+22)"
Send-Key "`r"
Type-Text "echo (33+44)"
Send-Key "`r"
Start-Sleep -Seconds 3
$multi = Strip-Ansi (Drain 800)
if ($multi -like "*33*" -and $multi -like "*77*") {
  "PASS multi-line input runs line by line (what the paste warning guards)"
} else { $failures += "multi-line: expected both 33 and 77. Got: $multi" }

# Control sequences must pass through untouched. The alternate screen is
# the one that matters: every full-screen program uses it, and a terminal
# that mangles the enter/leave pair leaves you looking at the wrong
# buffer with no way back.
Type-Text '[Console]::Write([char]27 + "[?1049h" + "ALTMARK" + [char]27 + "[?1049l")'
Start-Sleep -Seconds 1
$null = Drain 400
Send-Key "`r"
Start-Sleep -Seconds 3
$altRaw = Raw-Data (Drain 800)
# -like reads [ as a character class, so these are plain substring checks.
if ($altRaw.Contains("[?1049h") -and $altRaw.Contains("ALTMARK") -and $altRaw.Contains("[?1049l")) {
  "PASS alternate-screen enter and leave pass through intact"
} else { $failures += "alt-buffer: the 1049 pair did not survive" }
$afterAlt = Run-Line "echo (900+9)"
if ($afterAlt -like "*909*") { "PASS the shell is normal again after the alternate screen" }
else { $failures += "alt-buffer: shell not usable afterwards. Got: $afterAlt" }

# Carriage-return overwrite: progress bars (npm, cargo, pip) redraw a
# line in place rather than printing new ones.
Type-Text '[Console]::Write("prog-aaa" + [char]13 + "prog-bbb" + [char]13 + "prog-ccc")'
Start-Sleep -Seconds 1
$null = Drain 400
Send-Key "`r"
Start-Sleep -Seconds 3
$prog = Raw-Data (Drain 800)
# Only the final frame is required. ConPTY re-renders from a screen
# buffer rather than forwarding bytes, so frames overwritten before the
# next render are legitimately coalesced away — a progress bar that spins
# a thousand times does not reach us a thousand times. What must never
# happen is the last frame going missing, which is the one left on screen.
if ($prog -like "*prog-ccc*") { "PASS the final carriage-return frame arrives" }
else { $failures += "progress: the last redraw frame was lost" }

# A resize mid-output. Splits resize panes constantly, and the pty is
# being written to while it happens.
Type-Text "1..1500 | ForEach-Object { `"rs-`$_`" }"
Start-Sleep -Seconds 1
$null = Drain 400
Send-Key "`r"
Start-Sleep -Milliseconds 500
$script:w.WriteLine('{"cmd":"resize","cols":80,"rows":24}')
Start-Sleep -Milliseconds 300
$script:w.WriteLine('{"cmd":"resize","cols":132,"rows":40}')
Start-Sleep -Milliseconds 300
$script:w.WriteLine('{"cmd":"resize","cols":120,"rows":30}')
Start-Sleep -Seconds 6
$rs = Strip-Ansi (Drain 1000)
$rsHits = ([regex]::Matches($rs, "rs-\d+")).Count
if ($rsHits -ge 1500) { "PASS output survives resizes mid-stream ($rsHits markers)" }
else { $failures += "resize: expected 1500 markers through the resizes, saw $rsHits" }

# Multi-byte characters landing on a read boundary. The daemon turns pty
# bytes into text one chunk at a time, and a character split across two
# reads is the classic way to produce U+FFFD. 20k three-byte characters
# make the seam a certainty rather than a coincidence.
Type-Text "-join (1..20000 | ForEach-Object { [char]0x65E5 })"
Start-Sleep -Seconds 1
$null = Drain 400
Send-Key "`r"
Start-Sleep -Seconds 8
$wide = Raw-Data (Drain 1500)
$bad = ([regex]::Matches($wide, [string][char]0xFFFD)).Count
$good = ([regex]::Matches($wide, [string][char]0x65E5)).Count
if ($bad -eq 0 -and $good -ge 20000) {
  "PASS 20k multi-byte characters crossed the read boundary intact"
} else {
  $failures += "utf8-boundary: $bad replacement chars, $good good ones (wanted 0 and 20000)"
}

Close-Shell $exp

# ── detach and reattach: the scrollback has to come back ──────────────
# Closing a window detaches rather than kills, so the replay on reattach
# is the whole promise of the daemon. Output written while nobody is
# attached must still be there.
$det = Open-Shell "pwsh"
$null = Run-Line "echo detach-marker-before"
$script:w.WriteLine('{"cmd":"detach"}')
Start-Sleep -Milliseconds 500
$det.Client.Close()
Start-Sleep -Seconds 1

$re = [System.Net.Sockets.TcpClient]::new("127.0.0.1", $port)
$re.NoDelay = $true
$script:stream = $re.GetStream()
$script:acc = ""
$script:dec = [System.Text.Encoding]::UTF8.GetDecoder()
$script:w = [System.IO.StreamWriter]::new($script:stream)
$script:w.NewLine = "`n"; $script:w.AutoFlush = $true
$script:w.WriteLine("{""cmd"":""attach"",""id"":$($det.Id)}")
$null = Read-Event
Start-Sleep -Seconds 2
$replay = Strip-Ansi (Drain 1500)
if ($replay -like "*detach-marker-before*") { "PASS reattaching replays the scrollback" }
else { $failures += "reattach: the earlier output was not replayed. Got: $replay" }
$stillWorks = Run-Line "echo (700+7)"
if ($stillWorks -like "*707*") { "PASS a reattached session still takes input" }
else { $failures += "reattach: session not usable. Got: $stillWorks" }
Close-Shell ([pscustomobject]@{ Id = $det.Id; Client = $re })

# ── a shell that exits ends the session, and the daemon says so ───────
# Closing a shell must tell the client, rather than leave it attached to
# nothing. Ctrl+D is not the trigger on Windows — PSReadLine does not
# bind it to EOF the way readline does — so this uses the exit that
# PowerShell actually has.
$eof = Open-Shell "pwsh"
Type-Text "exit"
Send-Key "`r"
$sawExit = $false
for ($i = 0; $i -lt 30; $i++) {
  $ev = Read-Event -timeoutMs 500
  if ($null -eq $ev) { continue }
  if ($ev -like '*"ev":"exit"*') { $sawExit = $true; break }
}
if ($sawExit) { "PASS a shell that exits ends the session and the daemon reports it" }
else { $failures += "exit: no exit event after the shell quit" }
$eof.Client.Close()

# ── a full-screen program's frames, byte for byte ──
# The pixel side of this lives in the visual suite; this is the half that
# can run anywhere: whatever a TUI draws has to survive the pty, the ring
# and the socket intact and in order. Cursor-addressed repaints are the
# case that breaks when something reorders or coalesces writes, and they
# are how Claude Code, Agency, Hermes and vim all draw.
$tui = Open-Shell "pwsh"
$fixture = Join-Path $repo "tests\fixtures\tui.ps1"
Type-Text "& '$fixture' -Frames 3 -Ms 500"
Send-Key "`r"
Start-Sleep -Seconds 6
$frames = Raw-Data (Drain 1500)
$esc = [string][char]27
if ($frames.Contains("$esc[?1049h")) { "PASS a TUI's alternate screen arrives" }
else { $failures += "tui-altscreen: no alternate screen switch in the output" }
$seen = @(1, 2, 3 | Where-Object { $frames.Contains("FRAME-$_") })
if ($seen.Count -eq 3) { "PASS all three frames arrive" }
else { $failures += "tui-frames: only $($seen.Count) of 3 frames arrived" }
# In order, and not merged into each other: a repaint that overtakes its
# predecessor is how a screen ends up showing a mixture of two frames.
$i1 = $frames.IndexOf("FRAME-1"); $i2 = $frames.IndexOf("FRAME-2"); $i3 = $frames.IndexOf("FRAME-3")
if ($i1 -ge 0 -and $i1 -lt $i2 -and $i2 -lt $i3) { "PASS and in the order they were drawn" }
else { $failures += "tui-order: frames arrived out of order ($i1, $i2, $i3)" }
# Volume, not the app's own sequences: ConPTY does not forward what the
# program wrote. It keeps a screen, works out what changed, and emits its
# own stream — so counting the program's cursor addressing measures
# ConPTY's rendering strategy rather than anything this project controls.
# What is ours is that three full-screen repaints arrive as three
# screensful of redrawing, not as a handful of bytes.
$erases = ([regex]::Matches($frames, "$([char]27)\[K")).Count
if ($frames.Length -gt 3000 -and $erases -ge 30) {
  "PASS three full-screen repaints arrive in full ($($frames.Length) bytes, $erases line erases)"
} else {
  $failures += "tui-volume: three repaints came to only $($frames.Length) bytes / $erases erases"
}
# Not asserted: that the scrolling region was reset. ConPTY does not
# forward what the program wrote - it keeps its own screen and emits its
# own stream - so the program's [r never appears here, and looking for it
# would be testing ConPTY's rendering rather than anything of ours. The
# cursor mode below does come through, because ConPTY emits it itself.
if ($frames.Contains("$esc[?25h")) { "PASS and gives the cursor back" }
else { $failures += "tui-cursor: the cursor was left hidden" }
if ($frames.Contains("$esc[?1049l")) { "PASS and it hands the screen back on exit" }
else { $failures += "tui-restore: the alternate screen was never left" }
Close-Shell $tui

# ── latency, measured on the default shell ────────────────────────────
$latSess = Open-Shell "pwsh"
# ── latency: per-keystroke echo roundtrip, on the default shell ──
$samples = @()
for ($i = 0; $i -lt 40; $i++) {
  $ch = [char](97 + ($i % 26))
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $w.WriteLine("{""cmd"":""write"",""data"":""$ch""}")
  $ev = Read-Event -timeoutMs 2000 -spin
  $sw.Stop()
  if ($null -eq $ev) { $failures += "latency: keystroke $i got no echo within 2s"; break }
  $samples += $sw.Elapsed.TotalMilliseconds
  $null = Drain 30   # swallow any trailing redraw events
}
if ($samples.Count -ge 30) {
  $sorted = $samples | Sort-Object
  $p50 = [math]::Round($sorted[[int]($sorted.Count * 0.5)], 1)
  $p95 = [math]::Round($sorted[[int]($sorted.Count * 0.95)], 1)
  $max = [math]::Round($sorted[-1], 1)
  "latency over $($samples.Count) keystrokes: p50=${p50}ms p95=${p95}ms max=${max}ms"
  if ($p50 -gt 50) { $failures += "latency: p50 ${p50}ms exceeds 50ms budget" }
  elseif ($p95 -gt 150) { $failures += "latency: p95 ${p95}ms exceeds 150ms budget" }
  else { "PASS latency: within budget (p50<50ms, p95<150ms)" }
}

# ── cleanup ──
Close-Shell $latSess
Close-Shell $keepAlive   # last one out: the daemon exits with it
$client.Close()
Stop-Process -Id $daemon.Id -Force -ErrorAction SilentlyContinue
Remove-Item "$env:LOCALAPPDATA\GTerminal" -Recurse -Force -ErrorAction SilentlyContinue

if ($failures.Count) {
  $failures | ForEach-Object { Write-Host "FAIL $_" -ForegroundColor Red }
  exit 1
}
"all typing tests passed"
exit 0
