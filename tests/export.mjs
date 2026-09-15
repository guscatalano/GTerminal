// Getting a transcript out as a file.
// Run: node tests/export.mjs
import { exportFilename, transcriptToHtml, transcriptToText } from "../src/export.ts";

let failed = 0;
function check(name, got, want) {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${ok ? "" : `: got ${JSON.stringify(got)}, wanted ${JSON.stringify(want)}`}`);
  if (!ok) failed++;
}
const E = "\x1b";

// ── text ──────────────────────────────────────────────────────────────
check("colours are stripped", transcriptToText(`${E}[31mred${E}[0m plain`), "red plain");
check("prompt marks are stripped", transcriptToText(`${E}]133;A\x07PS> ${E}]133;B\x07dir`), "PS> dir");
check("the window title is stripped", transcriptToText(`${E}]0;title\x07text`), "text");
check("a mode switch is stripped", transcriptToText(`${E}[?1049hhidden${E}[?1049l`), "hidden");
check("CRLF becomes LF", transcriptToText("a\r\nb"), "a\nb");
// A picture is a device control string and must not end up as a page
// of tildes in a bug report.
check("a sixel is stripped whole", transcriptToText(`before${E}Pq#0~~~~${E}\\after`), "beforeafter");

// ── html ──────────────────────────────────────────────────────────────
const red = transcriptToHtml(`${E}[31mfailed${E}[0m ok`, "t");
check("red text becomes a red span", /<span style="color:#c62828">failed<\/span> ok/.test(red), true);
check("bold is weight, not a tag", /font-weight:600/.test(transcriptToHtml(`${E}[1mb${E}[0m`, "t")), true);
check("a 256-colour index is honoured", /rgb\(/.test(transcriptToHtml(`${E}[38;5;196mx${E}[0m`, "t")), true);
check("and truecolour", /rgb\(10,20,30\)/.test(transcriptToHtml(`${E}[38;2;10;20;30mx${E}[0m`, "t")), true);
// The transcript is whatever a program printed, and a program that
// printed "<script>" must not get to run it in somebody's browser.
check("markup in the output is text, not markup", /&lt;script&gt;/.test(transcriptToHtml("<script>alert(1)</script>", "t")), true);
check("and so is the title", /&lt;b&gt;/.test(transcriptToHtml("x", "<b>")), true);
// A carriage return without a newline is a progress bar or a prompt
// repaint: the result should be the last frame, not all of them.
check("a CR repaint keeps only the last frame", /<pre>done<\/pre>/.test(transcriptToHtml("10%\r50%\rdone", "t")), true);
check("cursor movement is stepped over, not printed", /\[2J|\[H/.test(transcriptToHtml(`${E}[2J${E}[Hclean`, "t")), false);
check("a style that carries across lines stays applied", (transcriptToHtml(`${E}[32ma\nb${E}[0m`, "t").match(/color:#2e7d32/g) || []).length, 2);

// ── the name ──────────────────────────────────────────────────────────
const name = exportFilename(new Date(2026, 8, 15, 9, 5).getTime(), "pwsh", "txt");
check("the file says when and what", name, "gterminal 2026-09-15 0905 pwsh.txt");
check("a shell name is made safe", exportFilename(0, "Windows PowerShell", "html").endsWith(" windows-powershell.html"), true);

if (failed) {
  console.log(`${failed} export test(s) failed`);
  process.exit(1);
}
console.log("all export tests passed");
