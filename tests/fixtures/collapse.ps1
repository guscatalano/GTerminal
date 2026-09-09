# Replays the "collapse the answered prompt" redraw and then reads the
# screen back, so the result is what is actually on the row rather than
# what the sequence was supposed to do.
#
# The pattern: after reading an answer, move the cursor up one row, blank
# that row by writing exactly BufferWidth spaces, return to column 0 and
# write a shorter summary. Every console picker that tidies up after
# itself does some version of it, and it makes two assumptions about this
# terminal - that the reported width is the rendered width, and that a
# full-width write from column 0 leaves the cursor on the same row.
#
# Reading the buffer back is the point. The escape sequences can be
# perfect and the row still wrong, and a test that only watches the bytes
# go past cannot tell the difference.
param(
  # 0 keeps the prompt inside one row. Anything higher pushes it past the
  # window so it occupies two, which is the application's own bug - one
  # row is erased and the first half stays on screen. Reproduced here to
  # show what it looks like, not asserted on: it fails the same way on
  # every terminal.
  [int] $Overflow = 0
)

$width = [Console]::BufferWidth

function Get-Row {
  param([int] $Row)
  try {
    $rect = New-Object System.Management.Automation.Host.Rectangle 0, $Row, ($width - 1), $Row
    $cells = $Host.UI.RawUI.GetBufferContents($rect)
    $sb = ""
    for ($c = 0; $c -lt $width; $c++) { $sb += $cells[0, $c].Character }
    $sb.TrimEnd()
  } catch {
    "BUFFER-UNAVAILABLE"
  }
}

$prompt = "Select item (default: 1) 2"
if ($Overflow -gt 0) {
  $prompt = "Select item (default: 1) C:\repos\" + ("x" * [Math]::Max(1, $width - 34 + $Overflow))
}

[Console]::WriteLine($prompt)

$rowAfterPrompt = [Console]::CursorTop
$promptRow = $rowAfterPrompt - 1

# The collapse, exactly as the pattern does it.
[Console]::CursorTop = $promptRow
[Console]::CursorLeft = 0
[Console]::Write((" " * $width))
$drift = [Console]::CursorTop - $promptRow
[Console]::CursorLeft = 0
[Console]::WriteLine("Select item 2")

# What the rows actually hold now. The prompt's row should carry the
# summary and nothing else; the row above it should be untouched.
$onPromptRow = Get-Row $promptRow
$aboveRow = if ($promptRow -ge 1) { Get-Row ($promptRow - 1) } else { "" }

[Console]::WriteLine("COLLAPSE-WIDTH=$width")
[Console]::WriteLine("COLLAPSE-PROMPTLEN=$($prompt.Length)")
[Console]::WriteLine("COLLAPSE-DRIFT=$drift")
[Console]::WriteLine("COLLAPSE-ROW=[$onPromptRow]")
[Console]::WriteLine("COLLAPSE-ABOVE=[$aboveRow]")
[Console]::WriteLine("COLLAPSE-DONE")
