// Naming windows for a menu, and deciding which ones can be a target.
//
// Labels are internal ("main", "w2"); a menu has to say something a
// person recognises, and must never offer to move a tab to the window it
// is already in. See tests/windownames.mjs.

import { FIRST_WINDOW } from "./windows.ts";

/// "Window 1", "Window 2" — numbered as they were opened, with the first
/// window as 1. The label is not shown: w7 means nothing to anyone.
export function windowName(label: string): string {
  if (label === FIRST_WINDOW) return "Window 1";
  const n = /^w(\d+)$/.exec(label);
  return n ? `Window ${n[1]}` : label;
}

/// Where a tab in `here` could be moved to, in a stable order so the menu
/// does not reshuffle between openings.
export function moveTargets(labels: string[], here: string): string[] {
  return labels
    .filter((l) => l !== here)
    .sort((a, b) => {
      if (a === FIRST_WINDOW) return -1;
      if (b === FIRST_WINDOW) return 1;
      const na = Number(/^w(\d+)$/.exec(a)?.[1] ?? Number.MAX_SAFE_INTEGER);
      const nb = Number(/^w(\d+)$/.exec(b)?.[1] ?? Number.MAX_SAFE_INTEGER);
      return na === nb ? a.localeCompare(b) : na - nb;
    });
}
