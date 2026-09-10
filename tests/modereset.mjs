// The two mode-reset constants have to agree, and every replay has to use one.
// Run: node tests/modereset.mjs
//
// Recorded output gets replayed into a fresh terminal in three places: the
// daemon resurrecting a session, the transcript viewer, and the preview of
// a shell that ended. All three are the same job - and the sequences that
// need cleaning up are the ones a program only writes on its way in.
//
// A program that exits writes the way out too. A program killed by a
// reboot writes none of it, so the recording ends with the alternate
// screen on, the cursor hidden, autowrap off and a scrolling region set,
// and replaying it turns all of that on in a terminal that was just
// created.
//
// The frontend constant is a hand-copy of the Rust one and drifted: it sat
// three sequences behind for as long as those three existed. And the
// ended-session preview - which is precisely what is on screen after a
// reboot - applied no reset at all, while the transcript viewer beside it
// did. Neither was visible from either file alone, which is what this is
// for.
import { readFileSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";

const here = dirname(fileURLToPath(import.meta.url));
const ts = readFileSync(join(here, "..", "src", "main.ts"), "utf8");
const rs = readFileSync(join(here, "..", "src-tauri", "src", "mux.rs"), "utf8");

let failed = 0;
function check(name, ok, detail = "") {
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${ok ? "" : `: ${detail}`}`);
  if (!ok) failed++;
}

// Both constants, as the set of sequences each resets.
const seqs = (text) => new Set([...text.matchAll(/\\x1b(\[[?0-9;]*[a-zA-Z])/g)].map((m) => m[1]));

const viewer = ts.match(/const VIEWER_MODE_RESET =\s*\n?\s*("(?:[^"\\]|\\.)*")/)?.[1];
check("the frontend constant was found", Boolean(viewer), "VIEWER_MODE_RESET stopped matching");

const daemon = rs.match(/const MODE_RESET: &str =\s*\n?\s*("(?:[^"\\]|\\.)*")/)?.[1];
check("the daemon constant was found", Boolean(daemon), "MODE_RESET stopped matching");

if (viewer && daemon) {
  const want = seqs(daemon);
  const got = seqs(viewer);
  const missing = [...want].filter((s) => !got.has(s));
  check(
    "the frontend resets everything the daemon does",
    missing.length === 0,
    `missing ${missing.join(" ")} — a replay in the window would leave those set where the daemon's would not`
  );
  const extra = [...got].filter((s) => !want.has(s));
  check(
    "and nothing the daemon does not",
    extra.length === 0,
    `extra ${extra.join(" ")} — if these are worth resetting, the daemon's replays need them too`
  );
}

// The three sequences a killed program leaves behind, named so that
// trimming one has to be an argument rather than an edit.
for (const [seq, what] of [
  ["[r", "the scrolling region — a terminal that scrolls a band of itself"],
  ["[?7h", "autowrap"],
  ["[?6l", "origin mode"],
  ["[?1049l", "the alternate screen"],
  ["[?25h", "the cursor"],
]) {
  check(`the frontend puts back ${what}`, Boolean(viewer?.includes(seq.replace("[", "\\x1b["))), seq);
}

// Every replay of recorded output has to carry it. A write of recorded
// text with no reset is the bug this file was written for.
const previewWrites = ts.match(/if \(text\) tab\.term\.write\(([^)]*)\)/)?.[1] ?? "";
check(
  "the ended-session preview applies the reset",
  previewWrites.includes("VIEWER_MODE_RESET"),
  `it writes \`${previewWrites}\` — recorded output replayed with no cleanup, which is what is on screen right after a reboot`
);

const viewerWrites = ts.match(/term\.write\(data \+ ([A-Z_]+)\)/)?.[1] ?? "";
check(
  "the transcript viewer applies the reset",
  viewerWrites === "VIEWER_MODE_RESET",
  `it writes \`${viewerWrites}\``
);

if (failed) {
  console.log(`${failed} mode-reset test(s) failed`);
  process.exit(1);
}
console.log("all mode-reset tests passed");
