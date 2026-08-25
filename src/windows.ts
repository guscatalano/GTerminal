// Which state belongs to a window, and which belongs to the app.
//
// Two windows share one WebView2 origin, so they share localStorage. Get
// this wrong and they overwrite each other's tab order and pane layouts
// silently — which is exactly what two processes did before there was
// only ever one. See docs/multi-window.md.

/// State that answers "what is on screen in this window". Two windows
/// have different answers and must not share a key.
const PER_WINDOW = new Set([
  "gterm-order",
  "gterm-layouts",
  "gterm-split-meta",
  "gterm-tab-widths",
  "gterm-zen-pos",
]);

/// The first window keeps the unsuffixed keys. An install that has been
/// running for months has its layout under those names, and a feature
/// that adds windows must not cost it that layout.
export const FIRST_WINDOW = "main";

export function storageKey(key: string, label: string): string {
  if (!PER_WINDOW.has(key)) return key;
  return label === FIRST_WINDOW ? key : `${key}::${label}`;
}

/// Everything a closing window should take with it. Never a global key,
/// never another window's — a window closing must not tidy away the tab
/// order of one still open.
///
/// And never the first window's, which is not a leak but the thing the
/// restore feature reads on the next start: closing the app must not be
/// the same as discarding your layout.
export function keysToClear(allKeys: string[], label: string): string[] {
  if (label === FIRST_WINDOW) {
    return [];
  }
  const suffix = `::${label}`;
  return allKeys.filter((k) => k.endsWith(suffix) && PER_WINDOW.has(k.slice(0, -suffix.length)));
}

/// Is this state the window's own?
export function isPerWindow(key: string): boolean {
  return PER_WINDOW.has(key);
}
