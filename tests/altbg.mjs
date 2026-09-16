// Does the background art show through a full-screen TUI, and only where the
// app leaves the cell background alone? Run: node tests/altbg.mjs
//
// "Sometimes I see the theme behind a TUI and sometimes not" comes down to
// one thing: with a theme's art active, main.ts makes the terminal cell
// background fully transparent, so a cell left at the default background
// shows the art - and a cell the program paints with its own background
// (SGR 48) is opaque and hides it. A full-screen program (the alternate
// screen, where TUIs live) that fills the screen on the default background
// shows the art through; one that paints a background does not. Same app,
// two panels, two answers.
//
// This pins that on the renderer the app prefers: drive a program onto the
// alt screen and fill it, once on the default background (the art must show)
// and once on an explicit one (the art must not). A flat page colour stands
// in for the art; on the WebGL canvas a transparent cell reads as alpha 0.
import { execFileSync } from "child_process";
import { existsSync } from "fs";
import { fileURLToPath, pathToFileURL } from "url";
import { dirname, join } from "path";

const here = dirname(fileURLToPath(import.meta.url));
const fixture = join(here, "fixtures", "altbg-probe.html");
const renderScript = join(here, "edge-render.mjs");

const EDGES = [
  "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe",
  "C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe",
];
const edge = process.env.GT_BROWSER || EDGES.find((p) => existsSync(p));
if (!edge) {
  console.log("SKIP altbg: no Edge found - this needs the engine the app renders in");
  process.exit(0);
}

let failed = 0;
function check(name, ok, detail = "") {
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${ok ? "" : `: ${detail}`}`);
  if (!ok) failed++;
}

function probe(fill) {
  const url = `${pathToFileURL(fixture).href}?fill=${fill}`;
  const dom = execFileSync(
    process.execPath,
    [renderScript, edge, url, "8000"],
    { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 120_000 }
  );
  const m = dom.match(/id="verdict">RESULT ([^<]*)</);
  if (!m) return { error: "the probe never reported - the page did not run" };
  const seen = m[1].trim();
  const f = Object.fromEntries(seen.split(" ").map((kv) => kv.split("=")));
  return { seen, clear: Number(f.clear), glyph: Number(f.glyph) };
}

// The probe, with one retry for a frame that never came up. A result with no
// glyphs at all is not a screen that drew nothing on purpose; it is the
// WebGL context failing to come up on one launch in a batch - the flake
// webgl.mjs documents at length. Such a run cannot say anything about the
// art, so it is thrown away and asked for again, once.
function probeReal(fill) {
  const first = probe(fill);
  if (!first.error && first.glyph < 500) {
    console.log(`  (${fill}: an empty frame - no WebGL frame came up - retrying once)`);
    return probe(fill);
  }
  return first;
}

// Default background on the alt screen: the art shows through.
{
  const r = probeReal("default");
  if (r.error) {
    check("default: the probe ran", false, r.error);
  } else {
    check("default: the full-screen text actually drew", r.glyph > 2000, `glyph=${r.glyph} (${r.seen})`);
    check(
      "default: the art shows through a full-screen TUI on the default background",
      r.clear > 2000,
      `clear=${r.clear} - the art was hidden where the program left the cell background alone (${r.seen})`
    );
  }
}

// Explicit background on the alt screen: the art is hidden.
{
  const r = probeReal("explicit");
  if (r.error) {
    check("explicit: the probe ran", false, r.error);
  } else {
    check("explicit: the full-screen text actually drew", r.glyph > 2000, `glyph=${r.glyph} (${r.seen})`);
    check(
      "explicit: a cell background the program paints hides the art",
      r.clear < 200,
      `clear=${r.clear} - the art still showed through cells the program painted opaque (${r.seen})`
    );
  }
}

if (failed) {
  console.log("");
  console.log(`${failed} altbg test(s) failed`);
  process.exit(1);
}
console.log("");
console.log("all altbg tests passed");
