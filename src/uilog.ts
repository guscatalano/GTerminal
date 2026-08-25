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
// And it is off unless switched on. A terminal that records what you did
// with it, by default, is not a trade anyone agreed to - the file staying
// on the machine does not make it one. The cost is real and worth stating:
// when something breaks unexpectedly there is nothing to look at, and the
// first thing anyone can do is turn this on and try to make it happen
// again.

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
