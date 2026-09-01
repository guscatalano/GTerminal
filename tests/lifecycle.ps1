# Lifecycle regression tests: every daemon-side behavior GTerminal relies on.
# Fully isolated (scratch LOCALAPPDATA, PID-scoped kills); exits nonzero on
# any failure.
param(
  # Which binary to drive. Defaults to this repo's debug build; the
  # coverage run points it at an instrumented copy in a scratch target
  # directory, because the default path is often a binary somebody is
  # running - on Windows that file is locked, and rebuilding over it
  # would take their terminal with it.
  [string]$Exe
)
$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
$exe = if ($Exe) { $Exe } else { Join-Path $repo "src-tauri\target\debug\gterminal.exe" }
if (-not (Test-Path $exe)) { Write-Error "build first: cargo build in src-tauri" }

$env:LOCALAPPDATA = Join-Path $env:TEMP "gterminal-lifecycle-test"
New-Item -ItemType Directory -Force $env:LOCALAPPDATA | Out-Null
Remove-Item "$env:LOCALAPPDATA\GTerminal" -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force "$env:LOCALAPPDATA\GTerminal" | Out-Null
Set-Content "$env:LOCALAPPDATA\GTerminal\config.json" '{"grace_minutes": 5}'

$failures = @()
$script:daemons = @()

function Pass { param($name) "PASS $name" }
function Fail { param($name, $detail) $script:failures += "${name}: $detail" }

function Start-Daemon {
  Remove-Item "$env:LOCALAPPDATA\GTerminal\daemon.port" -ErrorAction SilentlyContinue
  $p = Start-Process -FilePath $exe -ArgumentList "--daemon" -WindowStyle Hidden -PassThru
  $script:daemons += $p.Id
  foreach ($i in 1..50) {
    Start-Sleep -Milliseconds 100
    if (Test-Path "$env:LOCALAPPDATA\GTerminal\daemon.port") { break }
  }
  Start-Sleep -Milliseconds 300
  [int](Get-Content "$env:LOCALAPPDATA\GTerminal\daemon.port").Trim()
}

function Stop-DaemonTree {
  param($daemonPid)
  Get-CimInstance Win32_Process |
    Where-Object { $_.ParentProcessId -eq $daemonPid } |
    ForEach-Object { taskkill /PID $_.ProcessId /T /F 2>&1 | Out-Null }
  taskkill /PID $daemonPid /F 2>&1 | Out-Null
}

function New-Conn {
  param($port)
  $c = [System.Net.Sockets.TcpClient]::new("127.0.0.1", $port)
  $c.NoDelay = $true
  $s = $c.GetStream()
  $w = [System.IO.StreamWriter]::new($s); $w.NewLine = "`n"; $w.AutoFlush = $true
  [pscustomobject]@{ Client = $c; Stream = $s; Writer = $w; Acc = ""; Buf = New-Object byte[] 65536 }
}

function Read-Line2 {
  param($conn, $timeoutMs = 3000)
  $deadline = [DateTime]::UtcNow.AddMilliseconds($timeoutMs)
  while (-not $conn.Acc.Contains("`n")) {
    if ($conn.Stream.DataAvailable) {
      $n = $conn.Stream.Read($conn.Buf, 0, $conn.Buf.Length)
      if ($n -eq 0) { return $null }
      $conn.Acc += [System.Text.Encoding]::UTF8.GetString($conn.Buf, 0, $n)
    } elseif ([DateTime]::UtcNow -gt $deadline) {
      return $null
    } else {
      Start-Sleep -Milliseconds 5
    }
  }
  $i = $conn.Acc.IndexOf("`n")
  $line = $conn.Acc.Substring(0, $i)
  $conn.Acc = $conn.Acc.Substring($i + 1)
  $line
}

function Drain2 {
  param($conn, $ms = 400)
  $out = ""
  while ($true) {
    $l = Read-Line2 $conn $ms
    if ($null -eq $l) { break }
    $out += $l + "`n"
  }
  $out
}

# Wait for the shell to finish a command, rather than for a number of
# seconds.
#
# The shell marks each new prompt with OSC 133;A, so "it has finished" is
# something to wait for rather than a duration to guess. Drain the
# connection first, or the prompt being waited for is the one that was
# already on screen.
function Run-Await {
  param($conn, [string]$data, [int]$timeoutSec = 45)
  $conn.Writer.WriteLine($data)
  $out = ""
  $deadline = (Get-Date).AddSeconds($timeoutSec)
  while ((Get-Date) -lt $deadline) {
    $out += Drain2 $conn 400
    if ($out -like "*]133;A*") { break }
  }
  $out
}

# Wait until the shell has drawn its first prompt.
#
# Every site that needed this slept five seconds and then DISCARDED what
# had arrived - throwing away the one piece of evidence that the shell was
# up at all. When five seconds was not enough, the checks that depend on
# the integration failed together, which is what gave it away: one at a
# time looked like flaky tests, all at once looked like the single cause
# it was.
function Wait-Ready {
  param($conn, [int]$timeoutSec = 60)
  $out = ""
  $answered = 0
  $deadline = (Get-Date).AddSeconds($timeoutSec)
  while ((Get-Date) -lt $deadline) {
    $out += Drain2 $conn 400
    # Answer the shell's cursor-position question WHEN IT IS ASKED, the way
    # a terminal does.
    #
    # These tests used to fire the answer blindly, once, straight after
    # attaching. A shell under ConPTY draws nothing until it is answered,
    # and it usually asks in the gap around the attach - so if the answer
    # went first it was consumed as stray input, the question came after
    # it, and nothing ever replied. The shell then sat there forever and
    # the test reported whatever it was really about: a session that "did
    # not spawn", a shell that "stopped responding after extreme resizes".
    #
    # The daemon only started handing the question to a client that
    # attaches after it was asked in "Deliver the question the shell is
    # waiting on"; before that it was stripped from the replay and blind
    # answering was the only thing available.
    $asked = [regex]::Matches($out, [regex]::Escape('\u001b[6n')).Count
    while ($answered -lt $asked) {
      $conn.Writer.WriteLine('{"cmd":"write","data":"\u001b[1;1R"}')
      $answered++
    }
    if ($out -like "*]133;A*") { return $out }
  }
  Write-Host "  note: no prompt mark after ${timeoutSec}s - the shell never drew a prompt (answered $answered cursor query/queries)" -ForegroundColor DarkYellow
  $out
}

# Ask again until the answer arrives, or fail for real at a deadline.
#
# These checks are about whether the shell integration registers things: a
# prompt hook, a predictor plugin, a PredictionSource. All of it happens
# while the shell starts, and how long that takes is the machine's
# business. Asking once at a chosen moment tests how fast the machine is;
# asking until a deadline tests whether it happens at all, which is what
# is actually being claimed.
#
# Waiting for the first prompt was not enough on its own - that mark is
# emitted before the predictor subsystem has finished registering, so a
# run could see the prompt and still find no predictor.
function Retry-Until {
  param($conn, [string]$data, [scriptblock]$ok, [int]$timeoutSec = 40)
  $deadline = (Get-Date).AddSeconds($timeoutSec)
  $out = ""
  while ((Get-Date) -lt $deadline) {
    $null = Drain2 $conn
    $out = Run-Await $conn $data 12
    if (& $ok $out) { return $out }
    Start-Sleep -Milliseconds 500
  }
  $out
}


function Request2 {
  param($port, $json, $retries = 2)
  for ($r = 0; $r -le $retries; $r++) {
    try {
      $c = New-Conn $port
      $c.Writer.WriteLine($json)
      $resp = Read-Line2 $c 5000
      $c.Client.Close()
      if ($null -ne $resp) { return $resp | ConvertFrom-Json }
    } catch {}
    Start-Sleep -Milliseconds 500
  }
  throw "no response to $json on port $port"
}

function Get-Sessions {
  param($port)
  # The daemon exits when its last session dies — treat that as empty.
  try { (Request2 $port '{"cmd":"list"}').sessions } catch { @() }
}

# ════ boot ════
$port = Start-Daemon
$daemon1 = $script:daemons[-1]

# ── create + attach + cwd tracking ──
$id = (Request2 $port '{"cmd":"create","cols":100,"rows":30}').id
if ($id -ne 1) { Fail "create" "expected id 1, got $id" } else { Pass "create session" }

