# A program that draws a picture.
#
# Sixel, which is how every terminal that can show an image has been
# told to show one since 1987: a DCS string of colour definitions and
# six-pixel-tall column runs. Written by hand rather than produced by a
# library so that what reaches the terminal is exactly what is written
# here, and a failure is about the terminal rather than about an encoder.
#
# Four bands of flat colour, wide enough to be unmistakable in a
# screenshot and small enough to decode in a blink.
param(
  # Pixels across. Each band is six pixels tall - that is what "sixel"
  # means - so the whole picture is four times six.
  [int] $Width = 240
)

$e = [char]27
$ST = "$e\"

# Colour registers, in sixel's own units: percentages, not bytes.
$colours = @(
  "#0;2;90;20;20",   # red
  "#1;2;20;80;35",   # green
  "#2;2;20;40;90",   # blue
  "#3;2;90;75;20"    # amber
)

$sb = New-Object System.Text.StringBuilder
[void]$sb.Append("${e}Pq")
foreach ($c in $colours) { [void]$sb.Append($c) }

for ($band = 0; $band -lt 4; $band++) {
  # Select the colour, then run of "~" - every one of the six pixels in
  # the column set - repeated across the width. "!" is sixel's repeat
  # introducer, which keeps this a hundred bytes rather than a thousand.
  [void]$sb.Append("#$band")
  [void]$sb.Append("!$Width~")
  # "-" ends the band and moves down six pixels. The last one is left
  # off: a trailing newline inside the picture adds a blank band.
  if ($band -lt 3) { [void]$sb.Append("-") }
}
[void]$sb.Append($ST)

[Console]::WriteLine("SIXEL-BEFORE")
[Console]::Write($sb.ToString())
[Console]::WriteLine()
[Console]::WriteLine("SIXEL-AFTER")
