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

# Ask for VT input first, or the rest of this is written into a void.
#
# Measured, not assumed: writing ESC[?1000h from here and reading what
# the terminal received showed only the cursor show/hide pair - conhost
# parses what a console program writes and re-emits its own stream, and
# it does not pass a mouse-mode request on behalf of a program that has
# not asked for virtual-terminal input. A real TUI sets this when it
# puts the console in raw mode, which is why one of those gets the
# mouse and this fixture did not.
$vt = @"
using System;
using System.Runtime.InteropServices;
public static class ConIn {
  [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr GetStdHandle(int n);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetConsoleMode(IntPtr h, out uint m);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool SetConsoleMode(IntPtr h, uint m);
}
"@
if (-not ("ConIn" -as [type])) { Add-Type -TypeDefinition $vt }
$stdin = [ConIn]::GetStdHandle(-10)
$mode = 0
$hadMode = [ConIn]::GetConsoleMode($stdin, [ref]$mode)
if ($hadMode) {
  # ENABLE_VIRTUAL_TERMINAL_INPUT, without ENABLE_LINE_INPUT and
  # ENABLE_ECHO_INPUT: raw, which is the state a TUI runs in.
  [void][ConIn]::SetConsoleMode($stdin, ($mode -bor 0x0200) -band (-bnot 0x0006))
}

$e = [char]27
[Console]::Write("$e[?1000h$e[?1006h")
try {
  # Several identical lines, not one. A drag has to land on text, and
  # the top of the pane is where a stray tooltip or flyout from
  # somewhere else on the desktop tends to sit - a test that can only
  # aim at one row has to aim at that one.
  # Instructions first, then a block of identical selectable lines. A
  # test drags at a fixed height and has to land on the marked text; with
  # the sentences underneath, it landed on "Hold Shift and drag..." and
  # reported that the wrong thing had been copied.
  [Console]::WriteLine("Drag across the lines below: nothing is selected, the press goes to this script.")
  [Console]::WriteLine("Hold Shift and drag: the terminal takes it back, and Ctrl+Shift+C copies.")
  foreach ($i in 1..12) {
    [Console]::WriteLine("SELECT-ME-IF-YOU-CAN line $i")
  }
  [Console]::WriteLine("MOUSEGRAB-READY")
  if ($Seconds -gt 0) {
    # Just wait. Counting what arrives was tried and is a fixture
    # problem rather than a terminal one: a console app on Windows is
    # handed mouse input as console records, not as bytes on stdin,
    # unless it is in raw VT input mode - and reading that from
    # PowerShell answered zero while the terminal was demonstrably
    # sending reports. The scene checks what the window sent instead,
    # which it logs in hex for every byte that goes to the shell.
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
  if ($hadMode) { [void][ConIn]::SetConsoleMode($stdin, $mode) }
  [Console]::WriteLine("MOUSEGRAB-DONE")
}