$a = New-Conn $port
$a.Writer.WriteLine("{""cmd"":""attach"",""id"":$id}")
$ok = Read-Line2 $a
if (($ok | ConvertFrom-Json).ok -ne $true) { Fail "attach" "no ok: $ok" } else { Pass "attach" }
$a.Writer.WriteLine('{"cmd":"write","data":"\u001b[1;1R"}')
Start-Sleep -Seconds 4
$a.Writer.WriteLine('{"cmd":"write","data":"cd C:\\Windows\r"}')
Start-Sleep -Milliseconds 1500
$a.Writer.WriteLine('{"cmd":"write","data":"echo lifecycle-marker-999\r"}')
Start-Sleep -Seconds 6   # checkpoint flush + prompt cwd emission
$null = Drain2 $a

$s = Get-Sessions $port | Where-Object id -eq $id
if ($s.cwd -notlike "*Windows") { Fail "cwd-tracking" "cwd=$($s.cwd)" } else { Pass "cwd tracking via prompt hook" }
if (-not $s.attached) { Fail "list-attached" "attached=false while attached" } else { Pass "list shows attached" }

# ── detach keeps the session alive ──
$a.Writer.WriteLine('{"cmd":"detach"}')
Start-Sleep -Milliseconds 600
$a.Client.Close()
$s = Get-Sessions $port | Where-Object id -eq $id
if ($null -eq $s -or $s.attached -or -not $s.alive) { Fail "detach" "session gone or still attached" } else { Pass "detach keeps session alive" }

# ── reattach replays scrollback ──
$b = New-Conn $port
$b.Writer.WriteLine("{""cmd"":""attach"",""id"":$id}")
$null = Read-Line2 $b
$replay = Read-Line2 $b
if ($replay -notlike "*lifecycle-marker-999*") { Fail "replay" "marker missing from replay" } else { Pass "reattach replays scrollback" }

# What a full-screen program drew is not scrollback.
#
# Reported: restore a session that had vim in it and the output comes back
# looking wrong. It did. A terminal never puts alternate-screen output
# into scrollback - that is what the alternate screen is for - and we were
# recording all of it, so a replay was mostly absolute cursor moves and
# screen clears painted into a normal buffer at a different size.
#
# The fixture writes markers inside the alternate screen and either side
# of it, so the replay can be checked for both.
$altFixture = Join-Path (Split-Path $PSScriptRoot -Parent) "tests/fixtures/altscreen.ps1"
$b.Writer.WriteLine("{""cmd"":""write"",""data"":""echo before-the-fullscreen-program\r""}")
Start-Sleep -Seconds 3
$fsCmd = "& '" + $altFixture.Replace([char]92, [char]47) + "'"
$b.Writer.WriteLine("{""cmd"":""write"",""data"":""$fsCmd\r""}")
Start-Sleep -Seconds 20
$b.Writer.WriteLine("{""cmd"":""write"",""data"":""echo after-the-fullscreen-program\r""}")
Start-Sleep -Seconds 4
$null = Drain2 $b
$b.Writer.WriteLine('{"cmd":"detach"}')
Start-Sleep -Milliseconds 600
$b.Client.Close()

$c2 = New-Conn $port
$c2.Writer.WriteLine("{""cmd"":""attach"",""id"":$id}")
$null = Read-Line2 $c2
$fsReplayLine = Read-Line2 $c2
$fsReplay = try { ($fsReplayLine | ConvertFrom-Json).data } catch { "" }
$c2.Client.Close()

Write-Host ("  replay after a full-screen program: {0} chars" -f $fsReplay.Length) -ForegroundColor DarkGray
if ($fsReplay -match "before-the-fullscreen-program" -and $fsReplay -match "after-the-fullscreen-program") {
  Pass "a replay keeps what the shell printed either side of a full-screen program"
} else {
  Fail "fullscreen-replay" "the shell's own output is missing from the replay - nothing below was tested"
}
if ($fsReplay -match "ALTSCREEN-FIXTURE-READY") {
  Pass "and keeps what it printed before taking the screen"
} else {
  Fail "fullscreen-replay" "output from before the alternate screen was dropped too - the filter is eating too much"
}
foreach ($v in @("47", "1047", "1049")) {
  $c = ([regex]::Matches($fsReplay, "ALT-$v-ROW-")).Count
  Write-Host ("  drawn on the {0} alternate screen, still in the replay: {1}" -f $v, $c) -ForegroundColor DarkGray
}
$drawn = ([regex]::Matches($fsReplay, "ALT-1049-ROW-")).Count
if ($drawn -eq 0) { Pass "and none of what it drew on the alternate screen" }
else { Fail "fullscreen-replay" "the replay carries $drawn line(s) the program drew on its own screen - restoring paints them into the shell's buffer" }

# A replay must carry no questions.
#
# Reported as random characters in every new window - "?1;2c?1;2c", which
# is a terminal answering "what are you" twice. A terminal answers by
# writing back up the pipe, as though the answer had been typed. That is
# right when a running program asks and wrong when the question is a
# recording of one asked minutes ago, because the answer then arrives at a
# shell sitting at its prompt.
#
# Checked on the wire rather than on screen: the console host puts its own
# cursor-position question into every session's output, so there is always
# one to find, while whether the shell echoes the answer or quietly eats it
# varies by machine - which is why the screen is a poor place to look.
$esc = [char]27
$replayData = try { ($replay | ConvertFrom-Json).data } catch { "" }
if ($replayData.Length -eq 0) {
  Fail "replay-queries" "the replay payload could not be read - the checks below would pass on nothing"
} else {
  foreach ($q in @(@("cursor-position questions", "$esc[6n"), @("device-attributes questions", "$esc[c"))) {
    $n = [regex]::Matches($replayData, [regex]::Escape($q[1])).Count
    if ($n -eq 0) { Pass "and carries no $($q[0]) for the terminal to answer" }
    else { Fail "replay-queries" "the replay still carries $($q[0]) x$n - answering it types into a live shell" }
  }


# A replay must leave the terminal able to select text.
#
# Reported as "I cannot select text and copy in the new terminal". A
# program that turns mouse reporting on leaves that in the scrollback,
# and a window attaching afterwards replays it - switching mouse
# reporting on in a terminal nobody asked to. Dragging then sends mouse
# events to the shell rather than selecting, so there is nothing to copy.
#
# The window is new and the mode it inherited is not, which is what makes
# it baffling from the outside. Every replay now ends with the modes put
# back, and this is that check: the reset has to be there, and it has to
# be last, because anything after it could turn them on again.
$esc = [char]27
$mouseOff = "$esc[?1000l"
$sgrOff = "$esc[?1006l"
if ($replayData -match [regex]::Escape($mouseOff) -and $replayData -match [regex]::Escape($sgrOff)) {
  Pass "a replay puts mouse reporting back before handing over"
} else {
  Fail "replay-modes" "a replay does not reset mouse reporting - a window attaching after a program that turned it on cannot select text"
}
$lastOff = $replayData.LastIndexOf($mouseOff)
if ($lastOff -lt 0) {
  # Already reported by the check above. Saying it twice is better than
  # throwing here, which is what this did first - and a suite that dies
  # mid-file takes every check after it down with no explanation.
  Fail "replay-modes" "no reset to look after - nothing else can be said about ordering"
} else {
  $tail = $replayData.Substring($lastOff)
  if ($tail -notmatch [regex]::Escape("$esc[?1000h") -and $tail -notmatch [regex]::Escape("$esc[?1002h")) {
    Pass "and nothing after it turns them back on"
  } else {
    Fail "replay-modes" "something in the replay turns mouse reporting on after the reset"
  }
}
}

# ── soft kill: grace window, process survives ──
$null = Request2 $port "{""cmd"":""kill"",""id"":$id}"
Start-Sleep -Milliseconds 400
$b.Client.Close()
$s = Get-Sessions $port | Where-Object id -eq $id
if ($null -eq $s -or -not $s.alive -or $null -eq $s.expires_ms) { Fail "soft-kill" "expected alive doomed session, got: $($s | ConvertTo-Json -Compress)" } else { Pass "kill is soft: alive with expiry" }

