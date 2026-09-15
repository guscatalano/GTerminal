// Pictures in the terminal, and the half of them that is ours.
// Run: node tests/images.mjs
//
// Sixel: a program writes a DCS string of colour definitions and
// six-pixel bands, and a terminal that understands it draws an image.
// This proves the drawing.
//
// It cannot prove the delivery, and on Windows today the delivery is
// where it stops. ConPTY parses what a console program writes and
// re-emits its own stream, and it drops DCS strings on the floor:
// measured by running tests/fixtures/sixel.ps1 in a real session and
// reading what arrived at the window, which contained the text either
// side of the picture and not one byte of the picture. So a program
// cannot get a picture to this terminal no matter what either of them
// supports. See docs/ideas.md.
//
// Which makes this the test that says the day conhost passes them
// through, nothing here needs finding again - and that the load order
// which cost an hour is not quietly undone.
import { execFileSync } from "child_process";
import { existsSync, readFileSync } from "fs";
import { fileURLToPath, pathToFileURL } from "url";
import { dirname, join, basename } from "path";
import { tmpdir } from "os";

const here = dirname(fileURLToPath(import.meta.url));
const fixture = join(here, "fixtures", "image-probe.html");

const EDGES = [
  "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe",
  "C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe",
];
const edge = EDGES.find((p) => existsSync(p));
if (!edge) {
  console.log("SKIP images: no Edge found — this needs the engine the app renders in");
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
    `--user-data-dir=${join(tmpdir(), "gterm-headless-" + basename(fixture) + "-" + process.pid)}`,
    "--allow-file-access-from-files",
    "--virtual-time-budget=20000",
    "--dump-dom",
    pathToFileURL(fixture).href,
  ],
  { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 180_000 }
);

const m = dom.match(/id="out">RESULTS(-ERROR)? ([^<]*)</);
if (!m) {
  console.log("FAIL images: the probe never reported — the page did not run");
  process.exit(1);
}
if (m[1]) {
  console.log(`FAIL images: the probe threw — ${m[2]}`);
  process.exit(1);
}
const r = JSON.parse(
  m[2].replace(/&quot;/g, '"').replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&")
);

check("a sixel picture is drawn", r.drewSomething === true, JSON.stringify(r));
// The size the fixture asked for, so a picture that decoded to
// something else - a stray pixel, a full-width band - is caught rather
// than counted as success.
check("at the size the program asked for", r.pictureWidth === 240 && r.pictureHeight === 24, `got ${r.pictureWidth}x${r.pictureHeight}`);
check("a cell that is only text holds no image", r.textCellHasNoImage === true);
// The sixel bytes must be consumed rather than printed. A parser that
// does not recognise the string leaves its contents in the buffer,
// which looks like line noise where the picture should be.
check("and the picture's bytes are not left lying in the buffer as text", (r.rowUnderPicture ?? "").trim() === "", `row held ${JSON.stringify(r.rowUnderPicture)}`);

// The load order, which is the whole reason the first attempt drew
// nothing: the addon registers its DCS handler when it is activated, so
// one loaded after the terminal is open is one that missed the picture.
// Cheap to state, and indistinguishable from a broken addon when wrong.
const main = readFileSync(join(here, "..", "src", "main.ts"), "utf8");
const loadAt = main.indexOf("new ImageAddon(");
const openAt = main.indexOf("term.open(paneBody)");
check(
  "the window loads the image addon before it opens the terminal",
  loadAt > 0 && openAt > 0 && loadAt < openAt,
  `loadAddon at ${loadAt}, open at ${openAt}`
);


// The part that makes this worse than absent while it cannot work.
//
// The addon answers Primary Device Attributes with ESC[?62;4;9;22c,
// and the 4 is a claim to draw sixel. A program that asks and is told
// yes sends a picture and draws nothing, because ConPTY eats it; a
// program told no prints its ASCII fallback. So the capability must not
// be claimed by default while nothing can carry it.
check(
  "the window does not load the addon unless it was deliberately turned on",
  /if \(config\.images === true\)/.test(main),
  "the default has to be off: a terminal that claims sixel and cannot receive it turns a working text fallback into an empty screen"
);
check(
  "and the setting says so rather than promising pictures",
  /no effect today/.test(main),
  "the settings text must say the feature does nothing yet"
);

if (failed) {
  console.log(`${failed} image test(s) failed`);
  process.exit(1);
}
console.log("all image tests passed");
