// Key-routing decisions, kept pure and out of main.ts so they can be
// tested without a browser (tests/keys.mjs). Every function here answers
// one question: for this key, in this context, does the app act or does
// the terminal get it?
//
// This exists because the two bugs it guards against are invisible from
// the machine you develop on. Ctrl+V looked fine to anyone running
// PowerShell and did nothing under cmd or bash; Ctrl+F opened a second,
// Edge-supplied find bar depending on where focus happened to be.

export interface KeyEventLike {
  ctrlKey: boolean;
  shiftKey: boolean;
  altKey: boolean;
  key: string;
}

export interface KeyContext {
  /// True while a full-screen program (vim, less, htop) owns the screen.
  /// Those programs have their own meanings for these keys — vim's
  /// visual block, readline's quoted insert — so nothing is stolen there.
  alternate: boolean;
  ctrlVPaste: boolean;
  ctrlFFind: boolean;
}

export type KeyAction = "paste" | "find" | "pass";

/// Unshifted Ctrl chords the app answers for. "pass" means the terminal
/// gets the key untouched.
///
/// Shells almost never implement these themselves: bash reads Ctrl+V as
/// quoted-insert and Ctrl+F as forward-char, cmd ignores both, and
/// PSReadLine only pastes in its Windows edit mode — so whether they
/// worked used to depend on which shell the pane happened to run.
export function routeCtrlKey(e: KeyEventLike, ctx: KeyContext): KeyAction {
  if (!e.ctrlKey || e.shiftKey || e.altKey) return "pass";
  const k = e.key.toUpperCase();
  if (k === "V" && ctx.ctrlVPaste && !ctx.alternate) return "paste";
  if (k === "F" && ctx.ctrlFFind && !ctx.alternate) return "find";
  return "pass";
}

/// Turn a key press into a Tauri accelerator string ("Alt+Space",
/// "Control+Shift+Backquote"), or null when it is not usable on its own —
/// a bare modifier, or a plain key with nothing held, which would swallow
/// that key everywhere on the machine.
///
/// `code` is used rather than `key` so the binding survives layout
/// changes: the key left of 1 stays the summon key whether the layout
/// calls it backquote, plus-minus or paragraph.
export function accelerator(e: {
  ctrlKey: boolean;
  shiftKey: boolean;
  altKey: boolean;
  metaKey: boolean;
  code: string;
  key: string;
}): string | null {
  const mods: string[] = [];
  if (e.ctrlKey) mods.push("Control");
  if (e.altKey) mods.push("Alt");
  if (e.shiftKey) mods.push("Shift");
  if (e.metaKey) mods.push("Super");
  let base = "";
  if (/^Key[A-Z]$/.test(e.code)) base = e.code.slice(3);
  else if (/^Digit[0-9]$/.test(e.code)) base = e.code.slice(5);
  else if (/^Numpad[0-9]$/.test(e.code)) base = e.code;
  else if (/^F([1-9]|1[0-9]|2[0-4])$/.test(e.code)) base = e.code;
  else {
    const named: Record<string, string> = {
      Space: "Space",
      Backquote: "Backquote",
      Minus: "Minus",
      Equal: "Equal",
      BracketLeft: "BracketLeft",
      BracketRight: "BracketRight",
      Backslash: "Backslash",
      Semicolon: "Semicolon",
      Quote: "Quote",
      Comma: "Comma",
      Period: "Period",
      Slash: "Slash",
      Escape: "Escape",
      Enter: "Enter",
      Tab: "Tab",
      Insert: "Insert",
      Delete: "Delete",
      Home: "Home",
      End: "End",
      PageUp: "PageUp",
      PageDown: "PageDown",
      ArrowUp: "Up",
      ArrowDown: "Down",
      ArrowLeft: "Left",
      ArrowRight: "Right",
    };
    base = named[e.code] ?? "";
  }
  if (!base) return null; // modifier alone, or a key we cannot name
  // A global shortcut with no modifier takes that key away from every
  // other program on the machine. Function keys are the exception people
  // actually want (F12 as a summon key is a convention).
  if (!mods.length && !/^F([1-9]|1[0-9]|2[0-4])$/.test(base)) return null;
  return [...mods, base].join("+");
}

/// Keys WebView2 hands to Edge — find-on-page and the print dialog. They
/// fire wherever focus is, including inside our own find box, so their
/// default has to be cancelled at the document rather than in the
/// terminal's handler. Ctrl+P is included because a print dialog is
/// meaningless here and the key belongs to the shell's history.
export function isBrowserAccelerator(e: KeyEventLike): boolean {
  if (!e.ctrlKey || e.altKey) return false;
  const k = e.key.toUpperCase();
  return k === "F" || k === "P";
}
