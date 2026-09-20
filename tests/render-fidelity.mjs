// Does the renderer draw what the buffer holds after a partial redraw?
// Run: node tests/render-fidelity.mjs
//
// The other half of the mispaint bisection. chunking.mjs proves the bytes
// reach the buffer correctly however they are split; this proves that what
// is drawn matches the buffer, row by row, after the partial repaints a
// TUI does every frame. A drawn row that differs from its buffer row is a
// stale cell — a leftover from a previous frame the renderer thought it
// could skip — which is exactly the "random mispaint" shape.
//
// It drives the DOM renderer, the one whose rows can be read back without
// a screenshot. The WebGL renderer's pixels are the visual scenes' job;
// the stale-cell family looks the same in both, and this pins it wherever
// it is deterministic to pin.
import { execFileSync } from "child_process";
import { existsSync } from "fs";
import { fileURLToPath, pathToFileURL } from "url";
import { dirname, join } from "path";

const here = dirname(fileURLToPath(import.meta.url));
const fixture = join(here, "fixtures", "render-fidelity-probe.html");
const renderScript = join(here, "edge-render.mjs");

const EDGES = [
  "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe",
  "C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe",
];
const edge = process.env.GT_BROWSER || EDGES.find((p) => existsSync(p));
if (!edge) {
  console.log("SKIP render-fidelity: no Edge found — this needs the engine the app renders in");
  process.exit(0);
}

let failed = 0;
function check(name, ok, detail = "") {
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${ok ? "" : `: ${detail}`}`);
  if (!ok) failed++;
}

// Real time, not virtual: the DOM renderer paints on animation frames, and
// the probe waits two of them after each write. rt mode lets those fire.
const dom = execFileSync(
  process.execPath,
  [renderScript, edge, pathToFileURL(fixture).href, "12000", "rt"],
  { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 180_000 }
);

const payload = dom.match(/RESULTS(-ERROR)? ([^<]*)/);
if (!payload) {
  console.log("FAIL render-fidelity: the probe never reported — the page did not run");
  process.exit(1);
}
if (payload[1]) {
  console.log(`FAIL render-fidelity: the probe threw — ${payload[2]}`);
  process.exit(1);
}
const results = JSON.parse(payload[2].replace(/&quot;/g, '"').replace(/&amp;/g, "&"));

check(`the probe ran the frames (${results.length})`, results.length > 0, "nothing came back");

for (const r of results) {
  check(
    `"${r.name}" — the renderer shows what the buffer holds`,
    r.ok,
    r.ok
      ? ""
      : `${r.field}: buffer=${JSON.stringify(r.buffer)} drawn=${JSON.stringify(r.drawn)} — ` +
        `a drawn row that differs from the buffer is a stale cell, the render-side mispaint`
  );
}

if (failed) {
  console.log(`${failed} render-fidelity test(s) failed`);
  process.exit(1);
}
console.log(`all render-fidelity tests passed (${results.length} frames)`);
