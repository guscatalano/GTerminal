import { execFileSync } from "child_process";
import { readFileSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..");

// The suites `npm test` runs, taken from `npm test` itself rather than by
// globbing this directory.
//
// Globbing was wrong in a way that only showed up on a clean checkout: it
// picked up coverage-report.mjs, which is a reporter and not a suite, and
// which exits nonzero when there is no coverage data yet. Locally there
// always was some left over from a previous run, so it passed; in CI there
// was none, it "failed", and that took the whole coverage job down with it
// - the Rust half never ran at all.
//
// Reading the list from package.json also means this cannot drift: a suite
// added to `npm test` is measured, and one that is not in `npm test` is
// not silently being counted as covered.
const testScript = JSON.parse(readFileSync(join(root, "package.json"), "utf8")).scripts.test;
const suites = [...testScript.matchAll(/node\s+tests\/([\w-]+)\.mjs/g)].map((m) => `${m[1]}.mjs`);

let failed = [];
for (const f of suites) {
  try {
    execFileSync(process.execPath, [join(here, f)], { stdio: "inherit" });
  } catch {
    failed.push(f);
  }
}

console.log("");
console.log(`ran ${suites.length} node suite(s)`);
if (failed.length) {
  console.log(`failed: ${failed.join(", ")}`);
  process.exit(1);
}
