// What the window's × does with your terminals.
//
// Pure and separate from main.ts because the parts worth pinning are the
// wording each choice shows and the normalisation of the stored value —
// neither needs a window to test. The flow that uses these (the confirm
// dialog, ending or keeping shells, reopening a remembered workspace)
// lives in main.ts; see tests/close.mjs.

export type CloseMode = "hide" | "keep" | "remember" | "close";

/// The stored `close_action`, normalised. The legacy "quit" reads as
/// "close"; anything unset or unrecognised is "remember" — so a close
/// genuinely closes and the folders come back next launch, rather than
/// shells running on unseen, which is what "detach and keep forever" was.
export function normalizeCloseMode(v: string | undefined): CloseMode {
  if (v === "hide" || v === "keep" || v === "remember" || v === "close") return v;
  if (v === "quit") return "close";
  return "remember";
}

/// The three choices the confirm dialog offers, in order, with the copy
/// that must be honest about what each does to a *running program*: "keep"
/// leaves it alive, "remember" ends it but reopens the folder, "close"
/// ends and forgets.
export const CLOSE_CHOICES: Array<{ mode: "keep" | "remember" | "close"; label: string; desc: string }> = [
  {
    mode: "keep",
    label: "Keep them running",
    desc: "Your terminals and anything running in them stay alive in the background. Reopen GTerminal any time and they're back, exactly where you left them.",
  },
  {
    mode: "remember",
    label: "Close but remember",
    desc: "Ends the terminals and anything running in them, but reopens the same ones — in the same folders — next time.",
  },
  {
    mode: "close",
    label: "Close them",
    desc: "Ends everything and forgets it. A clean slate next launch.",
  },
];

/// Whether closing in this mode ends the live shells. "keep" leaves them
/// running; "remember" and "close" end them (the difference is only
/// whether the folders are saved to reopen).
export function endsShells(mode: CloseMode): boolean {
  return mode === "remember" || mode === "close";
}
