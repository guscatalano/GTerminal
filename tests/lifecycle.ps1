# Lifecycle regression tests: every daemon-side behavior GTerminal relies on.
# Fully isolated (scratch LOCALAPPDATA, PID-scoped kills); exits nonzero on
# any failure.
$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
$exe = Join-Path $repo "src-tauri\target\debug\gterminal.exe"
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
Stop-DaemonTree $daemon2
Start-Sleep -Seconds 1
if (-not (Test-Path "$env:LOCALAPPDATA\GTerminal\sessions\$id3.ring")) {
  Fail "reboot-checkpoint" "no checkpoint after daemon death"
} else { Pass "checkpoint survives daemon death" }

$port = Start-Daemon
$s = Get-Sessions $port | Where-Object id -eq $id3
if ($null -eq $s -or $s.alive) { Fail "reboot-cold" "cold session not offered after restart" } else { Pass "cold session offered after 'reboot'" }
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
Start-Sleep -Seconds 6
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

# ── prediction "off": PSReadLine ghost suggestions suppressed ──
# The inline ghost renders as dim+italic (ESC[2m ESC[3m — see the SGR probe);
# with PredictionSource None those sequences must not appear while typing.
Set-Content "$env:LOCALAPPDATA\GTerminal\config.json" '{"grace_minutes": 5, "prediction": "off"}'
$id9 = (Request2 $port '{"cmd":"create","cols":100,"rows":30}').id
$n2 = New-Conn $port
$n2.Writer.WriteLine("{""cmd"":""attach"",""id"":$id9}")
$null = Read-Line2 $n2
$n2.Writer.WriteLine('{"cmd":"write","data":"\u001b[1;1R"}')
Start-Sleep -Seconds 5
$null = Drain2 $n2
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
