import { execFileSync } from "child_process";
import { readFileSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..");

// The render suites: the ones that drive a real browser to read back what
// was actually drawn. They are found, not listed, by which suites `npm
// test` runs load the CDP helper edge-render.mjs - so a new render suite is
// in this matrix the moment it is in `npm test`, and this file never drifts
// (the same reasoning run-node.mjs uses to read its list from package.json).
const testScript = JSON.parse(readFileSync(join(root, "package.json"), "utf8")).scripts.test;
const all = [...testScript.matchAll(/node\s+tests\/([\w-]+)\.mjs/g)].map((m) => `${m[1]}.mjs`);
const suites = all.filter((f) => readFileSync(join(here, f), "utf8").includes("edge-render.mjs"));

// Which engine these run against. GT_BROWSER, when set, is the whole point
// of this runner: point every render suite at one pinned browser so a CI
// matrix can sweep Stable/Beta/Dev, or a daily job can catch the newest
// build regressing us. Unset, each suite falls back to the system Edge it
// always used.
const browser = process.env.GT_BROWSER || "(system Edge)";
console.log(`render suites against: ${browser}`);
console.log("");

let failed = [];
for (const f of suites) {
  try {
    execFileSync(process.execPath, [join(here, f)], { stdio: "inherit" });
  } catch {
    failed.push(f);
  }
}

console.log("");
console.log(`ran ${suites.length} render suite(s) against ${browser}`);
if (failed.length) {
  console.log(`failed: ${failed.join(", ")}`);
  process.exit(1);
}