# ── restore cancels the doom ──
$c = New-Conn $port
$c.Writer.WriteLine("{""cmd"":""attach"",""id"":$id}")
$null = Read-Line2 $c
$null = Read-Line2 $c
Start-Sleep -Milliseconds 400
$s = Get-Sessions $port | Where-Object id -eq $id
if ($null -ne $s.expires_ms) { Fail "undo-kill" "expiry not cleared on attach" } else { Pass "restore cancels pending kill" }

# ── kill twice is hard: gone immediately, checkpoint deleted ──
$null = Request2 $port "{""cmd"":""kill"",""id"":$id}"
# Final kill empties the daemon, which then exits; tolerate a lost reply.
try { $null = Request2 $port "{""cmd"":""kill"",""id"":$id}" 0 } catch {}
Start-Sleep -Milliseconds 600
$c.Client.Close()
$s = Get-Sessions $port | Where-Object id -eq $id
$files = Test-Path "$env:LOCALAPPDATA\GTerminal\sessions\$id.ring"
if ($null -ne $s -or $files) { Fail "hard-kill" "session or checkpoint survived double kill" } else { Pass "double kill is immediate and clean" }

# ── typed exit goes to restorable trash ──
$port = Start-Daemon   # previous daemon idle-exited with its last session
$id2 = (Request2 $port '{"cmd":"create","cols":100,"rows":30}').id
$d = New-Conn $port
$d.Writer.WriteLine("{""cmd"":""attach"",""id"":$id2}")
$null = Read-Line2 $d
$d.Writer.WriteLine('{"cmd":"write","data":"\u001b[1;1R"}')
Start-Sleep -Seconds 4
$null = Drain2 $d
$d.Writer.WriteLine('{"cmd":"write","data":"exit\r"}')
Start-Sleep -Seconds 3
$d.Client.Close()
$s = Get-Sessions $port | Where-Object id -eq $id2
if ($null -eq $s -or $s.alive -or $null -eq $s.expires_ms) { Fail "exit-trash" "expected dead session with expiry, got: $($s | ConvertTo-Json -Compress)" } else { Pass "typed exit lands in restorable trash" }

# ── trash resurrection shows the divider ──
$e = New-Conn $port
$e.Writer.WriteLine("{""cmd"":""attach"",""id"":$id2}")
$null = Read-Line2 $e
$replay = Read-Line2 $e
if ($replay -notlike "*restored*") { Fail "resurrect" "divider missing in replay" } else { Pass "trash resurrects with divider" }
$e.Client.Close()
$null = Request2 $port "{""cmd"":""kill"",""id"":$id2}"
# Final kill empties the daemon, which then exits; tolerate a lost reply.
try { $null = Request2 $port "{""cmd"":""kill"",""id"":$id2}" 0 } catch {}

# ── reboot survival ──
$port = Start-Daemon   # old daemon may have idle-exited after the kills
$daemon2 = $script:daemons[-1]
$id3 = (Request2 $port '{"cmd":"create","cols":100,"rows":30}').id
$f = New-Conn $port
$f.Writer.WriteLine("{""cmd"":""attach"",""id"":$id3}")
$null = Read-Line2 $f
$f.Writer.WriteLine('{"cmd":"write","data":"\u001b[1;1R"}')
Start-Sleep -Seconds 4
$f.Writer.WriteLine('{"cmd":"write","data":"cd C:\\Windows\r"}')
Start-Sleep -Milliseconds 1500
$f.Writer.WriteLine('{"cmd":"write","data":"echo reboot-marker-777\r"}')
Start-Sleep -Seconds 6
$f.Client.Close()

# A session nobody ever typed into, going through the same "reboot" as the
# one above. It holds its own prompt and a screenful of erase sequences —
# nothing anyone would reopen to read, and reopening it only makes a new
# shell in a folder, which a new tab already does. The distinction is
# *typing*, not bytes written: the terminal answers the ESC[6n that every
# session opens with, so "something was written" is true even here.
$husk = (Request2 $port '{"cmd":"create","cols":100,"rows":30}').id
$hc = New-Conn $port
$hc.Writer.WriteLine("{""cmd"":""attach"",""id"":$husk}")
$null = Read-Line2 $hc
$hc.Writer.WriteLine('{"cmd":"write","data":"[1;1R"}')   # the terminal, not a person
Start-Sleep -Seconds 6                                          # prompt renders, checkpoint flushes
$hc.Client.Close()
$huskRing = "$env:LOCALAPPDATA\GTerminal\sessions\$husk.ring"
if (Test-Path $huskRing) { Pass "an untouched session checkpoints like any other" }
else { Fail "husk" "nothing was checkpointed, so the restart proves nothing" }

Stop-DaemonTree $daemon2
Start-Sleep -Seconds 1
if (-not (Test-Path "$env:LOCALAPPDATA\GTerminal\sessions\$id3.ring")) {
  Fail "reboot-checkpoint" "no checkpoint after daemon death"
} else { Pass "checkpoint survives daemon death" }

$port = Start-Daemon
$s = Get-Sessions $port | Where-Object id -eq $id3
if ($null -eq $s -or $s.alive) { Fail "reboot-cold" "cold session not offered after restart" } else { Pass "cold session offered after 'reboot'" }
# The one nobody typed into does not come back, and does not leave its
# checkpoint behind either — a file with no session is a phantom that
# reappears every restart.
if (Get-Sessions $port | Where-Object id -eq $husk) {
  Fail "husk" "a shell nobody typed into came back after the restart"
} else { Pass "a shell nobody typed into is dropped instead" }
if (Test-Path $huskRing) { Fail "husk" "its checkpoint was left on disk" }
else { Pass "and its checkpoint is deleted with it" }
$g = New-Conn $port
$g.Writer.WriteLine("{""cmd"":""attach"",""id"":$id3}")
$null = Read-Line2 $g
$replay = Read-Line2 $g
$okMarker = $replay -like "*reboot-marker-777*"
$okDivider = $replay -like "*restored*"
if (-not ($okMarker -and $okDivider)) { Fail "reboot-resurrect" "marker=$okMarker divider=$okDivider" } else { Pass "reboot resurrection replays scrollback" }
$g.Writer.WriteLine('{"cmd":"write","data":"\u001b[1;1R"}')
Start-Sleep -Seconds 4
$live = Drain2 $g 2000
if ($live -notlike "*C:\\Windows*") { Fail "reboot-cwd" "new shell not in saved cwd" } else { Pass "reboot resurrection restores cwd" }
$g.Client.Close()

# ── cmd shell profile: spawns and tracks cwd via its prompt hook ──
$id4 = (Request2 $port '{"cmd":"create","cols":100,"rows":30,"shell":"cmd"}').id
$h = New-Conn $port
$h.Writer.WriteLine("{""cmd"":""attach"",""id"":$id4}")
$null = Read-Line2 $h
$h.Writer.WriteLine('{"cmd":"write","data":"\u001b[1;1R"}')
Start-Sleep -Seconds 3
$h.Writer.WriteLine('{"cmd":"write","data":"cd C:\\Windows\r"}')
Start-Sleep -Seconds 6   # checkpoint flush + prompt cwd emission
$s = Get-Sessions $port | Where-Object id -eq $id4
if ($null -eq $s -or -not $s.alive) { Fail "cmd-shell" "cmd session did not survive" }
elseif ($s.cwd -notlike "*Windows*") { Fail "cmd-cwd" "cmd cwd tracking failed: cwd=$($s.cwd)" }
else { Pass "cmd shell profile with cwd tracking" }
$h.Client.Close()
$null = Request2 $port "{""cmd"":""kill"",""id"":$id4}"
try { $null = Request2 $port "{""cmd"":""kill"",""id"":$id4}" 0 } catch {}

