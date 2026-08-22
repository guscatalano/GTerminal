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
