// Where in a transcript the thing you searched for actually is.
//
// The history page already filters sessions by their text. What it did
// not do is say *where*: a match returned a session, and the session was
// a wall of output somebody then had to search again by eye. This is the
// piece that turns "some session last Tuesday mentions it" into the line
// that does, with enough of its neighbours to recognise it by.
//
// Pure, so the shape of a hit can be argued about in a test rather than
// in a viewer.

export interface HistoryHit {
  /// Zero-based line in the transcript, after ANSI has been stripped.
  line: number;
  /// The line itself, trimmed of trailing whitespace.
  text: string;
  /// Index of the match within `text`, for highlighting.
  at: number;
}

/// How many hits one transcript may contribute.
///
/// A session that mentions the word four hundred times is not four
/// hundred results, it is one result with a lot of noise in it; past
/// this the list says "and N more" and lets the transcript viewer's own
/// find take over.
export const MAX_HITS_PER_SESSION = 8;

/// Every line in `text` that contains `needle`, case-insensitively.
///
/// Case-insensitive on purpose and with no option to change it: the
/// question this answers is "did I see this word last week", and nobody
/// asking it remembers the case they saw it in.
export function findHits(text: string, needle: string): HistoryHit[] {
  const n = needle.trim().toLowerCase();
  if (!n) return [];
  const out: HistoryHit[] = [];
  // A bare carriage return is a repaint of the line so far, not a line.
  // PSReadLine redraws the command as it is typed, and reading each frame
  // as its own line turned "echo NEEDLE" into "…Oecho NEEDLE-IN-OPecho
  // NEEDLE-IN-OPEecho…" in the results. Keep what was on the line after
  // the last repaint, which is what the screen showed.
  const lines = text.split(/\r\n|\n/).map((l) => {
    const cr = l.lastIndexOf("\r");
    return cr < 0 ? l : l.slice(cr + 1);
  });
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].replace(/\s+$/, "");
    const at = line.toLowerCase().indexOf(n);
    if (at < 0) continue;
    out.push({ line: i, text: line, at });
    if (out.length >= MAX_HITS_PER_SESSION) break;
  }
  return out;
}

/// The bit of a line worth showing next to a hit.
///
/// Long lines - a minified stack trace, a JSON blob - are cut to a
/// window around the match rather than at the front, because the front
/// of such a line is usually the part that says nothing. The ellipses
/// say which end was cut.
export function excerpt(hit: HistoryHit, needleLength: number, width = 96): string {
  const { text, at } = hit;
  if (text.length <= width) return text;
  const half = Math.floor((width - needleLength) / 2);
  let start = Math.max(0, at - half);
  let end = Math.min(text.length, start + width);
  if (end - start < width) start = Math.max(0, end - width);
  const head = start > 0 ? "…" : "";
  const tail = end < text.length ? "…" : "";
  return head + text.slice(start, end) + tail;
}
