# A stand-in for the programs this is actually about: Claude Code,
# Agency, Hermes, vim, lazygit. What they have in common is not their
# purpose but their drawing — the alternate screen, and whole-viewport
# repaints addressed by cursor position rather than by scrolling.
#
# Each frame fills every row edge to edge in one colour, so "did the
# screen redraw" becomes a question about pixels that a screenshot can
# answer. A real TUI would be a worse test: harder to install, slower,
# and its output would depend on its own state rather than on ours.
param([int]$Frames = 3, [int]$Ms = 2500)
$e = [char]27
$w = [Math]::Max(20, $Host.UI.RawUI.WindowSize.Width)
$h = [Math]::Max(5, $Host.UI.RawUI.WindowSize.Height)
Write-Host -NoNewline "$e[?1049h"      # alternate screen, like every TUI
try {
  foreach ($i in 1..$Frames) {
    # Alternating fills: a redraw that does not reach the screen leaves
    # the previous colour there, which is exactly the reported fault.
    $bg = if ($i % 2) { "$e[41m" } else { "$e[44m" }
    $ch = if ($i % 2) { '#' } else { '=' }
    $line = $bg + ($ch * ($w - 1)) + "$e[0m"
    $frame = ""
    foreach ($row in 1..$h) { $frame += "$e[$row;1H" + $line }
    # A marker the daemon-level tests can count, off-screen at the end.
    $frame += "$e[1;1HFRAME-$i"
    Write-Host -NoNewline $frame
    Start-Sleep -Milliseconds $Ms
  }
} finally {
  Write-Host -NoNewline "$e[?1049l"    # back to the shell's screen
}
