// Turn the raw coverage output into a report that says something true.
// Run: node tests/coverage-report.mjs   (after tests/coverage.ps1 has run)
//
// The headline number needs care in this repository, because the naive one
// is actively misleading. Measured across every node suite, the extracted
// modules sit at 92-100% and main.ts at 0%, which averages to about 10%.
// That 10% does not mean the UI is untested: main.ts is 9,000 lines of
// webview code exercised by thirty-five visual scenes that drive a real
// window, and a coverage tool watching node cannot see any of it. Reported
// as one number, it would punish the project for testing its UI end to end
// instead of against mocks, and push whoever read it toward writing worse
// tests.
//
// So this reports the parts separately and names what is not measured.
import { readFileSync, existsSync, appendFileSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..");

/// Files whose coverage this measurement genuinely cannot see, and why.
/// Listed rather than filtered out silently - "not measured here" and
/// "not tested" are different claims and the report has to tell them
/// apart.
const NOT_MEASURED_HERE = [
  {
    file: "src/main.ts",
    by: "the visual suite — 35 scenes driving a real window, and tests/typing.ps1",
    why: "a coverage tool watching node cannot see a webview",
  },
];

/// The Rust half has the same problem and no clean way to state it
/// per-file, because the untested and the unmeasurable live in the same
/// files: mux.rs is part daemon (exercised hard by lifecycle.ps1, and
/// invisible here) and part library (unit-tested). So it is said once,
/// under the table, rather than pretended away.
const RUST_CAVEAT =
  "The Tauri command layer and the window are exercised by the visual " +
  "scenes and are not counted above - nothing here runs a window. The " +
  "daemon IS counted: tests/lifecycle.ps1 and tests/typing.ps1 run against " +
  "an instrumented binary, which is why mux.rs reads what it does. That " +
  "took some getting: an instrumented process writes its .profraw from an " +
  "exit handler and every suite stops the daemon with taskkill /F, so its " +
  "counters were collected and thrown away on every run. It now flushes " +
  "them itself (mux::flush_coverage, #[cfg(coverage)] only). A low number " +
  "here still means \"not reachable from a unit test or the E2E suites\", " +
  "which is not the same as untested. The denominator is not stable " +
  "either: what gets instrumented depends on what the tests keep alive, so " +
  "read these as a picture of what is reachable, not as a trend line.";

const pct = (c, t) => (t === 0 ? 0 : (100 * c) / t);
const bar = (p) => {
  const n = Math.round(p / 5);
  return "█".repeat(n) + "░".repeat(20 - n);
};

function tsCoverage() {
  const p = join(root, "coverage", "ts", "coverage-summary.json");
  if (!existsSync(p)) return null;
  const raw = JSON.parse(readFileSync(p, "utf8"));
  const rows = Object.entries(raw)
    .filter(([k]) => k !== "total")
    .map(([k, v]) => [k.split(/[\\/]/).slice(-1)[0], v]);
  const excluded = new Set(NOT_MEASURED_HERE.map((e) => e.file.split("/").pop()));
  const measured = rows.filter(([f]) => !excluded.has(f));
  const skipped = rows.filter(([f]) => excluded.has(f));
  const covered = measured.reduce((n, [, v]) => n + v.lines.covered, 0);
  const total = measured.reduce((n, [, v]) => n + v.lines.total, 0);
  return { measured, skipped, covered, total };
}

/// lcov is what cargo-llvm-cov writes; DA lines are "line number,hits".
function rustCoverage() {
  const p = join(root, "coverage", "rust", "lcov.info");
  if (!existsSync(p)) return null;
  const text = readFileSync(p, "utf8");
  const files = [];
  let file = null;
  let hit = 0;
  let found = 0;
  for (const line of text.split(/\r?\n/)) {
    if (line.startsWith("SF:")) {
      file = line.slice(3).split(/[\\/]/).slice(-1)[0];
      hit = 0;
      found = 0;
    } else if (line.startsWith("DA:")) {
      const [, hits] = line.slice(3).split(",");
      found++;
      if (Number(hits) > 0) hit++;
    } else if (line === "end_of_record" && file) {
      files.push([file, { covered: hit, total: found }]);
      file = null;
    }
  }
  const covered = files.reduce((n, [, v]) => n + v.covered, 0);
  const total = files.reduce((n, [, v]) => n + v.total, 0);
  return { files, covered, total };
}

const out = [];
const say = (s = "") => out.push(s);

say("## Coverage");
say("");

const ts = tsCoverage();
const rs = rustCoverage();

if (ts) {
  say(`### TypeScript — ${pct(ts.covered, ts.total).toFixed(1)}% of lines`);
  say("");
  say("| Module | Lines | Covered |");
  say("| --- | --: | --: |");
  for (const [f, v] of ts.measured.sort((a, b) => pct(a[1].lines.covered, a[1].lines.total) - pct(b[1].lines.covered, b[1].lines.total))) {
    say(`| \`${f}\` | ${v.lines.total} | ${pct(v.lines.covered, v.lines.total).toFixed(0)}% ${bar(pct(v.lines.covered, v.lines.total))} |`);
  }
  say("");
}

if (rs) {
  say(`### Rust — ${pct(rs.covered, rs.total).toFixed(1)}% of lines`);
  say("");
  say("| File | Lines | Covered |");
  say("| --- | --: | --: |");
  for (const [f, v] of rs.files.sort((a, b) => pct(a[1].covered, a[1].total) - pct(b[1].covered, b[1].total))) {
    say(`| \`${f}\` | ${v.total} | ${pct(v.covered, v.total).toFixed(0)}% ${bar(pct(v.covered, v.total))} |`);
  }
  say("");
}

if (ts && ts.skipped.length) {
  say("### Not measured here");
  say("");
  for (const [f, v] of ts.skipped) {
    const why = NOT_MEASURED_HERE.find((e) => e.file.endsWith(f))?.by ?? "";
    say(`- \`${f}\` (${v.lines.total} lines) — covered by ${why}. A coverage tool watching node cannot see a webview, so this reads as 0% and is left out of the number above rather than dragging it down to something untrue.`);
  }
  say("");
}

if (rs) {
  say("> " + RUST_CAVEAT);
  say("");
}

say("<sub>Line coverage. The suites that drive the built binary and a real window are not counted here — see above.</sub>");

const text = out.join("\n");
console.log(text);

// And into the job summary, where anyone looking at the run will see it.
if (process.env.GITHUB_STEP_SUMMARY) {
  appendFileSync(process.env.GITHUB_STEP_SUMMARY, text + "\n");
}

if (!ts && !rs) {
  console.error("no coverage data found - run tests/coverage.ps1 first");
  process.exit(1);
}
