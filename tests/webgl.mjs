// The WebGL renderer has to composite a transparent background.
// Run: node tests/webgl.mjs
//
// Every theme with background art sets the terminal background to
// #00000000 and expects the art to show through the cells. For a long
// time it could not: the app dropped those tabs to the DOM renderer,
// which is much slower, on the grounds that "WebGL can't composite
// transparency". That was true of older versions of the addon and is not
// true of the one in this tree - measured, not assumed, which is what
// this test is.
//
// It matters because the conclusion is invisible from the code: nothing
// in main.ts can tell you whether a transparent theme still shows the
// page behind it. An xterm upgrade could quietly take it away, and the
// symptom would be black boxes over everybody's wallpaper.
import { execFileSync } from "child_process";
import { existsSync } from "fs";
import { fileURLToPath, pathToFileURL } from "url";
import { dirname, join, basename } from "path";
import { tmpdir } from "os";

const here = dirname(fileURLToPath(import.meta.url));
const fixture = join(here, "fixtures", "webgl-probe.html");

// Edge ships with Windows, and the app's webview is the same engine.
const EDGES = [
  "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe",
  "C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe",
];
const edge = EDGES.find((p) => existsSync(p));
if (!edge) {
  console.log("SKIP webgl: no Edge found — this needs the same engine the app renders in");
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

/// Render the fixture headless and read the line it leaves in the DOM.
function probe(transparent) {
  const url = `${pathToFileURL(fixture).href}?transparent=${transparent ? 1 : 0}`;
  const dom = execFileSync(
    edge,
    [
      "--headless=new",
      "--no-sandbox",
      // Its own profile directory. Four suites here drive headless Edge,
      // and without this they share one - where a second instance can
      // attach to the first, or find it locked, and exit having rendered
      // nothing. webgl.mjs passes alone and failed in the batch exactly
      // once, which is the shape that has cost this project four days.
      `--user-data-dir=${join(tmpdir(), "gterm-headless-" + basename(fixture) + "-" + process.pid + "-" + (launches++))}`,
      // ES modules over file:// are a cross-origin load to Chromium, and
      // without this the fixture never runs at all - it just reports
      // "pending", which looks like a renderer that drew nothing.
      "--allow-file-access-from-files",
      "--virtual-time-budget=8000",
      "--dump-dom",
      url,
    ],
    { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 120_000 }
  );
  // The verdict element, not the first "RESULT" in the dump: the script
  // that writes it is in the same document and contains the word too.
  const line = dom.match(/id="verdict">([^<]*)</)?.[1] ?? "RESULT missing";
  const nums = Object.fromEntries(
    [...line.matchAll(/(\w+)=(\d+)/g)].map(([, k, v]) => [k, Number(v)])
  );
  return { line, ...nums };
}

/// The probe, with one retry for a frame that never happened.
///
/// A result where every pixel is clear and not one glyph was drawn -
/// `opaque=0 glyph=0` - is not a renderer that painted transparency; it
/// is a WebGL context that never came up, which is what a headless Edge
/// does when it is the thirtieth one launched in a row and the GPU
/// process has been asked for too much. Alone this suite passed every
/// time; in the batch it failed two runs in three with exactly that
/// signature. Such a frame proves nothing either way, so it is thrown
/// away and asked for again, once. A second one is a real failure.
function probeReal(transparent) {
  const first = probe(transparent);
  if (first.opaque === 0 && first.glyph === 0) {
    console.log(`  (an empty frame - no WebGL context - retrying once: ${first.line})`);
    return probe(transparent);
  }
  return first;
}

// A transparent theme: nearly every pixel the renderer owns must be left
// alone, and the glyphs must still be there — if they are not, the
// snapshot caught an empty buffer and proves nothing.
const clear = probeReal(true);
console.log(`  transparent theme -> ${clear.line}`);
check("a transparent background is left transparent", clear.clear > 0, `${clear.line} — the renderer painted over every pixel, so background art cannot show through`);
check("and the text is still drawn", clear.glyph > 100, `${clear.line} — too few glyph pixels; the snapshot did not catch a real frame, so the result above means nothing`);

// The control. Without it, a renderer that drew nothing at all would look
// like a pass above.
const solid = probeReal(false);
console.log(`  opaque theme      -> ${solid.line}`);
check("an opaque background is painted", solid.clear === 0, `${solid.line} — an opaque theme left transparent pixels, so the probe is not measuring the renderer`);
check("and its text is drawn too", solid.glyph > 100, solid.line);

if (failed) {
  console.log(`${failed} webgl test(s) failed`);
  process.exit(1);
}
console.log("all webgl tests passed");
