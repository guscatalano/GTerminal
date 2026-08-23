# Command blocks — design notes

**Status:** built 2026-08-23 against v0.6.0. Everything under "Test
cases" is implemented and passing; everything under "Not in this pass"
is still not.

One thing the plan got wrong: the first prompt of a session *did* emit a
`D`, because the shell's own init block lands in history and looks like
a command that just finished. Seeding the history id at init does not
help — the init is added to history after that line runs. The rule that
works is simpler and needs no history at all: the first prompt of a
session has nothing above it to close.

The terminal receives one undifferentiated stream of bytes and cannot
tell where one command's output ends and the next begins. Everything
below follows from fixing that one thing.

## The marks

**OSC 133**, the de-facto standard, already used by Windows Terminal,
VS Code, iTerm2 and WezTerm. Four marks:

| | |
|---|---|
| `133;A` | a prompt starts here |
| `133;B` | the prompt has finished printing; typing starts here |
| `133;C` | output starts here |
| `133;D;<code>` | the command finished, with this exit code |

This is the same mechanism as the **OSC 9;9** cwd report the prompt hook
already emits (`mux.rs`, `PROMPT_CMD`) and the daemon already parses
(`last_cwd`). The injection point, the transport and the parser all
exist; this is more marks through the same pipe.

### Where each mark comes from

PowerShell has no "about to execute" hook, so `C` cannot be emitted
honestly and is **not emitted at all**. `A`, `B` and `D` all come from
the prompt function, which runs *between* commands:

```
prompt() {
  emit D;<exit code of the command that just ran>   ← closes the previous block
  emit A                                            ← this prompt starts
  emit 9;9;<cwd>                                    ← existing cwd report
  <the user's prompt text>
  emit B                                            ← typing starts here
}
```

So `D` for a command arrives at the *top of the next prompt*, not when
the command ends. That is how every OSC 133 shell integration works, and
it means a block is only closed once you get your prompt back — which is
also exactly when the information becomes true.

Output is therefore everything between `B` and the next `D`, minus the
echoed command line itself. Good enough for every use below, and it
needs no hook that PowerShell does not have.

### Exit codes are not simply `$LASTEXITCODE`

`$LASTEXITCODE` is only set by native executables. A failing cmdlet
(`Get-ChildItem /nope`) leaves it stale from whatever ran before, so
reading it alone reports a failure as a success, or worse, reports an
old failure against an innocent command. The hook checks `$?` first and
only trusts `$LASTEXITCODE` when the last command was native:

- `$? -eq $true` → `0`
- `$? -eq $false` and `$LASTEXITCODE` is a non-zero int → that code
- `$? -eq $false` otherwise → `1`

The prompt also runs when you press Enter on an empty line, where no
command ran at all. Comparing `Get-History -Count 1`'s id against the
last one seen distinguishes "command finished" from "prompt redrawn",
the same way the existing command logger does.

## What it buys

- `Ctrl+Shift+Up` / `Ctrl+Shift+Down` — jump prompt to prompt, so a
  400-line build log is one keystroke rather than a scroll
- **failures marked in the scrollbar** — a screen of output shows which
  command failed without reading it
- right-click a block → copy its output, or the command and its output
  together, which is the thing everyone does by hand when pasting an
  error into a bug report

## Where the marks are drawn

In the **overview ruler** (the scrollbar), not in the text area. xterm
decorations occupy real character cells, so a gutter mark would sit on
top of the first column of output. The ruler is free real estate, is
already how the find bar shows matches, and gives the whole scrollback
at a glance rather than only the visible screen.

Only failures are marked. Marking every command makes the ruler a
barcode and the failures stop standing out, which is the one thing it is
for.

## Structure

`src/blocks.ts` holds a `BlockTracker` per session — pure, no DOM, so
the parsing is testable without a browser. The frontend feeds it marks
from `term.parser.registerOscHandler(133, …)` and lines from xterm
markers, which move with the scrollback on their own.

Blocks are frontend-only state. They are not persisted: a restored
session replays its scrollback without the marks that were in the live
stream, and inventing blocks for it would be a lie. A restored session
starts collecting blocks from its next prompt.

## Test cases

### Unit — `tests/blocks.mjs` against `src/blocks.ts`

Parsing:

- `A` then `D;0` → one block, succeeded
- `A`, `B`, `D;3` → exit code 3, failed
- `D` arriving before any `A` (the very first prompt of a session, which
  closes nothing) → ignored, no phantom block
- `A` with no `D` yet → block open, exit code unknown, *not* zero
- `D` with no code (`133;D`) → finished, code unknown — must not be
  read as success
- `D;abc` → malformed, treated as unknown rather than throwing
- a second `A` with no intervening `D` → the open block closes as
  unknown rather than swallowing the next one

Queries:

- `blockAt(line)` finds the block containing a line, including the
  prompt line itself and the last line of output
- `blockAt` on a line above the first block → nothing
- `prevPrompt(line)` / `nextPrompt(line)` skip to the neighbouring
  prompt and stop at the ends rather than wrapping
- navigation from inside a block goes to *that* block's prompt when
  moving up, not the one before it
- `failures()` lists only non-zero exits, so the ruler stays quiet

Bookkeeping:

- lines are read through the marker at query time, so blocks track
  scrollback trimming rather than holding stale absolute rows
- a disposed marker (scrolled out of the buffer) drops its block instead
  of reporting a negative line

### End-to-end — `tests/lifecycle.ps1`

The unit tests cover our parsing; these cover the half that lives in
PowerShell, where the risk actually is:

- a session emits `133;A` and `133;B` at its prompt
- `cmd /c exit 3` produces `133;D;3` — a real native exit code
- `echo` of a value produces `133;D;0`
- a failing *cmdlet* produces a non-zero code, not the stale
  `$LASTEXITCODE` of some earlier command — the case that makes naive
  implementations report failures as successes
- pressing Enter on an empty line does not emit a `D` for a command that
  never ran

## Not in this pass

- collapsing a block's output
- rerunning a command from its block
- `133;C`, which PowerShell cannot honestly provide
- persisting blocks across a restore
- clicking a block to select its output (the menu covers the need; a
  click target competes with text selection, which is the same fight
  the pane grip lost)
