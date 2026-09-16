// Does a tab recover when its WebGL context is lost? Run: node tests/contextloss.mjs
//
// A GPU reset, an RDP reconnect or a driver recycle takes the WebGL context
// away mid-session - routine on the VMs and remote desktops this app runs
// on. xterm then draws nothing and freezes on its last frame until a repaint
// is forced, which is the oldest "gets stuck on old output, comes back on
// resize" report. guardWebglContext() in main.ts drops the addon on loss so
// the terminal falls back to the DOM renderer and keeps drawing; this proves
// that recovery holds for the xterm in this tree.
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

const dom = execFileSync(
  process.execPath,
  [renderScript, edge, pathToFileURL(fixture).href, "8000"],
  { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 120_000 }
);

const m = dom.match(/id="verdict">RESULT ([^<]*)</);
if (!m) {
  console.log("FAIL contextloss: the probe never reported - the page did not run");
  process.exit(1);
}
const seen = m[1].trim();
const f = Object.fromEntries(
  seen.split(/\s+/).map((kv) => {
    const [k, v] = kv.split("=");
    return [k, v];
  })
);

let failed = 0;
function check(name, ok, detail = "") {
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${ok ? "" : `: ${detail}`}`);
  if (!ok) failed++;
}

check("a WebGL canvas was there to begin with", f.hadCanvas === "true", `no canvas means WebGL never rendered, so the rest proves nothing (RESULT ${seen})`);
check("the context loss fired", f.loss === "true", `RESULT ${seen}`);
check("the addon disposed itself in response", f.disposed === "true", `RESULT ${seen}`);
check("the WebGL canvas is gone, so it reverted to the DOM renderer", f.canvasGone === "true", `RESULT ${seen}`);
check("the terminal still took writes after the loss", f.bufferKept === "true", `output after the loss did not reach the buffer (RESULT ${seen})`);

if (failed) {
  console.log("");
  console.log(`${failed} context-loss test(s) failed`);
  process.exit(1);
}
console.log("");
console.log("all context-loss tests passed");
