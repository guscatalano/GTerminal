// Command block parsing: which rows belong to which command, and how it
// went. Run: node tests/blocks.mjs
//
// The cases here are the ones from docs/command-blocks.md. Most are about
// telling "we don't know" apart from "it succeeded" — a shell that reports
// a bare 133;D, a prompt that closes nothing, a command still running.
// Getting those wrong paints a green scrollbar over a failed build.
import { BlockTracker, parseExit } from "../src/blocks.ts";

let failed = 0;
function check(name, got, want) {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${ok ? "" : `: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`}`);
  if (!ok) failed++;
}

// A stand-in for xterm's IMarker.
const mk = (line) => ({ line, isDisposed: false });
const dead = (line) => ({ line, isDisposed: true });

// ── parsing ────────────────────────────────────────────────────────────
check("exit code parses", parseExit(["3"]), 3);
check("zero is zero", parseExit(["0"]), 0);
// A bare `133;D` means finished-but-unsaid. Reading it as 0 would report
// every such command as a success.
check("a missing code is unknown, not success", parseExit([]), undefined);
check("a non-numeric code is unknown", parseExit(["abc"]), undefined);
check("a negative-looking code is unknown", parseExit(["-1"]), undefined);

// ── one command ────────────────────────────────────────────────────────
{
  const t = new BlockTracker();
  t.feed("A", mk(10));
  t.feed("D;0", mk(14));
  const b = t.all();
  check("one block", b.length, 1);
  check("it closed", b[0].closed, true);
  check("it succeeded", b[0].exit, 0);
  check("no failures", t.failures().length, 0);
}
{
  const t = new BlockTracker();
  t.feed("A", mk(10));
  t.feed("B", mk(10));
  t.feed("D;3", mk(20));
  check("exit 3 recorded", t.all()[0].exit, 3);
  check("counted as a failure", t.failures().length, 1);
  check("input row recorded", t.all()[0].input.line, 10);
}

// ── the awkward ones ───────────────────────────────────────────────────
{
  // The very first prompt of a session closes nothing; without a guard it
  // invents a block above the first command.
  const t = new BlockTracker();
  t.feed("D;0", mk(1));
  check("a D before any A is ignored", t.all().length, 0);
}
{
  const t = new BlockTracker();
  t.feed("A", mk(5));
  const b = t.all()[0];
  check("an unfinished command is open", b.closed, false);
  check("and its exit is unknown, not zero", b.exit, undefined);
  check("an open block is not a failure", t.failures().length, 0);
}
{
  const t = new BlockTracker();
  t.feed("A", mk(5));
  t.feed("D", mk(9)); // finished, code unsaid
  const b = t.all()[0];
  check("a bare D closes the block", b.closed, true);
  check("with an unknown exit", b.exit, undefined);
  check("unknown is not marked as a failure", t.failures().length, 0);
}
{
  // Two prompts with no D between them: the first must close as unknown
  // rather than swallowing the second command's rows.
  const t = new BlockTracker();
  t.feed("A", mk(5));
  t.feed("A", mk(9));
  t.feed("D;0", mk(12));
  const b = t.all();
  check("both prompts made blocks", b.length, 2);
  check("the abandoned one closed", b[0].closed, true);
  check("with no exit code", b[0].exit, undefined);
  check("the second one is intact", b[1].exit, 0);
}

// ── queries ────────────────────────────────────────────────────────────
const three = () => {
  const t = new BlockTracker();
  t.feed("A", mk(10));
  t.feed("D;0", mk(20));
  t.feed("A", mk(20));
  t.feed("D;1", mk(30));
  t.feed("A", mk(30));
  t.feed("D;0", mk(40));
  return t;
};
{
  const t = three();
  check("a row inside a block finds it", t.blockAt(15).prompt.line, 10);
  check("the prompt row itself belongs to its block", t.blockAt(10).prompt.line, 10);
  check("the last row before the next prompt", t.blockAt(19).prompt.line, 10);
  check("the next prompt row starts the next block", t.blockAt(20).prompt.line, 20);
  check("a row above every prompt belongs to nothing", t.blockAt(2), undefined);

  // Up from inside a block goes to that block's own prompt; up again from
  // the prompt row goes to the one before.
  check("up from mid-block goes to its prompt", t.prevPrompt(15), 10);
  check("up from a prompt goes to the previous one", t.prevPrompt(30), 20);
  check("up from the first prompt stops", t.prevPrompt(10), undefined);
  check("down goes to the next prompt", t.nextPrompt(15), 20);
  check("down from a prompt skips to the next", t.nextPrompt(20), 30);
  check("down from the last prompt stops", t.nextPrompt(30), undefined);

  check("only the failure is listed", t.failures().length, 1);
  check("and it is the right one", t.failures()[0].exit, 1);
  check("last closed is the newest", t.lastClosed().prompt.line, 30);
}

// ── scrollback trimming ────────────────────────────────────────────────
{
  // Rows that scroll out of the buffer take their blocks with them. If
  // they lingered, navigation would jump to rows that no longer exist.
  const t = new BlockTracker();
  const gone = dead(10);
  t.feed("A", gone);
  t.feed("D;1", mk(20));
  t.feed("A", mk(20));
  t.feed("D;0", mk(30));
  check("the trimmed block is dropped", t.all().length, 1);
  check("and stops being reported as a failure", t.failures().length, 0);
  check("navigation ignores it", t.prevPrompt(25), 20);
}

if (failed) {
  console.log(`${failed} block test(s) failed`);
  process.exit(1);
}
console.log("all block tests passed");
