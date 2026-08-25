// Handing a tab's identity to one of its own panes.
//
// A tab is identified by the session it was opened with. Close that pane
// while others remain and the tab must live on under a survivor, taking
// everything keyed by the old id with it: its place in the strip, its
// name, its group, its width.
//
// Nothing here fails loudly. Get it wrong and the tab jumps to the end of
// the strip, or loses the name you gave it, or leaves an entry behind
// that belongs to a session that no longer has a tab. See tests/retag.mjs.

/// Move one keyed entry from the old id to the new one.
///
/// The old key is always removed, even when there was nothing under it —
/// a leftover entry outlives every window that could explain it.
export function retagKeyed<T>(
  record: Record<number, T>,
  oldKey: number,
  newKey: number
): Record<number, T> {
  const out: Record<number, T> = { ...record };
  if (oldKey in out) {
    out[newKey] = out[oldKey];
    delete out[oldKey];
  }
  return out;
}

/// The tab keeps its place in the strip.
///
/// Deleting the old id and appending the new one would be simpler and
/// would move the tab to the end — which is what someone sees as "my tab
/// jumped" after closing a pane in it. Renaming in place holds the
/// position.
///
/// A new key already in the order would otherwise appear twice, and a
/// duplicate in the strip is a tab that cannot be closed.
export function retagOrder(order: number[], oldKey: number, newKey: number): number[] {
  const renamed = order.map((id) => (id === oldKey ? newKey : id));
  return renamed.filter((id, i) => renamed.indexOf(id) === i);
}
