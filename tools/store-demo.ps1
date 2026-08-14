# Colorful demo output for store screenshots.
"`e[1m  GTerminal`e[0m `e[90m— every theme, full ANSI`e[0m"
""
$row1 = ""; foreach ($c in 40..47) { $row1 += "`e[${c}m    `e[0m" }
$row2 = ""; foreach ($c in 100..107) { $row2 += "`e[${c}m    `e[0m" }
"  $row1"
"  $row2"
""
$grad = "  "
for ($i = 0; $i -lt 64; $i++) {
  $r = [int](255 * $i / 63); $b = 255 - $r; $g2 = [int](120 + 80 * [math]::Sin($i / 8.0))
  $grad += "`e[48;2;$r;$g2;${b}m `e[0m"
}
$grad
""
"  `e[1mbold`e[0m  `e[3mitalic`e[0m  `e[4munderline`e[0m  `e[9mstrike`e[0m  `e[7m reverse `e[0m"
""
"  `e[32m√ daemon`e[0m       sessions survive reboots"
"  `e[32m√ history`e[0m      every transcript kept searchable"
"  `e[32m√ predictor`e[0m    autocomplete from your own habits"
"  `e[33m~ 25 themes`e[0m    generated art, contrast audited"