# ── default_cwd config: new sessions start in the configured directory ──
$defDir = Join-Path $env:TEMP "gterminal-defcwd-test"
New-Item -ItemType Directory -Force $defDir | Out-Null
Set-Content "$env:LOCALAPPDATA\GTerminal\config.json" ('{"grace_minutes": 5, "default_cwd": ' + ($defDir | ConvertTo-Json) + '}')
$id5 = (Request2 $port '{"cmd":"create","cols":100,"rows":30}').id
$i = New-Conn $port
$i.Writer.WriteLine("{""cmd"":""attach"",""id"":$id5}")
$null = Read-Line2 $i
$i.Writer.WriteLine('{"cmd":"write","data":"\u001b[1;1R"}')
Start-Sleep -Seconds 6   # prompt renders -> OSC 9;9 cwd emission
$s = Get-Sessions $port | Where-Object id -eq $id5
if ($s.cwd -notlike "*gterminal-defcwd-test*") { Fail "default-cwd" "cwd=$($s.cwd)" } else { Pass "default_cwd config honored for new sessions" }
$i.Client.Close()
$null = Request2 $port "{""cmd"":""kill"",""id"":$id5}"
try { $null = Request2 $port "{""cmd"":""kill"",""id"":$id5}" 0 } catch {}
# bad path falls back to home instead of failing to spawn
Set-Content "$env:LOCALAPPDATA\GTerminal\config.json" '{"grace_minutes": 5, "default_cwd": "Q:\\does\\not\\exist"}'
$id6 = (Request2 $port '{"cmd":"create","cols":100,"rows":30}').id
$j = New-Conn $port
$j.Writer.WriteLine("{""cmd"":""attach"",""id"":$id6}")
$null = Read-Line2 $j
$j.Writer.WriteLine('{"cmd":"write","data":"\u001b[1;1R"}')
# Six seconds was a guess, and on a loaded runner a shell still starting
# looks exactly like one that failed to spawn - which is what this
# reported. Wait for the prompt it draws when it is actually up.
$null = Wait-Ready $j 45
$s = Get-Sessions $port | Where-Object id -eq $id6
if ($null -eq $s -or -not $s.alive) { Fail "default-cwd-fallback" "session did not spawn with bad default_cwd" }
elseif ($s.cwd -like "*does*not*exist*") { Fail "default-cwd-fallback" "cwd=$($s.cwd)" }
else { Pass "bad default_cwd falls back to home" }
$j.Client.Close()
$null = Request2 $port "{""cmd"":""kill"",""id"":$id6}"
try { $null = Request2 $port "{""cmd"":""kill"",""id"":$id6}" 0 } catch {}

# ── explicit create cwd (templates) beats config default_cwd ──
# config still points at the bogus Q:\ path; the request's cwd must win.
$id7 = (Request2 $port '{"cmd":"create","cols":100,"rows":30,"cwd":"C:\\Windows"}').id
$k = New-Conn $port
$k.Writer.WriteLine("{""cmd"":""attach"",""id"":$id7}")
$null = Read-Line2 $k
$k.Writer.WriteLine('{"cmd":"write","data":"\u001b[1;1R"}')
Start-Sleep -Seconds 6
$s = Get-Sessions $port | Where-Object id -eq $id7
if ($s.cwd -notlike "*Windows") { Fail "template-cwd" "cwd=$($s.cwd)" } else { Pass "explicit create cwd overrides default_cwd" }
$k.Client.Close()
$null = Request2 $port "{""cmd"":""kill"",""id"":$id7}"
try { $null = Request2 $port "{""cmd"":""kill"",""id"":$id7}" 0 } catch {}
Remove-Item $defDir -Recurse -Force -ErrorAction SilentlyContinue

# ── history transcripts: output recorded durably, meta finalized ──
$hist = "$env:LOCALAPPDATA\GTerminal\history"
$log = Get-ChildItem $hist -Filter *.log -ErrorAction SilentlyContinue |
  Where-Object { (Get-Content $_.FullName -Raw) -like "*lifecycle-marker-999*" } |
  Select-Object -First 1
if (-not $log) { Fail "history-transcript" "no transcript contains the session-1 marker" }
else {
  Pass "history transcript captured session output"
  $hmPath = Join-Path $hist ($log.BaseName + ".json")
  if (-not (Test-Path $hmPath)) { Fail "history-meta" "meta json missing for $($log.Name)" }
  else {
    $hm = Get-Content $hmPath -Raw | ConvertFrom-Json
    if ($hm.ended_ms) { Pass "history meta finalized with ended_ms" }
    else { Fail "history-meta" "ended_ms not stamped after session death" }
  }
}
# retention: plant an ancient transcript pair and wait out a purge tick.
# A keeper session holds the daemon (and its purge thread) alive meanwhile.
$keep = (Request2 $port '{"cmd":"create","cols":80,"rows":24}').id
$oldTs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - 90L * 24 * 3600 * 1000
Set-Content "$hist\$oldTs-99.log" "ancient output"
Set-Content "$hist\$oldTs-99.json" "{""id"":99,""created_ms"":$oldTs,""ended_ms"":$oldTs,""cwd"":""C:\\"",""shell"":""auto""}"
Start-Sleep -Seconds 20
if ((Test-Path "$hist\$oldTs-99.log") -or (Test-Path "$hist\$oldTs-99.json")) {
  Fail "history-purge" "90-day-old transcript survived the retention purge"
} else { Pass "history retention purge removes expired transcripts" }
$null = Request2 $port "{""cmd"":""kill"",""id"":$keep}"
try { $null = Request2 $port "{""cmd"":""kill"",""id"":$keep}" 0 } catch {}

# ── transcript-fed predictor: command logging + plugin registration ──
Set-Content "$env:LOCALAPPDATA\GTerminal\config.json" '{"grace_minutes": 5, "prediction": "list"}'
$id10 = (Request2 $port '{"cmd":"create","cols":110,"rows":30}').id
$p2 = New-Conn $port
$p2.Writer.WriteLine("{""cmd"":""attach"",""id"":$id10}")
$null = Read-Line2 $p2
$p2.Writer.WriteLine('{"cmd":"write","data":"\u001b[1;1R"}')
$null = Wait-Ready $p2
# The prompt AFTER the command is what logs it, and the hook that writes
# it is installed while the shell starts. Run it again until the line
# turns up rather than once at a moment of this test's choosing.
$clog = "$env:LOCALAPPDATA\GTerminal\commands.log"
$clogText = ""
$clogDeadline = (Get-Date).AddSeconds(40)
while ((Get-Date) -lt $clogDeadline) {
  $null = Run-Await $p2 '{"cmd":"write","data":"echo gterm-cmdlog-777\r"}' 12
  Start-Sleep -Milliseconds 300
  $clogText = if (Test-Path $clog) { Get-Content $clog -Raw } else { "" }
  if ($clogText -like "*`techo gterm-cmdlog-777*") { break }
}
if ($clogText -like "*`techo gterm-cmdlog-777*") {
  Pass "prompt hook logs commands with their directory"
} else { Fail "cmdlog" "commands.log missing cwd-tab-command entry" }
$pred = Retry-Until $p2 ('{"cmd":"write","data":"[System.Management.Automation.Subsystem.SubsystemManager]::GetSubsystemInfo([System.Management.Automation.Subsystem.SubsystemKind]::CommandPredictor).Implementations.Name -join *q*,*q*\r"}'.Replace("*q*", "'")) { param($o) $o -like "*gterm*" }
if ($pred -like "*gterm*") { Pass "gterm predictor plugin registered" } else { Fail "predictor" "gterm not among CommandPredictor implementations" }
$p2.Client.Close()
$null = Request2 $port "{""cmd"":""kill"",""id"":$id10}"
try { $null = Request2 $port "{""cmd"":""kill"",""id"":$id10}" 0 } catch {}

# ── "GTerminal only" mode: PredictionSource is Plugin, not HistoryAndPlugin ──
Set-Content "$env:LOCALAPPDATA\GTerminal\config.json" '{"grace_minutes": 5, "prediction": "plugin-list"}'
$id11 = (Request2 $port '{"cmd":"create","cols":110,"rows":30}').id
$p3 = New-Conn $port
$p3.Writer.WriteLine("{""cmd"":""attach"",""id"":$id11}")
$null = Read-Line2 $p3
$p3.Writer.WriteLine('{"cmd":"write","data":"\u001b[1;1R"}')
$null = Wait-Ready $p3
# Retried until it answers at all, not until it answers correctly: the
# assertion below is still the one deciding whether Plugin is the value.
$srcOut = Retry-Until $p3 '{"cmd":"write","data":"echo \"src=$((Get-PSReadLineOption).PredictionSource)\"\r"}' { param($o) $o -like "*src=Plugin*" -or $o -like "*src=HistoryAndPlugin*" }
if ($srcOut -like "*src=Plugin*" -and $srcOut -notlike "*src=HistoryAndPlugin*") {
  Pass "GTerminal-only mode sets PredictionSource Plugin"
} else { Fail "plugin-only" "PredictionSource not Plugin" }
$p3.Client.Close()
$null = Request2 $port "{""cmd"":""kill"",""id"":$id11}"
try { $null = Request2 $port "{""cmd"":""kill"",""id"":$id11}" 0 } catch {}

