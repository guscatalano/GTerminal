// Select, then right-click. Is the selection still there to be copied?
// Run: node tests/rightclick.mjs
//
// Reported from real use: "it only works if I select with shift and then
// right click and copy; if I select without, then right clicking it
// disappears."
//
// The menu is built from the contextmenu event and offers to copy
// whatever the terminal holds at that moment, so the question is
// whether the selection is still there when that moment arrives.
//
// It is - in every case here, with the guard and without it. Which
// makes this suite's real value the thing it ruled out: the selection
// is not being lost to the right button at all, so the report was
// about something else, and it was. With the console-style right
// button ("Copy / paste" in settings) a right-click *copies* the
// selection and clears the highlight, silently. That is the console's
// own behaviour and worth keeping, and it is indistinguishable from
// losing the text unless something says so - which is why the pane now
// does. See copiedNote in src/hints.ts.
import { execFileSync } from "child_process";
import { existsSync } from "fs";
import { fileURLToPath, pathToFileURL } from "url";
import { dirname, join } from "path";

const here = dirname(fileURLToPath(import.meta.url));
const fixture = join(here, "fixtures", "rightclick-probe.html");
const renderScript = join(here, "edge-render.mjs");

const EDGES = [
  "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe",
  "C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe",
];
const edge = EDGES.find((p) => existsSync(p));
if (!edge) {
  console.log("SKIP rightclick: no Edge found — this needs the engine the app renders in");
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
  console.log("FAIL rightclick: the probe never reported — the page did not run");
  process.exit(1);
}
if (m[1]) {
  console.log(`FAIL rightclick: the probe threw — ${m[2]}`);
  process.exit(1);
}
const results = new Map(
  JSON.parse(
    m[2]
      .replace(/&quot;/g, '"')
      .replace(/&lt;/g, "<")
      .replace(/&gt;/g, ">")
      .replace(/&amp;/g, "&")
  ).map((r) => [r.name, r])
);
const got = (name) => results.get(name) ?? {};

// What xterm does on its own, measured rather than assumed - and it
// came back the other way round from the comment on main.ts's guard.
// This version ignores the right button for selection entirely, so the
// selection is not lost here and the guard is protecting against
// something that no longer happens. It stays: it costs one branch, and
// an xterm that changed its mind would otherwise take the selection
// with it. But the suite records the truth, because a guard everybody
// believes in for the wrong reason is how the real cause of a report
// goes unlooked-for.
{
  const r = got("without the guard, a right-click away from the selection loses it");
  check(
    "the right button does not disturb the selection on its own",
    r.before?.includes("COPY-THIS") === true && r.atMenu?.includes("COPY-THIS") === true,
    `selection was ${JSON.stringify(r.before)} before and ${JSON.stringify(r.atMenu)} when the menu was built — if this starts failing, xterm has changed and the guard in main.ts is the only thing holding the selection up`
  );
}

// The app.
{
  const r = got("with the guard, a plain selection survives the right-click");
  check(
    "a plain selection is still there when the menu is built",
    r.atMenu?.includes("COPY-THIS") === true,
    `the menu would have been built with ${JSON.stringify(r.atMenu)}`
  );
  check(
    "and the text is remembered as well as kept",
    r.remembered?.includes("COPY-THIS") === true,
    `remembered ${JSON.stringify(r.remembered)}`
  );
}

// The reported case: the selection was only possible with shift, and
// then the right button is pressed without it, because that is what a
// hand does next.
{
  const r = got("a shift-made selection survives a plain right-click while a program reads the mouse");
  check(
    "shift-selecting inside a program that reads the mouse gives a selection",
    r.before?.includes("COPY-THIS") === true,
    `selection was ${JSON.stringify(r.before)}`
  );
  check(
    "and it is still there when the menu is built",
    r.atMenu?.includes("COPY-THIS") === true,
    `the menu would have been built with ${JSON.stringify(r.atMenu)} — this is the reported failure`
  );
  check(
    "and the right button did not go to the program instead",
    !/\x1b\[<2;/.test(r.toApp ?? ""),
    `the program received ${JSON.stringify(r.toApp)}`
  );
}

// And the gesture the settings text promises always works.
{
  const r = got("and shift+right-click keeps it too");
  check(
    "shift+right-click also arrives with the selection intact",
    r.atMenu?.includes("COPY-THIS") === true,
    `the menu would have been built with ${JSON.stringify(r.atMenu)}`
  );
}

if (failed) {
  console.log(`${failed} right-click test(s) failed`);
  process.exit(1);
}
console.log(`all right-click tests passed (${results.size} cases)`);
