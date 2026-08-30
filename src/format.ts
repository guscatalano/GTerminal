// Number and text formatting for the status bar, the history page and
// the clipboard previews.
//
// Small functions, but they are the ones on screen every second — a
// wrong unit or a jittering decimal is the kind of thing a terminal user
// notices immediately and never stops noticing. Pulled out of main.ts so
// the rounding can be pinned down.

/// Bytes in the compact form a status bar has room for: 0B, 512B, 1.5K,
/// 29.4G. One decimal until three digits, then none — so the width stops
/// growing and the bar does not shuffle as the number moves.
export function fmtBytes(n: number): string {
  if (!isFinite(n) || n <= 0) return "0B";
  const u = ["B", "K", "M", "G", "T"];
  let i = 0;
  while (n >= 1024 && i < u.length - 1) {
    n /= 1024;
    i++;
  }
  return `${n >= 100 || i === 0 ? Math.round(n) : n.toFixed(1)}${u[i]}`;
}

export function fmtRate(n: number): string {
  return `${fmtBytes(n)}/s`;
}

/// Uptime at the coarsest useful grain: nobody reads seconds off a
/// status bar, and a seconds field would repaint it every second.
export function fmtDuration(s: number): string {
  const d = Math.floor(s / 86400);
  const h = Math.floor((s % 86400) / 3600);
  const m = Math.floor((s % 3600) / 60);
  if (d) return `${d}d ${h}h`;
  if (h) return `${h}h ${m}m`;
  return `${m}m`;
}

export function pct(n: number): string {
  return `${Math.round(n)}%`;
}

/// Token counts in the same compact shape as fmtBytes, but base 1000:
/// tokens are counted in thousands, not kibibytes, and reusing fmtBytes
/// here would be quietly lying about the unit.
export function fmtTokens(n: number): string {
  if (!isFinite(n) || n <= 0) return "0";
  const u = ["", "K", "M", "B"];
  let i = 0;
  while (n >= 1000 && i < u.length - 1) {
    n /= 1000;
    i++;
  }
  return `${n >= 100 || i === 0 ? Math.round(n) : n.toFixed(1)}${u[i]}`;
}

/// Transcript sizes on the history page, where MB is the useful unit and
/// a zero would be a lie about a file that exists.
export function fmtSize(b: number): string {
  return b >= 1048576 ? `${(b / 1048576).toFixed(1)} MB` : `${Math.max(1, Math.round(b / 1024))} KB`;
}

/// One line of clipboard text for a menu row. Newlines become a visible
/// mark rather than disappearing — "a b" and "a\nb" paste very
/// differently, and the menu is where you choose between them.
export function clipPreview(text: string): string {
  const t = text.replace(/\r?\n/g, " ⏎ ").replace(/\t/g, " ").trim();
  return t.length > 46 ? t.slice(0, 45) + "…" : t;
}
