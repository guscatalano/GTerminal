// The UI event log's shape and its redaction.
// Run: node tests/uilog.mjs
import { formatEvent, describeText, logLevel, shouldLog } from "../src/uilog.ts";

let failed = 0;
function check(name, got, want) {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${ok ? "" : `: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`}`);
  if (!ok) failed++;
}

// One JSON object per line: greppable, and parseable when there is a lot
// of it. The timestamp comes first so sorting a file sorts it by time.
{
  const line = formatEvent({ ev: "menu.open", at: "terminal", items: 7 }, "2026-08-24T13:00:00.000Z");
  check("one line of JSON", line.includes("\n"), false);
  const back = JSON.parse(line);
  check("timestamp first", Object.keys(back)[0], "t");
  check("then the event name", Object.keys(back)[1], "ev");
  check("fields survive", [back.at, back.items], ["terminal", 7]);
}

// The whole point of the redaction: sizes, never contents.
check("text becomes a size", describeText("hello"), { chars: 5, lines: 1 });
check("and a line count", describeText("a\nb\nc"), { chars: 5, lines: 3 });
check("CRLF counts once per line", describeText("a\r\nb"), { chars: 4, lines: 2 });
check("empty text has no lines", describeText(""), { chars: 0, lines: 0 });
// A password on the clipboard must not be reconstructable from the log,
// so nothing about the characters themselves is recorded.
{
  const line = formatEvent({ ev: "paste", source: "menu", ...describeText("hunter2") }, "t");
  check("the text itself never appears", line.includes("hunter2"), false);
  check("but its size does", JSON.parse(line).chars, 7);
}

// ── what gets recorded at which level ──────────────────────────────────
// Errors by default: an exception says nothing about what was typed or
// copied, and is the most useful line in the file.
check("errors are recorded by default", shouldLog("error", logLevel(undefined)), true);
check("and so are rejected promises", shouldLog("error.promise", logLevel(undefined)), true);
check("but menus are not", shouldLog("menu.open", logLevel(undefined)), false);
check("nor pastes", shouldLog("paste", logLevel(undefined)), false);
// Asked for everything, everything is recorded.
check("full records a paste", shouldLog("paste", logLevel("full")), true);
check("full records an error too", shouldLog("error", logLevel("full")), true);
// Off means off, including errors: someone who turned it off meant it.
check("off records nothing", shouldLog("error", logLevel("off")), false);
check("off really means nothing", shouldLog("menu.open", logLevel("off")), false);
// The setting used to be a boolean, and configs written then still exist.
check("the old true means full", logLevel(true), "full");
check("the old false means off", logLevel(false), "off");
check("anything unrecognised falls back to errors", logLevel("nonsense"), "errors");
// A name that merely starts with the word must not sneak through.
check("errorless is not an error", shouldLog("errorless.thing", logLevel(undefined)), false);

if (failed) {
  console.log(`${failed} uilog test(s) failed`);
  process.exit(1);
}
console.log("all uilog tests passed");
