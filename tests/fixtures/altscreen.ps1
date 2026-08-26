# The three ways a program can ask for the alternate screen.
#
# Everything this project tests uses ?1049h, because vim, copilot and the
# fixture all do. The older spellings are still in the wild - ?47h is what
# a program written against plain xterm uses, ?1047h is the one that keeps
# the cursor separately - and a terminal that handles one but not another
# looks exactly like the report that prompted this: the program runs, the
# screen never becomes the program's.
#
# Each variant fills the screen with a different colour and writes a
# marker, then leaves. What the caller checks is that the screen changed
# for each one, and changed back afterwards.
$esc = [char]27
function Emit { param($s) [Console]::Out.Write($s); [Console]::Out.Flush() }

$variants = @(
  @{ Enter = "?47h";   Leave = "?47l";   Colour = "41"; Name = "47" }
  @{ Enter = "?1047h"; Leave = "?1047l"; Colour = "42"; Name = "1047" }
  @{ Enter = "?1049h"; Leave = "?1049l"; Colour = "44"; Name = "1049" }
)
Emit "$esc[2J$esc[H"
Emit "ALTSCREEN-FIXTURE-READY`r`n"
Start-Sleep -Milliseconds 800

foreach ($v in $variants) {
  Emit "$esc[$($v.Enter)"
  # Paint the whole screen, the way a full-screen program does.
  Emit "$esc[$($v.Colour)m$esc[2J$esc[H"
  foreach ($row in 1..24) {
    Emit "$esc[$row;1HALT-$($v.Name)-ROW-$row" + (" " * 40)
  }
  Emit "$esc[0m"
  Start-Sleep -Milliseconds 2500
  Emit "$esc[$($v.Leave)"
  Emit "`r`nLEFT-$($v.Name)`r`n"
  Start-Sleep -Milliseconds 1500
}
Emit "ALTSCREEN-FIXTURE-DONE`r`n"
Start-Sleep -Milliseconds 800
