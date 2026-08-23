// Command blocks: which rows of the scrollback belong to which command,
// and how that command went. Fed by OSC 133 marks from the shell.
//
// No DOM here on purpose — the parsing is the part with edge cases (a
// prompt that closes nothing, an exit code that is missing rather than
// zero) and it should be testable without a browser. See
// docs/command-blocks.md, and tests/blocks.mjs for the cases.

/// The bit of xterm's IMarker we depend on. A marker follows its row as
/// the scrollback scrolls and disposes itself when the row is trimmed,
/// which is why blocks store markers rather than row numbers.
export interface Marker {
  readonly line: number;
  readonly isDisposed: boolean;
}

export interface Block {
  /// Row where the prompt began (133;A).
  prompt: Marker;
  /// Row where typing began (133;B), when the shell reported it.
  input?: Marker;
  /// Row where the command was found to have finished (133;D) — which is
  /// the *next* prompt, since that is when the shell can report it.
  end?: Marker;
  /// Exit code. undefined means unknown: either still running, or the
  /// shell reported a bare `133;D` with no code. Deliberately not
  /// defaulted to 0 — "we don't know" and "it succeeded" are different
  /// answers and only one of them should colour a scrollbar.
  exit?: number;
  closed: boolean;
}

/// `133;D;3` → 3. A bare `133;D`, or anything non-numeric, is unknown.
export function parseExit(fields: string[]): number | undefined {
  const raw = fields[0];
  if (raw === undefined || !/^\d+$/.test(raw)) return undefined;
  return Number(raw);
}

export class BlockTracker {
  private blocks: Block[] = [];
  private open: Block | undefined;

  /// Feed one OSC 133 payload — the text after "133;", so "A", "B",
  /// "D;0". `marker` is the row the mark arrived on.
  feed(data: string, marker: Marker): void {
    const [kind, ...fields] = data.split(";");
    if (kind === "A") {
      // A new prompt ends whatever was still open. If the previous block
      // never got its D, it stays unknown rather than absorbing this one.
      if (this.open) this.open.closed = true;
      this.open = { prompt: marker, closed: false };
      this.blocks.push(this.open);
      return;
    }
    if (kind === "B") {
      if (this.open) this.open.input = marker;
      return;
    }
    if (kind === "D") {
      // The first prompt of a session closes nothing. Without this a
      // phantom block appears above the first command.
      if (!this.open) return;
      this.open.exit = parseExit(fields);
      this.open.end = marker;
      this.open.closed = true;
      this.open = undefined;
      return;
    }
    // C is never emitted by our shell hook, and anything else is not ours.
  }

  /// Blocks still in the buffer, oldest first. Rows that scrolled out of
  /// the scrollback take their blocks with them.
  all(): Block[] {
    this.blocks = this.blocks.filter((b) => !b.prompt.isDisposed);
    return this.blocks;
  }

  /// The block a row belongs to. A block runs from its own prompt up to
  /// the row before the next prompt, so every row below the first prompt
  /// belongs to exactly one.
  blockAt(line: number): Block | undefined {
    const live = this.all();
    let found: Block | undefined;
    for (const b of live) {
      if (b.prompt.line <= line) found = b;
      else break;
    }
    return found;
  }

  /// Nearest prompt above `line`. Strictly above, so pressing up from
  /// inside a block goes to that block's own prompt, and again from the
  /// prompt row goes to the one before it.
  prevPrompt(line: number): number | undefined {
    let best: number | undefined;
    for (const b of this.all()) {
      if (b.prompt.line < line) best = b.prompt.line;
      else break;
    }
    return best;
  }

  /// Nearest prompt below `line`. Neither direction wraps: running off
  /// the end of the scrollback should stop, not loop back.
  nextPrompt(line: number): number | undefined {
    for (const b of this.all()) {
      if (b.prompt.line > line) return b.prompt.line;
    }
    return undefined;
  }

  /// Commands that failed. Unknown exits are not failures — marking them
  /// would fill the scrollbar with maybes.
  failures(): Block[] {
    return this.all().filter((b) => b.closed && b.exit !== undefined && b.exit !== 0);
  }

  /// The most recently closed block, for "copy the last command output".
  lastClosed(): Block | undefined {
    const live = this.all();
    for (let i = live.length - 1; i >= 0; i--) {
      if (live[i].closed) return live[i];
    }
    return undefined;
  }
}
