// A record of what the *window* did.
//
// The session transcripts show what the shell printed, which is the same
// text whether it was typed, pasted from a menu, or pasted by accident —
// so "hovering Paste pastes it" could not be checked against anything.
// This is the missing half: menus opening, items being chosen (or
// refused), and pastes, with where each came from.
//
// What it must never contain is the clipboard. A log people are asked to
// send should not carry what they copied, so text is reduced to a size
// and a line count before it goes anywhere near the file.
//
// Three levels, because the two obvious ones are both wrong. Recording
// everything by default is a trade nobody agreed to; recording nothing
// means the first thing anyone can say about an unexpected bug is "turn
// on logging and try to make it happen again".
//
// So errors by default: a thrown exception says nothing about what you
// typed, pasted or copied - it is the app admitting it broke - and it is
// the single most useful line in the file. Everything else waits to be
// asked for.

export interface UiEvent {
  ev: string;
  [key: string]: unknown;
}

/// One line of the log. Separated from the writing so the shape can be
/// tested without a filesystem — and so the redaction is a thing that can
/// be pointed at rather than a habit.
export function formatEvent(e: UiEvent, now: string): string {
  const { ev, ...rest } = e;
  return JSON.stringify({ t: now, ev, ...rest });
}

/// What may be said about a piece of text: how big it was, not what it
/// said. Line count matters because a multi-line paste is the dangerous
/// one, and the first thing anyone asks about a paste bug.
export function describeText(text: string): { chars: number; lines: number } {
  return { chars: text.length, lines: text ? text.split(/\r\n|\r|\n/).length : 0 };
}

export type LogLevel = "off" | "errors" | "full";

/// What the setting means, including the booleans it used to be.
export function logLevel(setting: unknown): LogLevel {
  if (setting === true || setting === "full") return "full";
  if (setting === false || setting === "off") return "off";
  return "errors";
}

/// Errors are recorded at the default level; everything else is not.
/// The prefix is the rule: `error` and `error.promise` are the window
/// saying it broke, and carry no trace of what was typed or copied.
export function shouldLog(ev: string, level: LogLevel): boolean {
  if (level === "off") return false;
  if (level === "full") return true;
  return ev === "error" || ev.startsWith("error.");
}
