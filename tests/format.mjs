// Status bar and preview formatting. Run: node tests/format.mjs
//
// These are the numbers on screen every second. A unit that flips, a
// decimal that jitters, or a width that grows and shrinks makes the
// whole bar restless — which is the sort of thing that is never reported
// as a bug and quietly makes an app feel cheap.
import { fmtBytes, fmtRate, fmtDuration, pct, fmtSize, clipPreview } from "../src/format.ts";

let failed = 0;
function check(name, got, want) {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${ok ? "" : `: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`}`);
  if (!ok) failed++;
}

// ── bytes ──────────────────────────────────────────────────────────────
check("zero", fmtBytes(0), "0B");
check("bytes stay whole", fmtBytes(512), "512B");
check("bytes never take a decimal", fmtBytes(999), "999B");
check("the boundary rolls over", fmtBytes(1024), "1.0K");
check("just under stays in bytes", fmtBytes(1023), "1023B");
check("a decimal below 100", fmtBytes(1536), "1.5K");
// Past three digits the decimal is dropped, so the field stops widening
// as the value climbs — a bar that changes width is a bar that twitches.
check("no decimal at 100 and up", fmtBytes(102400), "100K");
check("megabytes", fmtBytes(1048576), "1.0M");
check("gigabytes", fmtBytes(1073741824), "1.0G");
check("terabytes", fmtBytes(1099511627776), "1.0T");
// Nothing bigger than T: a petabyte reads as four digits of T rather
// than an empty unit.
check("beyond the table it keeps counting in T", fmtBytes(1125899906842624), "1024T");
check("negatives are not a thing here", fmtBytes(-5), "0B");
check("NaN does not leak to the screen", fmtBytes(NaN), "0B");
check("infinity does not either", fmtBytes(Infinity), "0B");
check("a rate is bytes per second", fmtRate(2048), "2.0K/s");
check("an idle rate", fmtRate(0), "0B/s");

// ── durations ──────────────────────────────────────────────────────────
check("under an hour is minutes", fmtDuration(300), "5m");
check("zero is still minutes", fmtDuration(0), "0m");
// Seconds are deliberately absent: a status bar that repaints every
// second to advance a number nobody reads is just noise.
check("seconds are not shown", fmtDuration(59), "0m");
check("an hour brings hours and minutes", fmtDuration(3661), "1h 1m");
check("a day brings days and hours", fmtDuration(90061), "1d 1h");
check("exactly a day", fmtDuration(86400), "1d 0h");
check("a long uptime", fmtDuration(864000), "10d 0h");

// ── percentages ────────────────────────────────────────────────────────
check("rounds to whole", pct(12.4), "12%");
check("rounds up", pct(12.5), "13%");
check("zero", pct(0), "0%");
check("full", pct(100), "100%");

// ── transcript sizes ───────────────────────────────────────────────────
check("megabytes get a decimal", fmtSize(1572864), "1.5 MB");
check("below a megabyte is KB", fmtSize(4096), "4 KB");
// A file that exists must never read as 0 KB — that says "nothing here"
// about a transcript that has content.
check("a tiny file is not zero", fmtSize(1), "1 KB");
check("an empty file is still not zero", fmtSize(0), "1 KB");
check("the boundary", fmtSize(1048576), "1.0 MB");

// ── clipboard previews ─────────────────────────────────────────────────
check("short text is untouched", clipPreview("git status"), "git status");
// The newline mark matters: "a b" and "a\nb" paste very differently, and
// this menu is where you choose between them.
check("newlines are shown, not swallowed", clipPreview("a\nb"), "a ⏎ b");
check("CRLF too", clipPreview("a\r\nb"), "a ⏎ b");
check("tabs become spaces", clipPreview("a\tb"), "a b");
check("surrounding space is trimmed", clipPreview("  git status  "), "git status");
{
  const long = clipPreview("x".repeat(100));
  check("long text is cut", long.length, 46);
  check("and marked as cut", long.endsWith("…"), true);
}
check("exactly at the limit is not cut", clipPreview("y".repeat(46)), "y".repeat(46));
check("one over is cut", clipPreview("y".repeat(47)).endsWith("…"), true);
check("empty stays empty", clipPreview(""), "");
check("whitespace only collapses to nothing", clipPreview("\n\t  "), "⏎");

if (failed) {
  console.log(`${failed} format test(s) failed`);
  process.exit(1);
}
console.log("all format tests passed");
