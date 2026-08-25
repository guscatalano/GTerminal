// Which state belongs to a window, and which to the app.
// Run: node tests/windows.mjs
//
// Two windows share one localStorage. The failure this guards against is
// silent: open a second window and the first one's tab order and pane
// layouts are quietly overwritten by whichever saved last.
import { storageKey, keysToClear, isPerWindow, FIRST_WINDOW } from "../src/windows.ts";

let failed = 0;
function check(name, got, want) {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${ok ? "" : `: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`}`);
  if (!ok) failed++;
}

// ── whose key is it ────────────────────────────────────────────────────
// The first window keeps the names it has always used: an install that
// has been running for months must not lose its layout to this feature.
check("the first window keeps the plain key", storageKey("gterm-layouts", FIRST_WINDOW), "gterm-layouts");
check("a second window gets its own", storageKey("gterm-layouts", "w2"), "gterm-layouts::w2");
check("and so does a third", storageKey("gterm-order", "w3"), "gterm-order::w3");
// Global state is the same key everywhere, or a rename in one window
// would not show in another.
check("titles are shared", storageKey("gterm-titles", "w2"), "gterm-titles");
check("so is the clipboard history", storageKey("gterm-cliphist", "w9"), "gterm-cliphist");
check("and the sidebar preference", storageKey("gterm-sidebar", "w2"), "gterm-sidebar");
// Two windows: different layout, same titles.
check(
  "two windows differ where it matters and agree where it does not",
  [
    storageKey("gterm-layouts", "w2") !== storageKey("gterm-layouts", "w3"),
    storageKey("gterm-titles", "w2") === storageKey("gterm-titles", "w3"),
  ],
  [true, true]
);

// ── what a closing window takes with it ────────────────────────────────
{
  const all = [
    "gterm-order", "gterm-layouts", "gterm-titles", "gterm-hidden",
    "gterm-order::w2", "gterm-layouts::w2", "gterm-order::w3",
  ];
  // A window may only clear its own, or closing one would tidy away the
  // tab order of a window still open.
  check("a second window clears only its own", keysToClear(all, "w2").sort(), ["gterm-layouts::w2", "gterm-order::w2"]);
  check("and never a global key", keysToClear(all, "w2").includes("gterm-titles"), false);
  check("nor another window's", keysToClear(all, "w2").includes("gterm-order::w3"), false);
  // The first window's keys are not a leak: they are what start-up reads
  // to put the tabs back. Clearing them on close would make closing the
  // app the same as discarding the layout.
  check("the first window clears nothing", keysToClear(all, FIRST_WINDOW), []);
}

check("layouts are per window", isPerWindow("gterm-layouts"), true);
check("hidden sessions are not", isPerWindow("gterm-hidden"), false);

if (failed) {
  console.log(`${failed} window test(s) failed`);
  process.exit(1);
}
console.log("all window tests passed");