# ── prediction "off": PSReadLine ghost suggestions suppressed ──
# The inline ghost renders as dim+italic (ESC[2m ESC[3m — see the SGR probe);
# with PredictionSource None those sequences must not appear while typing.
Set-Content "$env:LOCALAPPDATA\GTerminal\config.json" '{"grace_minutes": 5, "prediction": "off"}'
$id9 = (Request2 $port '{"cmd":"create","cols":100,"rows":30}').id
$n2 = New-Conn $port
$n2.Writer.WriteLine("{""cmd"":""attach"",""id"":$id9}")
$null = Read-Line2 $n2
$n2.Writer.WriteLine('{"cmd":"write","data":"\u001b[1;1R"}')
$null = Wait-Ready $n2
foreach ($c in "git sta".ToCharArray()) {
  $n2.Writer.WriteLine("{""cmd"":""write"",""data"":""$c""}")
  Start-Sleep -Milliseconds 120
}
Start-Sleep -Seconds 1
$typed = Drain2 $n2 800
if ($typed.Contains('\u001b[2m\u001b[3m')) { Fail "prediction-off" "ghost suggestion escapes present with prediction=off" }
elseif (-not $typed.Contains('g')) { Fail "prediction-off" "no echo received while typing" }
else { Pass "prediction off suppresses ghost suggestions" }
$n2.Client.Close()
$null = Request2 $port "{""cmd"":""kill"",""id"":$id9}"
try { $null = Request2 $port "{""cmd"":""kill"",""id"":$id9}" 0 } catch {}

# ── OSC 133 command blocks: marks, and honest exit codes ──
# The frontend's parsing is unit-tested (tests/blocks.mjs); this covers the
# half that lives in PowerShell, where the risk is. Exit codes especially:
# $LASTEXITCODE is only set by native executables, so a naive hook reports
# a failing cmdlet as a success, or blames it for an older failure.
Set-Content "$env:LOCALAPPDATA\GTerminal\config.json" '{"grace_minutes": 5, "prediction": "off"}'
$id12 = (Request2 $port '{"cmd":"create","cols":110,"rows":30}').id
$b1 = New-Conn $port
$b1.Writer.WriteLine("{""cmd"":""attach"",""id"":$id12}")
$null = Read-Line2 $b1
$b1.Writer.WriteLine('{"cmd":"write","data":"\u001b[1;1R"}')
$firstPrompt = Wait-Ready $b1
if ($firstPrompt -like "*]133;A*" -and $firstPrompt -like "*]133;B*") {
  Pass "prompt emits OSC 133 A and B marks"
} else { Fail "osc133-ab" "no 133;A / 133;B in the first prompt" }
# The very first prompt closes nothing, so it must not claim a command ran.
if ($firstPrompt -like "*]133;D*") {
  Fail "osc133-phantom" "first prompt emitted a D for a command that never ran"
} else { Pass "the first prompt emits no D" }

# A native command with a real exit code.
$b1.Writer.WriteLine('{"cmd":"write","data":"cmd /c exit 3\r"}')
Start-Sleep -Seconds 3
$out133 = Drain2 $b1 2000
if ($out133 -like "*]133;D;3*") { Pass "native exit code reported as 133;D;3" }
else { Fail "osc133-native" "expected 133;D;3 after 'cmd /c exit 3'" }

# Success is 0.
$b1.Writer.WriteLine('{"cmd":"write","data":"echo gterm-ok\r"}')
Start-Sleep -Seconds 3
$okOut = Drain2 $b1 2000
if ($okOut -like "*]133;D;0*") { Pass "a successful command reports 133;D;0" }
else { Fail "osc133-ok" "expected 133;D;0 after a successful command" }

# A failing *cmdlet* sets no $LASTEXITCODE. Reading that variable alone
# would report the previous command's 0 here, marking a failure green.
$b1.Writer.WriteLine('{"cmd":"write","data":"Get-Item C:\\gterm-does-not-exist-xyz\r"}')
Start-Sleep -Seconds 3
$cmdletOut = Drain2 $b1 2000
if ($cmdletOut -like "*]133;D;0*") {
  Fail "osc133-cmdlet" "failing cmdlet reported as success — `$? is being ignored"
} elseif ($cmdletOut -like "*]133;D;*") {
  Pass "a failing cmdlet reports a non-zero code"
} else { Fail "osc133-cmdlet" "no D mark after a failing cmdlet" }

# Enter on an empty line runs nothing, so nothing may be closed.
$b1.Writer.WriteLine('{"cmd":"write","data":"\r"}')
Start-Sleep -Seconds 2
$emptyOut = Drain2 $b1 2000
if ($emptyOut -like "*]133;D*") {
  Fail "osc133-empty" "empty Enter emitted a D for a command that never ran"
} else { Pass "an empty line closes no block" }
$b1.Client.Close()
$null = Request2 $port "{""cmd"":""kill"",""id"":$id12}"
try { $null = Request2 $port "{""cmd"":""kill"",""id"":$id12}" 0 } catch {}

# ── protocol robustness: one bad client must not cost anyone else ──
# Every window is a client of the same daemon, and every session in every
# window lives inside it. A frame the daemon does not expect has to be
# answered or ignored, never taken as a reason to fall over — the blast
# radius of a daemon crash is every session the user has open.
Set-Content "$env:LOCALAPPDATA\GTerminal\config.json" '{"grace_minutes": 5, "prediction": "off"}'
$guard = (Request2 $port '{"cmd":"create","cols":80,"rows":24}').id
$junk = New-Conn $port
$junk.Writer.WriteLine('this is not json at all')
$junk.Writer.WriteLine('{"cmd":')                       # truncated json
$junk.Writer.WriteLine('{"cmd":"nonsense","id":1}')     # unknown command
$junk.Writer.WriteLine('{"cmd":"attach","id":999999}')  # no such session
$junk.Writer.WriteLine('{"cmd":"kill","id":999999}')
$junk.Writer.WriteLine('{"cmd":"write","id":999999,"data":"x"}')
$junk.Writer.WriteLine('{"cmd":"resize","id":999999,"cols":0,"rows":0}')
$junk.Writer.WriteLine('{"cmd":"resize","id":999999,"cols":100000,"rows":100000}')
$junk.Writer.WriteLine('{}')                            # no command at all
$junk.Writer.WriteLine('[]')                            # right json, wrong shape
Start-Sleep -Seconds 2
try { $junk.Client.Close() } catch {}

# The daemon must still be answering, and the session it was holding must
# still be there.
$after = Request2 $port '{"cmd":"list"}'
if ($null -ne $after -and ($after.sessions | Where-Object { $_.id -eq $guard })) {
  Pass "daemon survives malformed frames with its sessions intact"
} else {
  Fail "protocol" "daemon stopped answering, or lost a session, after junk input"
}
$still = (Request2 $port '{"cmd":"create","cols":80,"rows":24}').id
if ($still) { Pass "daemon still accepts new sessions after junk input" }
else { Fail "protocol" "create failed after junk input" }
foreach ($k in @($guard, $still)) {
  $null = Request2 $port "{""cmd"":""kill"",""id"":$k}"
  try { $null = Request2 $port "{""cmd"":""kill"",""id"":$k}" 0 } catch {}
}

# ── many sessions at once, and all of them restored correctly ──
# A window full of tabs is a window full of sessions. What matters is not
# just that they all start, but that each one comes back as *itself* on
# reattach: the failure worth catching is a mix-up, where a tab is
# restored with someone else's scrollback.
$N = 12
$many = @()
foreach ($i in 1..$N) {
  $sid = (Request2 $port "{""cmd"":""create"",""cols"":100,""rows"":30}").id
  if ($sid) { $many += $sid }
}
if ($many.Count -eq $N) { Pass "$N sessions created" }
else { Fail "many-create" "only $($many.Count) of $N sessions were created" }

$list = Request2 $port '{"cmd":"list"}'
$listed = @($list.sessions | Where-Object { $many -contains $_.id }).Count
if ($listed -eq $N) { Pass "all $N sessions are listed" }
else { Fail "many-list" "list reported $listed of $N" }

