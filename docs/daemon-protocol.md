# The daemon outlives the app that started it

Sessions live in the daemon, so the daemon is deliberately hard to kill:
closing every window leaves it running, and it only exits when its last
session is gone. That is the whole point of the design — and it means an
update replaces `gterminal.exe` while the *old* daemon keeps serving.

A new window then talks to an old daemon. Every release that adds a
request has this problem, and 0.7.0 is the first one where it showed:
`peek` (reading an ended session's output without resurrecting it) is
answered by an older daemon with `{"ok":false,"error":"bad request"}`, so
the preview says "Its saved output could not be read" and the user has no
way to know why, or what to do about it.

Nothing is broken by this — the daemon refuses unknown requests and keeps
the connection, which it has always done. The gap is that the window
cannot tell the difference between "this session has no output" and "the
daemon I am talking to is too old to tell me", and neither can the person
reading the screen.

## What this adds

**The daemon says who it is.** The `list` reply carries three more
fields: `protocol` (an integer, bumped when a request is added),
`version` (the daemon binary's version), and `pid`. Old daemons omit
them, and a missing `protocol` is exactly the signal that matters: it
means "older than the first version that reported anything".

**The window says so, once, and offers the remedy.** A notice, not a
modal: the app works, one feature does not. It names what is stale and
what restarting costs, because restarting is not free — the shells in
that daemon end. Their scrollback and folders survive (they come back as
ended sessions), but running programs do not.

**Restarting is offered rather than done.** The window knows the pid, so
it can stop that exact process and let the next request start a fresh
one. It must never do that on its own: a background service quietly
restarting itself is how someone loses an `ssh` session they were in the
middle of.

When the daemon has *no* live shells, restarting costs nothing, and the
notice should say that instead — it is the difference between "you will
lose four shells" and "this is free".

## Verbs added since, and how they avoid the same trap

Two requests have been added without bumping `protocol`, because a bump
marks every daemon now running as stale and shows its user a restart
notice — for a feature that only helps the update *after* this one. They
are advertised in the `list` reply's `can` array instead, which is
additive: a daemon too old to know them omits it, and an absent list
means "assume nothing".

- **`shutdown`** — stand down, immediately or once the last live shell
  has gone. See the comment on the request itself.
- **`send`** — type into a session addressed by id, without attaching.
  `write` goes to whatever the connection attached to, and attaching
  takes the session away from the window that had it open; that rule is
  right for two windows and exactly wrong for the remote-control page,
  which must be able to send one Ctrl-C without pulling a tab out from
  under the person at the keyboard. Unlike `write`, it answers: the
  caller is over a network and has to be able to tell "typed into a
  shell" from "went nowhere".
- **`observe`** — receive a session's output without taking it. The
  connection is sent everything the session has (its scrollback, plus
  whatever a full-screen program is currently holding on the alternate
  screen) and then every chunk as it arrives, in the same
  `{"ev":"data"}` shape `attach` uses. It does not touch the
  attachment, so a phone watching a session cannot take it out of the
  window on the desk.

  The reason it cannot be built on `peek` is the ring. The ring
  deliberately keeps nothing that a program drew after it took over the
  screen — thousands of repaints are not scrollback — so a watcher
  polling `peek` sees nothing at all while any full-screen program is
  running. An observer is fed the pty directly and sees the repaints
  too.

A daemon too old for either answers `{"ok":false,"error":"bad request"}`
and keeps the connection, which is the behaviour this whole document is
about. The caller reports that rather than swallowing it.

## Deliberately not doing

**Handing PTYs to the new daemon.** A real handoff — passing pty handles
between processes so shells survive the upgrade — is the only way to make
this invisible, and it is a large amount of Windows-specific machinery
for a problem measured in one notice per update.

**Auto-restarting when idle.** Tempting, and safe by the argument above,
but "safe" is judged from the daemon's view: a session with no live shell
may still be one the user is about to reopen, and a restart that renumbers
or drops anything while they are not looking is the kind of surprise this
app is supposed to avoid. If it is free, say so and let them press it.

## Test cases

Daemon (`tests/lifecycle.ps1`):

1. `list` reports a protocol number, a version string, and a pid.
2. The reported pid is the daemon's real process — kill *that* pid and
   the daemon is gone.
3. An unknown request is refused without breaking the connection: send
   nonsense, then `list` on the same connection and get a reply.
4. A restart via the reported pid brings the sessions back as ended ones,
   with their scrollback intact.

Daemon, `send` (`tests/lifecycle.ps1`):

11. `list` advertises `send` in its `can` array.
12. A `send` to a live session is answered, and the text reaches the
    shell — seen on the connection that is attached to it.
13. The attachment does not move: the window that had the session still
    has it afterwards. Only one of these two failing is the interesting
    bug, which is why both are checked.
14. A `send` to a session that does not exist is refused rather than
    silently discarded.

Daemon, `observe` (`tests/lifecycle.ps1`):

15. `list` advertises `observe` in its `can` array.
16. A session can be watched, and the window that had it still has it
    afterwards — the whole point of the verb being separate from
    `attach`.
17. Ordinary output reaches the watcher.
18. So does what a program draws on the alternate screen. This is the
    case the feature exists for: it was reported as an agent TUI
    rendering nothing in the phone view, and a watcher built on `peek`
    cannot ever pass it.
19. The ring, for contrast, still holds the ordinary output and still
    refuses to keep the repaints. If that ever flips, the ring has
    stopped being scrollback.
20. Watching a session that does not exist is refused.

Frontend (`tests/daemon.mjs`), against `src/daemon.ts`:

5. A missing `protocol` means stale — that is what an old daemon looks
   like, and the case this exists for.
6. A lower protocol than the app needs is stale.
7. An equal protocol is not.
8. A *higher* protocol is not stale either: an older window talking to a
   newer daemon is not the failure being warned about, and nagging about
   it would be noise.
9. The notice names the daemon's version when it reports one, and says
   "an older version" when it does not — because that is precisely the
   case where it cannot say.
10. The notice distinguishes "nothing is running, so this is free" from
    "N shells will end", and counts only live shells: sessions that have
    already ended cost nothing to restart.
