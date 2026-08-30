// Every node suite, in one process tree.
// Run: npm run test:node
//
// `npm test` runs these as a chain of separate commands, which is right
// there: the first failure stops the run. This exists so coverage can wrap
// them all in a single measurement - NODE_V8_COVERAGE is inherited by
// children, so one c8 around this collects every suite.
//
// It keeps going after a failure on purpose. A coverage run that stops at
// the first broken suite reports the coverage of everything before it as
// if that were the whole picture.
import { execFileSync } from "child_process";
import { readdirSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";

const here = dirname(fileURLToPath(import.meta.url));

// Everything except the helpers: run-node itself, and anything under
// fixtures or lib.
const suites = readdirSync(here)
  .filter((f) => f.endsWith(".mjs") && f !== "run-node.mjs")
  .sort();

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