# Attach to all of them at once — that is what a window with twelve tabs
# does — then give each a marker of its own.
$conns = @{}
foreach ($sid in $many) {
  $c = New-Conn $port
  $c.Writer.WriteLine("{""cmd"":""attach"",""id"":$sid}")
  $null = Read-Line2 $c
  $c.Writer.WriteLine('{"cmd":"write","data":"\u001b[1;1R"}')
  $conns[$sid] = $c
}
Start-Sleep -Seconds 6          # one wait for all twelve, not twelve waits
foreach ($sid in $many) {
  $null = Drain2 $conns[$sid] 200
  $conns[$sid].Writer.WriteLine("{""cmd"":""write"",""data"":""echo marker-$sid\r""}")
}
Start-Sleep -Seconds 4
$ownMarker = 0
foreach ($sid in $many) {
  $txt = Drain2 $conns[$sid] 400
  # its own marker, and nobody else's
  $others = @($many | Where-Object { $_ -ne $sid -and $txt -like "*marker-$_ *" }).Count
  if ($txt -like "*marker-$sid*" -and $others -eq 0) { $ownMarker++ }
}
if ($ownMarker -eq $N) { Pass "all $N sessions ran and returned their own output" }
else { Fail "many-run" "only $ownMarker of $N had their own marker and no one else's" }

# Detach every one of them, the way closing a window does.
foreach ($sid in $many) {
  $conns[$sid].Writer.WriteLine('{"cmd":"detach"}')
}
Start-Sleep -Seconds 1
foreach ($sid in $many) { try { $conns[$sid].Client.Close() } catch {} }
Start-Sleep -Seconds 2

$survivors = @((Request2 $port '{"cmd":"list"}').sessions | Where-Object { $many -contains $_.id }).Count
if ($survivors -eq $N) { Pass "all $N sessions survive being detached" }
else { Fail "many-detach" "$survivors of $N survived the detach" }

# Reattach all of them and check each replays its own scrollback. A
# restored tab showing another tab's history is the failure this is for.
$reconns = @{}
foreach ($sid in $many) {
  $c = New-Conn $port
  $c.Writer.WriteLine("{""cmd"":""attach"",""id"":$sid}")
  $null = Read-Line2 $c
  $reconns[$sid] = $c
}
Start-Sleep -Seconds 3
$restored = 0
foreach ($sid in $many) {
  $txt = Drain2 $reconns[$sid] 500
  $others = @($many | Where-Object { $_ -ne $sid -and $txt -like "*marker-$_ *" }).Count
  if ($txt -like "*marker-$sid*" -and $others -eq 0) { $restored++ }
}
if ($restored -eq $N) { Pass "all $N sessions replay their own scrollback on reattach" }
else { Fail "many-restore" "only $restored of $N replayed their own history" }

# And they still work afterwards.
$usable = 0
foreach ($sid in $many) {
  $reconns[$sid].Writer.WriteLine("{""cmd"":""write"",""data"":""echo back-$sid\r""}")
}
Start-Sleep -Seconds 4
foreach ($sid in $many) {
  if ((Drain2 $reconns[$sid] 400) -like "*back-$sid*") { $usable++ }
}
if ($usable -eq $N) { Pass "all $N restored sessions still take input" }
else { Fail "many-usable" "only $usable of $N accepted input after restore" }

foreach ($sid in $many) {
  try { $reconns[$sid].Client.Close() } catch {}
  $null = Request2 $port "{""cmd"":""kill"",""id"":$sid}"
  try { $null = Request2 $port "{""cmd"":""kill"",""id"":$sid}" 0 } catch {}
}

# ── the grace window, which is the whole "close never kills" promise ──
# Closing a tab must not end the process. The first kill is soft: the
# session keeps running, marked as closing, and attaching to it again
# cancels the doom. Getting this wrong loses work silently.
Set-Content "$env:LOCALAPPDATA\GTerminal\config.json" '{"grace_minutes": 5, "prediction": "off"}'
$g1 = (Request2 $port '{"cmd":"create","cols":80,"rows":24}').id
$null = Request2 $port "{""cmd"":""kill"",""id"":$g1}"
Start-Sleep -Seconds 1
$after = @((Request2 $port '{"cmd":"list"}').sessions | Where-Object { $_.id -eq $g1 })
if ($after.Count -eq 1) { Pass "a closed session survives its grace window" }
else { Fail "grace" "the session vanished on the first kill" }
if ($after[0].expires_ms) { Pass "and is marked as closing" }
else { Fail "grace" "no expires_ms on a soft-killed session" }

# Reattaching cancels the pending kill — this is the undo.
$gc = New-Conn $port
$gc.Writer.WriteLine("{""cmd"":""attach"",""id"":$g1}")
$null = Read-Line2 $gc
Start-Sleep -Seconds 1
$revived = @((Request2 $port '{"cmd":"list"}').sessions | Where-Object { $_.id -eq $g1 })
if ($revived.Count -eq 1 -and -not $revived[0].expires_ms) {
  Pass "reattaching cancels the pending kill"
} else { Fail "grace" "still marked for death after reattaching" }
$gc.Client.Close()

# The second kill is the real one.
$null = Request2 $port "{""cmd"":""kill"",""id"":$g1}"
$null = Request2 $port "{""cmd"":""kill"",""id"":$g1}"
Start-Sleep -Seconds 2
$gone = @((Request2 $port '{"cmd":"list"}').sessions | Where-Object { $_.id -eq $g1 })
if ($gone.Count -eq 0) { Pass "killing twice ends the session for real" }
else { Fail "grace" "session survived a hard kill" }

# ── writing to a session that is gone ──
# A window can hold a stale id across a kill; the daemon has to say no
# rather than fall over, because it is holding everyone else's sessions.
$keep = (Request2 $port '{"cmd":"create","cols":80,"rows":24}').id
$stale = New-Conn $port
$stale.Writer.WriteLine("{""cmd"":""write"",""id"":$g1,""data"":""hello""}")
$stale.Writer.WriteLine("{""cmd"":""resize"",""id"":$g1,""cols"":80,""rows"":24}")
Start-Sleep -Seconds 1
try { $stale.Client.Close() } catch {}
$alive2 = @((Request2 $port '{"cmd":"list"}').sessions | Where-Object { $_.id -eq $keep })
if ($alive2.Count -eq 1) { Pass "writing to a dead session does not disturb the living" }
else { Fail "stale-write" "the daemon lost a session after a write to a dead id" }

# ── rapid create and kill ──
# Windows open and close tabs fast; a race in the session map shows up as
# a daemon that stops answering rather than as an error.
$burst = @()
foreach ($i in 1..10) { $burst += (Request2 $port '{"cmd":"create","cols":80,"rows":24}').id }
foreach ($b in $burst) { $null = Request2 $port "{""cmd"":""kill"",""id"":$b}" }
foreach ($b in $burst) { try { $null = Request2 $port "{""cmd"":""kill"",""id"":$b}" 0 } catch {} }
Start-Sleep -Seconds 2
$stillThere = Request2 $port '{"cmd":"list"}'
if ($null -ne $stillThere) { Pass "the daemon survives ten sessions opened and closed in a burst" }
else { Fail "burst" "daemon stopped answering after a create/kill burst" }

# ── absurd resizes ──
# A zero-column terminal is a division by zero waiting to happen, and a
# hundred-thousand-column one is an allocation. Neither may take the
# daemon down.
$rz = (Request2 $port '{"cmd":"create","cols":80,"rows":24}').id
$rc = New-Conn $port
$rc.Writer.WriteLine("{""cmd"":""attach"",""id"":$rz}")
$null = Read-Line2 $rc
# Wait for the shell to actually be up, answering its cursor query when it
# asks, instead of firing the answer blindly and sleeping four seconds. A
# shell that never got its answer is not a shell wedged by the resizes
# below, but that is exactly what this reported.
$null = Wait-Ready $rc 60
foreach ($dim in '{"cols":0,"rows":0}', '{"cols":1,"rows":1}', '{"cols":9999,"rows":9999}', '{"cols":120,"rows":30}') {
  $rc.Writer.WriteLine("{""cmd"":""resize""," + $dim.Substring(1))
  Start-Sleep -Milliseconds 300
}
Start-Sleep -Seconds 1
# Asked until it answers. A shell a few seconds slower than the guess is
# not a shell that "stopped responding after extreme resizes", which is
# what a single look three seconds later reported.
$rzOut = Retry-Until $rc 'echo resize-survivor\r' { param($o) $o -like "*resize-survivor*" } 30
if ($rzOut -like "*resize-survivor*") { Pass "a session survives absurd resizes" }
else { Fail "resize-extremes" "the session stopped responding after extreme resizes" }
$rc.Client.Close()
foreach ($k in @($keep, $rz)) {
  $null = Request2 $port "{""cmd"":""kill"",""id"":$k}"
  try { $null = Request2 $port "{""cmd"":""kill"",""id"":$k}" 0 } catch {}
}


