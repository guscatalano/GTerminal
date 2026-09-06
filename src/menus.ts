// When a click on a menu row counts as choosing it.
//
// A menu is placed at the pointer, so its first row appears directly
// under the cursor. That makes three accidents possible, and all of them
// were reported as "it pasted without me clicking it":
//
//   - the release of the gesture that opened the menu lands on the row
//     that has just appeared beneath it;
//   - a press that began somewhere else (the terminal, say) is released
//     over the menu, which the browser still reports as a click;
//   - the input device emits a second press of its own at the same spot —
//     a precision touchpad's two-finger tap whose fingers lift a moment
//     apart, a synthesized click after a long-press, a mouse macro. That
//     one arrives late enough to clear a timer and lands on the row like
//     a real press, so neither of the first two rules sees it.
//
// None of them involves a deliberate press on the row, which is what
// choosing a menu item actually is. See tests/menus.mjs.

/// Three conditions, all required: the press began on this row, the menu
/// has been up long enough that the click cannot belong to whatever
/// opened it, and the pointer actually travelled from the point the menu
/// opened at to reach the row.
///
/// The travel rule is the one that does not depend on timing. A menu
/// anchored at the pointer puts its border, not a row, under the cursor,
/// so reaching any row means moving — while every stray press listed
/// above happens exactly where the menu opened.
export function activates(
  pressedOnRow: boolean,
  msSinceOpened: number,
  pressTravelPx: number,
  armMs = 250,
  minTravelPx = 8
): boolean {
  if (!pressedOnRow) return false;
  // A menu that never recorded an opening time is not suspect — it has
  // been up since before anyone reached for it.
  if (Number.isFinite(msSinceOpened) && msSinceOpened < armMs) return false;
  // Likewise a menu with no opening point: there is nothing to measure
  // the press against, so distance cannot be held against it.
  if (Number.isFinite(pressTravelPx) && pressTravelPx < minTravelPx) return false;
  return true;
}
