// Key-routing tests: the app's answer for Ctrl+F / Ctrl+V, and which
// keys Edge would otherwise steal. Run: node tests/keys.mjs
//
// These exist because both bugs they cover were invisible on the machine
// they were written on. Ctrl+V "worked" for anyone running PowerShell and
// did nothing under cmd or bash, because the app never handled it and
// PSReadLine did. Ctrl+F opened a second, Edge-supplied find bar — but
// only on the second press, once focus had moved into our own find box.
// Neither reproduces without either another shell or another focus state,
// which is exactly what a unit test is for.
//
// Node 24 strips types natively, so this imports the real module rather
// than a copy of it.
import { routeCtrlKey, isBrowserAccelerator } from "../src/keys.ts";

let failed = 0;
function check(name, got, want) {
  if (got === want) {
    console.log(`PASS ${name}`);
  } else {
    console.log(`FAIL ${name}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`);
    failed++;
  }
}

const key = (k, mods = {}) => ({
  ctrlKey: false,
  shiftKey: false,
  altKey: false,
  key: k,
  ...mods,
});
const ctx = (over = {}) => ({
  alternate: false,
  ctrlVPaste: true,
  ctrlFFind: true,
  ...over,
});

// ── the app answers at a shell prompt ──────────────────────────────────
check("Ctrl+V at a prompt pastes", routeCtrlKey(key("v", { ctrlKey: true }), ctx()), "paste");
check("Ctrl+F at a prompt finds", routeCtrlKey(key("f", { ctrlKey: true }), ctx()), "find");

// Browsers report the letter's case; both spellings must route the same.
check("uppercase V routes too", routeCtrlKey(key("V", { ctrlKey: true }), ctx()), "paste");
check("uppercase F routes too", routeCtrlKey(key("F", { ctrlKey: true }), ctx()), "find");

// ── full-screen programs keep their keys ───────────────────────────────
// vim's visual block and readline's quoted insert live on Ctrl+V; vim and
// less page with Ctrl+F. Stealing these would trade one broken key for
// another, so the alternate buffer is always passed through.
check(
  "Ctrl+V in vim passes through",
  routeCtrlKey(key("v", { ctrlKey: true }), ctx({ alternate: true })),
  "pass"
);
check(
  "Ctrl+F in less passes through",
  routeCtrlKey(key("f", { ctrlKey: true }), ctx({ alternate: true })),
  "pass"
);

// ── the settings genuinely turn it off ─────────────────────────────────
check(
  "Ctrl+V passes when disabled",
  routeCtrlKey(key("v", { ctrlKey: true }), ctx({ ctrlVPaste: false })),
  "pass"
);
check(
  "Ctrl+F passes when disabled",
  routeCtrlKey(key("f", { ctrlKey: true }), ctx({ ctrlFFind: false })),
  "pass"
);
check(
  "disabling one leaves the other alone",
  routeCtrlKey(key("f", { ctrlKey: true }), ctx({ ctrlVPaste: false })),
  "find"
);

// ── only the unshifted, un-alted chord ─────────────────────────────────
// Ctrl+Shift+V and Ctrl+Shift+F are handled by their own branch; this
// router must not claim them twice, or the shifted branch is dead code.
check(
  "Ctrl+Shift+V is not this router's",
  routeCtrlKey(key("V", { ctrlKey: true, shiftKey: true }), ctx()),
  "pass"
);
check(
  "Ctrl+Shift+F is not this router's",
  routeCtrlKey(key("F", { ctrlKey: true, shiftKey: true }), ctx()),
  "pass"
);
check(
  "Ctrl+Alt+V passes (AltGr combinations type characters)",
  routeCtrlKey(key("v", { ctrlKey: true, altKey: true }), ctx()),
  "pass"
);
check("plain V passes", routeCtrlKey(key("v"), ctx()), "pass");
check("plain F passes", routeCtrlKey(key("f"), ctx()), "pass");

// ── keys we must cancel before Edge sees them ──────────────────────────
// xterm returns out of _keyDown as soon as a custom handler says false,
// before its own preventDefault, and the accelerator fires wherever focus
// is — including inside our find box, which is what produced two find
// bars on the second Ctrl+F.
check("Ctrl+F is Edge's find-on-page", isBrowserAccelerator(key("f", { ctrlKey: true })), true);
check("Ctrl+P is Edge's print dialog", isBrowserAccelerator(key("p", { ctrlKey: true })), true);
check(
  "Ctrl+Shift+F still counts (focus may be anywhere)",
  isBrowserAccelerator(key("F", { ctrlKey: true, shiftKey: true })),
  true
);
check("Ctrl+Alt+F does not", isBrowserAccelerator(key("f", { ctrlKey: true, altKey: true })), false);
check("plain F does not", isBrowserAccelerator(key("f")), false);
check("Ctrl+R is not ours to cancel", isBrowserAccelerator(key("r", { ctrlKey: true })), false);

// Ctrl+C must never be swallowed: it is SIGINT, and copy lives on
// Ctrl+Shift+C precisely so this key can reach the shell.
check("Ctrl+C reaches the shell", routeCtrlKey(key("c", { ctrlKey: true }), ctx()), "pass");
check("Ctrl+C is not cancelled", isBrowserAccelerator(key("c", { ctrlKey: true })), false);

if (failed) {
  console.log(`${failed} key test(s) failed`);
  process.exit(1);
}
console.log("all key tests passed");
