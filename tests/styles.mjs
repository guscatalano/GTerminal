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

if (failed) {
  console.log(`${failed} style test(s) failed`);
  process.exit(1);
}
console.log("all style tests passed");
