# Things this terminal does not do yet

Not a roadmap and not a wish list. Each entry says what is missing, why
it is worth doing *here* rather than in general, and what it would cost
— so that picking one up starts from an argument rather than from a
title. Entries leave this file when they ship or when the argument
stops holding; the second is a real outcome and should be written down
as one.

The order is the order they were argued in, which is roughly value per
unit of new machinery. It is not a queue — the numbers are names, so
that "do 5" means something, not positions in a plan. They stay with
their entry when the order changes and are not reused after one ships.

## Done

### 1. Inline images (sixel) — *built, and blocked below us*

The window draws them now: `@xterm/addon-image` is loaded before the
terminal is opened (it registers its DCS handler on activate, so one
loaded afterwards misses the picture — an hour, that), with a
per-tab budget in megabytes because decoded image data is RGBA and a
program in a loop is otherwise unbounded. The daemon refuses to keep
them, like it refuses what a full-screen program draws: a sixel is tens
or hundreds of kilobytes against a ring capped at 512KB, so one chart
would evict every line of text in the session.

**And none of it can be reached from a program today.** ConPTY parses
what a console program writes and re-emits its own stream, and it drops
DCS strings entirely. Measured, not assumed: `tests/fixtures/sixel.ps1`
run in a real session, reading what arrived at the window — the text
either side of the picture, and not one byte of the picture. The same
shape as the mouse-mode finding next to it, and less fixable: a program
can ask for mouse reporting by setting a console mode, and there is no
console mode that means "pass my pictures through".

![Four bands of sixel drawn by the terminal](img/sixel-rendered.png)

That is the engine and the addon this app loads, given the bytes
directly — the picture `tests/fixtures/sixel.ps1` writes, which a
program cannot get here through ConPTY. Kept because "it draws them,
something else is in the way" is a claim worth being able to see.

And it is worse than absent while that holds, which is the part worth
knowing. The addon answers Primary Device Attributes with
`ESC[?62;4;9;22c` — the `4` is a claim to draw sixel — so a program
asks what the terminal can do, is told "pictures", sends one, and gets
nothing. Told "no", the same program prints its ASCII fallback. So
loading it turned a working fallback into an empty screen, and the
default is off until something can carry the reply.

So it ships inert, deliberately. `tests/images.mjs` proves our half
against the real engine, including the load order, so the day conhost
forwards DCS this works without anybody rediscovering how. Worth
revisiting if the daemon ever grows a path that is not ConPTY, or when
a Windows build starts passing them.

### 2. Say when a long command finishes — *done*

Off by default, thirty seconds by default, and silent while you are
looking at the window, because the prompt coming back has already said
it. Settings under Keyboard and input.

One thing the building of it settled: a command's start is taken from
the Enter that sent it, not from the prompt mark. The shell reports
when a command *finished* and when a prompt appeared, never when one
started, so timing from the prompt would count the minutes somebody
spent typing - and a two-second command typed slowly would arrive as a
long one. The cost is that a session driven from somewhere else, the
phone view included, has no start time and says nothing. That is the
right trade for now and worth revisiting if the daemon ever stamps the
input it writes.

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

### 4. Open `src/main.ts:4821` from the output

`addon-web-links` matches URLs only, so every file-and-line in compiler
or test output is dead text. A link provider plus a configurable open
command. The payoff is daily for anybody reading build output; the work
is one provider and one setting, and the hard part is the pattern —
Windows paths, relative paths, and `path:line:col` all at once, without
turning ordinary prose into links.

### 5. Copy on select

The other half of QuickEdit, and this app already offers the console's
right-button behaviour for people arriving from conhost. One setting.
Had it existed, the whole "I select and it disappears" thread would not
have happened.

### 6. Broadcast input to several panes

Splits exist; typing the same thing into each is manual. tmux calls it
synchronize-panes and Windows Terminal has it too. Worth it if you run
agents side by side, which is what these panes are usually for.

### 7. Find, properly

`addon-search` is wired up but the surface is thin: no regex, no case or
whole-word toggles, and nothing that searches the history viewer's
transcripts, which is where "what was that command last Tuesday" lives.

### 8. Export a block or a session

Transcripts are kept and can be read back. Getting one *out* — as text,
or as HTML with the colours intact — is a small addition on top, and the
thing anybody does with a failure they want to show someone else.

### 9. Auto-run a command in a new shell

Offered once and never built: a `command` field on a session template,
delivered through the daemon's `pending_input` so it lands after the
first prompt rather than into a shell that is still starting.

### 10. A screen-reader mode

xterm has one and nothing exposes it. A checkbox and a line of settings
text, and the only reason it is not higher is that nobody has asked.

## Known and deliberate

### 11. The daemon socket

Unauthenticated localhost TCP, which was defensible while only the
window spoke to it. Remote control changes the shape of that: the daemon
is now what sits behind a network-facing server, and anything else
running as this user can drive a shell through it. The README has
listed the named-pipe hardening as the planned step for some time; it
has more weight behind it now than when it was written.
