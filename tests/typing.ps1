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
$stream = $client.GetStream()
$w = [System.IO.StreamWriter]::new($stream); $w.NewLine = "`n"; $w.AutoFlush = $true
$r = [System.IO.StreamReader]::new($stream)

# NDJSON reading via raw polls: a sync ReadTimeout on a NetworkStream kills
# the connection when it fires, so timeouts must never hit the socket.
$script:acc = ""
$script:buf = New-Object byte[] 65536
function Read-Event {
  param($timeoutMs = 2000, [switch]$spin)
  $deadline = [DateTime]::UtcNow.AddMilliseconds($timeoutMs)
  while (-not $script:acc.Contains("`n")) {
    if ($stream.DataAvailable) {
      $n = $stream.Read($script:buf, 0, $script:buf.Length)
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

# ── setup: create + attach a session, answer ConPTY's cursor query ──
$w.WriteLine('{"cmd":"create","cols":120,"rows":30}')
$id = ($r.ReadLine() | ConvertFrom-Json).id
$client2 = [System.Net.Sockets.TcpClient]::new("127.0.0.1", $port)
$client2.NoDelay = $true
$stream = $client2.GetStream()
$w = [System.IO.StreamWriter]::new($stream); $w.NewLine = "`n"; $w.AutoFlush = $true
$w.WriteLine("{""cmd"":""attach"",""id"":$id}")
$null = Read-Event
$w.WriteLine('{"cmd":"write","data":"\u001b[1;1R"}')
Start-Sleep -Seconds 5
$null = Drain 500   # swallow banner + first prompt

# ── test 1: correctness — burst-type a string, verify exact arrival ──
$payload = "typing-test-0123456789-abcdefghijklmnopqrstuvwxyz"
foreach ($c in "echo $payload".ToCharArray()) {
  $w.WriteLine("{""cmd"":""write"",""data"":""$c""}")   # no delay: stress ordering
}
Start-Sleep -Seconds 2
$echoed = Strip-Ansi (Drain 500)
$w.WriteLine('{"cmd":"write","data":"\r"}')
Start-Sleep -Seconds 2
$output = Strip-Ansi (Drain 500)
if ($echoed -like "*echo $payload*") {
  "PASS correctness: all $("echo $payload".Length) chars echoed contiguously"
} else {
  # Informational only: PSReadLine line-redraws can fragment the echo; the
  # command output below is the authoritative proof of intact arrival.
  "note: echo display fragmented by line redraws (not a failure by itself)"
}
if ($output -notlike "*$payload*") {
  $failures += "correctness: shell did not receive the payload intact. Got: $output"
} else {
  "PASS correctness: shell received and executed the full payload intact"
}

# ── test 2: latency — per-keystroke echo roundtrip ──
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

# ── cleanup: kill twice (grace window makes the first kill soft) ──
$w.WriteLine('{"cmd":"write","data":""}')
$ctl = [System.Net.Sockets.TcpClient]::new("127.0.0.1", $port)
$cs = $ctl.GetStream()
$cw = [System.IO.StreamWriter]::new($cs); $cw.NewLine = "`n"; $cw.AutoFlush = $true
$cr = [System.IO.StreamReader]::new($cs)
$cw.WriteLine("{""cmd"":""kill"",""id"":$id}"); $null = $cr.ReadLine()
$cw.WriteLine("{""cmd"":""kill"",""id"":$id}"); $null = $cr.ReadLine()
$ctl.Close(); $client2.Close(); $client.Close()
Stop-Process -Id $daemon.Id -Force -ErrorAction SilentlyContinue
Remove-Item "$env:LOCALAPPDATA\GTerminal" -Recurse -Force -ErrorAction SilentlyContinue

if ($failures.Count) {
  $failures | ForEach-Object { Write-Host "FAIL $_" -ForegroundColor Red }
  exit 1
}
"all typing tests passed"
exit 0
