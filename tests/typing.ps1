# Typing regression test: correctness (no dropped/reordered keystrokes) and
# echo latency (keystroke -> shell echo roundtrip) through the daemon path.
# Runs against a fully isolated daemon (scratch LOCALAPPDATA); never touches
# the user's real daemon or sessions. Exits nonzero on failure.
param(
  # Which binary to drive. Defaults to this repo's debug build; the
  # coverage run points it at an instrumented copy in a scratch target
  # directory, because the default path is often a binary somebody is
  # running - on Windows that file is locked, and rebuilding over it
  # would take their terminal with it.
  [string]$Exe,
  # How many times the soak types its sentence. The default is a couple of
  # minutes; raise it to leave the thing running for an afternoon.
  [int]$SoakReps = 100,
  # What counts as lag.
  #
  # Not a round number, and not as low as it could be: echo latency has a
  # floor that is not ours. Measured across pwsh, Windows PowerShell and
  # cmd, every shell shows the same p99 of about 16.4ms and the same
  # occasional 23ms - cmd included, which has no PSReadLine at all. That
  # is ConPTY's own flush cadence on the 15.6ms Windows timer, and no
  # change on this side of the pty can move it.
  #
  # So 50ms is "no more than three of those ticks", which is the tightest
  # bar that is about this app rather than about Windows. Lower than that
  # and the suite starts failing on a quantum nobody here owns.
  [int]$SoakBudgetMs = 50,
  # Characters to push through the endurance run. Zero skips it. This is
  # the one that answers "does it still feel like this after a very long
  # time", so the interesting values are stupid ones - a few million.
  [int64]$SoakChars = 0
)
$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
$exe = if ($Exe) { $Exe } else { Join-Path $repo "src-tauri\target\debug\gterminal.exe" }
if (-not (Test-Path $exe)) { Write-Error "build first: cargo build in src-tauri" }

# Ctrl+C has to be able to reach the shells this suite starts: the
# "ignore Ctrl+C" state is inherited from whoever launched us, and with it
# set nothing in the tree can be interrupted. See tests/lib/attended.ps1.
. "$PSScriptRoot/lib/attended.ps1"
$null = Enable-CtrlCHandling

# The harness must not be the slow thing.
#
# Latency here is measured by a PowerShell process timing its own round
# trips, so every quantum this process loses to the scheduler lands in the
# numbers as if the daemon had stalled. It showed up as a distribution
# with two modes: a median under a millisecond and a p99 of about 16ms,
# which is not a coincidence - it is one Windows scheduler quantum, and
# nothing in a pty round trip has that shape.
#
# Above normal, so the measurement is of the app rather than of who else
# wanted the core. The daemon under test raises the same two threads for
# the same reason; a test that did not would be measuring a handicap it
# invented.
try {
  [System.Diagnostics.Process]::GetCurrentProcess().PriorityClass = "High"
} catch {
  Write-Host "  note: could not raise this process's priority; latency tails may be scheduling, not the app" -ForegroundColor DarkYellow
}

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
# Longest stretch the previous spinning Read-Event went without running.
#
# A latency number measured by this process is only about the app while
# this process is on a CPU. On a shared CI runner it often is not: the
# host takes the core away for tens or hundreds of milliseconds, and a
# keystroke measured across that gap looks exactly like a daemon that
# stalled. It is not a rare effect - it is why the same commit can pass
# this suite on one runner and fail it on the next.
#
# The spin loop reads the clock continuously, so the largest jump between
# two consecutive reads is precisely how long it was descheduled. That
# separates "the terminal was slow" from "we were not running", which no
# amount of re-running can do.
$script:spinGapMs = 0.0

