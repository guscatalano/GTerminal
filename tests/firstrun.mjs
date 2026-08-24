// The first-run theme hint: once, and only for a genuinely new install.
// Run: node tests/firstrun.mjs
import { shouldSuggestThemes } from "../src/firstrun.ts";

let failed = 0;
function check(name, got, want) {
  const ok = got === want;
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${ok ? "" : `: got ${got}, want ${want}`}`);
  if (!ok) failed++;
}

check("a brand new install is told once", shouldSuggestThemes({ fresh: true }), true);
// The whole requirement in one line: never afterwards.
check("and never again after that", shouldSuggestThemes({ fresh: true, shown: true }), false);
// Someone upgrading has a config full of their own choices. Telling them
// the app has themes is an advert, not a welcome.
check("an existing install is not told", shouldSuggestThemes({ fresh: false }), false);
check("nor is one that has already seen it", shouldSuggestThemes({ fresh: false, shown: true }), false);

if (failed) {
  console.log(`${failed} first-run test(s) failed`);
  process.exit(1);
}
console.log("all first-run tests passed");
