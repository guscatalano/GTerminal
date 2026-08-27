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
import {
  routeCtrlKey,
  isBrowserAccelerator,
  accelerator,
  pasteNeedsWarning,
  pasteLineCount,
} from "../src/keys.ts";

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
// ── held keys ──────────────────────────────────────────────────────────
// A held key repeats: Windows sends a fresh keydown every few tens of
// milliseconds until it is let go. Pasting is one-shot, so the repeats
// have to go nowhere - and they must not fall through to the terminal
// either, which would send a Ctrl+V this app has claimed.
//
// This is the shape of a double paste nobody can reproduce on demand: it
// depends on how long the key was held, not on what was copied.
check(
  "a repeated Ctrl+V pastes nothing more",
  routeCtrlKey(key("v", { ctrlKey: true, repeat: true }), ctx()),
  "swallow"
);
check(
  "a repeated Ctrl+F does not reopen the find bar",
  routeCtrlKey(key("f", { ctrlKey: true, repeat: true }), ctx()),
  "swallow"
);
// The first press still acts - only the repeats after it are dropped.
check(
  "the first press is unaffected",
  routeCtrlKey(key("v", { ctrlKey: true, repeat: false }), ctx()),
  "paste"
);
// A repeat of a key this app does not claim still belongs to the shell,
// which is how held arrow keys and held letters keep working.
check(
  "a repeated key the app does not claim is still the shell's",
  routeCtrlKey(key("d", { ctrlKey: true, repeat: true }), ctx()),
  "pass"
);

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

// ── summon hotkey capture ──────────────────────────────────────────────
// The picker turns a keypress into a Tauri accelerator string. Getting
// this wrong fails at registration with no visible cause, so the parsing
// is worth pinning down.
const press = (code, mods = {}) => ({
  ctrlKey: false,
  shiftKey: false,
  altKey: false,
  metaKey: false,
  code,
  key: "",
  ...mods,
});

check("Alt+Space", accelerator(press("Space", { altKey: true })), "Alt+Space");
check(
  "Ctrl+Shift+backquote, the classic quake key",
  accelerator(press("Backquote", { ctrlKey: true, shiftKey: true })),
  "Control+Shift+Backquote"
);
check("Super+T", accelerator(press("KeyT", { metaKey: true })), "Super+T");
check("digits", accelerator(press("Digit3", { altKey: true })), "Alt+3");
check("arrows are renamed", accelerator(press("ArrowUp", { altKey: true })), "Alt+Up");
check("modifier order is stable", accelerator(press("KeyG", {
  shiftKey: true, ctrlKey: true, altKey: true,
})), "Control+Alt+Shift+G");

// A bare key would be taken from every other program on the machine.
check("a bare letter is rejected", accelerator(press("KeyG")), null);
check("a bare Space is rejected", accelerator(press("Space")), null);
// Function keys are the exception: F12 as a summon key is a convention.
check("a bare F12 is allowed", accelerator(press("F12")), "F12");
check("F12 with a modifier too", accelerator(press("F12", { ctrlKey: true })), "Control+F12");

// Holding a modifier alone must not commit a half-finished combination.
check("Control alone is not a hotkey", accelerator(press("ControlLeft", { ctrlKey: true })), null);
check("Shift alone is not a hotkey", accelerator(press("ShiftRight", { shiftKey: true })), null);

// code, not key: the binding has to survive a layout change, where the
// key left of 1 is no longer called backquote.
check(
  "layout-independent (code wins over key)",
  accelerator({ ...press("Backquote", { altKey: true }), key: "plusminus" }),
  "Alt+Backquote"
);

// ── paste warning ──────────────────────────────────────────────────────
const lim = (over = {}) => ({ enabled: true, lines: 3, chars: 2000, ...over });

// A trailing newline is what every editor puts at the end of a file, and
// it submits the one line rather than adding another — counting it would
// make every single-command paste look like two.
check("one line", pasteLineCount("git status"), 1);
check("one line with a trailing newline", pasteLineCount("git status\n"), 1);
check("CRLF counts once", pasteLineCount("git status\r\n"), 1);
check("two lines", pasteLineCount("a\nb"), 2);
check("two lines, trailing newline", pasteLineCount("a\nb\n"), 2);
check("blank lines still count", pasteLineCount("a\n\nb"), 3);
check("empty is nothing", pasteLineCount(""), 0);
check("a lone newline is nothing", pasteLineCount("\n"), 0);

check("a short command does not warn", pasteNeedsWarning("git status", lim()), false);
check("two lines is under the default", pasteNeedsWarning("a\nb", lim()), false);
check("three lines warns", pasteNeedsWarning("a\nb\nc", lim()), true);
check(
  "one very long line warns on length alone",
  pasteNeedsWarning("x".repeat(2000), lim()),
  true
);
check(
  "just under the character limit does not",
  pasteNeedsWarning("x".repeat(1999), lim()),
  false
);
check("empty never warns", pasteNeedsWarning("", lim()), false);
check("disabled never warns", pasteNeedsWarning("a\nb\nc\nd", lim({ enabled: false })), false);
check(
  "thresholds are honoured",
  pasteNeedsWarning("a\nb", lim({ lines: 2 })),
  true
);

if (failed) {
  console.log(`${failed} key test(s) failed`);
  process.exit(1);
}
console.log("all key tests passed");
