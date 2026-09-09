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

const EDGES = [
  "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe",
  "C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe",
];
const edge = EDGES.find((p) => existsSync(p));
if (!edge) {
  console.log("SKIP redraw: no Edge found — this needs the engine the app renders in");
  process.exit(0);
}

let failed = 0;
function check(name, ok, detail = "") {
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${ok ? "" : `: ${detail}`}`);
  if (!ok) failed++;
}

const dom = execFileSync(
  edge,
  [
    "--headless=new",
    "--no-sandbox",
    // ES modules over file:// are a cross-origin load to Chromium.
    "--allow-file-access-from-files",
    "--virtual-time-budget=15000",
    "--dump-dom",
    pathToFileURL(fixture).href,
  ],
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

for (const name of results.keys()) {
  if (!(name in EXPECTED)) check(`${name} is asserted on`, false, "the probe runs it but nothing checks it");
}

if (failed) {
  console.log(`${failed} redraw test(s) failed`);
  process.exit(1);
}
console.log(`all redraw tests passed (${results.size} sequences)`);
