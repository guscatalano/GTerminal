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
export const SHIFT_HINT_TEXT =
  "This program is using the mouse. Hold Shift to select text — then Ctrl+Shift+C to copy.";
