// Invariants of the tab badge list.
// Run: node tests/badges.mjs
//
// The list is a hand-maintained table of a hundred-odd entries, and both
// ways it can break are silent. A repeated emoji appears twice in the
// picker and looks like a rendering bug. A keyword with a capital letter
// in it can never be found, because the picker lowercases what you type
// and then asks whether the keyword string contains it - so the badge is
// there, and searching for it says there is nothing.
import { readFileSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";

const here = dirname(fileURLToPath(import.meta.url));
const src = readFileSync(join(here, "..", "src", "main.ts"), "utf8");

let failed = 0;
function check(name, ok, detail = "") {
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${ok ? "" : `: ${detail}`}`);
  if (!ok) failed++;
}

const block = src.slice(src.indexOf("const BADGE_CHOICES"));
const entries = [...block.slice(0, block.indexOf("\n];")).matchAll(/\["([^"]+)", "([^"]+)"\]/g)].map(
  (m) => ({ emoji: m[1], keys: m[2] })
);

check("the badge list was found", entries.length > 20, `only parsed ${entries.length} entries`);

const seen = new Map();
const dupes = [];
for (const { emoji } of entries) {
  if (seen.has(emoji)) dupes.push(emoji);
  seen.set(emoji, true);
}
check("no badge appears twice", dupes.length === 0, `repeated: ${dupes.join(" ")}`);

const shouty = entries.filter((e) => e.keys !== e.keys.toLowerCase());
check(
  "every keyword is lowercase",
  shouty.length === 0,
  `${shouty.map((e) => `${e.emoji} (${e.keys})`).join(", ")} — the picker lowercases the query, so these can never be found`
);

const bare = entries.filter((e) => !e.keys.trim());
check("every badge has something to search for", bare.length === 0, `${bare.map((e) => e.emoji).join(" ")}`);

// Three badges sit side by side in a strip inside a tab. Anything longer
// than a single glyph and its variation selector is a badge that pushes
// the title out of its own tab.
const wide = entries.filter((e) => [...e.emoji].length > 2);
check(
  "no badge is wider than one glyph",
  wide.length === 0,
  `${wide.map((e) => `${e.emoji} (${[...e.emoji].length} code points)`).join(", ")}`
);

// The picker matches by substring, so these are the searches a person
// actually types. Each one failing would mean a whole category went away
// without anybody noticing.
for (const term of ["python", "rust", "prod", "staging", "merge", "branch", "linux", "docker", "test", "deploy"]) {
  check(`searching "${term}" finds a badge`, entries.some((e) => e.keys.includes(term)));
}

if (failed) {
  console.log(`${failed} badge test(s) failed`);
  process.exit(1);
}
console.log(`all badge tests passed (${entries.length} badges)`);
