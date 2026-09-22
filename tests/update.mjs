// Store builds learn about updates, and open the Store to get them.
// Run: node tests/update.mjs
//
// A Store install correctly refuses to install an MSI over itself, but it
// was also silent about updates entirely — so a Store user sat on an old
// version with no way to know a newer one shipped. These pin the two ends
// of the fix: the check now runs for packaged builds too (installing still
// refuses), and the settings page shows the available version with a
// one-click Store link. Shape checks, since the check itself is a network
// call gated on a real package identity.
import { readFileSync } from "fs";

let failed = 0;
function check(name, ok, detail = "") {
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${ok ? "" : `: ${detail}`}`);
  if (!ok) failed++;
}

const main = readFileSync(new URL("../src/main.ts", import.meta.url), "utf8");
const lib = readFileSync(new URL("../src-tauri/src/lib.rs", import.meta.url), "utf8");

// ── the backend: check for packaged, install still refuses ─────────────
// update_check must no longer bail outright for a packaged build — that
// silence was the bug. It keys off `packaged` and only skips the
// auto/pin controls for it, which are installer concepts.
check(
  "update_check runs for packaged builds",
  /let packaged = package_family_name\(\)\.is_some\(\);/.test(lib) &&
    /if !packaged && !cfg\.get\("update_auto"\)/.test(lib),
  "update_check should compute `packaged` and only skip auto/pin for it, not return None"
);
// But installing over a Store app must still be refused — that is the
// Store's job, and running an MSI over it makes a second copy.
check(
  "update_install still refuses a Store install",
  /fn update_install[\s\S]{0,200}!update::updates_supported\(package_family_name\(\)\.is_some\(\)\)[\s\S]{0,120}Store install/.test(lib),
  "update_install must still return an error for packaged builds"
);

// ── the frontend: notice + one-click Store, for packaged ───────────────
check(
  "packaged builds get the available version from the check",
  // Two callers now: announceUpdate (the dot) and the packaged Updates
  // branch. Before, the packaged branch was a passive note that asked
  // nothing, so there was only the one.
  (main.match(/invoke<UpdateVersion \| null>\("update_check"\)/g) ?? []).length >= 2 &&
    /if \(!status\.supported\)/.test(main),
  "the packaged Updates branch should call update_check to learn the available version"
);
check(
  "and a one-click Update in Microsoft Store",
  /Update in Microsoft Store/.test(main) && /ms-windows-store:\/\/pdp\/\?PFN=/.test(main),
  "the packaged branch should deep-link to the Store by package family name"
);
check(
  "which needs the package family name",
  /invoke<string \| null>\("package_family_name"\)/.test(main),
  "the Store deep-link is built from package_family_name"
);
check(
  "and it reassures that closing keeps the shells",
  /Closing GTerminal keeps your shells running/.test(main),
  "the packaged Updates note should say sessions survive a close-to-update"
);

if (failed) {
  console.log(`${failed} update test(s) failed`);
  process.exit(1);
}
console.log("all update tests passed");