# ── a session moves between windows ──
# One attacher at a time, newest wins: that is what makes a second window
# safe, since a session is never shared - it is somewhere. The window
# that had it must be told, or it keeps a tab that will never speak
# again and looks hung.
$moved = (Request2 $port '{"cmd":"create","cols":80,"rows":24}').id
$first = New-Conn $port
$first.Writer.WriteLine("{""cmd"":""attach"",""id"":$moved}")
$null = Read-Line2 $first
$null = Drain2 $first 600
$second = New-Conn $port
$second.Writer.WriteLine("{""cmd"":""attach"",""id"":$moved}")
$okSecond = Read-Line2 $second
if (($okSecond | ConvertFrom-Json).ok -eq $true) { Pass "a second window may take a session" }
else { Fail "handover" "the second attach was refused: $okSecond" }
$told = Drain2 $first 2000
if ($told -match '"ev":"taken"') { Pass "and the first is told it lost it" }
else { Fail "handover" "the displaced client was never told: $($told -replace '\s+', ' ')" }
# The session itself is untouched by the move.
$still = @(Get-Sessions $port | Where-Object { $_.id -eq $moved -and $_.alive })
if ($still.Count -eq 1) { Pass "and the session itself is unharmed" }
else { Fail "handover" "the session did not survive being handed over" }
try { $first.Client.Close() } catch {}
try { $second.Client.Close() } catch {}
$null = Request2 $port "{""cmd"":""kill"",""id"":$moved}"
try { $null = Request2 $port "{""cmd"":""kill"",""id"":$moved}" 0 } catch {}

# ── the daemon says who it is ──
# The daemon outlives the app that started it, so an update leaves a new
# window talking to the previous release's daemon. Without these fields
# the window cannot tell "this session is empty" from "this daemon is too
# old to answer" — see docs/daemon-protocol.md.
$hello = Request2 $port '{"cmd":"list"}'
$proto = 0
if ($null -ne $hello.protocol -and [int]::TryParse([string]$hello.protocol, [ref]$proto) -and $proto -ge 2) {
  Pass "list reports a protocol number"
} else { Fail "protocol" "no protocol in the list reply: $($hello.protocol)" }
if ($hello.version -match '^\d+\.\d+\.\d+$') { Pass "and the version it is running" }
else { Fail "protocol" "no version in the list reply: $($hello.version)" }
# The pid is what the window uses to stop this exact process, so a wrong
# one would have it kill something else entirely.
if ($hello.pid -eq $script:daemons[-1]) { Pass "and its own pid, which is the one running" }
else { Fail "protocol" "reported pid $($hello.pid), daemon is $($script:daemons[-1])" }

# ── an unknown request is refused, not fatal ──
# This is what a *newer* window's request looks like to an older daemon:
# it must be answered and the connection left usable, or the window loses
# the session it was attached to as well as the feature.
$un = New-Conn $port
$un.Writer.WriteLine('{"cmd":"peek_the_future","id":1}')
$refusal = Read-Line2 $un 3000
if ($refusal -and ($refusal | ConvertFrom-Json).ok -eq $false) { Pass "an unknown request is refused" }
else { Fail "unknown-request" "no refusal came back: $refusal" }
$un.Writer.WriteLine('{"cmd":"list"}')
$still = Read-Line2 $un 3000
if ($still -and ($still | ConvertFrom-Json).ok -eq $true) { Pass "and the connection still works afterwards" }
else { Fail "unknown-request" "the connection died on an unknown request" }
$un.Client.Close()

# ── closing several sessions in a row ──
# Reported from real use: closing a handful of tabs left only *one* of them
# under "Closing soon" and the rest unaccounted for. Each close is its own
# soft kill, so every one of them should get its own grace window — and the
# daemon must not treat a set of doomed sessions as an empty one and exit.
$many = @()
foreach ($i in 1..4) { $many += (Request2 $port '{"cmd":"create","cols":80,"rows":24}').id }
foreach ($m in $many) { $null = Request2 $port "{""cmd"":""kill"",""id"":$m}" }
Start-Sleep -Seconds 1
$after = @(Get-Sessions $port)
$doomed = @($after | Where-Object { $many -contains $_.id -and $_.expires_ms })
if ($doomed.Count -eq 4) { Pass "closing four sessions puts all four in the grace window" }
else {
  $ids = ($doomed | ForEach-Object { $_.id }) -join ","
  Fail "close-many" "expected 4 in the grace window, got $($doomed.Count) ($ids)"
}
$lost = @($many | Where-Object { $id = $_; -not ($after | Where-Object { $_.id -eq $id }) })
if ($lost.Count -eq 0) { Pass "and none of them vanish from the list" }
else { Fail "close-many" "sessions disappeared instead of closing soon: $($lost -join ',')" }

# The daemon holds four doomed sessions and nothing attached. Exiting here
# would take the grace window with it, and with it the whole point of it.
Start-Sleep -Seconds 2
if (@(Get-Sessions $port).Count -ge 4) { Pass "the daemon stays up while every session is closing" }
else { Fail "close-many" "the daemon exited while sessions were still in their grace window" }

# ── restoring one of them ──
# Attaching cancels that session's pending kill and must leave the others
# exactly as they were: undoing one close is not undoing all of them.
$revive = New-Conn $port
$revive.Writer.WriteLine("{""cmd"":""attach"",""id"":$($many[0])}")
$null = Read-Line2 $revive
Start-Sleep -Milliseconds 800
$after2 = @(Get-Sessions $port)
$one = $after2 | Where-Object { $_.id -eq $many[0] }
if ($one -and -not $one.expires_ms) { Pass "attaching cancels that session's grace window" }
else { Fail "revive" "the restored session is still marked as closing" }
$others = @($after2 | Where-Object { $many[1..3] -contains $_.id -and $_.expires_ms })
if ($others.Count -eq 3) { Pass "and leaves the other three closing" }
else { Fail "revive" "restoring one session disturbed the others ($($others.Count) of 3 still closing)" }
$revive.Writer.WriteLine('{"cmd":"detach"}')
Start-Sleep -Milliseconds 400
$revive.Client.Close()

# ── a hard kill takes one, not the set ──
$null = Request2 $port "{""cmd"":""kill"",""id"":$($many[1])}"
Start-Sleep -Milliseconds 800
$after3 = @(Get-Sessions $port)
if (-not ($after3 | Where-Object { $_.id -eq $many[1] })) { Pass "a second kill ends that one session" }
else { Fail "hard-kill" "the doomed session survived its second kill" }
$survivors = @($after3 | Where-Object { $many[2..3] -contains $_.id -and $_.expires_ms })
if ($survivors.Count -eq 2) { Pass "and the rest keep their grace windows" }
else { Fail "hard-kill" "a hard kill took the other closing sessions with it" }

# ── grace turned off ──
# grace_minutes is read from config on every kill, so a user who sets it to
# 0 gets an immediate close from then on, with no "Closing soon" stop.
Set-Content "$env:LOCALAPPDATA\GTerminal\config.json" '{"grace_minutes": 0}'
$instant = (Request2 $port '{"cmd":"create","cols":80,"rows":24}').id
$null = Request2 $port "{""cmd"":""kill"",""id"":$instant}"
Start-Sleep -Milliseconds 800
if (-not (@(Get-Sessions $port) | Where-Object { $_.id -eq $instant })) {
  Pass "grace_minutes 0 closes immediately, with no grace window"
} else { Fail "grace-off" "the session lingered although the grace window is disabled" }
Set-Content "$env:LOCALAPPDATA\GTerminal\config.json" '{"grace_minutes": 5}'
foreach ($m in $many) { try { $null = Request2 $port "{""cmd"":""kill"",""id"":$m}" 0 } catch {} }

