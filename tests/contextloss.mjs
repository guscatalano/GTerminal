// Does a tab survive its WebGL context going away? Run: node tests/contextloss.mjs
//
// A GPU reset, an RDP reconnect or a driver recycle takes the WebGL context
// away mid-session - routine on the VMs and remote desktops this app runs
// on. Two outcomes have to hold, and this drives both in a real browser:
//
//   lose    - the loss is permanent. The addon fires onContextLoss and
//             guardWebglContext() in main.ts drops it, so the terminal
//             reverts to the DOM renderer and keeps drawing instead of
//             freezing on its last frame until a resize (the oldest report).
//   restore - the context comes back inside the addon's 3s window. WebGL is
//             kept, onContextLoss never fires, and nothing falls back.
//
// It asserts on data, not paint (the event fired or not, the canvas, the
// buffer), so it holds under headless virtual time.
import { execFileSync } from "child_process";
import { existsSync } from "fs";
import { fileURLToPath, pathToFileURL } from "url";
import { dirname, join } from "path";

const here = dirname(fileURLToPath(import.meta.url));
const fixture = join(here, "fixtures", "contextloss-probe.html");
const renderScript = join(here, "edge-render.mjs");

const EDGES = [
  "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe",
  "C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe",
];
const edge = process.env.GT_BROWSER || EDGES.find((p) => existsSync(p));
if (!edge) {
  console.log("SKIP contextloss: no Edge found - this needs the engine the app renders in");
  process.exit(0);
}

let failed = 0;
function check(name, ok, detail = "") {
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${ok ? "" : `: ${detail}`}`);
  if (!ok) failed++;
}

function probe(scenario) {
  const url = `${pathToFileURL(fixture).href}?scenario=${scenario}`;
  const dom = execFileSync(
    process.execPath,
    [renderScript, edge, url, "8000"],
    { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 120_000 }
  );
  const m = dom.match(/id="verdict">RESULT ([^<]*)</);
  if (!m) return { error: "the probe never reported - the page did not run" };
  const seen = m[1].trim();
  const f = Object.fromEntries(seen.split(" ").map((kv) => kv.split("=")));
  return { f, seen };
}

// Permanent loss -> fall back to the DOM renderer and keep drawing.
{
  const { f, seen, error } = probe("lose");
  if (error) {
    check("lose: the probe ran", false, error);
  } else {
    check("lose: a WebGL canvas was there to begin with", f.hadCanvas === "true", `RESULT ${seen}`);
    check("lose: the context loss fired", f.loss === "true", `RESULT ${seen}`);
    check("lose: the addon disposed itself in response", f.disposed === "true", `RESULT ${seen}`);
    check("lose: the canvas is gone, so it reverted to the DOM renderer", f.canvasGone === "true", `RESULT ${seen}`);
    check("lose: the terminal still took writes after the loss", f.bufferKept === "true", `RESULT ${seen}`);
  }
}

// Transient loss, restored in time -> WebGL kept, nothing falls back.
{
  const { f, seen, error } = probe("restore");
  if (error) {
    check("restore: the probe ran", false, error);
  } else {
    check("restore: a WebGL canvas was there to begin with", f.hadCanvas === "true", `RESULT ${seen}`);
    check("restore: onContextLoss did not fire, because the context came back", f.loss === "false", `RESULT ${seen}`);
    check("restore: nothing was disposed", f.disposed === "false", `RESULT ${seen}`);
    check("restore: the WebGL canvas is still there, so WebGL was kept", f.canvasGone === "false", `RESULT ${seen}`);
    check("restore: the terminal kept taking writes throughout", f.bufferKept === "true", `RESULT ${seen}`);
  }
}

if (failed) {
  console.log("");
  console.log(`${failed} context-loss test(s) failed`);
  process.exit(1);
}
console.log("");
console.log("all context-loss tests passed");
