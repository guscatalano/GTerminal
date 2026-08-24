// Whether a control is really on screen, and how that is reported.
// Run: node tests/controls.mjs
//
// Asked in as many words: "I want a way to check if the – button on tabs
// even shows up". Present-but-clipped and not-rendered-at-all look the
// same from the outside and have different fixes, so they are reported
// as different things.
import { controlState, visibilityReport } from "../src/controls.ts";

let failed = 0;
function check(name, got, want) {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${ok ? "" : `: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`}`);
  if (!ok) failed++;
}
const r = (width, right, ownerRight, hidden = false) => ({ width, right, ownerRight, hidden });

check("inside its tab is visible", controlState(r(16, 140, 158)), "visible");
check("flush with the edge still is", controlState(r(16, 158, 158)), "visible");
// Sub-pixel layout must not read as broken.
check("half a pixel over is not cut off", controlState(r(16, 158.4, 158)), "visible");
check("past the edge is clipped", controlState(r(16, 170, 158)), "clipped");
check("display:none is hidden", controlState(r(16, 140, 158, true)), "hidden");
// A zero-width control is not laid out, whatever its coordinates claim.
check("zero width is hidden, not visible", controlState(r(0, 140, 158)), "hidden");

check("nothing to check", visibilityReport([]), "No tabs are open to check.");
check("one tab reads as one", visibilityReport([r(16, 140, 158)]), "Visible on the open tab.");
check("all of them", visibilityReport([r(16, 1, 2), r(16, 1, 2)]), "Visible on all 2 tabs.");
check(
  "cut off everywhere names the cause",
  visibilityReport([r(16, 170, 158), r(16, 170, 158)]),
  "Cut off on every tab — the tabs are too narrow."
);
check(
  "a mix says which is which",
  visibilityReport([r(16, 140, 158), r(16, 170, 158)]),
  "Visible on 1 of 2 tabs, cut off on 1 — those tabs are too narrow."
);
check(
  "turned off is not the same as clipped",
  visibilityReport([r(16, 140, 158, true), r(16, 140, 158, true)]),
  "Not shown on 2 of 2 tabs."
);

if (failed) {
  console.log(`${failed} control test(s) failed`);
  process.exit(1);
}
console.log("all control tests passed");
