# A program that asks the terminal what it is.
#
# Ordinary behaviour: plenty of programs ask, and a terminal answers. The
# answer is only a problem later, when the recording of the question is
# replayed into a terminal attached to a shell sitting at its prompt - the
# answer then arrives as though someone had typed it.
#
# CSI c is the question. The answer is "?1;2c", which is what turned up in
# the report.
$esc = [char]27
"ASKS-FIXTURE-READY"
[Console]::Out.Write("$esc[c")
[Console]::Out.Flush()
Start-Sleep -Milliseconds 700
[Console]::Out.Write("$esc[c")
[Console]::Out.Flush()
Start-Sleep -Milliseconds 700
"ASKS-FIXTURE-DONE"
