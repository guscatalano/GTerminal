// When a click on a menu row counts as choosing it.
// Run: node tests/menus.mjs
//
// Reported from real use: "if you hover over Paste it pastes, you need to
// actually click on it". Nothing fires on hover — but a menu sits under
// the pointer that opened it, so a stray release lands on its first row
// and looks exactly like that.
import { activates } from "../src/menus.ts";

let failed = 0;
function check(name, got, want) {
  const ok = got === want;
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${ok ? "" : `: got ${got}, want ${want}`}`);
  if (!ok) failed++;
}

// The ordinary case: you press on the row, a moment after the menu opened.
check("a deliberate press chooses the item", activates(true, 900), true);

// The release of the gesture that opened the menu. No press ever landed
// on the row, so this is not a choice however long the menu has been up.
check("a release with no press on the row does not", activates(false, 900), false);
check("and still does not, however late it arrives", activates(false, 60_000), false);

// A press on the row, but within the arming window — it belongs to
// whatever opened the menu, not to the row that appeared under it.
check("a press too soon after opening does not", activates(true, 10), false);
check("nor right at the edge below the threshold", activates(true, 249), false);
check("at the threshold it counts", activates(true, 250), true);
check("a custom window is respected", activates(true, 300, 500), false);

// A menu with no recorded opening time has been there since before anyone
// reached for it — treating that as "too soon" would make it unclickable.
check("an unarmed menu still works", activates(true, Number.NaN), true);
check("and an unarmed menu still needs a press", activates(false, Number.NaN), false);

if (failed) {
  console.log(`${failed} menu test(s) failed`);
  process.exit(1);
}
console.log("all menu tests passed");
