# The two ways a PowerShell script paints the terminal and leaves it that
# way, and the reading that shows it happened.
#
# Reported from real use as "a script seemed to paint the entire terminal
# blue", with `color` needed to get out. Both routes below produce that,
# and they are not the same thing underneath:
#
#   sgr   the script writes ESC[44m and never writes ESC[0m. Everything
#         after it carries that background, including the prompt, because
#         SGR is state. An erase while it is set fills with it.
#   host  the script assigns $Host.UI.RawUI.BackgroundColor, which changes
#         the console's default attribute rather than the current one -
#         so it survives a reset that would have cleared the first kind.
#         This is the one `color` exists for.
#
# The script then reads its own console buffer back, because the question
# is not what it wrote but what the screen now holds.
param(
  [ValidateSet("sgr", "host", "reset")]
  [string] $Mode = "sgr"
)

$e = [char]27
$width = [Console]::BufferWidth

function Row-Background {
  param([int] $Row)
  try {
    $rect = New-Object System.Management.Automation.Host.Rectangle 0, $Row, ($width - 1), $Row
    $cells = $Host.UI.RawUI.GetBufferContents($rect)
    "$($cells[0, 2].BackgroundColor)"
  } catch {
    "UNAVAILABLE"
  }
}

switch ($Mode) {
  "sgr" {
    # Console::Write, not Write-Host. Write-Host emits its own colour
    # sequences around whatever it prints and resets afterwards, so it
    # quietly undoes the very thing this is meant to leave behind - the
    # first version of this fixture measured Black and looked like proof
    # that the reported fault could not happen.
    [Console]::Write("$e[44m")
    [Console]::WriteLine("painted by an SGR background nobody reset")
  }
  "host" {
    $Host.UI.RawUI.BackgroundColor = "DarkBlue"
    Clear-Host
    [Console]::WriteLine("painted by the host's background colour")
  }
  "reset" {
    [Console]::Write("$e[0m")
    [Console]::ResetColor()
    [Console]::WriteLine("put back")
  }
}

# The row just written is the one to look at: whatever background was in
# force when it was drawn is the background it kept.
$row = [Math]::Max(0, [Console]::CursorTop - 1)
[Console]::WriteLine("PAINT-MODE=$Mode")
[Console]::WriteLine("PAINT-BG=[$(Row-Background $row)]")
[Console]::WriteLine("PAINT-DONE")
