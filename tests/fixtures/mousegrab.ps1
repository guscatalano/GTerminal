# A program that takes the mouse, the way every full-screen one does.
#
# Not a TUI - it draws nothing and stays on the normal screen - because
# the thing under test is the mouse, and mixing in the alternate screen
# would make a failure ambiguous between the two. It asks for mouse
# reporting (DECSET 1000 for presses, 1006 for the extended encoding a
# terminal wider than 95 columns needs), prints something worth
# selecting, and waits.
#
# While it runs, a plain drag belongs to this script and selects
# nothing; a drag with Shift belongs to the terminal. That is the
# behaviour tests/mouse.mjs asserts headlessly and the hint in the window
# explains, and this is how either can be tried by hand.
param(
  # Hold the mouse until a key is pressed (the default), or for this many
  # seconds. A test driving this needs it to end by itself.
  [int] $Seconds = 0
)

$e = [char]27
[Console]::Write("$e[?1000h$e[?1006h")
try {
  [Console]::WriteLine("SELECT-ME-IF-YOU-CAN — this script is reading the mouse.")
  [Console]::WriteLine("Drag across the line above: nothing is selected, the press goes here.")
  [Console]::WriteLine("Hold Shift and drag: the terminal takes it back, and Ctrl+Shift+C copies.")
  [Console]::WriteLine("MOUSEGRAB-READY")
  if ($Seconds -gt 0) {
    Start-Sleep -Seconds $Seconds
  } else {
    [Console]::WriteLine("Press any key to give the mouse back.")
    [void]$Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
  }
} finally {
  # Always. A mouse mode left set is a terminal that keeps eating drags
  # after the program that wanted them has gone - which is the failure
  # the last case in tests/mouse.mjs exists to catch.
  [Console]::Write("$e[?1000l$e[?1006l")
  [Console]::WriteLine("MOUSEGRAB-DONE")
}
