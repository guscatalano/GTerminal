// Stylesheet invariants that silently disable features when broken.
// Run: node tests/styles.mjs
import { readFileSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";

const here = dirname(fileURLToPath(import.meta.url));
const css = readFileSync(join(here, "..", "src", "styles.css"), "utf8");
const ts = readFileSync(join(here, "..", "src", "main.ts"), "utf8");

let failed = 0;
function check(name, ok, detail = "") {
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${ok ? "" : `: ${detail}`}`);
  if (!ok) failed++;
}

// The browser's [hidden] rule is a UA style, and any author `display`
// outranks it. Without a global override, every element that has a display
// of its own ignores the attribute — which is how settings search broke:
// rows are display:flex, so `el.hidden = true` did nothing at all. The
// failure is invisible (no error, feature just does nothing), so it is
// worth pinning.
const globalHidden = /(^|\})\s*\[hidden\]\s*\{[^}]*display\s*:\s*none\s*!important/m.test(css);
check(
  "[hidden] is forced to display:none globally",
  globalHidden,
  "add `[hidden] { display: none !important }` — without it, any element with its own display ignores .hidden"
);

// Anything the code hides via the attribute depends on that rule; if the
// count ever drops to zero the rule above is dead weight and this test
// should go with it.
const hides = [...ts.matchAll(/\.hidden\s*=\s*(?!=)/g)].length;
check(`the code sets .hidden somewhere (${hides} sites)`, hides > 0, "no .hidden assignments found");

// ── the box FitAddon measures ──────────────────────────────────────────
// FitAddon picks the row count from getComputedStyle(parent).height and
// subtracts only the *terminal element's* padding. .pane-body is that
// parent, and its padding is the parent's, so the addon never sees it.
// Under the global `* { box-sizing: border-box }` the reported height
// already includes that padding, so the terminal is handed it as usable
// space it does not have — measured live, that was 35 rows of 19px laid
// out in a 648px box, with the last row sliced by the status bar.
//
// So: if .pane-body has padding, it must be content-box. Widening the
// padding does not help — it is the thing being double-counted, and
// making it bigger makes the overflow bigger.
const paneBody = /\.pane-body\s*\{([^}]*)\}/.exec(css)?.[1] ?? "";
check(".pane-body rule exists", paneBody !== "", "could not find the .pane-body rule");
const hasPadding = /(^|[;{\s])padding(-top|-bottom)?\s*:/.test(paneBody);
const isContentBox = /box-sizing\s*:\s*content-box/.test(paneBody);
check(
  ".pane-body padding is not double-counted by FitAddon",
  !hasPadding || isContentBox,
  "it has padding, so it needs `box-sizing: content-box` — under border-box the height FitAddon reads includes that padding and the terminal overflows by exactly that many pixels"
);

// The fit is measured from .pane-body, so that is the box whose resizes
// matter. Watching .pane instead misses everything that resizes the body
// without resizing the pane — the status bar appearing during startup, a
// name bar appearing when a tab splits — and leaves a stale row count.
check(
  "the resize observer watches the box the fit is measured from",
  /observer\.observe\(paneBody\)/.test(ts),
  "expected observer.observe(paneBody); watching .pane misses resizes of the body itself"
);

// ── the tab strip when maximized ───────────────────────────────────────
// Reported as "if the window is maximized i miss them frequently". A
// maximized window's client area starts at the monitor's top edge, so the
// tab row's 6px of top padding sits exactly where a mouse flung at the top
// of the screen stops — a dead strip over the tabs. The rule that gives it
// back is invisible when it breaks: the tabs still work, they are just a
// few pixels lower than the edge you aimed at.
const rowPad = /#tabbar-row\s*\{([^}]*)\}/.exec(css)?.[1] ?? "";
check("#tabbar-row rule exists", rowPad !== "", "could not find the #tabbar-row rule");
const maxRow = /#app\.maximized\s+#tabbar-row\s*\{([^}]*)\}/.exec(css)?.[1] ?? "";
check(
  "maximized, the tab row gives up its top padding",
  /padding(-top)?\s*:\s*0/.test(maxRow),
  "expected `#app.maximized #tabbar-row { padding-top: 0 }` — without it the top 6px of a maximized window is padding, not tab"
);
// The window controls cancel that padding with a negative margin so they
// reach the edge. Left in once the padding is gone, they hang above the
// row and lose the top of their own hit box — the same bug, moved.
const ctlPull = /\.win-ctl\s*\{([^}]*)\}/.exec(css)?.[1] ?? "";
const pulls = /margin\s*:\s*-/.test(ctlPull) || /margin-top\s*:\s*-/.test(ctlPull);
const maxCtl = /#app\.maximized[^{]*\.win-ctl[^{]*\{([^}]*)\}/.exec(css)?.[1] ?? "";
check(
  "and the window controls stop pulling themselves above it",
  !pulls || /margin(-top)?\s*:\s*0/.test(maxCtl),
  ".win-ctl has a negative top margin to cancel that padding; with the padding gone it needs zeroing under #app.maximized"
);
// The class is the whole mechanism. It has to follow the window rather
// than only the button, since Win+Up, a double-click on the drag region
// and a window restored maximized all get there without one.
check(
  "the maximized class follows the window",
  /classList\.toggle\("maximized"/.test(ts) && /onResized\(/.test(ts),
  'expected classList.toggle("maximized", …) driven by window.onResized — a class set only by the maximize button misses Win+Up and a window that opened maximized'
);

// Clicking a chrome button leaves DOM focus on it, and the next Enter
// presses it again: hit maximize, press Enter, and the window unmaximizes
// itself. Reported exactly that way.
check(
  "the maximize button hands the keyboard back to the terminal",
  /toggleMaximize\(\)[\s\S]{0,200}?handBackToTerminal\(\)/.test(ts),
  "expected handBackToTerminal() after win.toggleMaximize() — otherwise focus stays on the button and Enter toggles it back"
);

if (failed) {
  console.log(`${failed} style test(s) failed`);
  process.exit(1);
}
console.log("all style tests passed");
