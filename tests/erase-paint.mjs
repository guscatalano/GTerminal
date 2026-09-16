// After an erase, does the renderer actually paint the cleared cells?
// Run: node tests/erase-paint.mjs
//
// redraw.mjs reads term.buffer - what xterm thinks is on screen - and
// proves every erase primitive lands there correctly. It cannot see one
// layer further out: a renderer that has the right buffer and paints
// stale pixels anyway. "Output does not get cleared as expected" is a
// report about that layer, and a bug that reproduces on one machine only
// almost always lives there - a frame the compositor never scheduled, a
// GPU/driver quirk, a dirty region left unrepainted - not in the buffer,
// which is identical on every machine.
//
// So this fills the screen with glyphs, reads the renderer's own output
// back, erases the bottom half, and reads again. The cleared half must go
// to background; the untouched half must not. That second requirement is
// what makes the test honest: a renderer that simply drew nothing would
// clear the bottom too, and the surviving top is what rules that false
// pass out. Both renderers, because the app runs on either and they are
// separate code with the same job - and the WebGL/DOM split is the exact
// axis a one-machine renderer bug sits on.
//
// WebGL is asserted; the DOM renderer is only reported. getImageData reads
// the WebGL frame straight off the canvas, and WebGL lands its frames
// headless (webgl.mjs and paint.mjs both rely on that). The DOM renderer
// builds its rows on a requestAnimationFrame that headless virtual time
// starves - it sits on the fill and never shows the erase - so a hard
// check on it would fail green code at random, exactly the trap paint.mjs
// calls out. Its real clearing is covered by the tui-dom visual scene,
// which drives the same renderer through a real compositor.
import { execFileSync } from "child_process";
import { existsSync } from "fs";
import { fileURLToPath, pathToFileURL } from "url";
import { dirname, join } from "path";

const here = dirname(fileURLToPath(import.meta.url));
const fixture = join(here, "fixtures", "erase-paint-probe.html");
const renderScript = join(here, "edge-render.mjs");

