# Things this terminal does not do yet

Not a roadmap and not a wish list. Each entry says what is missing, why
it is worth doing *here* rather than in general, and what it would cost
— so that picking one up starts from an argument rather than from a
title. Entries leave this file when they ship or when the argument
stops holding; the second is a real outcome and should be written down
as one.

The order is the order they were argued in, which is roughly value per
unit of new machinery. It is not a queue.

## Doing now

### 1. Inline images (sixel)

`@xterm/addon-image` is not installed, so a program that draws a chart,
a diagram or an image preview produces nothing here and something in
Windows Terminal or WezTerm. That asymmetry is the worst kind: the
program looks broken, and the terminal looks fine.

The decision that comes with it is the scrollback. Image data is orders
of magnitude larger than the text around it, and the ring is capped at
512KB per session — see `RingFilter` in `mux.rs`, which already refuses
to keep what a full-screen program draws for exactly this reason. Images
should be treated the same way: rendered live, not preserved into a
replay.

### 2. Say when a long command finishes

Every part of this already exists: `BlockTracker` knows when a command
started, ended and what it exited with; there is a tray icon; there is a
summon hotkey; and the window now knows whether it is on screen, which
was added for remote control. Nothing joins them up.

A command that ran longer than some threshold and finished while the
window was hidden or unfocused should say so, naming the command and its
exit code. It is the "I started a build and wandered off" case, and it
needs a notification permission and a threshold rather than any new
understanding of the shell.

### 3. Jump between prompts — *done, and it was half-built already*

Written up as "the blocks are parsed and nothing navigates them", which
was wrong: `prevPrompt`, `nextPrompt` and Ctrl+Shift+↑/↓ have been there
all along. Checking beat describing, again.

What was actually missing was the other half - walking back through the
commands that *failed*, which `failures()` could answer and nothing
asked. Ctrl+Shift+E now does it, wrapping from the oldest back to the
newest, and saying so when a scrollback holds no failures at all rather
than behaving like a key that is not bound.

## Argued for, not started

### Open `src/main.ts:4821` from the output

`addon-web-links` matches URLs only, so every file-and-line in compiler
or test output is dead text. A link provider plus a configurable open
command. The payoff is daily for anybody reading build output; the work
is one provider and one setting, and the hard part is the pattern —
Windows paths, relative paths, and `path:line:col` all at once, without
turning ordinary prose into links.

### Copy on select

The other half of QuickEdit, and this app already offers the console's
right-button behaviour for people arriving from conhost. One setting.
Had it existed, the whole "I select and it disappears" thread would not
have happened.

### Broadcast input to several panes

Splits exist; typing the same thing into each is manual. tmux calls it
synchronize-panes and Windows Terminal has it too. Worth it if you run
agents side by side, which is what these panes are usually for.

### Find, properly

`addon-search` is wired up but the surface is thin: no regex, no case or
whole-word toggles, and nothing that searches the history viewer's
transcripts, which is where "what was that command last Tuesday" lives.

### Export a block or a session

Transcripts are kept and can be read back. Getting one *out* — as text,
or as HTML with the colours intact — is a small addition on top, and the
thing anybody does with a failure they want to show someone else.

### Auto-run a command in a new shell

Offered once and never built: a `command` field on a session template,
delivered through the daemon's `pending_input` so it lands after the
first prompt rather than into a shell that is still starting.

### A screen-reader mode

xterm has one and nothing exposes it. A checkbox and a line of settings
text, and the only reason it is not higher is that nobody has asked.

## Known and deliberate

### The daemon socket

Unauthenticated localhost TCP, which was defensible while only the
window spoke to it. Remote control changes the shape of that: the daemon
is now what sits behind a network-facing server, and anything else
running as this user can drive a shell through it. The README has
listed the named-pipe hardening as the planned step for some time; it
has more weight behind it now than when it was written.
