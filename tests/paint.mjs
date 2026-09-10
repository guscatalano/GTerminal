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

const EDGES = [
  "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe",
  "C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe",
];
const edge = EDGES.find((p) => existsSync(p));
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
  const dom = execFileSync(
    edge,
    [
      "--headless=new",
      "--no-sandbox",
      "--allow-file-access-from-files",
      "--virtual-time-budget=90000",
      "--dump-dom",
      url,
    ],
    { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 180_000 }
  );
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

  if (renderer === "webgl") {
    // The assertion: every time the buffer changed, the picture followed.
    // A screen that sticks shows up as a frame that never arrived, with
    // what it was still showing instead.
    check(`${renderer}: every buffer change reached the screen`, r.missed === 0, detail);
  } else {
    // Reported, not asserted - and now known to be the harness.
    //
    // The DOM renderer misses frames here, typically five of twelve,
    // sitting on the previous fill for the full four seconds, while WebGL
    // lands all twelve in the same run, same page, same clock. That
    // differential looked like the oldest report about this terminal, and
    // it was written up as the likely cause of it.
    //
    // It was not. tui-dom drives the same fixture through a real window
    // with a real compositor, and the DOM renderer passes it: 73% of the
    // screen changing on the first frame and 72% on each redraw after,
    // which is what WebGL scores on the same scene. The misses here are
    // virtual time starving requestAnimationFrame, which is exactly the
    // reason this was never asserted on, and the reason a differential
    // between two things measured in the same broken clock is still not
    // evidence about either of them.
    //
    // Kept, because a change in the number is still worth seeing, and
    // because the day it starts missing on WebGL too - which is asserted
    // - this line is what says whether that is new or normal.
    if (r.missed > 0) {
      console.log(`NOTE ${renderer}: ${r.missed} of ${r.frames} buffer changes did not reach the screen`);
      console.log(`     ${detail}`);
      console.log(`     not a failure here - see the comment in this file, and the tui-dom scene`);
    } else {
      console.log(`NOTE ${renderer}: all ${r.frames} buffer changes reached the screen`);
    }
  }

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