const EDGES = [
  "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe",
  "C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe",
];
const edge = process.env.GT_BROWSER || EDGES.find((p) => existsSync(p));
if (!edge) {
  console.log("SKIP erase-paint: no Edge found — this needs the engine the app renders in");
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
  // starves - so read it on the real clock, where it paints. WebGL is read
  // under virtual time as before. Same fixture, same checks, both modes.
  const args =
    renderer === "dom"
      ? [renderScript, edge, url, "5000", "rt"]
      : [renderScript, edge, url, "90000"];
  const dom = execFileSync(process.execPath, args, {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
    timeout: 180_000,
  });
  // The output element specifically. The script that fills it lives in the
  // same document and contains the word RESULTS in its own source, so a
  // loose match reads the program instead of its answer.
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

// The probe, with one retry for a WebGL frame that never happened. A
// result where the fill drew nothing at all - both halves zero before any
// erase - is not a renderer that cleared everything; it is a GL context
// that never came up, the failure webgl.mjs documents at length. Such a
// run cannot say anything about clearing, so it is thrown away and asked
// for again, once. A second empty fill is a real failure.
function probeReal(renderer) {
  const first = probe(renderer);
  if (!first.error && first.beforeTop === 0 && first.beforeBottom === 0) {
    console.log(`  (${renderer}: an empty fill - no frame came up - retrying once)`);
    return probe(renderer);
  }
  return first;
}

for (const renderer of ["webgl", "dom"]) {
  const r = probeReal(renderer);
  if (r.error) {
    check(`${renderer}: the probe ran`, false, r.error);
    continue;
  }
  console.log(
    `  ${renderer} (${r.kind}): filled top=${r.beforeTop} bottom=${r.beforeBottom}; ` +
      `after ED-below top=${r.partialTop} bottom=${r.partialBottom}; ` +
      `after 2J top=${r.fullTop} bottom=${r.fullBottom}; ` +
      `after EL-below top=${r.elTop} bottom=${r.elBottom}; ` +
      `alt on top=${r.altOnTop} bottom=${r.altOnBottom}, off top=${r.altOffTop} bottom=${r.altOffBottom}`
  );

  const budget = (r.beforeTop + r.beforeBottom) / 8;
  const cleared = r.partialBottom <= r.beforeBottom / 8;
  const survived = r.partialTop >= r.beforeTop / 2;
  const fullyCleared = r.fullTop + r.fullBottom <= budget;
  const elCleared = r.elBottom <= r.beforeBottom / 8;
  const elSurvived = r.elTop >= r.beforeTop / 2;
  const altDrew = r.altOnTop > 0 && r.altOnBottom > 0;
  const altRepainted = r.altOffTop + r.altOffBottom <= budget;

  // Both renderers, held to the same checks below. WebGL is read under
  // virtual time, which it lands its frames under; the DOM renderer is
  // read on the real clock (probe() runs it in rt mode) because virtual
  // time starves its requestAnimationFrame - the reason this used to be a
  // NOTE and read like the "it only clears when I resize" report. On the
  // real clock it clears, repaints and leaves the alt screen the way WebGL
  // does, so the assertions run for both. The tui-dom scene still drives
  // the DOM renderer through a real compositor as the higher-fidelity check.

  // The control both assertions below stand on: the fill actually put
  // glyphs on the screen, in both halves. Without this a renderer that
  // drew nothing would sail through "the cleared half is empty".
  check(
    `${renderer}: the fill lit both halves of the screen`,
    r.beforeTop > 0 && r.beforeBottom > 0,
    `top=${r.beforeTop} bottom=${r.beforeBottom} — the snapshot caught no filled frame, so nothing below is measuring a clear`
  );

  // The assertion. Erase-below drove the bottom half to (near) nothing:
  // the cleared cells are actually background on screen, not stale glyphs
  // the renderer forgot to repaint. An eighth of the filled amount is the
  // bar - antialiasing can leave a few edge pixels, but a band that did
  // not get repainted stays near its full brightness.
  check(
    `${renderer}: the erased region is actually painted clear`,
    cleared,
    `bottom was ${r.beforeBottom} filled and is ${r.partialBottom} after erase — the cleared cells are still lit, which is the not-cleared report`
  );

  // The other half of the same erase, and the reason the pass above is
  // not a renderer that merely stopped drawing: the untouched top half
  // must still be lit. If this drops, the erase (or the renderer) took
  // more than it was asked to.
  check(
    `${renderer}: the untouched region survived the erase`,
    survived,
    `top was ${r.beforeTop} filled and is ${r.partialTop} after erasing only below it — the clear reached cells it should not have, or the frame was lost`
  );

  // And a whole-screen ESC[2J leaves nothing lit anywhere.
  check(
    `${renderer}: a full clear leaves nothing on screen`,
    fullyCleared,
    `screen still shows top=${r.fullTop} bottom=${r.fullBottom} after 2J`
  );

  // The EL (partial-line erase) path, read as pixels with no resize in
  // between. This is the one the "it clears when I resize" report points
  // at most directly: a row whose cells were cleared in the buffer but
  // never marked dirty in the renderer stays lit here, because nothing
  // forced the repaint. The surviving top half is again what rules out a
  // renderer that simply stopped drawing.
  check(
    `${renderer}: an EL partial-line erase is actually painted clear`,
    elCleared,
    `bottom was ${r.beforeBottom} filled and is ${r.elBottom} after ESC[K on those rows — the cleared lines are still lit with no resize to force a repaint`
  );
  check(
    `${renderer}: the rows above the EL survived`,
    elSurvived,
    `top was ${r.beforeTop} filled and is ${r.elTop} after erasing only the rows below — the EL took rows it should not have, or the frame was lost`
  );

  // The alternate screen left. altOn is the control - the full-screen
  // program did draw - and altOff is the assertion: after ESC[?1049l the
  // renderer repainted the main screen it switched back to, rather than
  // leaving the program's last frame lit. A ghost that "fixes itself on
  // resize" is precisely this repaint not happening, and it is read here
  // as pixels with no resize.
  check(
    `${renderer}: the alt screen actually drew (control for the exit below)`,
    altDrew,
    `alt screen read top=${r.altOnTop} bottom=${r.altOnBottom} - it never came up, so the exit proving clean means nothing`
  );
  check(
    `${renderer}: the main screen is repainted after the alt screen is left`,
    altRepainted,
    `after ESC[?1049l the screen still shows top=${r.altOffTop} bottom=${r.altOffBottom} - the program's frame is a ghost the renderer never cleared`
  );
}

if (failed) {
  console.log(`${failed} erase-paint test(s) failed`);
  process.exit(1);
}
console.log("all erase-paint tests passed");
