// Remote control: the defaults, the link, and the words next to the
// switch. Run: node tests/remote.mjs
//
// The failure this guards against is not a crash. It is an install that
// starts listening on a port because it was updated, or a settings page
// that says "only this machine" while the server is bound to every
// address. Both are silent, and both publish a shell.
import {
  DEFAULT_PORT,
  PUBLISHING_WARNING,
  addressesFor,
  bindConsequence,
  maskToken,
  remoteBind,
  remoteInput,
  remoteOn,
  remotePairing,
  remotePort,
  remoteUrl,
  pairingConsequence,
  describePending,
  describeRefused,
  describeViewer,
  remoteBadge,
  statusLine,
} from "../src/remote.ts";
import { readFileSync } from "fs";

let failed = 0;
function check(name, got, want) {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${ok ? "" : `: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`}`);
  if (!ok) failed++;
}

// ── off, unless somebody said otherwise ────────────────────────────────
// Every config.json that existed before this feature looks like the first
// two cases. None of those machines may come back from an update with a
// socket open.
check("a config that has never heard of this is off", remoteOn({}), false);
check("and so is one full of other settings", remoteOn({ ui_log: "errors", history_days: 14 }), false);
check("false is off", remoteOn({ remote_enabled: false }), false);
check("true is on", remoteOn({ remote_enabled: true }), true);
// A config file gets hand-edited, and a truthy-looking string is not a
// yes when the thing being said yes to is a shell on a port.
check("the string 'true' is not a yes", remoteOn({ remote_enabled: "true" }), false);
check("nor is 1", remoteOn({ remote_enabled: 1 }), false);

// ── typing is its own switch ───────────────────────────────────────────
// Watching a shell and driving one are different things to have
// published, and the second must never arrive as a side effect of the
// first.
check("typing is off by default", remoteInput({ remote_enabled: true }), false);
check("and only a real true turns it on", remoteInput({ remote_input: "yes" }), false);
check("on when it says on", remoteInput({ remote_input: true }), true);

// ── pairing is its own switch too ──────────────────────────────────────
// Letting a device ask to connect is a way onto the machine's shells, so
// it is off until turned on, and, like the rest, only a real true does it.
check("pairing is off by default", remotePairing({ remote_enabled: true }), false);
check("a truthy string does not turn pairing on", remotePairing({ remote_pairing: "yes" }), false);
check("nor does 1", remotePairing({ remote_pairing: 1 }), false);
check("on when it says on", remotePairing({ remote_pairing: true }), true);
// The sentence under the switch changes with it, and both states say
// something true rather than one being blank.
check("the on sentence mentions the code", /code/.test(pairingConsequence(true)), true);
check("the off sentence says the token is needed", /token/.test(pairingConsequence(false)), true);

// ── one waiting device, described ──────────────────────────────────────
// The code leads, because checking it against the phone is the job; the
// device name is the client's own claim and comes second.
check(
  "a waiting device leads with its code",
  describePending({ id: "abc", code: "429173", device: "iPhone", at_ms: 0 }),
  "iPhone wants to connect. Code on it: 429173"
);
check(
  "a device that named nothing is still described",
  describePending({ id: "abc", code: "000042", device: "", at_ms: 0 }),
  "A device wants to connect. Code on it: 000042"
);

// ── the bind fails closed ──────────────────────────────────────────────
check("nothing said means loopback", remoteBind({}), "local");
check("nonsense means loopback", remoteBind({ remote_bind: "banana" }), "local");
check("empty means loopback", remoteBind({ remote_bind: "" }), "local");
check("lan is the deliberate choice", remoteBind({ remote_bind: "lan" }), "lan");
check("and so is spelling out the address", remoteBind({ remote_bind: "0.0.0.0" }), "lan");

// ── the port ───────────────────────────────────────────────────────────
// The same range the Rust side enforces. A settings page showing one port
// while the server binds another is a link that just does not open.
check("no port means the default", remotePort({}), DEFAULT_PORT);
check("a privileged port is refused", remotePort({ remote_port: 80 }), DEFAULT_PORT);
check("zero is refused", remotePort({ remote_port: 0 }), DEFAULT_PORT);
check("out of range is refused", remotePort({ remote_port: 99999 }), DEFAULT_PORT);
check("a string is refused", remotePort({ remote_port: "9000" }), DEFAULT_PORT);
check("a real port is kept", remotePort({ remote_port: 9000 }), 9000);
// The number is duplicated in two languages; this is the thing that
// catches it drifting.
check("the default matches the server's", DEFAULT_PORT, 8722);

// ── the link ───────────────────────────────────────────────────────────
check(
  "the link carries the token",
  remoteUrl("10.44.0.3", 8722, "abc123"),
  "http://10.44.0.3:8722/?t=abc123"
);
// A token is generated from a fixed alphabet, but the URL builder must
// not assume that: one stray character and the link would be truncated
// exactly where the secret starts.
check(
  "a token with awkward characters is escaped",
  remoteUrl("127.0.0.1", 9000, "a b&c"),
  "http://127.0.0.1:9000/?t=a%20b%26c"
);
// A WireGuard address can be IPv6, and an unbracketed one makes the port
// part of the address.
check(
  "an IPv6 host is bracketed",
  remoteUrl("fd00::1", 8722, "t"),
  "http://[fd00::1]:8722/?t=t"
);

check(
  "every address the server reports gets a link",
  addressesFor({ port: 8722, hosts: ["192.168.1.9", "127.0.0.1"] }, "tok"),
  ["http://192.168.1.9:8722/?t=tok", "http://127.0.0.1:8722/?t=tok"]
);
check(
  "and loopback is the answer when it reports none",
  addressesFor({ port: 8722, hosts: [] }, "tok"),
  ["http://127.0.0.1:8722/?t=tok"]
);

// ── what the page says ─────────────────────────────────────────────────
// The masked token exists to be checked against a phone, so it has to
// keep enough of both ends to compare and give away neither.
check("a token is masked in the middle", maskToken("abcdefghijklmnop"), "abcd••••••••mnop");
check("and keeps its length", maskToken("abcdefghijklmnop").length, 16);
check("a short one is not worth masking", maskToken("abcd"), "abcd");
check("and nothing masks to nothing", maskToken(""), "");

{
  // The consequence of binding wide has to name the consequence. "All
  // interfaces" is accurate and tells a person nothing.
  const wide = bindConsequence("lan");
  check("binding wide says what can reach it", wide.includes("every device on the network"), true);
  check("and that the token is all there is", wide.includes("token"), true);
  const local = bindConsequence("local");
  check("loopback says only this machine", local.includes("Only this machine"), true);
  check("and names the way to reach it anyway", local.includes("WireGuard"), true);
}

{
  // The sentence a person has to have read before they turn this on.
  check("the warning says these are real shells", PUBLISHING_WARNING.includes("real shells"), true);
  check("and that typing means running commands", PUBLISHING_WARNING.includes("run commands"), true);
}

// ── the status line ────────────────────────────────────────────────────
check("off says nothing is listening", statusLine({}, {}), "Off. Nothing is listening, and no port is open.");
check(
  "on and bound says where",
  statusLine({ remote_enabled: true }, { running: true, bind: "127.0.0.1", port: 8722 }),
  "Listening on 127.0.0.1 only, port 8722."
);
check(
  "bound wide says so in the same breath",
  statusLine({ remote_enabled: true }, { running: true, bind: "0.0.0.0", port: 8722 }),
  "Listening on every address on this machine, port 8722."
);
// The case that matters most: the switch says on and nothing is
// listening. Whatever the server said is the only useful thing to show.
check(
  "a server that refused says why",
  statusLine({ remote_enabled: true }, { running: false, error: "could not listen on 0.0.0.0:8722 — address in use" }),
  "could not listen on 0.0.0.0:8722 — address in use"
);
check(
  "and 'on but not up' is not reported as running",
  statusLine({ remote_enabled: true }, { running: false }),
  "Turned on, but not listening yet."
);


// ── what draws the shell ───────────────────────────────────────────────
// The page's first renderer was a small hand-written ANSI reader that
// appended text as it arrived. It reads a shell wrong in a way that is
// not subtle: PSReadLine repaints the line being typed with absolute
// cursor moves and draws its prediction in dim text it then overwrites,
// so appending shows every intermediate frame and every suggestion as if
// the shell had printed them - "it's showing stuff that doesn't exist
// and it doesn't show what's on the shell".
//
// These are shape checks on the page, not behaviour tests. They exist so
// that the fix cannot be quietly undone by someone deciding a small
// parser would be lighter than shipping an engine.
const page = readFileSync(new URL("../src-tauri/src/remote.html", import.meta.url), "utf8");
const server = readFileSync(new URL("../src-tauri/src/remote.rs", import.meta.url), "utf8");

check("the page renders with a real terminal", /new Terminal\(/.test(page), true);
check("which it loads from this server", page.includes('"/xterm.js?t="'), true);
check("and the server has a route to serve it", server.includes('("GET", "/xterm.js") => Route::Engine'), true);
check("behind the same token as everything else", /Route::Engine => respond/.test(server), true);
check(
  "no hand-rolled SGR table is left to drift from it",
  /const PALETTE = \{[\s\S]*?30:/.test(page),
  false
);
// hidden has to hide. The bar sets display on a class, which outranks
// the user agent's [hidden] rule - so the read-only notice and the
// composer were both drawn, each squeezed into half the bottom bar.
check("hidden actually hides", /\[hidden\]\s*\{\s*display:\s*none\s*!important/.test(page), true);

// ── the pairing flow, both ends ────────────────────────────────────────
// The server answers /pair/start and /pair/status before the token gate -
// a device with no token has nothing to present - but only when pairing
// is switched on. These are shape checks so the pre-auth path cannot be
// quietly removed, leaving the page's pairing UI polling a dead route.
check("the server routes pair start", server.includes('"/pair/start") => Route::PairStart'), true);
check("the server routes pair status", server.includes('"/pair/status") => Route::PairStatus'), true);
check(
  "starting a pairing is a POST, not something a link can do",
  server.includes('("POST", "/pair/start")'),
  true
);
check(
  "pairing is answered before the token gate",
  /ctx\.pairing && \(r == Route::PairStart \|\| r == Route::PairStatus\)/.test(server),
  true
);
check(
  "an approved pairing is the only state that returns the token",
  /PairState::Approved[\s\S]*?"token": ctx\.token/.test(server),
  true
);
// The page asks to pair when it has no token, and only falls back to the
// token gate when the server says pairing is off (a 404 on /pair/start).
check("the page asks to pair when it has no token", page.includes('fetch("/pair/start"'), true);
check("and polls for the decision", page.includes('"/pair/status?id="'), true);
check(
  "a 404 means pairing is off and the token gate is shown",
  /status === 404/.test(page),
  true
);
// A rate-limited ask is not the token gate: pairing is on, the device is
// just being throttled, and the page has to say wait rather than "paste
// the token".
check("a 429 is handled as a rate limit, not a missing token", /status === 429/.test(page), true);
// And the server has the per-IP defences the DoS question was about: a
// per-IP cap and a denial cooldown, both keyed on the peer address.
check("the server caps pending per address", server.includes("MAX_PENDING_PER_IP"), true);
check("and holds a denied address in a cooldown", server.includes("PAIR_DENY_COOLDOWN_MS"), true);
check(
  "the pairing limits are keyed on the request's address",
  server.includes("start_pair(device, addr.clone())"),
  true
);


// ── the warning in the window ──────────────────────────────────────────
// A setting buried in a settings page is not a warning. While this is on
// there is a port open onto the user's shells, and the whole risk of the
// feature is forgetting that.
check("off shows nothing at all", remoteBadge({}, {}), null);
check(
  "on says so",
  remoteBadge({ remote_enabled: true }, { running: true, viewers: 0 })?.text,
  "Remote on"
);
check(
  "bound wide says more than on",
  remoteBadge({ remote_enabled: true, remote_bind: "lan" }, { running: true, viewers: 0 })?.level,
  "wide"
);
check(
  "and somebody connected outranks both",
  remoteBadge({ remote_enabled: true, remote_bind: "lan" }, { running: true, viewers: 1 })?.text,
  "1 watching"
);
check(
  "which is counted, not just noticed",
  remoteBadge({ remote_enabled: true }, { running: true, viewers: 3 })?.text,
  "3 watching"
);
// The sentence has to say whether whoever is there can only read.
check(
  "the tooltip says typing is off when it is",
  /Typing is off/.test(remoteBadge({ remote_enabled: true }, {})?.title ?? ""),
  true
);
check(
  "and says it is on when it is",
  /Typing is on/.test(
    remoteBadge({ remote_enabled: true, remote_input: true }, {})?.title ?? ""
  ),
  true
);


// The badge is a way in as well as a warning, and the way in is a string
// matched against a section heading. Two ends of a jump that disagree
// land you at the top of a long settings page with nothing said about
// why, which is indistinguishable from a button that does nothing.
const main = readFileSync(new URL("../src/main.ts", import.meta.url), "utf8");
check(
  "the badge asks for a section that exists",
  main.includes('openSettings("Remote control")') &&
    main.includes('settingsSection("Remote control")'),
  true
);


// ── who is connected ───────────────────────────────────────────────────
// The token is the only credential, so nothing here knows who anybody
// is. What it can say is what the connection showed, and the line has to
// keep the claim ("my browser says iPhone") next to the fact ("it came
// from this address") rather than letting the first stand for the both.
const T0 = 1_700_000_000_000;
check(
  "a watcher is described by device and address",
  describeViewer({ device: "iPhone", addr: "10.0.0.14", since_ms: T0 - 65_000 }, T0),
  "iPhone at 10.0.0.14 · connected 1m ago"
);
check(
  "with what it is watching, when it is watching something",
  describeViewer({ device: "iPad", addr: "10.0.0.9", session: 3, since_ms: T0 - 5_000 }, T0),
  "iPad at 10.0.0.9 · watching session 3 · connected 5s ago"
);
check(
  "and whether it has typed, which is the half that matters",
  describeViewer({ device: "Android", addr: "10.0.0.3", session: 1, typed: 4, since_ms: T0 }, T0),
  "Android at 10.0.0.3 · watching session 1 · typed 4 times · connected 0s ago"
);
check(
  "nothing known is said as nothing known, never guessed",
  describeViewer({}, T0),
  "a device at an unknown address"
);
// Session 0 is a real session id. A truthiness test would drop it.
check(
  "session zero is still a session",
  describeViewer({ device: "Mac", addr: "10.0.0.2", session: 0 }, T0).includes("watching session 0"),
  true
);

check("no refusals says nothing at all", describeRefused(null, T0), "");
check("no refusals is not the same as zero refusals", describeRefused({ count: 0 }, T0), "");
check(
  "one refusal is reported with where it came from",
  describeRefused({ count: 1, addr: "10.0.0.77", last_ms: T0 - 120_000 }, T0),
  "Turned away once for the wrong token — last from 10.0.0.77 2m ago."
);
check(
  "and several are counted",
  describeRefused({ count: 9, addr: "10.0.0.77", last_ms: T0 }, T0),
  "Turned away 9 times for the wrong token — last from 10.0.0.77 0s ago."
);

// The badge's tooltip is where somebody reads this first, so it carries
// the same answer rather than sending them to the settings page for it.
check(
  "the badge says who, not just how many",
  /iPhone at 10\.0\.0\.14/.test(
    remoteBadge(
      { remote_enabled: true },
      { viewers: 1, who: [{ device: "iPhone", addr: "10.0.0.14", session: 2 }] }
    )?.title ?? ""
  ),
  true
);


// Closing the window hides it to the tray and the app keeps running,
// which is right for sessions and wrong for a port onto them: the badge
// that warns about the port lives in the window. So the server follows
// the window, and the settings page has to call that paused rather than
// off - somebody told "off" goes looking for a switch that is already
// where they left it.
check(
  "no window open is paused, not off",
  statusLine({ remote_enabled: true }, { running: false, paused: true }),
  "Paused: nothing is listening while no window is open. Showing a window starts it again."
);
check(
  "and paused outranks an error left over from before",
  statusLine({ remote_enabled: true }, { running: false, paused: true, error: "address in use" }),
  "Paused: nothing is listening while no window is open. Showing a window starts it again."
);
check(
  "while off is still off",
  statusLine({}, { paused: true }),
  "Off. Nothing is listening, and no port is open."
);

if (failed) {
  console.log(`${failed} remote test(s) failed`);
  process.exit(1);
}
console.log("all remote tests passed");
