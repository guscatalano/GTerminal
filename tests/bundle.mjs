// The shipped bundle must not assign to names that do not exist.
// Run: node tests/bundle.mjs
//
// This exists because of one line in one function. xterm.js is built from
// TypeScript enums, which compile to
//
//   var E; (function (E) { E[E.X = 0] = "X"; })(E || (E = {}));
//
// and when nothing reads the enum, a minifier is entitled to drop the
// declaration. esbuild dropped it and kept the argument, producing
// `(void 0 || (i = {}))` - an assignment to a name that no longer exists.
// Bundles are modules, modules are strict mode, and strict mode throws
// ReferenceError rather than quietly making a global.
//
// The function it landed in was requestMode, which replies to a program
// asking what this terminal supports. A throw there abandons the rest of
// the parser's chunk, so everything written after the question is lost,
// and a program that redraws its whole screen shows nothing new while
// appearing to run fine.
//
// Nothing in this project sends that sequence and the console host
// answers the ones programs send, so it never surfaced here. It surfaced
// in a user's log.
import { readdirSync, readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { execSync } from "node:child_process";

const dir = "dist/assets";
if (!existsSync(dir)) {
  console.log("no dist yet - building it, since there is nothing to check otherwise");
  execSync("npx vite build", { stdio: "ignore" });
}

let failed = 0;
const files = readdirSync(dir).filter((n) => n.endsWith(".js"));
if (!files.length) {
  console.log("FAIL bundle: no javascript in dist/assets");
  process.exit(1);
}

for (const name of files) {
  const src = readFileSync(join(dir, name), "utf8");
  // `(void 0 || (x = {}))` - the argument of an enum wrapper whose
  // declaration was elided. The `void 0` is the tell: had the name
  // survived, the minifier would have written `(x || (x = {}))`.
  const broken = [...src.matchAll(/\(void 0\s*\|\|\s*\(([A-Za-z_$][\w$]*)\s*=\s*\{\}\)\)/g)];
  for (const m of broken) {
    console.log(`FAIL bundle: ${name} assigns to undeclared "${m[1]}" - this throws in strict mode`);
    failed++;
  }
}

if (failed) {
  console.log(`${failed} undeclared assignment(s) in the shipped bundle`);
  process.exit(1);
}
console.log(`all bundle tests passed (${files.length} file(s) checked)`);
