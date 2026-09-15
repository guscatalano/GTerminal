// Telling someone a key exists at the moment they need it.
//
// The shortcut list in settings is where a key lives once you know to go
// looking for it. It is no use at all in the case this exists for: a
// full-screen program has asked for the mouse, so dragging selects
// nothing, so there is no selection, so the menu that would have offered
// Copy has nothing to copy - every path to the answer is closed by the
// same thing that raised the question. Reported as the program
// "hijacking copying", which is what it looks like from the outside.
//
// So the window says it, once, at the moment the drag comes back empty.

export interface ShiftHintGesture {
  /// Whether a program is reading the mouse. While it is, the drag
  /// belongs to the program and not to the selection.
  tracking: boolean;
  /// Whether the gesture was a drag rather than a click. A click that
  /// selects nothing is a click, not a failed selection, and telling
  /// somebody about Shift every time they click into a TUI would be
  /// noise - and noise is how a hint stops being read.
  dragged: boolean;
  /// Whether Shift was held. If it was, the person already knows.
  shift: boolean;
  /// Whether anything ended up selected.
  selected: boolean;
}

export interface ShiftHintMemory {
  /// How many times it has been shown before.
  shown: number;
  /// Set once a shift-drag has actually selected something. After that
  /// the hint is never shown again: it has been learned, and repeating
  /// it is talking to somebody who is already doing the thing.
  learned: boolean;
}

/// At most this many times, ever. Twice rather than once because the
/// first one lands while somebody is mid-task and reading something
/// else; and not three times, because by then it is nagging.
export const SHIFT_HINT_LIMIT = 2;

/// Should the window say "hold Shift" right now?
export function shouldOfferShiftHint(g: ShiftHintGesture, m: ShiftHintMemory): boolean {
  if (!g.tracking) return false;
  if (!g.dragged) return false;
  if (g.shift) return false;
  if (g.selected) return false;
  if (m.learned) return false;
  return m.shown < SHIFT_HINT_LIMIT;
}

/// Has this gesture just taught the lesson, so it need never be given?
export function shiftHintLearned(g: ShiftHintGesture): boolean {
  return g.tracking && g.shift && g.selected;
}

/// What it says.
///
/// Names what happened before what to do about it. "Hold Shift to
/// select" on its own reads as an arbitrary rule; saying the program is
/// using the mouse explains why the drag did nothing, which is the
/// question actually being asked at that moment.
///
/// Suggested rather than instructed, and that is not politeness. Shift
/// is the terminal's way of taking a gesture back from a program that
/// asked for the mouse, and how much it takes back is between the
/// terminal and that program - a program can be reading the mouse
/// without wanting a drag, and one that does its own selection may
/// still not give this one up. An instruction that does nothing when
/// followed is worse than no instruction; a suggestion that does
/// nothing is a suggestion that did not suit.
export const SHIFT_HINT_TEXT =
  "This program is using the mouse, so the drag went to it. Try holding Shift to select — then Ctrl+Shift+C to copy.";

/// What was just copied, in a form that can be checked at a glance.
///
/// The console's right button copies the selection and clears the
/// highlight, which is its behaviour everywhere and worth keeping - but
/// a highlight that vanishes with nothing said is indistinguishable
/// from one that was lost. Reported exactly that way: "I select, then
/// right-click, and it disappears", by somebody whose text had in fact
/// been copied. The copy is the quiet half of a gesture whose loud half
/// is the selection going away.
///
/// A count and a first line rather than the text itself: the point is
/// to recognise what you got, and a confirmation that reprints a page
/// of output is a second problem. It is on screen for a few seconds and
/// reaches no log - see uilog.ts, which exists so that what was copied
/// stays out of files people are asked to send.
/// The other half of the surprise.
///
/// Whoever reads this note has just lost a highlight to a gesture they
/// expected to open a menu — and the menu is one modifier away, a fact
/// that otherwise lives only in the settings page, which is not where
/// they are. There are two settings for the right button: Menu, and the
/// console's Copy / paste. Shift reaches the menu under both, which is
/// why this is worth carrying to the moment somebody wants it rather
/// than leaving it where it is true but unread.
export const RIGHT_CLICK_MENU_NOTE = "Shift+right-click for the menu";

export function copiedNote(text: string): string {
  const lines = text.split(/\r\n|\r|\n/);
  const chars = `${text.length} character${text.length === 1 ? "" : "s"}`;
  let what: string;
  if (lines.length > 1) {
    what = `Copied ${lines.length} lines, ${chars}`;
  } else {
    const one = lines[0].trim();
    const shown = one.length > 40 ? `${one.slice(0, 40)}…` : one;
    what = `Copied ${chars}: ${shown}`;
  }
  return `${what} · ${RIGHT_CLICK_MENU_NOTE}`;
}
