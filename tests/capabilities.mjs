// Every window command the UI calls has to be allowed in the capability
// file. Run: node tests/capabilities.mjs
//
// Tauri rejects a command that is not listed, and the rejection arrives as
// a rejected promise inside the webview: nothing is logged where anyone
// looks, and the feature simply does not happen. That is how the maximized
// tab strip nearly shipped dead — the class that gives the tabs the top of
// the screen is set from isMaximized(), which was not in the list, so the
// class was never set and the tabs stayed 6px down for no visible reason.
import { readFileSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";

const here = dirname(fileURLToPath(import.meta.url));
const ts = readFileSync(join(here, "..", "src", "main.ts"), "utf8");
const caps = JSON.parse(readFileSync(join(here, "..", "src-tauri", "capabilities", "default.json"), "utf8"));

let failed = 0;
function check(name, ok, detail = "") {
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${ok ? "" : `: ${detail}`}`);
  if (!ok) failed++;
}

// Events and properties, not commands: they go through the event system
// (core:default covers listening) or are plain fields on the window.
const notCommands = new Set([
  "onCloseRequested",
  "onResized",
  "onMoved",
  "onFocusChanged",
  "once",
  "listen",
  "emit",
  "label",
]);

// `getCurrentWindow().foo()` and the `const win = getCurrentWindow()` alias.
const called = new Set();
for (const m of ts.matchAll(/getCurrentWindow\(\)\s*\.\s*(\w+)\s*\(/g)) called.add(m[1]);
for (const m of ts.matchAll(/\bwin\s*\.\s*(\w+)\s*\(/g)) called.add(m[1]);
for (const n of notCommands) called.delete(n);

check(
  "the window API is actually being called",
  called.size > 0,
  "found no getCurrentWindow() calls — this test is matching nothing and would pass whatever the capability file said"
);

const kebab = (s) => s.replace(/[A-Z]/g, (c) => `-${c.toLowerCase()}`);
const allowed = new Set(caps.permissions);
for (const name of [...called].sort()) {
  const perm = `core:window:allow-${kebab(name)}`;
  check(
    `${name}() is allowed`,
    allowed.has(perm),
    `add "${perm}" to src-tauri/capabilities/default.json — without it the call is rejected in the webview and the feature silently does nothing`
  );
}

if (failed) {
  console.log(`${failed} capability test(s) failed`);
  process.exit(1);
}
console.log("all capability tests passed");
