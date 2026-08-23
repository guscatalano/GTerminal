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
function Read-Event {
  param($timeoutMs = 2000, [switch]$spin)
  $deadline = [DateTime]::UtcNow.AddMilliseconds($timeoutMs)
  while (-not $script:acc.Contains("`n")) {
    if ($script:stream.DataAvailable) {
      $n = $script:stream.Read($script:buf, 0, $script:buf.Length)
      if ($n -eq 0) { return $null }
      $script:acc += [System.Text.Encoding]::UTF8.GetString($script:buf, 0, $n)
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
  $script:w = [System.IO.StreamWriter]::new($script:stream)
  $script:w.NewLine = "`n"; $script:w.AutoFlush = $true
  $script:w.WriteLine("{""cmd"":""attach"",""id"":$sid}")
  $null = Read-Event
  $script:w.WriteLine('{"cmd":"write","data":"\u001b[1;1R"}')   # ConPTY cursor query
  Start-Sleep -Seconds 5
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
else { $failures += "ctrl-c-running: shell did not come back. Got: $back" }

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

Close-Shell $exp

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
