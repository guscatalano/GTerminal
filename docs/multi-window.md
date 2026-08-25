# More than one window

Until now the app was one window, and launching it again started a second
*process* — which looked like multi-window and behaved like a race. Both
copies shared one `%LOCALAPPDATA%` and one WebView2 origin, so both wrote
the same fourteen `gterm-*` keys: tab order, pane layouts, hidden set,
titles. Whichever saved last won, silently. Two tray icons, two claimants
on the summon hotkey, and one set of state being overwritten by both.

Single-instance stopped that. This is the feature it was standing in for.

## What a window owns

The daemon already has the right model: sessions live there, and exactly
one client may attach to a session at a time. So a session is never
*shared* between windows — it is in one of them, and moving it is a
detach and an attach. Nothing in the daemon needs to change.

What has to change is the window's own state, which is currently global:

| state | scope | why |
|---|---|---|
| tab order, pane layouts, split names, tab widths, zen position | **per window** | this is "what is on screen here", and two windows have different answers |
| hidden (parked) sessions | global | parking is about the session, not the window that parked it |
| titles, renames, badges, groups, clipboard history, AI titles | global | properties of a session or of the app, the same wherever it is shown |
| sidebar on/off and width | global | a preference, not a layout |

Per-window keys are suffixed with the window's label. The first window
keeps the unsuffixed keys it already has, so nothing is migrated and an
existing install opens exactly as it did.

## The rule that makes it safe

**A window never adopts a session that is already attached.**

Start-up currently restores every session that is not hidden and not
closing. With a second window open, that would take the first window's
tabs away — the daemon would honour it, because a new attach displaces
the old one, and the user would watch their terminals move.

The daemon already reports `attached` per session. Restoring skips those,
and the picker never lists them.

## Deliberately not doing

**Dragging a tab between windows.** It falls out of the model — detach
there, attach here — but it needs drop targets across window boundaries,
which is a different problem from owning state correctly. Later.

**A window per workspace.** Tempting, since workspaces already name a set
of templates, but it makes "which window does the hotkey mean" much
harder to answer. The summon hotkey targets the last focused window; that
answer should stay easy to explain.

## Test cases

Pure (`tests/windows.mjs`):

1. A per-window key for the first window is the plain key — an existing
   install must not lose its layout to a rename.
2. A per-window key for any other window is suffixed with its label.
3. Global keys are never suffixed, whichever window asks.
4. Two windows produce different keys for the same per-window state, and
   the same key for global state.
5. Closing a window yields exactly its own keys to clean up, and never a
   global one or another window's.

Restore (`tests/restore.mjs`):

6. A session attached elsewhere is not adoptable, even though it is
   alive, unhidden and not closing.
7. It is still listed as a session — it exists, it is simply somewhere.

Daemon (`tests/lifecycle.ps1`):

8. Attaching from a second connection displaces the first, and the first
   is told: the model this rests on, asserted rather than assumed.

Visual (`tests/visual.ps1`):

9. A second window opens, runs its own shell, and typing in it does not
   appear in the first.
10. Closing the second window leaves the first window's tabs intact —
    the failure this whole design is about.
