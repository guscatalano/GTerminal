// When a click on a menu row counts as choosing it.
//
// A menu is placed at the pointer, so its first row appears directly
// under the cursor. That makes two accidents possible, and both were
// reported as "it pasted as soon as I hovered over Paste":
//
//   - the release of the gesture that opened the menu lands on the row
//     that has just appeared beneath it;
//   - a press that began somewhere else (the terminal, say) is released
//     over the menu, which the browser still reports as a click.
//
// Neither involves a deliberate press on the row, which is what choosing
// a menu item actually is. See tests/menus.mjs.

/// Both conditions are required: the press began on this row, and the
/// menu has been up long enough that the click cannot belong to whatever
/// opened it.
export function activates(pressedOnRow: boolean, msSinceOpened: number, armMs = 250): boolean {
  if (!pressedOnRow) return false;
  // A menu that never recorded an opening time is not suspect — it has
  // been up since before anyone reached for it.
  if (!Number.isFinite(msSinceOpened)) return true;
  return msSinceOpened >= armMs;
}
