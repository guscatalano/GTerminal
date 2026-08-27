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
  /// True when the operating system is repeating a held key. Nothing
  /// here checked it, so holding Ctrl+V a fraction too long pasted twice.
  repeat?: boolean;
}

export interface KeyContext {
  /// True while a full-screen program (vim, less, htop) owns the screen.
  /// Those programs have their own meanings for these keys — vim's
  /// visual block, readline's quoted insert — so nothing is stolen there.
  alternate: boolean;
  ctrlVPaste: boolean;
  ctrlFFind: boolean;
}

/// "swallow" means the app claims the key and does nothing with it: the
/// terminal must not see it either. It exists for held keys, where the
/// first press has already acted and the repeats must go nowhere.
export type KeyAction = "paste" | "find" | "pass" | "swallow";

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
  const claimed =
    (k === "V" && ctx.ctrlVPaste && !ctx.alternate) || (k === "F" && ctx.ctrlFFind && !ctx.alternate);
  // A held key repeats. Windows sends a fresh keydown every few tens of
  // milliseconds while it is down, and both of these are one-shot: a
  // repeat would paste the clipboard again, or reopen a find bar that is
  // already open. The repeats are swallowed rather than passed on,
  // because the terminal has no business seeing a Ctrl+V this app claims.
  //
  // This is the shape of a double paste nobody can reproduce on demand:
  // it depends on how long a key was held, not on what was copied.
  if (claimed && e.repeat) return "swallow";
  if (k === "V" && ctx.ctrlVPaste && !ctx.alternate) return "paste";
  if (k === "F" && ctx.ctrlFFind && !ctx.alternate) return "find";
  return "pass";
}

export interface PasteLimits {
  enabled: boolean;
  /// Warn at or above this many lines. A pasted command that arrives as
  /// several lines can run several commands.
  lines: number;
  /// Warn at or above this many characters, however few lines it is.
  chars: number;
}

/// How many commands a paste could turn into. A single trailing newline
/// is what any editor adds to the end of a file and just submits the one
/// line, so it does not count as another.
export function pasteLineCount(text: string): number {
  const body = text.replace(/(\r\n|\r|\n)$/, "");
  if (!body) return 0;
  return body.split(/\r\n|\r|\n/).length;
}

/// Whether a paste is big enough to be worth confirming. Long or
/// multi-line clipboard content is the classic way to run something you
/// did not read — worse under cmd, which has no bracketed paste, so the
/// lines execute as they arrive.
export function pasteNeedsWarning(text: string, limits: PasteLimits): boolean {
  if (!limits.enabled || !text) return false;
  return pasteLineCount(text) >= limits.lines || text.length >= limits.chars;
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
