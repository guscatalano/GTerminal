// Every keyboard shortcut, in one list, so the settings page and the
// README can both be right at once.
//
// Asked for after Ctrl+Shift+Tab and Ctrl+1..9 turned out to exist and be
// written down nowhere: they were in the key handler and in no table, so
// the only way to find them was to read main.ts. A shortcut nobody can
// discover may as well not be implemented.
//
// The `handler` field is what keeps this honest. It names the code that
// implements each row, and tests/shortcuts.mjs checks that code is still
// there - so deleting a shortcut without deleting its documentation fails
// a test rather than quietly leaving a lie in Settings.

export interface Shortcut {
  /// Displayed exactly as written, e.g. "Ctrl+Shift+T".
  keys: string;
  what: string;
  /// A distinctive fragment of the code implementing it, for the drift
  /// test. Not shown to anyone.
  handler: string;
  /// Only bound in a particular situation, spelled out for the reader.
  only?: string;
}

export interface ShortcutGroup {
  title: string;
  items: Shortcut[];
}

export const SHORTCUTS: ShortcutGroup[] = [
  {
    title: "Tabs",
    items: [
      { keys: "Ctrl+Shift+T", what: "New tab", handler: "createTab" },
      { keys: "Ctrl+Tab", what: "Next tab", handler: "cycleTab(e.shiftKey ? -1 : 1)" },
      { keys: "Ctrl+Shift+Tab", what: "Previous tab", handler: "cycleTab(e.shiftKey ? -1 : 1)" },
      {
        keys: "Ctrl+1 … Ctrl+8",
        what: "Jump straight to that tab",
        handler: "jumpToTab(Number(e.key))",
      },
      {
        keys: "Ctrl+9",
        what: "Jump to the last tab, however many there are",
        handler: "n === 9 ? ids[ids.length - 1]",
      },
      {
        keys: "Ctrl+Shift+W",
        what: "Close the tab — press twice; the session stays restorable",
        handler: "closeTab",
      },
      { keys: "Ctrl+Shift+H", what: "Park the tab as a pill in the bar", handler: "hideTab" },
    ],
  },
  {
    title: "Panes",
    items: [
      { keys: "Ctrl+Shift+D", what: "Split the terminal", handler: "splitPane" },
      {
        keys: "Alt+← ↑ → ↓",
        what: "Move focus between panes",
        handler: "focusNeighbour(arrow)",
        only: "while the tab is split",
      },
      {
        keys: "Alt+1 … Alt+9",
        what: "Jump to a numbered pane, matching the overlay Alt shows",
        handler: "focusPaneByNumber(Number(e.key))",
        only: "while the tab is split",
      },
      {
        keys: "Ctrl+Shift+Alt+← ↑ → ↓",
        what: "Move the pane itself",
        handler: "movePaneDir(arrow)",
        only: "while the tab is split",
      },
      { keys: "Ctrl+Shift+A", what: "Arrange panes", handler: "arrange" },
    ],
  },
  {
    title: "Text",
    items: [
      { keys: "Ctrl+Shift+C", what: "Copy the selection", handler: "pushClip(sel)" },
      { keys: "Ctrl+Shift+V", what: "Paste", handler: "pasteClipboardInto" },
      {
        keys: "Ctrl+V",
        what: "Paste",
        handler: 'k === "V" && ctx.ctrlVPaste',
        only: "when enabled in Settings, and never over a full-screen program",
      },
      {
        keys: "Ctrl+F",
        what: "Find in the terminal",
        handler: 'k === "F" && ctx.ctrlFFind',
        only: "when enabled in Settings, and never over a full-screen program",
      },
      {
        keys: "Ctrl+Shift+↑ / ↓",
        what: "Jump prompt to prompt — skip a build log in one keystroke",
        handler: "jumpPrompt(",
      },
    ],
  },
  {
    title: "Window",
    items: [
      { keys: "F11", what: "Full screen — terminal only", handler: "toggleZen" },
      { keys: "Ctrl+Shift+N", what: "Open another window", handler: "openAnotherWindow()" },
      { keys: "Ctrl+Shift+B", what: "Toggle the session sidebar", handler: "toggleSidebar" },
      { keys: "Ctrl+Shift+Z", what: "Restore a detached session", handler: "renderRestoreMenu" },
      { keys: "Ctrl+Shift+S", what: "Toggle the status bar", handler: "toggleStatusBar" },
    ],
  },
];

/// Flattened, for tests and for search.
export function allShortcuts(): Shortcut[] {
  return SHORTCUTS.flatMap((g) => g.items);
}
