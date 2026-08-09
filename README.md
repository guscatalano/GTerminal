# GTerminal

A lightweight terminal for Windows with tmux-style session persistence: closing a tab, closing the window, or even rebooting doesn't lose your terminals.

## How it works

- **UI**: [Tauri](https://tauri.app) (WebView2) + [xterm.js](https://xtermjs.org) with the WebGL renderer — far lighter than an Electron equivalent.
- **Sessions**: the same executable, launched as `gterminal --daemon`, owns every shell via ConPTY (`portable-pty`) and outlives the window. The UI is a thin client that attaches over a localhost socket and replays each session's scrollback ring buffer.
- **Reboot survival**: the daemon checkpoints every session (scrollback, working directory, running programs) to `%LOCALAPPDATA%\GTerminal\sessions` every few seconds. After a reboot, sessions come back "cold": a fresh shell in the saved directory with the old scrollback replayed behind a divider. If Claude Code was running in a session, `claude --continue` is pre-typed so a single Enter resumes the conversation.

## Behavior

| Action | Result |
| --- | --- |
| × / `Ctrl+Shift+W` / middle-click | Detach — shell keeps running |
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

## Development

Requires Rust (1.85+) and Node.

```sh
npm install
npm run tauri dev     # run
npm run tauri build   # package installer
npm run test:typing   # typing correctness + echo latency regression test
```

`test:typing` runs against an isolated daemon (scratch state dir): it burst-types a payload character-by-character and asserts the shell received it intact, then measures per-keystroke echo latency (budget: p50 < 50ms, p95 < 150ms; typical: p50 ≈ 1–2ms).

## Known limitations

- The daemon socket is unauthenticated localhost TCP; switching to a user-ACL'd named pipe is the planned hardening step.
- Scrollback checkpoints are capped at 512KB per session and flushed every 3s, so a hard cut can lose the last few seconds.
- PowerShell only for now (pwsh preferred, Windows PowerShell fallback).
