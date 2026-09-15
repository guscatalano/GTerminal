// When a finished command is worth interrupting somebody for.
// Run: node tests/notify.mjs
//
// The restraint is the feature. A terminal that toasts every time a
// prompt comes back is one whose notifications are off within the hour,
// and then the one that mattered is missed with the rest. So most of
// what follows is about the cases that must stay silent.
import { readFileSync } from "fs";
import {
  DEFAULT_NOTIFY_AFTER_SECONDS,
  describeDuration,
  notifyAfterMs,
  notifyBody,
  notifyEnabled,
  notifyTitle,
  shouldNotify,
} from "../src/notify.ts";

let failed = 0;
function check(name, got, want) {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${ok ? "" : `: got ${JSON.stringify(got)}, wanted ${JSON.stringify(want)}`}`);
  if (!ok) failed++;
}

// Off unless asked for. Every config written before today has no such
// key, and none of those machines should start interrupting anybody
// because they updated.
check("absent means off", notifyEnabled({}), false);
check("and only a real true turns it on", notifyEnabled({ notify_done: "yes" }), false);
check("on is on", notifyEnabled({ notify_done: true }), true);

const on = { notify_done: true };
const away = { ranMs: 60_000, exit: 0, visible: false, focused: false };

check("a long command finishing while the window is hidden is worth saying", shouldNotify(on, away), true);
check("but not when the feature is off", shouldNotify({}, away), false);

// The window being on screen and in front means the prompt coming back
// is already the notification.
check(
  "not when you are looking at it",
  shouldNotify(on, { ...away, visible: true, focused: true }),
  false
);
check(
  "unless you asked for that too",
  shouldNotify({ ...on, notify_when_focused: true }, { ...away, visible: true, focused: true }),
  true
);
// Visible but behind something is the same situation as hidden: you are
// in a browser and the prompt came back where you cannot see it.
check(
  "a window behind another one still counts as away",
  shouldNotify(on, { ...away, visible: true, focused: false }),
  true
);

// The threshold, which is what stops it firing for commands you sat
// through and watched.
check("a short command says nothing", shouldNotify(on, { ...away, ranMs: 2_000 }), false);
check("the default wait is where it turns over", notifyAfterMs(on), DEFAULT_NOTIFY_AFTER_SECONDS * 1000);
check("a configured wait is honoured", notifyAfterMs({ ...on, notify_after_seconds: 120 }), 120_000);
// Zero would notify for everything, which is the behaviour the whole
// file exists to avoid, so it is refused rather than obeyed.
check("zero falls back rather than notifying for everything", notifyAfterMs({ ...on, notify_after_seconds: 0 }), DEFAULT_NOTIFY_AFTER_SECONDS * 1000);
check("so does a negative", notifyAfterMs({ ...on, notify_after_seconds: -30 }), DEFAULT_NOTIFY_AFTER_SECONDS * 1000);
check("and something absurd", notifyAfterMs({ ...on, notify_after_seconds: 99999 }), DEFAULT_NOTIFY_AFTER_SECONDS * 1000);
check("exactly at the threshold counts", shouldNotify(on, { ...away, ranMs: 30_000 }), true);
check("a millisecond under does not", shouldNotify(on, { ...away, ranMs: 29_999 }), false);

// What it says. Failure is the word that decides whether somebody comes
// back now or after their coffee, so it goes in the title.
check("a clean exit is just finished", notifyTitle({ ...away, exit: 0 }), "Command finished");
check("a failure says so, with the code", notifyTitle({ ...away, exit: 2 }), "Command failed (exit 2)");
// Unknown is not failure - the same rule parseExit follows in blocks.ts.
check("an unknown exit is not called a failure", notifyTitle({ ...away, exit: undefined }), "Command finished");

check("the body is the command and how long it took", notifyBody("cargo build --release", 95_000), "cargo build --release — 1m 35s");
check("a multi-line command shows its first line", notifyBody("git commit -m \"one\ntwo\"", 40_000), 'git commit -m "one — 40s');
check(
  "a long command is cut at the front, which is the half that says what it was",
  notifyBody("z".repeat(100), 40_000),
  "z".repeat(60) + "… — 40s"
);
check("and with no command there is still a duration", notifyBody("", 40_000), "Took 40s");

// Durations somebody would say out loud.
check("seconds", describeDuration(42_000), "42s");
check("a round minute drops the seconds", describeDuration(60_000), "1m");
check("and an odd one keeps them", describeDuration(95_000), "1m 35s");
check("hours", describeDuration(3_600_000), "1h");
check("and hours with minutes", describeDuration(5_400_000), "1h 30m");


// ── wired to the decision, not to a second copy of it ──────────────────
// The window asks the questions this file answers rather than deciding
// again at the call site, and it asks the window whether anyone is
// looking rather than assuming. Both have gone stale in this codebase
// before, in exactly this shape.
const main = readFileSync(new URL("../src/main.ts", import.meta.url), "utf8");
check("the window asks whether a finish is worth saying", main.includes("shouldNotify(config, finished)"), true);
check("and asks Windows whether it is on screen", main.includes("win.isVisible()"), true);
check("and whether it is the window being worked in", main.includes("win.isFocused()"), true);
// A permission can be taken away in Windows settings long after it was
// granted, so it is asked for every time rather than once at startup: a
// toast that silently never arrives is worse than one never offered.
check("and checks the permission at the point of sending", main.includes("isPermissionGranted()"), true);

if (failed) {
  console.log(`${failed} notify test(s) failed`);
  process.exit(1);
}
console.log("all notify tests passed");
