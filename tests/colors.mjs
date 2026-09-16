// What a program's colours do to the screen, and how long they last.
// Run: node tests/colors.mjs
//
// Reported from real use: a PowerShell script "seemed to paint the entire
// terminal blue", and it took `color` to get out of it. Two things are
// worth separating there. Whether the terminal did something wrong - and
// it did not, this is the standard behaviour of every terminal there has
// ever been - and whether anybody could have told, which is the part that
// made it worth a report.
//
// The mechanism is background-colour-erase. A program sets a background
// with SGR 44 and every cell it writes afterwards carries it, including
// the next line, because SGR is state and not a property of the text. And
// an erase - a clear, an erase-to-end-of-line - fills with the background
// in force rather than with the default. So a script that sets a
// background and then clears the screen paints all of it, in two
// sequences, and every prompt after that arrives on a blue ground until
// something resets it.
//
// `color` works because it resets the console's default attributes. From
// the terminal's side that is ESC[0m, which is the same thing a program
// should have sent itself.
//
// redraw.mjs reads the buffer as text and cannot see any of this: a blue
// screen and a black one hold the same characters. These cases read the
// cell attributes instead.
import { execFileSync } from "child_process";
import { existsSync } from "fs";
import { fileURLToPath, pathToFileURL } from "url";
import { dirname, join } from "path";

const here = dirname(fileURLToPath(import.meta.url));
const fixture = join(here, "fixtures", "colors-probe.html");
const renderScript = join(here, "edge-render.mjs");

const EDGES = [
  "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe",
  "C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe",
];
const edge = EDGES.find((p) => existsSync(p));
if (!edge) {
  console.log("SKIP colors: no Edge found — this needs the engine the app renders in");
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
  [renderScript, edge, pathToFileURL(fixture).href, "20000"],
  { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 180_000 }
);

const m = dom.match(/id="out">RESULTS(-ERROR)? ([^<]*)</);
if (!m) {
  console.log("FAIL colors: the probe never reported — the page did not run");
  process.exit(1);
}
if (m[1]) {
  console.log(`FAIL colors: the probe threw — ${m[2]}`);
  process.exit(1);
}
const results = new Map(
  JSON.parse(m[2].replace(/&quot;/g, '"').replace(/&amp;/g, "&")).map((r) => [r.name, r])
);

// SGR 44 is palette colour 4. A cell painted with it is not default, is a
// palette colour, and is that one.
const BLUE = 4;

// Which cases must come back blue, and which must come back untouched.
// Written out because the interesting thing about every one of them is
// which side of that line it falls on.
const EXPECT = {
  "a background applies to the text after it": "blue",
  "and keeps applying on the next line": "blue",
  "and to a line erased while it is set": "blue",
  "and to the rest of a line erased with EL": "blue",
  "a reset before the erase leaves the screen default": "default",
  "SGR 49 puts the background back on its own": "default",
  "a full reset ends it, which is what color does": "default",
  "text colour alone leaves the background alone": "default",
};

for (const [name, want] of Object.entries(EXPECT)) {
  const got = results.get(name);
  if (!got) {
    check(name, false, "the probe did not run this case");
    continue;
  }
  const bad = got.cells.filter((c) =>
    want === "blue" ? !(c.isPalette && c.bg === BLUE) : !c.isDefault
  );
  check(
    name,
    bad.length === 0,
    `cells ${bad.map((c) => `${c.at}(bg=${c.bg},default=${c.isDefault})`).join(" ")} are not ${want}`
  );
}

for (const name of results.keys()) {
  if (!(name in EXPECT)) check(`${name} is asserted on`, false, "the probe runs it but nothing checks it");
}

if (failed) {
  console.log(`${failed} colour test(s) failed`);
  process.exit(1);
}
console.log(`all colour tests passed (${results.size} cases)`);
