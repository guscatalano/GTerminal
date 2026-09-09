// Every visual scene is actually run by a full visual run.
// Run: node tests/scenes.mjs
//
// tests/visual.ps1 is two things at once. Each scene is guarded by
// `if (-not $Only -or $Only -eq "name")`, and a full run does not
// evaluate those guards in one process - it walks an explicit $scenes
// list and spawns a child per name. So a scene can be written, committed,
// reviewed and completely correct, and never execute: the guard is there,
// the name is not in the list, and nothing says so.
//
// That is not hypothetical. tui-dom and tui-fast were added to chase a
// renderer that appeared to drop frames, ran green in a release pipeline,
// and had never run at all - which was only noticed by reading the list
// of scene banners in a log and finding two missing. A test that does not
// run is worse than no test, because it is counted.
//
// Instant, and it runs on every push, unlike the suite it guards.
import { readFileSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";

const here = dirname(fileURLToPath(import.meta.url));
const src = readFileSync(join(here, "visual.ps1"), "utf8");

let failed = 0;
function check(name, ok, detail = "") {
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${ok ? "" : `: ${detail}`}`);
  if (!ok) failed++;
}

// The list a full run walks.
const listed = new Set(
  [...(src.match(/^\$scenes = @\((.*)\)$/m)?.[1] ?? "").matchAll(/"([^"]+)"/g)].map((m) => m[1])
);
check("the scene list was found", listed.size > 0, "the $scenes assignment stopped matching");

// The scenes that exist, taken from their own guards.
const guarded = new Set(
  [...src.matchAll(/if \(-not \$Only -or \$Only -eq "([^"]+)"\)/g)].map((m) => m[1])
);
check("scene guards were found", guarded.size > 0, "the -Only guard pattern stopped matching");

for (const name of guarded) {
  check(
    `${name} is in the list a full run walks`,
    listed.has(name),
    `tests/visual.ps1 has a scene guarded as "${name}" but $scenes does not name it, so a full run never launches it — add it to $scenes`
  );
}

for (const name of listed) {
  check(
    `${name} has a scene to run`,
    guarded.has(name),
    `$scenes names "${name}" but no guard matches it, so the run spawns a child that does nothing — remove it or fix the name`
  );
}

if (failed) {
  console.log(`${failed} scene test(s) failed`);
  process.exit(1);
}
console.log(`all scene tests passed (${listed.size} scenes)`);
