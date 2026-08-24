// Telling an old daemon from a new one, and what the notice says.
// Run: node tests/daemon.mjs
//
// The failure this guards against is silent: a window newer than the
// daemon it found refuses a request, the feature quietly does nothing,
// and nobody can tell whether the session was empty or the daemon was
// old. See docs/daemon-protocol.md.
import { staleDaemon, shellsAtRisk, daemonNotice } from "../src/daemon.ts";

let failed = 0;
function check(name, got, want) {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${ok ? "" : `: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`}`);
  if (!ok) failed++;
}

// ── which daemons are too old ──────────────────────────────────────────
// A daemon from before any of this reported nothing at all, so a missing
// protocol is the signal — not a low one.
check("no protocol at all is stale", staleDaemon({}, 1), true);
check("and stays stale however high the bar", staleDaemon({}, 7), true);
check("a lower protocol is stale", staleDaemon({ protocol: 1 }, 2), true);
check("the same protocol is fine", staleDaemon({ protocol: 2 }, 2), false);
// A daemon newer than the window happens mid-update. Nothing is broken by
// it and there is nothing to press, so it is not worth a notice.
check("a newer daemon is not stale", staleDaemon({ protocol: 5 }, 2), false);
check("nothing is required, nothing is stale", staleDaemon({}, 0), false);

// ── what a restart costs ───────────────────────────────────────────────
// Only live shells are lost. Ended ones are already on disk and come back
// either way, so counting them would overstate the price.
check("live shells are what is at risk", shellsAtRisk([{ alive: true }, { alive: true }]), 2);
check("ended ones cost nothing", shellsAtRisk([{ alive: false }, { alive: false }]), 0);
check("counted apart", shellsAtRisk([{ alive: true }, { alive: false }, { alive: true }]), 2);
check("nothing at all", shellsAtRisk([]), 0);
// A daemon that does not report liveness is assumed to be running things:
// overstating the cost makes someone hesitate, understating it loses work.
check("unknown liveness counts as live", shellsAtRisk([{}, {}]), 2);

// ── the sentence ───────────────────────────────────────────────────────
{
  const said = daemonNotice({ version: "0.6.0", protocol: 0 }, 4);
  check("names the version it found", said.includes("version 0.6.0"), true);
  check("and what it will cost", said.includes("ends 4 shells"), true);
}
{
  // A daemon too old to report a protocol is too old to report a version,
  // so the notice must read properly without one.
  const said = daemonNotice({}, 2);
  check("says 'an older version' when it cannot say which", said.includes("an older version"), true);
  check("and never the word undefined", said.includes("undefined"), false);
}
{
  const said = daemonNotice({ version: "0.6.0" }, 0);
  check("free when nothing is running", said.includes("costs nothing"), true);
  check("and does not threaten to end anything", said.includes("ends"), false);
}
{
  // "1 shells" is the sort of thing that makes people distrust the rest
  // of the sentence.
  const said = daemonNotice({ version: "0.6.0" }, 1);
  check("one shell reads as one shell", said.includes("ends 1 shell —"), true);
}

if (failed) {
  console.log(`${failed} daemon test(s) failed`);
  process.exit(1);
}
console.log("all daemon tests passed");
