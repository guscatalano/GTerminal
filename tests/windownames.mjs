// Naming windows, and which ones a tab can be moved to.
// Run: node tests/windownames.mjs
import { windowName, moveTargets } from "../src/windownames.ts";

let failed = 0;
function check(name, got, want) {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${ok ? "" : `: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`}`);
  if (!ok) failed++;
}

// "main" and "w2" are internal. A menu that offered to move a tab to "w7"
// would be asking about something the user has never seen.
check("the first window is Window 1", windowName("main"), "Window 1");
check("and the others are numbered", windowName("w2"), "Window 2");
check("however far they go", windowName("w11"), "Window 11");
check("anything unexpected shows as itself", windowName("odd-label"), "odd-label");

// Moving a tab to the window it is already in does nothing, so it must
// not be offered - an option that does nothing is a bug report waiting.
check("the current window is not a target", moveTargets(["main", "w2"], "main"), ["w2"]);
check("nor when it is a later one", moveTargets(["main", "w2", "w3"], "w2"), ["main", "w3"]);
check("alone means nowhere to move", moveTargets(["main"], "main"), []);
// Stable order, or the menu reshuffles between openings and the option
// under the pointer changes as you reach for it.
check("the first window leads", moveTargets(["w3", "main", "w2"], "w9"), ["main", "w2", "w3"]);
check("numbered in order, not as text", moveTargets(["w10", "w2", "w9"], "main"), ["w2", "w9", "w10"]);

if (failed) {
  console.log(`${failed} window-name test(s) failed`);
  process.exit(1);
}
console.log("all window-name tests passed");
