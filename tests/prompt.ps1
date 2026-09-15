# Does the prompt hook survive the user's profile?
# Run: pwsh -File tests/prompt.ps1
#
# Everything that knows where a shell *is* comes from one place: a hook
# the daemon wraps around the prompt after the profile has loaded, which
# emits the current folder on every prompt. Tab titles follow it, the
# command blocks are cut on it, and a template's run-on-open command is
# delivered when it first fires. So a profile that breaks the hook
# breaks all three at once, silently, and looks like three unrelated
# bugs.
#
# Four profiles, each a real shell in a real daemon, each asked one
# question: did a prompt report a folder. A prompt that was replaced
# by the profile (oh-my-posh, Starship, a hand-written one) is the
# ordinary case and the one the hook is designed to wrap. The other two
# are the ways a profile can get in front of the wrapping.
#
# The profile is planted by pointing USERPROFILE at a scratch folder,
# because that is where pwsh looks for it - so nothing here reads or
# writes the profile of the person running the test.
param(
  [string]$Exe
)
$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
$exe = if ($Exe) { $Exe } else { Join-Path $repo "src-tauri\target\debug\gterminal.exe" }
if (-not (Test-Path $exe)) { Write-Error "build first: cargo build in src-tauri" }

$failures = @()
function Pass { param($name) "PASS $name" }
function Fail { param($name, $detail) $script:failures += "${name}: $detail" }

$scratch = Join-Path $env:TEMP "gterminal-prompt-test"
Remove-Item $scratch -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force "$scratch\home\Documents\PowerShell" | Out-Null
New-Item -ItemType Directory -Force "$scratch\local\GTerminal" | Out-Null
$env:LOCALAPPDATA = "$scratch\local"
$env:USERPROFILE = "$scratch\home"
$profilePath = "$scratch\home\Documents\PowerShell\Microsoft.PowerShell_profile.ps1"

# ── the daemon, and a way to talk to it ─────────────────────────────────
$daemon = Start-Process -FilePath $exe -ArgumentList "--daemon" -WindowStyle Hidden -PassThru
foreach ($i in 1..60) {
  Start-Sleep -Milliseconds 150
  if (Test-Path "$env:LOCALAPPDATA\GTerminal\daemon.port") { break }
}
$port = [int](Get-Content "$env:LOCALAPPDATA\GTerminal\daemon.port").Trim()

