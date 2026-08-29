// Does the shortcut list still describe the app?
// Run: node tests/shortcuts.mjs
//
// A documented shortcut that no longer exists is worse than an
// undocumented one: it sends someone pressing keys that do nothing and
// concluding the app is broken. Each row names a fragment of the code
// implementing it, and this checks that code is still there - so removing
// a shortcut without removing its row fails here rather than quietly
// leaving a lie on the settings page.
import { readFileSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";
import { SHORTCUTS, allShortcuts } from "../src/shortcuts.ts";

const here = dirname(fileURLToPath(import.meta.url));
const src = ["main.ts", "keys.ts", "restore.ts", "layout.ts", "blocks.ts"]
  .map((f) => readFileSync(join(here, "..", "src", f), "utf8"))
  .join("\n");

let failed = 0;
function check(name, ok, detail = "") {
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${ok ? "" : `: ${detail}`}`);
  if (!ok) failed++;
}

const all = allShortcuts();
check(`the list is not empty (${all.length} shortcuts)`, all.length > 0, "nothing documented");

// The whole point of the handler field.
for (const s of all) {
  check(
    `${s.keys} — ${s.what}`,
    src.includes(s.handler),
    `nothing in src/ contains ${JSON.stringify(s.handler)}, so this row documents a shortcut that may no longer exist`
  );
}

// Two rows claiming the same chord means one of them is wrong, and the
// reader has no way to tell which.
const seen = new Map();
for (const s of all) {
  if (seen.has(s.keys)) {
    check(`${s.keys} is documented once`, false, `also documented as "${seen.get(s.keys)}"`);
  }
  seen.set(s.keys, s.what);
}
check("no chord is documented twice", seen.size === all.length);

// Groups exist so the settings page can lay them out; an empty one would
// render as a heading with nothing under it.
for (const g of SHORTCUTS) {
  check(`the ${g.title} group has entries`, g.items.length > 0, "empty group");
}

// The README table and this list are two audiences for one set of facts.
// It does not have to list everything, but what it lists must be real.
const readme = readFileSync(join(here, "..", "README.md"), "utf8");
// A row like "Ctrl+1 … Ctrl+8" documents every chord in that range, so
// expand it rather than reporting each one as undocumented.
const documented = new Set();
for (const s of all) {
  const keys = s.keys.replace(/\s/g, "");
  documented.add(keys);
  // "Ctrl+1…Ctrl+8" - the prefixes either side must match, or two
  // unrelated chords would be expanded into a range between them.
  const range = /^(.*?)(\d)…(.*?)(\d)$/.exec(keys);
  if (range && range[1] === range[3]) {
    for (let n = Number(range[2]); n <= Number(range[4]); n++) documented.add(range[1] + n);
  }
}
const inReadme = [...readme.matchAll(/`(Ctrl\+[^`]+|Alt\+[^`]+|F11)`/g)].map((m) =>
  m[1].replace(/\s/g, "")
);
const strays = inReadme.filter((k) => !documented.has(k) && !k.includes("…"));
check(
  "every chord in the README is one this list knows",
  strays.length === 0,
  `the README mentions ${strays.join(", ")}, which the shortcut list does not have — one of the two is out of date`
);

if (failed) {
  console.log(`${failed} shortcut test(s) failed`);
  process.exit(1);
}
console.log("all shortcut tests passed");
