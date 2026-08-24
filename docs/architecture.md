# How GTerminal is put together

Two processes, and the split between them is the whole design:

```
  gterminal.exe                        gterminal.exe --daemon
  ┌───────────────────────────┐        ┌──────────────────────────────┐
  │ Tauri shell (Rust)        │        │ session registry             │
  │  tray, hotkey, window      │       │  live:  pid + pty + ring     │
  │  #[tauri::command] bridge │◄──────►│  cold:  ring on disk, no pid │
  ├───────────────────────────┤  TCP   ├──────────────────────────────┤
  │ WebView2 (xterm.js)       │  JSON  │ ConPTY per session           │
  │  tabs, panes, chrome      │        │  checkpoints, transcripts    │
  └───────────────────────────┘        └──────────────────────────────┘
        the window                        where the shells actually live
```

A window is a **client**. Shells belong to the daemon, so closing a
window detaches rather than kills, and the daemon keeps running until its
last session is gone (`exit_if_idle`). This is what makes "close it and
come back later" work, and it is also the source of the awkward cases
documented further down: an update replaces the binary while the *old*
daemon is still serving.

## The wire

Newline-delimited JSON over TCP on loopback. The daemon writes its port
to `%LOCALAPPDATA%\GTerminal\daemon.port`; a client reads that, connects,
and starts one with `--daemon` if nothing answers.

Requests: `list`, `create`, `attach`, `peek`, `write`, `resize`, `kill`,
`detach`. Anything unrecognised is answered `{"ok":false,"error":"bad
request"}` and the connection stays open — which is what a newer window's
request looks like to an older daemon.

Two kinds of traffic share the socket. Control requests get one reply and
close. An `attach` turns the connection into a stream: the full scrollback
replays first, then live output arrives as `{"ev":"data"}` lines until
`detach` or the shell exits (`{"ev":"exit"}`).

**One attacher per session** (`attached: Option<(u64, TcpStream)>`). A
second window attaching takes the session from the first. Sessions move
between windows; they are never shared by two at once.

`list` also reports `protocol`, `version` and `pid`, so a window can tell
when it is newer than the daemon it found — see
[daemon-protocol.md](daemon-protocol.md).

## Sessions: live, cold, closing

- **live** — a ConPTY child, its writer, and a 512 KB ring of recent
  output. Flushed to disk every 3 s if dirty.
- **cold** — the process is gone (reboot, daemon killed, shell exited)
  but `sessions/<id>.json` and `sessions/<id>.ring` remain. Attaching
  *resurrects* it: a fresh shell in the saved cwd with the ring replayed
  above a `── session restored ──` divider. `peek` exists so a window can
  read one without resurrecting it.
- **closing** — killed but inside its grace window (`grace_minutes`,
  default 5). The process is still running; attaching cancels the pending
  kill. A second kill is immediate.

A session nobody ever typed into is not kept when its shell ends — it
holds a prompt and a screenful of erase sequences and nothing else. The
signal is `is_typing()` (escape sequences skipped, what remains judged),
not bytes written, because xterm answers the `ESC[6n` every session opens
with.

Replay always prepends `MODE_RESET`. Without it, replaying a dead TUI's
scrollback re-enables mouse tracking and the user's mouse starts typing
escape codes into a shell.

## On disk

```
%LOCALAPPDATA%\GTerminal\
  config.json          settings; read fresh per use, so most apply live
  daemon.port          the running daemon's port
  sessions\<id>.json   id, created, cwd, shell, saw_input
  sessions\<id>.ring   recent output, capped at 512 KB
  history\*.log/.json  durable transcripts, capped at 10 MB, purged by age
  commands.log         what was run where, for the predictor
  predictor.ps1        regenerated at daemon startup
```

Window-side state — tab order, pane layouts, hidden set, renames, badges,
sidebar width — lives in **localStorage**, not in `config.json`. It
belongs to the window rather than the sessions, and the daemon never sees
it. (WebView2 keeps that store under the OS's own known-folder path, not
`%LOCALAPPDATA%` as redirected by the environment — which is why tests
must set `WEBVIEW2_USER_DATA_FOLDER` to isolate it.)

## The window

xterm.js per pane, with fit/webgl/search/web-links addons.

- **A tab is a tree of panes** (`src/layout.ts`) — a guillotine model, the
  one tmux and i3 use. Leaves are sessions. A tab is identified by the
  session it was opened with; if that pane closes, the identity moves to a
  survivor (`retagTab`).
- **Boot** lists sessions, drops ones that are hidden or closing
  (`src/restore.ts`), asks which to restore past a threshold, then
  rebuilds saved layouts before opening anything left over.
- **Shell integration** is OSC 133 A/B/D emitted by an injected prompt
  function, plus OSC 9;9 for cwd. There is no C mark — PowerShell has no
  about-to-execute hook — so a command's start is inferred from its
  prompt. `src/blocks.ts` turns the marks into blocks with exit codes.
- **Titles** (`src/titles.ts`) prefer what is running over where it is
  running, because six shells in a home directory all read the same.

Logic that decides something worth arguing about is pulled out of
`main.ts` into a plain module with tests: layout, restore, titles, keys,
blocks, format, daemon.

## Rust side of the window

`lib.rs` is the bridge and the OS-facing parts: commands (`list_sessions`,
`create_session`, `attach_session`, `peek_session`, `write_session`,
`resize_session`, `kill_session`, `detach_session`, `daemon_info`,
`restart_daemon`, `summon_toggle`), events to the webview (`pty-output`,
`pty-exit`), the tray, the global hotkey, and the window's own behaviour.

Three Windows details worth knowing:

- **Close hides.** Closing sends the window to the tray so the summon
  hotkey keeps working. Sessions were never at stake either way.
- **Summon toggles on foreground**, asked of `GetForegroundWindow` rather
  than Tauri's `is_focused` — which answers for the window while the
  keyboard focus is in the WebView2 child.
- **Show and hide fade** by layered-window alpha. Moving the window
  instead was visibly steppy; fading the *page* leaves an opaque
  rectangle behind after its contents have gone.

## Building

`vite` builds `src/` into `dist/`, and **cargo embeds `dist/` at compile
time**. A debug build follows `devUrl` instead, loading the UI live from
the vite dev server — so `npm run tauri dev` reloads a running window on
every edit, and a plain `cargo build` binary shows a blank window with no
server running. `npm run app` produces a standalone debug build with the
UI baked in; that is the one to test against.

## Tests

| Suite | What it drives | Why it exists |
|---|---|---|
| `tests/*.mjs` | pure modules, importing `.ts` directly (Node type-stripping) | the decisions: layouts, restore choices, titles, key routing |
| `tests/lifecycle.ps1` | a real daemon over TCP, scratch `LOCALAPPDATA` | protocol, grace windows, resurrection, crash recovery |
| `tests/typing.ps1` | shells through a real ConPTY | what actually reaches the shell, across pwsh/powershell/cmd |
| `tests/visual.ps1` | a real window, synthetic input, video per scene | things only a screen can answer; records `docs/visual/*.avi` |
| `cargo test --lib` | Rust units | fades, tray strings, typing detection |

The visual suite refuses to start if the keyboard or mouse was touched in
the last two minutes: it takes the foreground and types, and would
otherwise land its keystrokes in whatever someone is doing.

Every suite runs against its own `LOCALAPPDATA` and kills only processes
it started. The daemon is shared user infrastructure — never `taskkill
/IM gterminal.exe`, and identify a daemon by the port it listens on
rather than by its name or start time.
