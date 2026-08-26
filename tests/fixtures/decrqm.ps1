# What does this terminal answer when a program asks about a mode?
#
# DECRQM - CSI ? <mode> $ p - is how a program decides whether to use a
# feature. A wrong answer is worse than no answer: told yes, a program
# commits to something the terminal will not honour, and its frames can
# stop appearing while everything else looks fine.
#
# The interesting one is 2026, synchronized output. xterm.js implements it
# and answers "supported", and it pauses ALL drawing on ?2026h until
# ?2026l or a one-second timeout. If the open reaches the terminal and the
# close does not, every frame costs a second and the screen looks stuck.
#
# Replies are printed back into the output stream so they land in the
# transcript, since the reply itself travels the other way and is not
# recorded anywhere else.
$esc = [char]27
function Ask {
  param([string]$mode, [string]$label)
  while ([Console]::KeyAvailable) { $null = [Console]::ReadKey($true) }   # clear
  [Console]::Out.Write("$esc[?$mode`$p")
  [Console]::Out.Flush()
  Start-Sleep -Milliseconds 700
  $got = ""
  while ([Console]::KeyAvailable) { $got += [Console]::ReadKey($true).KeyChar }
  $shown = ($got -replace [regex]::Escape($esc), "<ESC>")
  if ($shown -eq "") { $shown = "<NOTHING>" }
  "DECRQM $label ($mode) -> $shown"
}

"DECRQM-FIXTURE-READY"
Ask "2026" "synchronized-output"
Ask "1049" "alternate-screen"
Ask "25"   "cursor-visible"
Ask "2004" "bracketed-paste"
Ask "9999" "nonsense-mode"
"DECRQM-FIXTURE-DONE"