# == two daemons, one state directory ==
# A second daemon used to write its own port into the file and walk off
# with every client that looked the daemon up afterwards. Nothing
# crashed. The daemon holding the sessions kept running, unreachable,
# while the window found the newcomer and showed an empty sidebar - which
# is indistinguishable, from the outside, from having lost the lot.
#
# Hit for real: a stray daemon started by hand against the live state
# directory moved the port file, and the running sessions became
# unfindable until it was put back.
$portBefore = Start-Daemon
$firstPid = $script:daemons[-1]
# Deliberately not Start-Daemon: it clears the port file first, which is
# the one thing that makes a second daemon legitimate.
$second = Start-Process -FilePath $exe -ArgumentList "--daemon" -WindowStyle Hidden -PassThru
$script:daemons += $second.Id
Start-Sleep -Seconds 3
$portAfter = (Get-Content "$env:LOCALAPPDATA\GTerminal\daemon.port" -Raw).Trim()
$secondAlive = $null -ne (Get-Process -Id $second.Id -ErrorAction SilentlyContinue)

if ($portAfter -eq "$portBefore") { Pass "a second daemon leaves the port file pointing at the first" }
else { Fail "second-daemon" "the port file moved from $portBefore to $portAfter" }
if (-not $secondAlive) { Pass "and stands down instead of running alongside it" }
else { Fail "second-daemon" "the second daemon is still running" }
# Still serving, not just still named in a file.
try {
  $still = Request2 $portBefore '{"cmd":"list"}'
  if ($still.ok) { Pass "and the first daemon is still answering" }
  else { Fail "second-daemon" "the first daemon answered without ok: $($still | ConvertTo-Json -Compress)" }
} catch { Fail "second-daemon" "the first daemon stopped answering: $_" }

# ════ a window with no room left ════
# A pty with zero rows or columns is not a terminal, and the daemon
# refuses one. This holds that invariant; it does not demonstrate a bug.
#
# It was written chasing "if i keep a window minimized for too long it
# eventually goes into closing soon" - which is what a session whose SHELL
# HAS ENDED looks like while it waits out the grace window, so something
# is ending shells rather than killing sessions. A cmd shell was seen
# dying on a 100x0 resize once, and it did not reproduce: with the clamp
# removed, cmd survives every degenerate size, five runs out of five. The
# real cause is still open.
$zrPort = Start-Daemon
foreach ($zrShell in "pwsh", "cmd") {
  $zrId = (Request2 $zrPort ('{"cmd":"create","cols":100,"rows":30,"shell":"' + $zrShell + '"}')).id
  $zr = New-Conn $zrPort
  $zr.Writer.WriteLine("{""cmd"":""attach"",""id"":$zrId}")
  $null = Read-Line2 $zr
  $zr.Writer.WriteLine('{"cmd":"write","data":"[1;1R"}')
  $null = Wait-Ready $zr
  # Checked after EVERY size, not once at the end. Done once at the end
  # this test did not notice the clamp being removed at all: a session
  # whose shell has ended leaves `live`, so the whole row disappears and
  # every reading of it looks the same as a session that is simply not
  # there yet. Which size killed it is also the useful part of the
  # answer - measured, cmd dies on 100x0 and survives 0x0.
  $zrDiedAt = ""
  foreach ($zrSize in @(@(0, 0), @(1, 1), @(0, 30), @(100, 0))) {
    $zr.Writer.WriteLine('{"cmd":"resize","cols":' + $zrSize[0] + ',"rows":' + $zrSize[1] + '}')
    Start-Sleep -Milliseconds 800
    $zrRow = (Request2 $zrPort '{"cmd":"list"}').sessions | Where-Object { $_.id -eq $zrId }
    if (-not $zrRow -or $zrRow.alive -ne $true) {
      $zrDiedAt = "$($zrSize[0])x$($zrSize[1])"
      break
    }
  }
  if (-not $zrDiedAt) { Pass "a $zrShell shell survives being resized to nothing" }
  else { Fail "zero-resize" "the $zrShell shell died when its terminal was resized to $zrDiedAt" }
  $zr.Client.Close()
}

# ════ standing down gracefully ════
# A Store update replaces the package while the daemon keeps running, so a
# new window meets the previous release's daemon. Killing it was the only
# way to replace it, and killing it ends every shell it holds.
$sdPort = Start-Daemon
$sdPid = $script:daemons[-1]

# Retire while a shell is live: it must stay up, and say what it is
# waiting for.
$sdId = (Request2 $sdPort '{"cmd":"create","cols":80,"rows":24}').id
$sdRetire = Request2 $sdPort '{"cmd":"shutdown","when_idle":true}'
Start-Sleep -Seconds 1
# Alive AND answering. A process that is still listed but no longer
# serving is not "stayed up" in any sense the caller cares about.
$sdStillUp = $null -ne (Get-Process -Id $sdPid -ErrorAction SilentlyContinue)
if ($sdStillUp) {
  try { $sdStillUp = (Request2 $sdPort '{"cmd":"list"}').ok -eq $true } catch { $sdStillUp = $false }
}
if ($sdRetire.ok -and $sdRetire.retiring -and $sdRetire.live -ge 1) {
  Pass "a retiring daemon says how many shells it is waiting on"
} else { Fail "retire" "expected ok/retiring/live>=1, got $($sdRetire | ConvertTo-Json -Compress)" }
if ($sdStillUp) { Pass "and stays up while one is still running" }
else { Fail "retire" "the daemon exited with a live session" }

# Now end it. The daemon should go on its own, with nothing killed.
# Guarded: with the retire rule broken the daemon is already gone by now,
# and an unguarded request throws and takes the whole suite down with it -
# which reports the bug as a crash rather than as the one assertion that
# is actually wrong.
$sdKilled = $true
try {
  $null = Request2 $sdPort ('{"cmd":"kill","id":' + $sdId + '}')
  $null = Request2 $sdPort ('{"cmd":"kill","id":' + $sdId + '}')   # twice: skip the grace window
} catch { $sdKilled = $false }
if (-not $sdKilled) { Fail "retire" "the daemon stopped answering before its last shell ended" }
$sdGone = $false
foreach ($i in 1..60) {
  Start-Sleep -Milliseconds 250
  if (-not (Get-Process -Id $sdPid -ErrorAction SilentlyContinue)) { $sdGone = $true; break }
}
if ($sdGone) { Pass "and stands down by itself once the last shell ends" }
else { Fail "retire" "the daemon was still running after its last session ended" }

# The immediate form: checkpoint and exit on request, rather than being
# killed mid-write.
$sd2Port = Start-Daemon
$sd2Pid = $script:daemons[-1]
$null = Request2 $sd2Port '{"cmd":"create","cols":80,"rows":24}'
$sd2Reply = Request2 $sd2Port '{"cmd":"shutdown"}'
$sd2Gone = $false
foreach ($i in 1..40) {
  Start-Sleep -Milliseconds 250
  if (-not (Get-Process -Id $sd2Pid -ErrorAction SilentlyContinue)) { $sd2Gone = $true; break }
}
if ($sd2Reply.ok -and $sd2Reply.exiting) { Pass "an immediate shutdown is acknowledged before it goes" }
else { Fail "shutdown" "expected ok/exiting, got $($sd2Reply | ConvertTo-Json -Compress)" }
if ($sd2Gone) { Pass "and the daemon actually exits" }
else { Fail "shutdown" "the daemon was still running after being asked to stop" }
# Checkpointed on the way out, not left as whatever the last flush caught.
$sd2Meta = @(Get-ChildItem "$env:LOCALAPPDATA\GTerminal\sessions" -Filter *.json -ErrorAction SilentlyContinue)
if ($sd2Meta.Count -ge 1) { Pass "and wrote its sessions to disk before exiting" }
else { Fail "shutdown" "no session checkpoint was written on shutdown" }

# ════ cleanup ════
foreach ($d in $script:daemons) {
  if (Get-Process -Id $d -ErrorAction SilentlyContinue) { Stop-DaemonTree $d }
}
Remove-Item "$env:LOCALAPPDATA\GTerminal" -Recurse -Force -ErrorAction SilentlyContinue

if ($failures.Count) {
  $failures | ForEach-Object { Write-Host "FAIL $_" -ForegroundColor Red }
  exit 1
}
"all lifecycle tests passed"
exit 0
