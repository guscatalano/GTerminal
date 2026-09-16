// What this terminal does with the sequences a redrawing program uses.
// Run: node tests/redraw.mjs
//
// Command-line programs that redraw the screen - pickers collapsing an
// answered prompt, progress bars, vim, lazygit, agent TUIs - are all
// built from a small set of primitives: erase a line, erase the screen,
// address the cursor, insert or delete a row, hold a scrolling region,
// wrap or refuse to wrap. Everything those programs do on screen is those
// pieces, several hundred times a second.
//
// The suites that already exist watch the bytes go past: typing.ps1
// proves a sequence survives the daemon, and the visual scenes prove the
// picture changed. Neither can say what the sequence *did*. A terminal
// that relays ESC[2K perfectly and then ignores it passes both.
//
// So this writes each primitive into a terminal built the way main.ts
// builds one, and reads the buffer back as text. The rows that end up on
// screen are the assertion.
import { execFileSync } from "child_process";
import { existsSync } from "fs";
import { fileURLToPath, pathToFileURL } from "url";
import { dirname, join } from "path";

const here = dirname(fileURLToPath(import.meta.url));
const fixture = join(here, "fixtures", "redraw-probe.html");
const renderScript = join(here, "edge-render.mjs");

const EDGES = [
  "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe",
  "C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe",
];
const edge = process.env.GT_BROWSER || EDGES.find((p) => existsSync(p));
if (!edge) {
  console.log("SKIP redraw: no Edge found — this needs the engine the app renders in");
  process.exit(0);
}

// A directory per launch, not per suite. Two of these suites start
// Edge twice, and the second found the first's profile still locked -
// which is why naming it after the fixture and the pid fixed nothing.
let launches = 0;

let failed = 0;
function check(name, ok, detail = "") {
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${ok ? "" : `: ${detail}`}`);
  if (!ok) failed++;
}

const dom = execFileSync(
  process.execPath,
  [renderScript, edge, pathToFileURL(fixture).href, "15000"],
  { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 180_000 }
);

const payload = dom.match(/RESULTS(-ERROR)? ([^<]*)/);
if (!payload) {
  console.log("FAIL redraw: the probe never reported — the page did not run");
  process.exit(1);
}
if (payload[1]) {
  console.log(`FAIL redraw: the probe threw — ${payload[2]}`);
  process.exit(1);
}
const results = new Map(
  JSON.parse(payload[2].replace(/&quot;/g, '"').replace(/&amp;/g, "&")).map((r) => [r.name, r])
);

// What has to be on screen after each one. Written out rather than
// computed, so a change in behaviour has to be argued with rather than
// absorbed.
const EXPECTED = {
  "erase to end of line": ["ABCD"],
  "erase whole line": [],
  "erase to start of line": ["     FGH"],
  "clear screen and home": [],
  "erase below the cursor": ["AAA"],
  "cursor addressing places text": ["", "", "    X"],
  "column addressing": ["ABZDEFGH"],
  "insert a line": ["A", "", "B", "C"],
  "delete a line": ["A", "C"],
  "insert characters": ["A  BCD"],
  "delete characters": ["AD"],
  "a scroll region leaves the header alone": ["HEADER", "L2", "L3", "L4"],
  // The ZZ stays: restoring the cursor puts the writing position back,
  // it does not undo what was drawn while the cursor was away. CD landing
  // right after AB is the part under test.
  "save and restore the cursor": ["ABCD", "", "", "", "         ZZ"],
  "deferred wrap holds the row": ["x".repeat(40), "Z"],
  "autowrap off truncates": ["y".repeat(39) + "y"],
  "synchronised output still draws": ["FRAME-A", "ROW-TWO"],
  "wide characters advance two cells": ["日本 X"],
  "attributes reset": ["RED PLAIN"],
  // ESC[1J clears from the top through the cursor: row one gone, row two
  // gone up to the parked cursor, and row three left standing.
  "erase above the cursor": ["", "", "CCC"],
  // After ESC[?1049l only the main screen is left, and it holds what it
  // held before - none of the program's GARBAGE survives the restore.
  "the main screen returns after the alternate screen is left": ["MAIN"],
  // The band (rows three to five) scrolled to its last three lines while
  // the header on row one and the footer on row eight never moved.
  "a scroll region keeps a footer below it": ["HEAD", "", "CC", "DD", "EE", "", "", "FOOT"],
  // rowsOf reads from the top of the buffer, scrollback included, so these
  // two show the difference 3J makes directly: with the scrollback intact
  // the oldest lines are still held above the viewport (line0..line7), and
  // after 3J they are gone and only the eight on screen remain. The
  // buffer-length check below is what pins that, since the viewport itself
  // reads line12..line19 either way.
  "lines fill the scrollback": ["line0", "line1", "line2", "line3", "line4", "line5", "line6", "line7"],
  "erase scrollback with 3J": ["line12", "line13", "line14", "line15", "line16", "line17", "line18", "line19"],
};

for (const [name, want] of Object.entries(EXPECTED)) {
  const got = results.get(name);
  if (!got) {
    check(name, false, "the probe did not run this case");
    continue;
  }
  const same = JSON.stringify(got.rows) === JSON.stringify(want);
  check(
    name,
    same,
    `screen is ${JSON.stringify(got.rows)}, expected ${JSON.stringify(want)}`
  );
}

// The one that is a cursor position rather than a picture: a full-width
// write must leave the cursor pending on the last column, not on the next
// row. Every in-place redraw that blanks a line by writing its width
// depends on it.
const wrap = results.get("deferred wrap holds the row");
if (wrap) {
  check(
    "a full-width write leaves the cursor on the next row only after one more character",
    wrap.cursorY === 1,
    `cursor ended on row ${wrap.cursorY}`
  );
}

// ESC[3J erases the scrollback. The visible rows are identical with it and
// without it, so the assertion is on the buffer: how many lines the
// terminal is still holding, and how far the viewport sits below the top of
// them. The "lines fill" case is the control - it proves twenty lines really
// did push twelve into the scrollback, so that "length 8, baseY 0" after 3J
// means the scrollback was emptied rather than never having been there. A
// terminal that ignored 3J leaves both at their filled values, and the old
// screens stay scrollable above what looked like a clear.
const fill = results.get("lines fill the scrollback");
const cleared = results.get("erase scrollback with 3J");
if (fill && cleared) {
  check(
    "twenty lines built a scrollback to clear",
    fill.length > 8 && fill.baseY > 0,
    `filled buffer holds only ${fill.length} lines at baseY ${fill.baseY} - nothing scrolled off, so the 3J case proves nothing`
  );
  check(
    "ESC[3J empties the scrollback",
    cleared.length === 8 && cleared.baseY === 0,
    `after 3J the buffer still holds ${cleared.length} lines at baseY ${cleared.baseY}, so the earlier screens are still scrollable above the clear`
  );
}

for (const name of results.keys()) {
  if (!(name in EXPECTED)) check(`${name} is asserted on`, false, "the probe runs it but nothing checks it");
}

if (failed) {
  console.log(`${failed} redraw test(s) failed`);
  process.exit(1);
}
console.log(`all redraw tests passed (${results.size} sequences)`);
