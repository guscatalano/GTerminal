// Does a redraw depend on how its bytes were split across reads?
// Run: node tests/chunking.mjs
//
// A tab reads its output in whatever chunks the reads deliver, and those
// boundaries move with timing: a busy tab gets many small writes, a tab
// that sat idle gets one coalesced burst when it wakes. If a redraw
// sequence is mishandled when it arrives split at a particular byte, the
// screen is wrong — and because the split depends on timing, the wrong
// screen looks random and turns up "after the tab was idle for a while".
//
// So the probe writes each sequence into a fresh terminal several times,
// split differently each time (whole, one unit at a time, at every escape,
// at fixed strides, at seeded-random positions), and reads the whole
// buffer back after each. The assertion is total: no splitting may change
// where the terminal ends up. A failure is a real mispaint reproduced
// deterministically, with the row and the two spellings named.
//
// Runs in the engine the app renders in, via tests/edge-render.mjs, so it
// is the real xterm parsing real bytes, not a model of it.
import { execFileSync } from "child_process";
import { existsSync } from "fs";
import { fileURLToPath, pathToFileURL } from "url";
import { dirname, join } from "path";

const here = dirname(fileURLToPath(import.meta.url));
const fixture = join(here, "fixtures", "chunking-probe.html");
const renderScript = join(here, "edge-render.mjs");

const EDGES = [
  "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe",
  "C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe",
];
const edge = process.env.GT_BROWSER || EDGES.find((p) => existsSync(p));
if (!edge) {
  console.log("SKIP chunking: no Edge found — this needs the engine the app renders in");
  process.exit(0);
}

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
  console.log("FAIL chunking: the probe never reported — the page did not run");
  process.exit(1);
}
if (payload[1]) {
  console.log(`FAIL chunking: the probe threw — ${payload[2]}`);
  process.exit(1);
}
const results = JSON.parse(payload[2].replace(/&quot;/g, '"').replace(/&amp;/g, "&"));

check(`the probe ran the sequences (${results.length})`, results.length > 0, "nothing came back");

for (const r of results) {
  check(
    `"${r.name}" draws the same however it is split`,
    r.ok,
    r.ok
      ? ""
      : `split "${r.strategy}" diverged at ${r.field}: whole=${JSON.stringify(r.whole)} split=${JSON.stringify(r.got)} — ` +
        `a redraw that lands differently when its bytes arrive split is a mispaint that shows up under load or after idle`
  );
}

if (failed) {
  console.log(`${failed} chunking test(s) failed`);
  process.exit(1);
}
console.log(`all chunking tests passed (${results.length} sequences × 8 splittings)`);
