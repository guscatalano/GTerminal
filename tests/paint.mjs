// Does a repaint actually reach the screen?
// Run: node tests/paint.mjs
//
// This is the layer everything else stops short of. redraw.mjs proves a
// sequence lands in xterm's buffer. collapse.ps1 proves it lands in
// ConPTY's. The visual scenes photograph a real window and can only say
// that two frames differ, at a cadence slow enough to photograph. None of
// them can say that what is in the buffer became pixels - and "the screen
// keeps showing the frame before" is exactly a failure in that gap.
//
// So the probe fills the screen twenty times, alternating, and reads the
// renderer's own output back after each one. Two consecutive reads that
// are identical mean a frame did not land. That is the reported fault,
// stated as an assertion, running headless in the engine the app renders
// in and taking a couple of seconds.
//
// Both renderers, because they are different code with the same job and
// the app can be on either.
import { execFileSync } from "child_process";
import { existsSync } from "fs";
import { fileURLToPath, pathToFileURL } from "url";
import { dirname, join } from "path";

const here = dirname(fileURLToPath(import.meta.url));
const fixture = join(here, "fixtures", "paint-probe.html");
const renderScript = join(here, "edge-render.mjs");

const EDGES = [
  "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe",
  "C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe",
];
const edge = process.env.GT_BROWSER || EDGES.find((p) => existsSync(p));
if (!edge) {
  console.log("SKIP paint: no Edge found — this needs the engine the app renders in");
  process.exit(0);
}

let failed = 0;
function check(name, ok, detail = "") {
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${ok ? "" : `: ${detail}`}`);
  if (!ok) failed++;
}

function probe(renderer) {
  const url = `${pathToFileURL(fixture).href}?renderer=${renderer}`;
  // The DOM renderer draws on requestAnimationFrame, which virtual time
  // starves - so read it on the real clock, where it paints, and read WebGL
  // under virtual time as before. Same fixture, same assertions, both modes.
  const args =
    renderer === "dom"
      ? [renderScript, edge, url, "5000", "rt"]
      : [renderScript, edge, url, "90000"];
  const dom = execFileSync(process.execPath, args, {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
    timeout: 180_000,
  });
  // The output element specifically. The script that fills it lives in
  // the same document and contains the word RESULTS in its own source, so
  // a loose match reads the program instead of its answer.
  const m = dom.match(/id="out">RESULTS(-ERROR)? ([^<]*)</);
  if (!m) {
    const pending = dom.match(/id="out">([^<]*)</);
    return { error: `the probe never reported — the page left "${pending?.[1] ?? "nothing"}" behind` };
  }
  if (m[1]) return { error: m[2] };
  try {
    return JSON.parse(m[2].replace(/&quot;/g, '"').replace(/&amp;/g, "&"));
  } catch (e) {
    return { error: `unreadable payload: ${m[2].slice(0, 200)}` };
  }
}

for (const renderer of ["webgl", "dom"]) {
  const r = probe(renderer);
  if (r.error) {
    check(`${renderer}: the probe ran`, false, r.error);
    continue;
  }
  console.log(
    `  ${renderer}: ${r.landed}/${r.frames} frames reached the screen, slowest ${r.slowestMs}ms`
  );

  const detail = r.firstMiss
    ? `frame ${r.firstMiss.frame} wanted ${r.firstMiss.wanted} and the screen still showed ${r.firstMiss.saw} after 4s`
    : `${r.missed} frames never arrived`;

  // Both renderers, one assertion: every time the buffer changed, the
  // picture followed - a screen that sticks is a frame that never
  // arrived, with what it was still showing instead. WebGL is read under
  // virtual time; the DOM renderer is read on the real clock (see
  // probe()), because virtual time starves its requestAnimationFrame -
  // which for years made this a NOTE and read like the oldest "sticks on
  // old output" report about this terminal. On the real clock it lands
  // every frame too, so both are held to the same bar and a regression
  // in either renderer shows which.
  check(`${renderer}: every buffer change reached the screen`, r.missed === 0, detail);

  // And it was not instant every time by accident of the screen already
  // being that colour: the two frames are opposite, so each one had to be
  // repainted to satisfy the wait.
  check(`${renderer}: it drew both pictures`, r.frames >= 12, `only ${r.frames} frames ran`);
}

if (failed) {
  console.log(`${failed} paint test(s) failed`);
  process.exit(1);
}
console.log("all paint tests passed");