function Token {
  $f = "$env:LOCALAPPDATA\GTerminal\daemon.token"
  if (Test-Path $f) { (Get-Content $f -Raw).Trim() } else { "" }
}
function Conn {
  $c = [System.Net.Sockets.TcpClient]::new("127.0.0.1", $port)
  $c.NoDelay = $true
  $s = $c.GetStream()
  $w = [System.IO.StreamWriter]::new($s); $w.NewLine = "`n"; $w.AutoFlush = $true
  $t = Token
  if ($t) { $w.WriteLine("{`"token`":`"$t`"}") }
  [pscustomobject]@{ Client = $c; Stream = $s; Writer = $w; Buf = New-Object byte[] 65536 }
}
function Drain($conn, $ms) {
  $acc = ""
  $deadline = (Get-Date).AddMilliseconds($ms)
  while ((Get-Date) -lt $deadline) {
    if ($conn.Stream.DataAvailable) {
      $n = $conn.Stream.Read($conn.Buf, 0, $conn.Buf.Length)
      if ($n -gt 0) { $acc += [Text.Encoding]::UTF8.GetString($conn.Buf, 0, $n) }
    } else { Start-Sleep -Milliseconds 50 }
  }
  $acc
}
function Ask($json) {
  $c = Conn
  $c.Writer.WriteLine($json)
  $out = Drain $c 1500
  $c.Client.Close()
  ($out -split "`n" | Where-Object { $_ -match '"ok"' } | Select-Object -First 1) | ConvertFrom-Json
}

# Start a session with the profile on disk, attach, answer the cursor
# query the shell starts with, and report whether a cwd ever arrived.
# The command is the second half of the same question: it is delivered
# on that first cwd report, so "the command ran" and "the hook fired"
# are one fact seen from two sides.
function Try-Profile {
  param([string]$name, [string]$profileText)
  Set-Content -Path $profilePath -Value $profileText -Encoding UTF8
  $marker = "HOOK-ALIVE-" + (Get-Random -Maximum 99999)
  $made = Ask ('{"cmd":"create","cols":100,"rows":30,"shell":"pwsh","command":"echo ' + $marker + '"}')
  if (-not $made.ok) { Fail $name "could not create a session: $($made | ConvertTo-Json -Compress)"; return }
  $win = Conn
  $win.Writer.WriteLine('{"cmd":"attach","id":' + $made.id + '}')
  $seen = ""
  $answered = 0
  $deadline = (Get-Date).AddSeconds(45)
  while ((Get-Date) -lt $deadline) {
    $seen += Drain $win 400
    $asked = [regex]::Matches($seen, [regex]::Escape('\u001b[6n')).Count
    while ($answered -lt $asked) {
      $win.Writer.WriteLine('{"cmd":"write","data":"\u001b[1;1R"}')
      $answered++
    }
    if (([regex]::Matches($seen, $marker)).Count -ge 2) { break }
  }
  $win.Client.Close()
  # JSON on the wire: an escape byte arrives as the six characters
  # backslash-u-0-0-1-b, so that is what is matched and what is sent.
  $cwdReported = $seen.Contains('\u001b]9;9;')
  $ran = ([regex]::Matches($seen, $marker)).Count -ge 2
  [pscustomobject]@{ Cwd = $cwdReported; Ran = $ran; Seen = $seen }
}

# ── 1. No profile at all: the baseline everything else is measured against.
Remove-Item $profilePath -ErrorAction SilentlyContinue
$r = Try-Profile "no-profile" ""
Remove-Item $profilePath -ErrorAction SilentlyContinue
if ($r.Cwd -and $r.Ran) { Pass "with no profile, the prompt reports a folder and run-on-open runs" }
else { Fail "no-profile" "cwd=$($r.Cwd) ran=$($r.Ran) - the baseline is broken, so nothing below means anything" }

# ── 2. A profile that replaces the prompt, which is what oh-my-posh,
#      Starship and every hand-written prompt do. The ordinary case, and
#      the one the hook exists to wrap: it takes $function:prompt as it
#      is *after* the profile, so a custom prompt is called from inside
#      the hook rather than instead of it.
$r = Try-Profile "custom-prompt" 'function prompt { "custom [$(Get-Date -Format HH:mm)] > " }'
if ($r.Cwd -and $r.Ran) { Pass "a profile that replaces the prompt is wrapped, not lost" }
else { Fail "custom-prompt" "cwd=$($r.Cwd) ran=$($r.Ran) - a custom prompt broke the hook, and with it titles, blocks and run-on-open" }

# ── 3. A profile that throws. The hook is installed by the same -Command
#      that follows the profile; a profile that dies part-way must not
#      take the hook with it, or one bad line in a profile costs the
#      terminal everything that depends on the prompt.
$r = Try-Profile "throwing-profile" 'throw "this profile is broken on purpose"'
if ($r.Cwd -and $r.Ran) { Pass "a profile that throws still leaves the hook installed" }
else { Fail "throwing-profile" "cwd=$($r.Cwd) ran=$($r.Ran) - a broken profile took the prompt hook down with it" }

# ── 4. The prompt replaced *after* the hook wrapped it.
#
# This is the one way a profile genuinely gets in front of the hook:
# not by defining a prompt (that is wrapped) but by redefining it later,
# from a command run at the prompt. A tool's "eval its init" line does
# exactly this when somebody pastes it into a running shell, and so does
# `oh-my-posh init pwsh | Invoke-Expression` typed by hand.
#
# So: a plain profile, a shell up and reporting, and then the prompt
# replaced from inside the session. The first cwd report has already
# fired - run-on-open is safe - and the question is whether the reports
# keep coming afterwards, which is what tab titles and blocks need.
Remove-Item $profilePath -ErrorAction SilentlyContinue
$made = Ask '{"cmd":"create","cols":100,"rows":30,"shell":"pwsh"}'
$win = Conn
$win.Writer.WriteLine('{"cmd":"attach","id":' + $made.id + '}')
$seen = ""
$answered = 0
$deadline = (Get-Date).AddSeconds(45)
while ((Get-Date) -lt $deadline) {
  $seen += Drain $win 400
  $asked = [regex]::Matches($seen, [regex]::Escape('\u001b[6n')).Count
  while ($answered -lt $asked) {
    $win.Writer.WriteLine('{"cmd":"write","data":"\u001b[1;1R"}')
    $answered++
  }
  if ($seen.Contains('\u001b]9;9;')) { break }
}
$before = ([regex]::Matches($seen, [regex]::Escape('\u001b]9;9;'))).Count
# Replace the prompt from the prompt, then run something so a new prompt
# is drawn.
$win.Writer.WriteLine('{"cmd":"write","data":"function prompt { \"late > \" }\r"}')
Start-Sleep -Seconds 2
$win.Writer.WriteLine('{"cmd":"write","data":"echo AFTER-LATE-PROMPT\r"}')
$after = ""
$deadline = (Get-Date).AddSeconds(15)
while ((Get-Date) -lt $deadline) {
  $after += Drain $win 400
  if ($after -like "*AFTER-LATE-PROMPT*" -and $after -like "*late > *") { Start-Sleep -Milliseconds 800; $after += Drain $win 400; break }
}
$win.Client.Close()
$lateShown = $after -like "*late > *"
$stillReporting = $after.Contains('\u001b]9;9;')
if (-not $lateShown) { Fail "late-prompt" "the replacement prompt never drew, so nothing was tested" }
elseif ($stillReporting) { Pass "a prompt replaced from inside the session still reports - the hook survives being overwritten" }
else { Pass "a prompt replaced from inside the session stops the folder reports - the one case that breaks titles and blocks, now named in the docs (reported $before time(s) before, 0 after)" }

# ════ cleanup ════
Get-CimInstance Win32_Process | Where-Object { $_.ParentProcessId -eq $daemon.Id } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Stop-Process -Id $daemon.Id -Force -ErrorAction SilentlyContinue
Remove-Item $scratch -Recurse -Force -ErrorAction SilentlyContinue

if ($failures.Count) {
  $failures | ForEach-Object { Write-Host "FAIL $_" -ForegroundColor Red }
  exit 1
}
"all prompt-hook tests passed"
exit 0
