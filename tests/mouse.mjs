// Selecting text while a program is reading the mouse.
// Run: node tests/mouse.mjs
//
// Reported from real use: copying out of an agent TUI is impossible
// because the program "hijacks copying". That is a fair description of
// what happens and a misleading one about whose doing it is. A
// full-screen program asks for mouse reporting - DECSET 1000, 1002 or
// 1003, usually with 1006 for the extended encoding - and from that
// moment every press, drag and release is the program's, because that is
// how its own click targets work. A terminal that kept the drag for
// itself would break every such program.
//
// So the question is not whether the program takes the mouse. It is
// whether there is a way to take it back, whether that way works here,
// and whether it stops being needed when the program lets go. Those are
// the three things below.
//
// The gestures are synthetic but they are real DOM events on the real
// element xterm binds: nothing here asks the terminal what it would do,
// it makes it do it and reads what came out.
import { execFileSync } from "child_process";
import { existsSync } from "fs";
import { fileURLToPath, pathToFileURL } from "url";
import { dirname, join } from "path";

const here = dirname(fileURLToPath(import.meta.url));
const fixture = join(here, "fixtures", "mouse-probe.html");
const renderScript = join(here, "edge-render.mjs");

const EDGES = [
  "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe",
  "C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe",
];
const edge = process.env.GT_BROWSER || EDGES.find((p) => existsSync(p));
if (!edge) {
  console.log("SKIP mouse: no Edge found — this needs the engine the app renders in");
  process.exit(0);
}

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
  console.log("FAIL mouse: the probe never reported — the page did not run");
  process.exit(1);
}
if (m[1]) {
  console.log(`FAIL mouse: the probe threw — ${m[2]}`);
  process.exit(1);
}
const results = new Map(
  JSON.parse(
    m[2]
      .replace(/&quot;/g, '"')
      .replace(/&lt;/g, "<")
      .replace(/&gt;/g, ">")
      // Ampersand last, or an escaped entity is unescaped twice.
      .replace(/&amp;/g, "&")
  ).map((r) => [r.name, r])
);

const got = (name) => results.get(name) ?? { selection: "<case never ran>", toApp: "" };

// Before the gestures: can this environment select at all, and does the
// element have the size every coordinate below is computed from? Without
// this, "the drag is wrong" and "nothing here can select" produce the
// same failure and the suite points at the wrong one.
{
  const r = got("selecting works at all");
  check(
    "the terminal can select by itself, so the drags below mean something",
    r.selection.includes("SELECTABLE"),
    `selectAll() gave ${JSON.stringify(r.selection)} with the screen at ${r.rect}`
  );
}

// The baseline. If this fails nothing below means anything, because the
// gesture itself is not reaching the terminal.
{
  const r = got("a drag selects when nothing is reading the mouse");
  check(
    "a drag selects when nothing is reading the mouse",
    r.selection.includes("SELECTABLE"),
    `selection was ${JSON.stringify(r.selection)} [${r.trace}] — the synthetic drag is not reaching xterm, so every case below is untested`
  );
}

// Reported as "holding shift to select doesn't work, but without it it
// does" - which is true, in a shell where nothing is reading the mouse.
// There, selection is already yours and shift means *extend it*, so with
// no selection to extend it does nothing. This is why the hint must not
// appear in a plain shell: advice that does nothing when followed is
// worse than no advice.
{
  const r = got("shift with nothing reading the mouse extends rather than starts");
  check(
    "shift alone does not start a selection when nothing is reading the mouse",
    r.selection === "",
    `selection was ${JSON.stringify(r.selection)} — if this starts working, the hint can be shown more widely`
  );
}

// The reported problem, stated as the behaviour it actually is.
{
  const r = got("with mouse reporting on, a plain drag goes to the program");
  check(
    "with mouse reporting on, a plain drag selects nothing",
    r.selection === "",
    `selection was ${JSON.stringify(r.selection)}`
  );
  check(
    "and the program is the one that got the gesture",
    /\x1b\[</.test(r.toApp),
    `the program received ${JSON.stringify(r.toApp)} — if this is empty the drag went nowhere at all, which is a different fault from the one being described`
  );
}

// The answer to "so how do I copy out of it".
{
  const r = got("holding shift takes the drag back from the program");
  check(
    "holding shift selects anyway — this is the way out",
    r.selection.includes("SELECTABLE"),
    `selection was ${JSON.stringify(r.selection)}`
  );
  check(
    "and the program is not told about a gesture that was not its own",
    r.toApp === "",
    `the program received ${JSON.stringify(r.toApp)}`
  );
}

// The modes real programs use. 1000 is presses only; anything with a
// cursor or a hover state asks for 1002 or 1003, so an escape hatch that
// only works against 1000 works against nothing anybody runs.
for (const label of ["button-drag tracking (1002)", "any-motion tracking (1003)"]) {
  const r = got(`shift takes the drag back from ${label}`);
  check(
    `a plain drag goes to the program under ${label}`,
    r.plainSelection === "",
    `selection was ${JSON.stringify(r.plainSelection)}`
  );
  check(
    `and shift takes it back from ${label}`,
    r.selection.includes("SELECTABLE"),
    `selection was ${JSON.stringify(r.selection)}`
  );
  check(
    `without telling ${label} about it`,
    r.toApp === "",
    `the program received ${JSON.stringify(r.toApp)}`
  );
}

// And it is a loan, not a surrender.
{
  const r = got("and a plain drag works again once the program stops asking");
  check(
    "a plain drag works again once the program stops asking",
    r.selection.includes("SELECTABLE"),
    `selection was ${JSON.stringify(r.selection)} — a mode left set here is how a terminal stays broken after the program has gone`
  );
}

// Selecting is not copying: whatever the app binds for copy reads the
// selection afterwards, so it has to still be there.
{
  const r = got("the selection is still readable after the gesture ends");
  check(
    "the selection survives the gesture, so something can copy it",
    r.selection.includes("SELECTABLE"),
    `selection was ${JSON.stringify(r.selection)}`
  );
}

for (const name of results.keys()) {
  const asserted = [
    "selecting works at all",
    "shift with nothing reading the mouse extends rather than starts",
    "shift takes the drag back from button-drag tracking (1002)",
    "shift takes the drag back from any-motion tracking (1003)",
    "a drag selects when nothing is reading the mouse",
    "with mouse reporting on, a plain drag goes to the program",
    "holding shift takes the drag back from the program",
    "and a plain drag works again once the program stops asking",
    "the selection is still readable after the gesture ends",
  ];
  if (!asserted.includes(name)) {
    check(`${name} is asserted on`, false, "the probe runs it but nothing checks it");
  }
}

if (failed) {
  console.log(`${failed} mouse test(s) failed`);
  process.exit(1);
}
console.log(`all mouse tests passed (${results.size} gestures)`);
