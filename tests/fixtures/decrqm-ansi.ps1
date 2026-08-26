# The other half of DECRQM: the ANSI form, with no "?" prefix.
#
# CSI ? <mode> $ p asks about a private mode and is answered by the
# console host itself. CSI <mode> $ p asks about an ANSI mode, and if the
# host passes that one through it reaches the terminal's own handler -
# which is the code a crash was reported in.
#
# What matters is not the answer but whether drawing survives the
# question. A handler that throws takes the parser's chunk with it, and
# everything after the query in that write is lost - which looks exactly
# like a program whose redraws never land.
$esc = [char]27
function AskAnsi {
  param([string]$mode)
  while ([Console]::KeyAvailable) { $null = [Console]::ReadKey($true) }
  [Console]::Out.Write("$esc[$mode`$p")
  [Console]::Out.Flush()
  Start-Sleep -Milliseconds 600
  $got = ""
  while ([Console]::KeyAvailable) { $got += [Console]::ReadKey($true).KeyChar }
  $shown = ($got -replace [regex]::Escape($esc), "<ESC>")
  if ($shown -eq "") { $shown = "<NOTHING>" }
  "ANSI-DECRQM $mode -> $shown"
}

"ANSI-DECRQM-READY"
foreach ($m in @("2", "4", "12", "20")) { AskAnsi $m }

# The real test: a query and a full-screen paint in ONE write. If the
# query's handler throws, the parser abandons the rest of this chunk and
# the paint never appears, while the program believes it drew.
$paint = "$esc[2`$p" + "$esc[?1049h" + "$esc[44m$esc[2J$esc[H"
foreach ($row in 1..24) { $paint += "$esc[$row;1HAFTER-QUERY-ROW-$row" + (" " * 30) }
$paint += "$esc[0m"
[Console]::Out.Write($paint)
[Console]::Out.Flush()
# Held long enough for the caller to photograph it. The first
# version left the alternate screen before the frame was taken,
# and the caller read its own timing as a screen that never drew.
Start-Sleep -Seconds 9
[Console]::Out.Write("$esc[?1049l")
[Console]::Out.Flush()
"ANSI-DECRQM-DONE"
