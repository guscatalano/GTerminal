# GTerminal

A lightweight terminal for Windows with tmux-style session persistence: closing a tab, closing the window, or even rebooting doesn't lose your terminals.

## How it works

- **UI**: [Tauri](https://tauri.app) (WebView2) + [xterm.js](https://xtermjs.org) with the WebGL renderer — far lighter than an Electron equivalent.
- **Sessions**: the same executable, launched as `gterminal --daemon`, owns every shell via ConPTY (`portable-pty`) and outlives the window. The UI is a thin client that attaches over a localhost socket and replays each session's scrollback ring buffer.
- **Reboot survival**: the daemon checkpoints every session (scrollback, working directory, running programs) to `%LOCALAPPDATA%\GTerminal\sessions` every few seconds. After a reboot, sessions come back "cold": a fresh shell in the saved directory with the old scrollback replayed behind a divider. If Claude Code was running in a session, `claude --continue` is pre-typed so a single Enter resumes the conversation.

## Behavior

| Action | Result |
| --- | --- |
| × / `Ctrl+Shift+W` (twice) | Close — session enters "Closing soon" with a countdown, restorable until the timer runs out, then dies |
| Close the window | All sessions keep running; next launch restores them |
| Reboot | Sessions restored cold: cwd + scrollback, fresh shell |
| `exit` in the shell | Session genuinely ends |
| ⟳ menu / `Ctrl+Shift+Z` | Restore (or kill) detached sessions |
| – / `Ctrl+Shift+H` | Park a tab as a pill in the bar; click to bring back |
| `Ctrl+Shift+B` | Toggle the session sidebar (all sessions: open/hidden/cold) |
| Double-click tab | Rename it (custom names stick) |
| Right-click tab | Context menu: rename, tab groups, hide/detach/kill |
| Right-click terminal | Menu: Copy (with selection), Paste, Select all |
| `Ctrl+Shift+T` · `Ctrl+Tab` | New tab · cycle tabs |
| `Ctrl+Shift+C` / `Ctrl+Shift+V` | Copy / paste |

Tabs shrink browser-style as they multiply; overflow collapses into a `+N` menu. Tabs can be organized into colored, collapsible groups (right-click a tab); groups and names persist across restarts and reboots. Tab icons show what's running inside (✳️ Claude Code, 🐍 python, 🦀 cargo, 🐳 docker, …).

**"Oops" grace window**: killing a session doesn't actually kill it — the tab closes but the process keeps running for 5 minutes (a ⌛ "closes in Xm" entry in the sidebar/menus restores it, cancelling the kill entirely). An accidental `exit` is likewise restorable from its checkpoint for the same window. Kill something twice to skip the grace. Configure with `%LOCALAPPDATA%\GTerminal\config.json`: `{"grace_minutes": 10}` (0 disables).

**Config** (`%LOCALAPPDATA%\GTerminal\config.json`, all keys optional):

```json
{
  "grace_minutes": 5,
  "cursor_style": "bar",
  "cursor_blink": true,
  "theme": "one-dark"
}
```

`cursor_style` is `bar` (default, Windows Terminal-like), `block`, or `underline`; `cursor_blink` defaults to true. Cursor settings apply to new windows/tabs.

**Settings** (⚙ button): theme, font family/size, line height, cursor style/blink, and the undo window — applied live and saved to `config.json`. Themes are a whole look, not just colors — each carries its own font, line spacing, and cursor personality, individually overridable: One Dark, Dracula, Nord, Gruvbox Dark, Tokyo Night, Catppuccin Mocha, Solarized Dark, Solarized Light. The whole chrome (tab bar, sidebar, menus) recolors along with the terminal.

Sessions in their grace window get a dedicated **Closing soon** sidebar section with a live m:ss countdown; click to restore, × (twice) to kill immediately.

## Development

Requires Rust (1.85+) and Node.

```sh
npm install
npm run tauri dev     # run
npm run tauri build   # package installer
npm run test:typing   # typing correctness + echo latency regression test
```

`npm test` runs both suites against isolated daemons (scratch state dirs, never your real sessions):

- **typing**: burst-types a payload char-by-char and asserts intact arrival, then measures per-keystroke echo latency (budget p50 < 50ms / p95 < 150ms; typical p50 ≈ 1–2ms).
- **lifecycle**: create/attach, scrollback replay, cwd tracking, detach-keeps-alive, soft-kill grace + restore-cancels-kill, double-kill-is-hard, typed-exit-to-trash, trash resurrection, and full reboot survival (daemon force-killed, sessions restored cold with scrollback + cwd).

Every new feature should land with coverage in one of these suites.

## Known limitations

- The daemon socket is unauthenticated localhost TCP; switching to a user-ACL'd named pipe is the planned hardening step.
- Scrollback checkpoints are capped at 512KB per session and flushed every 3s, so a hard cut can lose the last few seconds.
- PowerShell only for now (pwsh preferred, Windows PowerShell fallback).
