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
  remotePort,
  remoteUrl,
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

if (failed) {
  console.log(`${failed} remote test(s) failed`);
  process.exit(1);
}
console.log("all remote tests passed");
