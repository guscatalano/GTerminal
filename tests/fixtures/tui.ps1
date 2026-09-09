# A stand-in for the programs this is actually about: Claude Code,
# Agency, Hermes, vim, lazygit. What they have in common is not their
# purpose but their drawing — the alternate screen, and whole-viewport
# repaints addressed by cursor position rather than by scrolling.
#
# Each frame fills every row edge to edge in one colour, so "did the
# screen redraw" becomes a question about pixels that a screenshot can
# answer. It also scrolls a region, hides and restores the cursor, and
# leaves the region reset - the modes a real program sets and that a
# terminal has to put back, since one left set is how a window ends up
# scrolling only part of itself.
#
# A real TUI would be a better test and is not available: nothing
# full-screen ships with Windows, so it would have to be installed, and
# its output would then depend on its own state rather than on ours.
param(
  [int]$Frames = 3,
  [int]$Ms = 2500,
  # Draw like a program that is about to be killed.
  #
  # The normal path resets its scrolling region and shows the cursor again
  # on every frame, and leaves the alternate screen in a finally - which is
  # what a program that exits does. A program that is killed does none of
  # it, and everything it switched on is sitting in the scrollback ring to
  # be replayed into a fresh terminal when the session is restored. That is
  # the state a reboot leaves, and there was no way to produce it here.
  [switch]$Sloppy
)
$e = [char]27
$w = [Math]::Max(20, $Host.UI.RawUI.WindowSize.Width)
$h = [Math]::Max(5, $Host.UI.RawUI.WindowSize.Height)
Write-Host -NoNewline "$e[?1049h"      # alternate screen, like every TUI
if ($Sloppy) {
  # Set the modes and never put them back. No finally either: this is a
  # program that gets killed, not one that ends.
  $mid = [Math]::Max(3, [int]($h / 2))
  Write-Host -NoNewline "$e[?25l"          # cursor hidden while drawing
  Write-Host -NoNewline "$e[?7l"           # autowrap off, to draw the last column
  Write-Host -NoNewline "$e[2;${mid}r"     # a scrolling region, and it stays
  foreach ($i in 1..$Frames) {
    $bg = if ($i % 2) { "$e[41m" } else { "$e[44m" }
    $ch = if ($i % 2) { '#' } else { '=' }
    $line = $bg + ($ch * ($w - 1)) + "$e[0m"
    $frame = ""
    foreach ($row in 1..$h) { $frame += "$e[$row;1H" + $line }
    $frame += "$e[1;1HSLOPPY-FRAME-$i"
    Write-Host -NoNewline $frame
    Start-Sleep -Milliseconds $Ms
  }
  return
}
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
    # What the flat fills leave out. A real full-screen program keeps a
    # scrolling region and writes inside it, hides the cursor while it
    # draws, and puts it back somewhere deliberate - and each of those is
    # a mode that can be left set, which is how a terminal ends up
    # scrolling only part of itself long after the program has gone.
    $mid = [Math]::Max(3, [int]($h / 2))
    Write-Host -NoNewline "$e[?25l"          # cursor away while drawing
    Write-Host -NoNewline "$e[2;${mid}r"     # scrolling region
    foreach ($line in 1..4) {
      Write-Host -NoNewline "$e[${mid};1Hscrolled line $line of frame $i$e[K`n"
    }
    Write-Host -NoNewline "$e[r"             # region back to the full screen
    Write-Host -NoNewline "$e[$h;1H$e[?25h"  # cursor back, and visible
    Start-Sleep -Milliseconds $Ms
  }
} finally {
  Write-Host -NoNewline "$e[?1049l"    # back to the shell's screen
}