function Read-Event {
  param($timeoutMs = 2000, [switch]$spin)
  $deadline = [DateTime]::UtcNow.AddMilliseconds($timeoutMs)
  $script:spinGapMs = 0.0
  $freq = [double][System.Diagnostics.Stopwatch]::Frequency
  $last = [System.Diagnostics.Stopwatch]::GetTimestamp()
  while (-not $script:acc.Contains("`n")) {
    if ($spin) {
      $now = [System.Diagnostics.Stopwatch]::GetTimestamp()
      $gap = ($now - $last) * 1000.0 / $freq
      if ($gap -gt $script:spinGapMs) { $script:spinGapMs = $gap }
      $last = $now
    }
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

# Read until the output says what was asked, or give up loudly.
#
# Drain waits for a gap in the traffic, which is a guess about how long a
# shell takes to answer dressed up as a measurement. It holds on a quiet
# desktop and fails on a loaded CI runner - which is exactly what it did,
# on a probe that had passed every local run: "the shell never reported
# its size", because the answer arrived 200ms after the drain gave up.
#
# Waiting for the pattern costs nothing when the answer is quick and does
# not lie when it is slow. The accumulated text comes back either way, so
# a real failure can still show what did arrive.
function Read-Until {
  param([string] $pattern, [int] $timeoutMs = 20000)
  $deadline = [DateTime]::UtcNow.AddMilliseconds($timeoutMs)
  $acc = ""
  while ([DateTime]::UtcNow -lt $deadline) {
    $line = Read-Event -timeoutMs 300
    if ($null -ne $line) { $acc += $line + "`n" }
    $text = Strip-Ansi $acc
    if ($text -match $pattern) { return $text }
  }
  Strip-Ansi $acc
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

# Ctrl+C against a *running* command, not a half-typed line. This is the
# key experts hit most and the one the matrix above does not cover: it
# has to reach the child process, stop it, and leave the shell usable.
#
# This failed on one machine for weeks and passed on every CI runner, and
# the cause was not in this project at all: the suite had inherited an
# "ignore Ctrl+C" console state from whatever launched it, and passed it
# down to the daemon, the shells, and everything they ran. The app was
# interrupting fine the whole time, because Explorer never passed it down.
# Enable-CtrlCHandling at the top of this file is what makes the test mean
# what it says.
Type-Text "Start-Sleep -Seconds 30"
Start-Sleep -Seconds 1
$null = Drain 400
Send-Key "`r"
Start-Sleep -Seconds 2          # let it actually start sleeping
$null = Drain 400
Send-Key ([string][char]3)
Start-Sleep -Seconds 2
$null = Drain 600
$back = Run-Line "echo (555+1)"
if ($back -like "*556*") { "PASS Ctrl+C interrupts a running command and returns the prompt" }
else {
  $failures += "ctrl-c-running: shell did not come back. Got: $back"
  # Start over in a fresh shell rather than carrying this one forward:
  # a shell that ignored the interrupt is still running a thirty-second
  # sleep, and every test below shares it. One broken thing used to
  # report itself three times that way.
  Close-Shell $exp
  $exp = Open-Shell "pwsh"
}

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

# ── the geometry a console program is handed ──────────────────────────
#
# Every picker that collapses its own prompt does the same thing: move the
# cursor up a row, blank that row by writing exactly BufferWidth spaces,
# then rewrite a shorter summary over it. Two halves of that are this
# terminal's to get right.
#
# The width it reports has to be the width being rendered. A pty that was
# never resized - or was resized without the shell being told - reports a
# stale number, and every erase after that is the wrong length: too short
# leaves the tail of the old line on screen, too long wraps and eats the
# line above. The resize test above only proves output survives a resize;
# nothing here had ever asked the shell what size it thought it was.
#
# And a write of exactly BufferWidth characters from column 0 has to leave
# the cursor on the row it started on. That is deferred end-of-line wrap,
# and a terminal without it puts the replacement one row low and leaves a
# blank row where the prompt was.
$geo = Open-Shell "pwsh"
# The echo of what is typed contains the source, and the result contains a
# number, so a digit-matching pattern can only find the answer.
Type-Text ('"GEOM=" + [Console]::BufferWidth + "x" + [Console]::WindowHeight' + "`r")
$geoOut = Read-Until "GEOM=\d+x\d+"
if ($geoOut -match "GEOM=(\d+)x(\d+)") {
  $gw = [int]$Matches[1]
  if ($gw -eq 120) { "PASS a console program sees the width the session was created with ($gw)" }
  else { $failures += "geometry: the session was created at 120 columns and the shell sees $gw - every in-place redraw erases the wrong length" }
} else {
  $failures += "geometry: the shell never reported its size"
}

# And after a resize, which is the case a pane split or a dragged window
# produces constantly.
$script:w.WriteLine('{"cmd":"resize","cols":100,"rows":28}')
Start-Sleep -Milliseconds 600
Type-Text ('"GEOM2=" + [Console]::BufferWidth' + "`r")
$geoOut2 = Read-Until "GEOM2=\d+"
if ($geoOut2 -match "GEOM2=(\d+)") {
  $gw2 = [int]$Matches[1]
  if ($gw2 -eq 100) { "PASS and sees the new width after a resize ($gw2)" }
  else { $failures += "geometry: resized to 100 columns and the shell still sees $gw2" }
} else {
  $failures += "geometry: the shell never reported its size after a resize"
}

# Deferred end-of-line wrap: the assumption every collapse-in-place redraw
# makes without checking.
$probe = '$t=[Console]::CursorTop; [Console]::CursorTop=$t-1; [Console]::CursorLeft=0; [Console]::Write('' '' * [Console]::BufferWidth); "DRIFT=" + ([Console]::CursorTop-($t-1))'
Type-Text ($probe + "`r")
$driftOut = Read-Until "DRIFT=-?\d+"
if ($driftOut -match "DRIFT=(-?\d+)") {
  $drift = [int]$Matches[1]
  if ($drift -eq 0) { "PASS a full-width write leaves the cursor on the same row (deferred wrap)" }
  else { $failures += "geometry: a full-width write moved the cursor $drift row(s) - an in-place redraw lands a row low and leaves a blank row behind" }
} else {
  $failures += "geometry: the wrap probe reported nothing"
}
Close-Shell $geo

# ── the collapse itself, read back off the screen ─────────────────────
#
# The probes above check what the pattern assumes. This one performs it
# and then reads the row, which is a different question: the sequences
# can be exactly right and the row still wrong, and a test that only
# watches bytes go past cannot tell those apart.
#
# The fixture writes a prompt, moves up a row, blanks it with a
# full-width write, and rewrites a short summary over it - then reads the
# console buffer back and prints what is actually there. A terminal that
# reports a width it is not rendering leaves the tail of the prompt on
# the row; one without deferred wrap leaves the row blank and puts the
# summary below it. Both are visible in the row text, which is why the
# fixture reads it rather than trusting the write.
$col = Open-Shell "pwsh"
$colFixture = Join-Path $repo "tests\fixtures\collapse.ps1"
Type-Text ("& '$colFixture'" + "`r")
$colOut = Read-Until "COLLAPSE-DONE"
if ($colOut -match "COLLAPSE-ROW=\[([^\]]*)\]") {
  $rowText = $Matches[1]
  if ($rowText -eq "BUFFER-UNAVAILABLE") {
    Write-Host "  note: the shell could not read its own console buffer, so the row could not be checked" -ForegroundColor DarkYellow
  } elseif ($rowText -eq "Select item 2") {
    "PASS a collapsed prompt leaves the summary alone on its row"
  } else {
    $failures += "collapse: the prompt's row reads '$rowText' rather than 'Select item 2' - the erase was the wrong length, so a redrawn prompt leaves the old one behind"
  }
} else {
  $failures += "collapse: the fixture never reported the row it rewrote"
}
if ($colOut -match "COLLAPSE-DRIFT=(-?\d+)") {
  if ([int]$Matches[1] -eq 0) { "PASS and the summary lands on the row the prompt was on" }
  else { $failures += "collapse: the full-width erase drifted $($Matches[1]) row(s), so the summary lands below a blank row" }
}
# The row above must not have been touched. An erase one character too
# long wraps into it, which is how a collapse eats the line before it.
if ($colOut -match "COLLAPSE-ABOVE=\[([^\]]*)\]") {
  $above = $Matches[1]
  if ($above -ne "" -and $above -ne "BUFFER-UNAVAILABLE") { "PASS and the line above it survives ('$above')" }
  elseif ($above -eq "") { $failures += "collapse: the line above the prompt was blanked - the erase wrapped into it" }
}
Close-Shell $col

# ── latency ───────────────────────────────────────────────────────────
#
# A latency test is only as good as the state it measures in. The first
# version of this measured single keystrokes at a fresh prompt in a
# just-opened session, which is the one situation where nothing that has
# ever gone wrong here can show up: the ring is empty so it never trims,
# the line is short so the shell repaints almost nothing, and no other
# session is running so the daemon's one lock is uncontended. It passed
# throughout a regression that made typing a long line in a session that
# had been open a while visibly laggy.
#
# So: the same measurement, in the four states that matter.

# One keystroke, timed to the first event back. Samples are returned in
# order so a caller can compare the start of a line against its end
# rather than only reading the distribution.
function Measure-Keystrokes {
  param([int]$count = 40, [string]$text = "")
  $samples = @()
  for ($i = 0; $i -lt $count; $i++) {
    $ch = if ($text) { [string]$text[$i % $text.Length] } else { [string][char](97 + ($i % 26)) }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $script:w.WriteLine("{""cmd"":""write"",""data"":""$(Esc-Json $ch)""}")
    $ev = Read-Event -timeoutMs 5000 -spin
    $sw.Stop()
    if ($null -eq $ev) { return $null }
    $samples += $sw.Elapsed.TotalMilliseconds
    $null = Drain 30   # swallow any trailing redraw events
  }
  ,$samples
}

function Pct {
  param($samples, [double]$p)
  $sorted = @($samples | Sort-Object)
  $i = [int][math]::Min($sorted.Count - 1, [math]::Floor($sorted.Count * $p))
  [math]::Round($sorted[$i], 1)
}

# Read events until a gap of $ms with nothing on the wire. Unlike Drain
# this keeps nothing: waiting out a megabyte of flood by concatenating it
# into a string is quadratic, and would time the harness, not the daemon.
function Wait-Quiet {
  param($ms = 800, $maxMs = 180000)
  $deadline = [DateTime]::UtcNow.AddMilliseconds($maxMs)
  while ([DateTime]::UtcNow -lt $deadline) {
    if ($null -eq (Read-Event -timeoutMs $ms)) { return $true }
  }
  $false
}

# Can the daemon still answer at all? One control request on its own
# connection, with real timeouts, so a daemon that has wedged is a failure
# rather than a suite that never finishes.
function Test-DaemonResponsive {
  param($timeoutMs = 5000)
  try {
    $c = [System.Net.Sockets.TcpClient]::new("127.0.0.1", $port)
    $st = $c.GetStream()
    $st.WriteTimeout = $timeoutMs
    $st.ReadTimeout = $timeoutMs
    $sw = [System.IO.StreamWriter]::new($st); $sw.NewLine = "`n"; $sw.AutoFlush = $true
    $sr = [System.IO.StreamReader]::new($st)
    $sw.WriteLine('{"cmd":"list"}')
    $line = $sr.ReadLine()
    $c.Close()
    return [bool]$line
  } catch {
    return $false
  }
}

# Print enough to carry the ring past its cap and into the regime where
# it trims. Everything about scrollback cost only starts there.
function Fill-Ring {
  Type-Text ("1..20000 | ForEach-Object { 'x' * 80 }" + "`r")
  if (-not (Wait-Quiet 1500)) { $failures += "latency: the ring fill never finished" }
}

function Check-Latency {
  param($name, $samples, $p50Budget, $p95Budget)
  if ($null -eq $samples -or $samples.Count -lt 30) {
    $failures += "latency ${name}: a keystroke got no echo within 5s"
    return
  }
  $p50 = Pct $samples 0.5
  $p95 = Pct $samples 0.95
  $max = [math]::Round((@($samples | Sort-Object))[-1], 1)
  "latency ${name}: p50=${p50}ms p95=${p95}ms max=${max}ms over $($samples.Count) keystrokes"
  if ($p50 -gt $p50Budget) { $failures += "latency ${name}: p50 ${p50}ms exceeds ${p50Budget}ms budget" }
  elseif ($p95 -gt $p95Budget) { $failures += "latency ${name}: p95 ${p95}ms exceeds ${p95Budget}ms budget" }
  else { "PASS latency ${name}: within budget (p50<${p50Budget}ms, p95<${p95Budget}ms)" }
}

$latSess = Open-Shell "pwsh"

# 1. The original: fresh session, empty prompt. Still worth keeping - it
#    is the floor everything else is compared against.
Check-Latency "fresh" (Measure-Keystrokes 40) 50 150

# 2. The same thing once the ring is past its cap. The ring is a buffer
#    drained from the front; trimming it per chunk instead of in batches
#    moves half a megabyte for every chunk of output, under the lock a
#    keystroke needs. Nothing about the fresh case can see that.
Fill-Ring
Check-Latency "full ring" (Measure-Keystrokes 40) 50 150

# 3. Along a long line, which is what a person actually notices: PSReadLine
#    repaints the whole input line on every keypress, so the echo grows
#    with the line while the keystroke stays one byte. The assertion is a
#    ratio, not a number - the end of a long line is allowed to cost more
#    than the start, but not a different order of magnitude, and a ratio
#    does not need a fast machine to stay honest.
$sentence = "the quick brown fox jumps over the lazy dog and keeps on running well past the point where any sensible animal would have stopped to rest a while"
$line = Measure-Keystrokes $sentence.Length $sentence
if ($null -eq $line -or $line.Count -lt 60) {
  $failures += "latency long line: a keystroke got no echo within 5s"
} else {
  $head = Pct ($line[0..19]) 0.5
  $tail = Pct ($line[-20..-1]) 0.5
  $ratio = if ($head -gt 0) { [math]::Round($tail / $head, 2) } else { 0 }
  "latency long line: first 20 p50=${head}ms, last 20 p50=${tail}ms (x${ratio})"
  if ($tail -gt 150) { $failures += "latency long line: ${tail}ms at the end of the line exceeds 150ms" }
  elseif ($ratio -gt 4) { $failures += "latency long line: the end of the line costs ${ratio}x the start" }
  else { "PASS latency long line: cost does not run away with line length" }
}
Type-Text "`u{3}"   # abandon the line rather than run that sentence
$null = Drain 300

# 4. With another session flooding a client that has stopped reading.
#
#    There is one lock for every session in the daemon, and the output
#    pump used to hold it across the write to the attached client. Once
#    that client's socket buffer fills the write blocks - with the whole
#    daemon's lock in hand - and nothing else can be typed into, listed,
#    created or killed until the client drains. A stalled reader took the
#    daemon down with it, and no test here could see that because none of
#    them ever stopped reading.
#
#    So this one stops reading: the flooder stays attached and its socket
#    is deliberately never drained. Everything below is bounded, because
#    the failure being tested for is a hang, and a test that hangs reports
#    nothing.
$flood = Open-Shell "pwsh"
Type-Text ("1..400000 | ForEach-Object { 'flooding ' + $_ + ' ' + ('.' * 60) }" + "`r")
Start-Sleep -Milliseconds 2000
if (-not (Test-DaemonResponsive 5000)) {
  $failures += "stalled client: the daemon stopped answering while one client was not reading"
} else {
  "PASS stalled client: the daemon still answers with a client stalled mid-flood"
  $typeSess = Open-Shell "pwsh"
  Check-Latency "stalled neighbour" (Measure-Keystrokes 40) 80 250
}
# Let the flooder's socket go before anything tries to kill it: on a build
# where the pump is blocked writing to it, the kill would block too, and
# the cleanup would hang instead of the suite reporting.
$flood.Client.Close()
Start-Sleep -Milliseconds 300

# ── soak: a long stretch of ordinary typing, every keystroke checked ──
#
# Percentiles hide the thing being looked for. A hitch every few seconds is
# invisible at p95 and is the entire complaint, so this types a real
# sentence over and over and asserts on the worst keystroke rather than the
# median - reporting which keystroke and how far into the run, because a
# stall on a schedule is the signature of something on a timer rather than
# something about typing.
#
# Four scenarios rather than one, because a single quiet pwsh at an empty
# prompt is the state in which nothing has ever gone wrong:
#
#   pwsh            the common case, and the baseline the others are read against
#   pwsh under load a neighbour session printing the whole time, and this
#                   session's own ring past its cap - the state a terminal
#                   that has been open all afternoon is actually in
#   powershell      a different PSReadLine, older and slower to repaint
#   cmd             no PSReadLine at all, which makes it the control for
#                   whether a tail belongs to the shell or to us
#
# An outlier is confirmed with a second pass of the same scenario before it
# fails the suite. Not to be lenient - the threshold stays where it is, and
# anything with a cause repeats, while a runner descheduling this process
# for a second does not. Raising a threshold each time it cries wolf is how
# the latency test that already lived in this file came to pass through a
# period of visible lag. Both passes are printed either way.
$soakLine = "the quick brown fox jumps over the lazy dog while the status bar counts whatever it counts"

function Invoke-Soak {
  param([int]$reps)
  $samples = New-Object System.Collections.Generic.List[double]
  $slow = New-Object System.Collections.Generic.List[object]
  $descheduled = New-Object System.Collections.Generic.List[object]
  $clock = [System.Diagnostics.Stopwatch]::StartNew()
  $aborted = ""
  $k = 0
  for ($rep = 0; $rep -lt $reps -and -not $aborted; $rep++) {
    foreach ($ch in $soakLine.ToCharArray()) {
      $sw = [System.Diagnostics.Stopwatch]::StartNew()
      $script:w.WriteLine("{""cmd"":""write"",""data"":""$(Esc-Json ([string]$ch))""}")
      $ev = Read-Event -timeoutMs 5000 -spin
      $sw.Stop()
      if ($null -eq $ev) { $aborted = "keystroke $k got no echo within 5s"; break }
      $ms = $sw.Elapsed.TotalMilliseconds
      $samples.Add($ms)
      if ($ms -gt $SoakBudgetMs) {
        # Was this the terminal, or was this process not running? The spin
        # loop knows: if most of the wait is a single gap between two of
        # its own clock reads, nothing was measured except the scheduler.
        $gap = [math]::Round($script:spinGapMs, 1)
        $entry = [pscustomobject]@{
          At   = $k
          Ms   = [math]::Round($ms, 1)
          Sec  = [math]::Round($clock.Elapsed.TotalSeconds, 1)
          Gap  = $gap
        }
        if ($gap -ge ($ms * 0.6)) { $descheduled.Add($entry) } else { $slow.Add($entry) }
      }
      $k++
      # A short quiet gap rather than a fixed drain: 30ms per keystroke
      # would make this test twenty minutes of sleeping.
      $null = Read-Event -timeoutMs 4
    }
    # Abandon the line rather than run it, and rather than let it grow.
    $script:w.WriteLine("{""cmd"":""write"",""data"":""\u0003""}")
    $null = Drain 40
  }
  [pscustomobject]@{
    Samples      = $samples
    Slow         = $slow
    Descheduled  = $descheduled
    Aborted      = $aborted
    Seconds      = [math]::Round($clock.Elapsed.TotalSeconds, 1)
  }
}

function Soak-Worst {
  param($run)
  [math]::Round(($run.Samples | Measure-Object -Maximum).Maximum, 1)
}

# Writes, and returns nothing. An earlier version ended with the worst
# figure so a caller could use it, which in PowerShell put the summary line
# on the pipeline as well - so `$worst = Show-Soak ...` captured the report
# instead of printing it, and the run went quiet about exactly the numbers
# it exists to show.
function Show-Soak {
  param($label, $run)
  $p50 = Pct $run.Samples 0.5
  $p99 = Pct $run.Samples 0.99
  Write-Host "soak ${label}: $($run.Samples.Count) keystrokes over $($run.Seconds)s - p50=${p50}ms p99=${p99}ms worst=$(Soak-Worst $run)ms, $($run.Slow.Count) over ${SoakBudgetMs}ms, $($run.Descheduled.Count) while off-CPU"
  foreach ($slow in ($run.Slow | Select-Object -First 8)) {
    Write-Host "  slow keystroke $($slow.At) at $($slow.Sec)s: $($slow.Ms)ms (off-CPU $($slow.Gap)ms of it)"
  }
  foreach ($slow in ($run.Descheduled | Select-Object -First 4)) {
    Write-Host "  not counted - this process was off-CPU for $($slow.Gap)ms of a $($slow.Ms)ms keystroke at $($slow.Sec)s"
  }
}

$soakScenarios = @(
  @{ Name = "pwsh"; Shell = "pwsh"; Load = $false },
  @{ Name = "pwsh under load"; Shell = "pwsh"; Load = $true },
  @{ Name = "powershell"; Shell = "powershell"; Load = $false },
  @{ Name = "cmd"; Shell = "cmd"; Load = $false }
)
# The reps are shared out, so widening the matrix costs coverage of each
# state rather than minutes on every run.
$soakEach = [math]::Max(4, [int]($SoakReps / $soakScenarios.Count))
$soakSessions = @()
$scenarioFlood = $null

foreach ($scenario in $soakScenarios) {
  # Whatever the last scenario was running is not part of this one. The
  # flood used to be left going for the rest of the matrix, so "cmd" was
  # quietly measured under load and only said so by failing - which is how
  # it found a real stall, and is still the wrong way to find one: a
  # scenario has to measure the state it names.
  if ($scenarioFlood) { Close-Shell $scenarioFlood; $scenarioFlood = $null }
  if ($scenario.Load) {
    # A neighbour printing the whole time. Detached on purpose: an
    # attached client that never reads is the stalled-reader case above,
    # and this one is about the work every chunk costs regardless of who
    # is listening - the ring, its trims, the transcript, the checkpoints.
    $flood = Open-Shell "pwsh"
    Type-Text ("1..400000 | ForEach-Object { 'flooding ' + $_ + ' ' + ('.' * 60) }" + "`r")
    $script:w.WriteLine('{"cmd":"detach"}')
    Start-Sleep -Milliseconds 500
    $scenarioFlood = $flood
  }
  $sess = Open-Shell $scenario.Shell
  $soakSessions += $sess
  if ($scenario.Load) {
    # And this session's own ring past its cap, so every chunk it produces
    # is in the trimming regime rather than the empty-buffer one.
    Fill-Ring
  }
  $run = Invoke-Soak $soakEach
  if ($run.Aborted) {
    $failures += "soak $($scenario.Name): $($run.Aborted)"
    continue
  }
  if ($run.Samples.Count -lt ($soakEach * $soakLine.Length * 0.99)) {
    $failures += "soak $($scenario.Name): only $($run.Samples.Count) keystrokes were measured"
    continue
  }
  Show-Soak $scenario.Name $run
  if ($run.Slow.Count -eq 0) {
    "PASS soak $($scenario.Name): no keystroke in $($run.Samples.Count) took over ${SoakBudgetMs}ms"
    continue
  }
  Write-Host "  confirming: a stall with a cause repeats, a descheduled process does not"
  $again = Invoke-Soak $soakEach
  if ($again.Aborted) {
    $failures += "soak $($scenario.Name) confirmation: $($again.Aborted)"
    continue
  }
  Show-Soak "$($scenario.Name) pass 2" $again
  if ($again.Slow.Count -gt 0) {
    $failures += "soak $($scenario.Name): keystrokes over ${SoakBudgetMs}ms in both passes (worst $(Soak-Worst $run)ms then $(Soak-Worst $again)ms) - every input is supposed to be free of that"
  } else {
    "PASS soak $($scenario.Name): $($run.Slow.Count) outlier did not reproduce in $($again.Samples.Count) further keystrokes"
  }
}

# ── endurance: volume, with latency sampled the whole way through ──
#
# The soak above measures every keystroke, which costs a round trip each
# and works out at about 20ms per character - fine for thousands, and
# fifty hours for the millions it would take to answer a different
# question: does this still type well after a very long time. Ring churn,
# a transcript growing without bound, handles, fragmentation and every
# checkpoint of an ever-larger buffer only show up at volume.
#
# So volume is pushed in bursts - keys sent as fast as the socket takes
# them, the way a person's hands actually arrive, and the way nothing else
# in this file types - and latency is sampled periodically along the way.
# The samples are what enforce "no lag": drift is the failure being looked
# for, so the first tenth of them is compared against the last.
if ($SoakChars -gt 0) {
  $endSess = Open-Shell "pwsh"
  # Long bursts, because the pause that lets the echo catch up is paid per
  # burst and not per character: at 400 characters it was most of the wall
  # clock, and the run was measuring its own politeness.
  $burst = ($soakLine * 14).Substring(0, 1200)
  $sent = [int64]0
  $sampled = New-Object System.Collections.Generic.List[double]
  $sampleSlow = New-Object System.Collections.Generic.List[object]
  $sampleEvery = [math]::Max(20000, [int]($SoakChars / 40))
  $nextSample = $sampleEvery
  $endClock = [System.Diagnostics.Stopwatch]::StartNew()
  $endAborted = ""
  while ($sent -lt $SoakChars -and -not $endAborted) {
    foreach ($ch in $burst.ToCharArray()) {
      $script:w.WriteLine("{""cmd"":""write"",""data"":""$(Esc-Json ([string]$ch))""}")
    }
    $sent += $burst.Length
    # Let the echo catch up before abandoning the line, so "keeping up" is
    # part of what is being measured rather than something skipped past.
    if (-not (Wait-Quiet 120 60000)) { $endAborted = "the echo never caught up after $sent characters" ; break }
    $script:w.WriteLine("{""cmd"":""write"",""data"":""\u0003""}")
    $null = Drain 40
    if ($sent -ge $nextSample) {
      $nextSample = $sent + $sampleEvery
      for ($i = 0; $i -lt 30; $i++) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $script:w.WriteLine("{""cmd"":""write"",""data"":""$(Esc-Json ([string]$soakLine[$i % $soakLine.Length]))""}")
        $ev = Read-Event -timeoutMs 5000 -spin
        $sw.Stop()
        if ($null -eq $ev) { $endAborted = "no echo within 5s after $sent characters"; break }
        $ms = $sw.Elapsed.TotalMilliseconds
        $sampled.Add($ms)
        if ($ms -gt $SoakBudgetMs) {
          $sampleSlow.Add([pscustomobject]@{ At = $sent; Ms = [math]::Round($ms, 1); Sec = [math]::Round($endClock.Elapsed.TotalSeconds, 1) })
        }
        $null = Read-Event -timeoutMs 4
      }
      $script:w.WriteLine("{""cmd"":""write"",""data"":""\u0003""}")
      $null = Drain 40
      $rate = [int]($sent / [math]::Max(1, $endClock.Elapsed.TotalSeconds))
      Write-Host ("  endurance: {0:N0} characters, {1:N0}/s, {2} samples, worst {3}ms" -f $sent, $rate, $sampled.Count, [math]::Round(($sampled | Measure-Object -Maximum).Maximum, 1))
    }
  }
  $endSecs = [math]::Round($endClock.Elapsed.TotalSeconds, 1)
  if ($endAborted) {
    $failures += "endurance: $endAborted"
  } elseif ($sampled.Count -lt 20) {
    $failures += "endurance: only $($sampled.Count) latency samples were taken over $sent characters"
  } else {
    $endWorst = [math]::Round(($sampled | Measure-Object -Maximum).Maximum, 1)
    Write-Host ("endurance: {0:N0} characters over {1}s - {2} samples, p50=$(Pct $sampled 0.5)ms p99=$(Pct $sampled 0.99)ms worst=${endWorst}ms, $($sampleSlow.Count) over ${SoakBudgetMs}ms" -f $sent, $endSecs, $sampled.Count)
    foreach ($slow in ($sampleSlow | Select-Object -First 8)) {
      Write-Host "  slow keystroke after $($slow.At) characters, at $($slow.Sec)s: $($slow.Ms)ms"
    }
    # Drift is the point: a terminal that types well for a minute and
    # badly after an hour passes every other test in this file.
    $tenth = [math]::Max(5, [int]($sampled.Count / 10))
    $early = Pct ($sampled[0..($tenth - 1)]) 0.5
    $late = Pct ($sampled[-$tenth..-1]) 0.5
    $drift = if ($early -gt 0) { [math]::Round($late / $early, 2) } else { 0 }
    # Only judged on a long run: a tenth of sixty samples is six, and six
    # round trips have enough spread between them to invent a drift that
    # is not there. The nine-million-character run has hundreds.
    Write-Host "  first $tenth samples p50=${early}ms, last $tenth p50=${late}ms (x${drift})$(if ($sampled.Count -lt 100) { ' - too few samples to judge drift' })"
    if ($sampleSlow.Count -gt 0) {
      $failures += "endurance: $($sampleSlow.Count) sampled keystrokes over ${SoakBudgetMs}ms (worst ${endWorst}ms) after volume"
    } elseif ($sampled.Count -ge 100 -and $drift -gt 3) {
      $failures += "endurance: latency drifted ${drift}x between the start and the end of $sent characters"
    } else {
      "PASS endurance: $sent characters, no sampled keystroke over ${SoakBudgetMs}ms, no drift"
    }
  }
  Close-Shell $endSess
}

# ── cleanup ──
foreach ($sess in $soakSessions) { Close-Shell $sess }
if ($scenarioFlood) { Close-Shell $scenarioFlood }
if ($typeSess) { Close-Shell $typeSess }
Close-Shell $flood
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
