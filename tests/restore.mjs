// Which sessions come back, in what order, and Ctrl+<n>.
// Run: node tests/restore.mjs
//
// Getting this wrong is never a crash. It quietly resurrects a tab you
// closed, drops one you wanted, or shuffles your tab strip — the kind of
// thing that erodes trust in a terminal without ever being reportable.
import { adoptable, inSavedOrder, shouldAsk, tabForNumber, sessionState } from "../src/restore.ts";

let failed = 0;
function check(name, got, want) {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${ok ? "" : `: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`}`);
  if (!ok) failed++;
}
const s = (id, created_ms = id * 100, expires_ms = null) => ({ id, created_ms, expires_ms });
const ids = (list) => list.map((x) => x.id);

// ── which list a session belongs in ────────────────────────────────────
// "Detached" and "ended" look the same in a sidebar and are not the same
// offer: one hands back the shell you left, the other starts a new one
// with the old output replayed. Putting an ended session under Detached
// promises a shell that no longer exists.
check("a session with a tab is open", sessionState({ alive: true }, true, false), "open");
check("no tab, still running, is detached", sessionState({ alive: true }, false, false), "detached");
check("no tab, shell gone, is ended", sessionState({ alive: false }, false, false), "ended");
check("parked is hidden", sessionState({ alive: true }, false, true), "hidden");
check("killed and counting down is closing", sessionState({ alive: true, expires_ms: 9 }, false, false), "closing");
// A tab beats everything: it is on screen, whatever else is true of it.
check("an open tab in its grace window still reads as open", sessionState({ alive: true, expires_ms: 9 }, true, false), "open");
// Closing beats hidden: the countdown is the fact with a deadline on it,
// and burying it under Hidden is how you miss the window to undo.
check("hidden and closing is closing", sessionState({ alive: true, expires_ms: 9 }, false, true), "closing");
// Hidden beats ended: the user parked it on purpose, and it is still
// theirs to bring back — the shell being gone does not undo that choice.
check("hidden and ended is hidden", sessionState({ alive: false }, false, true), "hidden");
check("ended and closing is closing", sessionState({ alive: false, expires_ms: 9 }, false, false), "closing");
// The daemon omitting `alive` must not silently mark everything ended.
check("an unknown liveness is treated as running", sessionState({}, false, false), "detached");
check("a zero expiry is not a countdown", sessionState({ alive: true, expires_ms: 0 }, false, false), "detached");

// ── what is worth reopening ────────────────────────────────────────────
check("an ordinary session is adopted", ids(adoptable([s(1)], new Set())), [1]);

// A session in its grace window was *closed*. Attaching cancels the
// pending kill, so adopting one would bring back every tab the user just
// closed, on every restart — the loudest possible way to ignore an
// instruction.
check(
  "a closing session is left alone",
  ids(adoptable([s(1), { ...s(2), expires_ms: 123 }], new Set())),
  [1]
);
check("a hidden session stays parked", ids(adoptable([s(1), s(2)], new Set([2]))), [1]);
check(
  "hidden and closing together",
  ids(adoptable([s(1), { ...s(2), expires_ms: 9 }, s(3)], new Set([3]))),
  [1]
);
check("everything excluded is empty, not everything", ids(adoptable([s(1)], new Set([1]))), []);
check("nothing in, nothing out", ids(adoptable([], new Set())), []);
// expires_ms of 0 means "not closing" rather than "closing at the epoch".
check("a zero expiry is not a grace window", ids(adoptable([{ ...s(1), expires_ms: 0 }], new Set())), [1]);

// ── the order they come back in ────────────────────────────────────────
check("the saved order wins", ids(inSavedOrder([s(1), s(2), s(3)], [3, 1, 2])), [3, 1, 2]);
check("unknown sessions go last", ids(inSavedOrder([s(1), s(2), s(9)], [2, 1])), [2, 1, 9]);
// Two unknowns must not land in whatever order the daemon happened to
// list them, or the strip reshuffles between restarts for no reason.
check(
  "unknowns are ordered by age, oldest first",
  ids(inSavedOrder([{ ...s(9), created_ms: 900 }, { ...s(8), created_ms: 100 }], [])),
  [8, 9]
);
check("an empty saved order falls back to age", ids(inSavedOrder([s(3), s(1), s(2)], [])), [1, 2, 3]);
check(
  "sessions in the saved order that no longer exist are skipped",
  ids(inSavedOrder([s(2)], [5, 2, 7])),
  [2]
);
{
  // Sorting must not rearrange the caller's array underneath it.
  const input = [s(3), s(1)];
  inSavedOrder(input, [1, 3]);
  check("the input array is left alone", ids(input), [3, 1]);
}

// ── whether to ask at all ──────────────────────────────────────────────
check("under the threshold, just restore", shouldAsk(2, true, 3), false);
// At exactly the threshold the wait is the one the user said they would
// tolerate, so asking is nagging.
check("at the threshold, still no question", shouldAsk(3, true, 3), false);
check("over it, ask", shouldAsk(4, true, 3), true);
check("turned off means never", shouldAsk(50, false, 3), false);
check("a threshold of one asks at two", shouldAsk(2, true, 1), true);
check("nothing to restore, nothing to ask", shouldAsk(0, true, 3), false);

// ── Ctrl+<n> ───────────────────────────────────────────────────────────
check("first tab", tabForNumber([11, 22, 33], 1), 11);
check("third tab", tabForNumber([11, 22, 33], 3), 33);
// 9 means the last one however many there are — what browsers do, and
// what people expect when there are more than nine.
check("nine is the last one", tabForNumber([11, 22, 33], 9), 33);
check("nine with exactly nine tabs", tabForNumber([1, 2, 3, 4, 5, 6, 7, 8, 9], 9), 9);
check("nine with more than nine tabs is still the last", tabForNumber([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 9), 10);
// Past the end must be undefined, not the last tab: the key falls through
// to the shell rather than doing something the user did not ask for.
check("past the end is nothing", tabForNumber([11, 22], 5), undefined);
check("no tabs at all", tabForNumber([], 1), undefined);
check("zero is not a tab number", tabForNumber([11], 0), undefined);
check("ten is out of range", tabForNumber([11], 10), undefined);

if (failed) {
  console.log(`${failed} restore test(s) failed`);
  process.exit(1);
}
console.log("all restore tests passed");
