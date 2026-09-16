// Where in a transcript a search hit is.
// Run: node tests/histsearch.mjs
import { MAX_HITS_PER_SESSION, excerpt, findHits } from "../src/histsearch.ts";

let failed = 0;
function check(name, got, want) {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${ok ? "" : `: got ${JSON.stringify(got)}, wanted ${JSON.stringify(want)}`}`);
  if (!ok) failed++;
}

const transcript = [
  "PS C:\\repo> cargo build",
  "   Compiling gterminal v0.2.0",
  "error[E0425]: cannot find value `foo` in this scope",
  "  --> src/main.rs:12:5",
  "PS C:\\repo> ",
].join("\r\n");

check(
  "a hit names the line it is on",
  findHits(transcript, "cannot find").map((h) => h.line),
  [2]
);
check(
  "and where in the line",
  findHits(transcript, "cannot find")[0].at,
  "error[E0425]: ".length
);
check("the line comes back whole, trailing space gone", findHits("hit here   \nmiss", "hit")[0].text, "hit here");
// "Did I see this word last week" is not a question anybody asks with
// the case they saw it in.
check("matching ignores case", findHits(transcript, "COMPILING").length, 1);
check("and so does the needle's own whitespace", findHits(transcript, "  cargo  ").length, 1);
check("nothing for nothing", findHits(transcript, "   "), []);
check("nothing for a word that is not there", findHits(transcript, "zebra"), []);
check("CRLF and LF split the same", findHits("a\r\nb\nc", "c")[0].line, 2);
// A bare CR is a repaint, not a line. PSReadLine redraws the command as
// it is typed, and reading each frame as a line turned one command into
// a smear of half-typed copies in the results.
check(
  "a repainted line is read as its last frame",
  findHits("PS> e\rPS> ec\rPS> echo NEEDLE\nNEEDLE", "needle").map((h) => [h.line, h.text]),
  [[0, "PS> echo NEEDLE"], [1, "NEEDLE"]]
);

// A session mentioning the word four hundred times is one result with
// noise in it, not four hundred results.
const noisy = Array.from({ length: 400 }, (_, i) => `line ${i} has the word`).join("\n");
check("hits per session are capped", findHits(noisy, "word").length, MAX_HITS_PER_SESSION);
check("and the cap keeps the earliest", findHits(noisy, "word")[0].line, 0);

// Long lines are cut around the match, not at the front - the front of
// a minified stack trace is the part that says nothing.
const long = "x".repeat(200) + "NEEDLE" + "y".repeat(200);
const hit = findHits(long, "needle")[0];
const shown = excerpt(hit, 6, 60);
check("a long line is cut to a window", shown.length <= 62, true);
check("that still contains the match", shown.includes("NEEDLE"), true);
check("and says both ends were cut", shown.startsWith("…") && shown.endsWith("…"), true);
check("a short line is not touched", excerpt({ line: 0, text: "short", at: 0 }, 5), "short");
// A match near the start keeps the start, and only the tail is cut.
const early = "NEEDLE" + "z".repeat(300);
check("a match at the front keeps the front", excerpt(findHits(early, "needle")[0], 6, 40).startsWith("NEEDLE"), true);

if (failed) {
  console.log(`${failed} history-search test(s) failed`);
  process.exit(1);
}
console.log("all history-search tests passed");
