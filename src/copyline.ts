/// Joining the rows of one logical line, for "copy this line".
///
/// A line long enough to wrap spans several buffer rows, and a click can
/// land on any of them - but a reader means the whole line. Given a way to
/// read a row (its wrapped flag and its text) this walks back to the line's
/// first row and forward through its continuations, and joins them. Only the
/// last row is trimmed: a wrapped row is full to the edge and its trailing
/// spaces belong to the line, while the final row's padding does not. Pure,
/// so tests/copyline.mjs can drive it without a terminal.

export interface Row {
  /// True when this row is a continuation of the one above it.
  isWrapped: boolean;
  /// The row's text; trimRight drops trailing whitespace (the final row).
  text(trimRight: boolean): string;
}

export function logicalLine(line: (y: number) => Row | undefined, row: number): string {
  let start = row;
  while (start > 0 && line(start)?.isWrapped) start--;
  let end = row;
  while (line(end + 1)?.isWrapped) end++;
  let out = "";
  for (let y = start; y <= end; y++) out += line(y)?.text(y === end) ?? "";
  return out;
}
