import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { WebglAddon } from "@xterm/addon-webgl";
import "@xterm/xterm/css/xterm.css";
import "./styles.css";

interface Tab {
  id: number;
  term: Terminal;
  fit: FitAddon;
  pane: HTMLElement;
  button: HTMLElement;
  label: HTMLElement;
}

interface SessionInfo {
  id: number;
  created_ms: number;
  attached: boolean;
}

const tabs = new Map<number, Tab>();
// Output that arrives for a session before its tab is registered (the shell's
// first prompt or the attach replay can beat the invoke resolving).
const pending = new Map<number, string[]>();
let activeId: number | null = null;

const tabbar = document.getElementById("tabbar")!;
const hiddenbar = document.getElementById("hiddenbar")!;
const panes = document.getElementById("panes")!;
const restoreMenu = document.getElementById("restore-menu")!;

// Sessions the user parked with "hide" — detached in the daemon but shown
// as pills in the tab bar. Persisted so they stay parked across restarts.
const hidden = new Set<number>(
  JSON.parse(localStorage.getItem("gterm-hidden") ?? "[]") as number[]
);
function saveHidden() {
  localStorage.setItem("gterm-hidden", JSON.stringify([...hidden]));
}

// Session ids reset when the daemon restarts, so stale entries are harmless.
const titles: Record<string, string> = JSON.parse(
  localStorage.getItem("gterm-titles") ?? "{}"
);
function saveTitle(id: number, title: string) {
  titles[id] = title;
  localStorage.setItem("gterm-titles", JSON.stringify(titles));
}

const THEME = {
  background: "#0f1115",
  foreground: "#d7dae0",
  cursor: "#d7dae0",
  cursorAccent: "#0f1115",
  selectionBackground: "#33415580",
  black: "#1c1f26",
  red: "#e06c75",
  green: "#98c379",
  yellow: "#e5c07b",
  blue: "#61afef",
  magenta: "#c678dd",
  cyan: "#56b6c2",
  white: "#d7dae0",
  brightBlack: "#5c6370",
  brightRed: "#ef7d85",
  brightGreen: "#a9d387",
  brightYellow: "#f0cd8a",
  brightBlue: "#74bdf7",
  brightMagenta: "#d48ce8",
  brightCyan: "#67c5d0",
  brightWhite: "#f0f2f6",
};

function orderedIds(): number[] {
  return [...tabbar.children].map((el) => Number((el as HTMLElement).dataset.id));
}

function setActive(id: number) {
  const tab = tabs.get(id);
  if (!tab) return;
  activeId = id;
  for (const [tid, t] of tabs) {
    t.pane.classList.toggle("active", tid === id);
    t.button.classList.toggle("active", tid === id);
  }
  fitTab(tab);
  tab.term.focus();
}

function fitTab(tab: Tab) {
  if (tab.pane.clientWidth === 0 || tab.pane.clientHeight === 0) return;
  const before = { cols: tab.term.cols, rows: tab.term.rows };
  tab.fit.fit();
  if (tab.term.cols !== before.cols || tab.term.rows !== before.rows) {
    invoke("resize_session", { id: tab.id, cols: tab.term.cols, rows: tab.term.rows }).catch(() => {});
  }
}

async function detachedSessions(): Promise<SessionInfo[]> {
  const sessions = await invoke<SessionInfo[]>("list_sessions").catch(() => []);
  return sessions.filter((s) => !tabs.has(s.id));
}

async function restoreLast() {
  const detached = await detachedSessions();
  if (detached.length) await createTab(detached[detached.length - 1].id);
}

function makeShortcutHandler(getId: () => number) {
  return (e: KeyboardEvent): boolean => {
    if (e.type !== "keydown") return true;
    if (e.ctrlKey && e.shiftKey && !e.altKey) {
      const key = e.key.toUpperCase();
      if (key === "T") {
        createTab();
        return false;
      }
      if (key === "W") {
        closeTab(getId());
        return false;
      }
      if (key === "H") {
        hideTab(getId());
        return false;
      }
      if (key === "Z") {
        restoreLast();
        return false;
      }
      if (key === "C") {
        const tab = tabs.get(getId());
        const sel = tab?.term.getSelection();
        if (sel) navigator.clipboard.writeText(sel).catch(() => {});
        return false;
      }
      if (key === "V") {
        navigator.clipboard
          .readText()
          .then((text) => text && invoke("write_session", { id: getId(), data: text }))
          .catch(() => {});
        return false;
      }
    }
    if (e.ctrlKey && !e.altKey && e.key === "Tab") {
      cycleTab(e.shiftKey ? -1 : 1);
      return false;
    }
    return true;
  };
}

function cycleTab(dir: number) {
  const ids = orderedIds();
  if (ids.length < 2 || activeId === null) return;
  const i = ids.indexOf(activeId);
  setActive(ids[(i + dir + ids.length) % ids.length]);
}

async function createTab(attachId?: number) {
  const pane = document.createElement("div");
  pane.className = "pane active";
  panes.appendChild(pane);

  const term = new Terminal({
    fontFamily: '"Cascadia Mono", Consolas, monospace',
    fontSize: 14,
    lineHeight: 1.1,
    cursorBlink: true,
    scrollback: 10000,
    theme: THEME,
    allowProposedApi: true,
  });
  const fit = new FitAddon();
  term.loadAddon(fit);
  term.open(pane);
  try {
    term.loadAddon(new WebglAddon());
  } catch {
    // WebGL unavailable; xterm falls back to the DOM renderer.
  }
  fit.fit();

  let id: number;
  try {
    if (attachId !== undefined) {
      id = attachId;
      await invoke("attach_session", { id, cols: term.cols, rows: term.rows });
    } else {
      id = await invoke<number>("create_session", { cols: term.cols, rows: term.rows });
    }
  } catch (err) {
    console.error(`Failed to ${attachId !== undefined ? "restore" : "start"} session:`, err);
    term.dispose();
    pane.remove();
    return;
  }

  if (hidden.delete(id)) {
    saveHidden();
    renderHiddenPills();
  }

  const button = document.createElement("div");
  button.className = "tab";
  button.dataset.id = String(id);
  const label = document.createElement("span");
  label.className = "tab-label";
  label.textContent = titles[id] ?? "PowerShell";
  const hide = document.createElement("button");
  hide.className = "tab-close";
  hide.textContent = "–";
  hide.title = "Hide tab — park it aside, still running (Ctrl+Shift+H)";
  const close = document.createElement("button");
  close.className = "tab-close";
  close.textContent = "×";
  close.title = "Detach tab — session keeps running (Ctrl+Shift+W)";
  button.append(label, hide, close);
  tabbar.appendChild(button);

  const tab: Tab = { id, term, fit, pane, button, label };
  tabs.set(id, tab);

  button.addEventListener("mousedown", (e) => {
    if (e.target !== close && e.target !== hide) setActive(id);
  });
  button.addEventListener("auxclick", (e) => {
    if (e.button === 1) closeTab(id);
  });
  hide.addEventListener("click", () => hideTab(id));
  close.addEventListener("click", () => closeTab(id));

  term.onData((data) => {
    invoke("write_session", { id, data }).catch(() => {});
  });
  term.onTitleChange((title) => {
    if (title.trim()) {
      label.textContent = title;
      saveTitle(id, title);
    }
  });
  term.attachCustomKeyEventHandler(makeShortcutHandler(() => id));

  const observer = new ResizeObserver(() => {
    if (activeId === id) fitTab(tab);
  });
  observer.observe(pane);

  const backlog = pending.get(id);
  if (backlog) {
    pending.delete(id);
    for (const chunk of backlog) term.write(chunk);
  }

  setActive(id);
}

function removeTab(id: number, closeWindowIfLast = true) {
  const tab = tabs.get(id);
  if (!tab) return;
  tabs.delete(id);
  const ids = orderedIds();
  const i = ids.indexOf(id);
  tab.term.dispose();
  tab.pane.remove();
  tab.button.remove();
  if (tabs.size === 0) {
    if (closeWindowIfLast) getCurrentWindow().close();
    return;
  }
  if (activeId === id) {
    const remaining = orderedIds();
    setActive(remaining[Math.min(i, remaining.length - 1)]);
  }
}

// Closing a tab detaches: the shell keeps running in the daemon and can be
// restored from the ⟳ menu, Ctrl+Shift+Z, or the next launch.
function closeTab(id: number) {
  invoke("detach_session", { id }).catch(() => {});
  removeTab(id);
}

// Hiding also detaches, but parks the session as a visible pill in the tab
// bar for one-click restore. Hidden state survives app restarts.
async function hideTab(id: number) {
  if (!tabs.has(id)) return;
  invoke("detach_session", { id }).catch(() => {});
  hidden.add(id);
  saveHidden();
  removeTab(id, false);
  renderHiddenPills();
  if (tabs.size === 0) await createTab();
}

async function restoreHidden(id: number) {
  const sessions = await invoke<SessionInfo[]>("list_sessions").catch(() => []);
  if (sessions.some((s) => s.id === id)) {
    await createTab(id);
  } else {
    // Session died while parked (e.g. killed elsewhere) — drop the pill.
    hidden.delete(id);
    saveHidden();
    renderHiddenPills();
  }
}

function renderHiddenPills() {
  hiddenbar.innerHTML = "";
  for (const id of hidden) {
    const pill = document.createElement("div");
    pill.className = "hidden-pill";
    const label = document.createElement("span");
    label.className = "hidden-pill-label";
    label.textContent = titles[id] ?? `Session ${id}`;
    label.title = "Restore hidden session";
    const kill = document.createElement("button");
    kill.className = "hidden-pill-kill";
    kill.textContent = "×";
    kill.title = "Kill session";
    pill.append(label, kill);
    pill.addEventListener("click", (e) => {
      if (e.target === kill) return;
      restoreHidden(id);
    });
    kill.addEventListener("click", async () => {
      await invoke("kill_session", { id }).catch(() => {});
      hidden.delete(id);
      saveHidden();
      renderHiddenPills();
    });
    hiddenbar.appendChild(pill);
  }
}

async function renderRestoreMenu() {
  const detached = await detachedSessions();
  restoreMenu.innerHTML = "";
  if (!detached.length) {
    const empty = document.createElement("div");
    empty.className = "restore-empty";
    empty.textContent = "No detached sessions";
    restoreMenu.appendChild(empty);
    return;
  }
  for (const s of detached) {
    const row = document.createElement("div");
    row.className = "restore-row";
    const label = document.createElement("span");
    label.className = "restore-label";
    label.textContent = titles[s.id] ?? `Session ${s.id}`;
    const kill = document.createElement("button");
    kill.className = "restore-kill";
    kill.textContent = "×";
    kill.title = "Kill session";
    row.append(label, kill);
    row.addEventListener("click", (e) => {
      if (e.target === kill) return;
      restoreMenu.classList.remove("open");
      createTab(s.id);
    });
    kill.addEventListener("click", async () => {
      await invoke("kill_session", { id: s.id }).catch(() => {});
      renderRestoreMenu();
    });
    restoreMenu.appendChild(row);
  }
}

async function main() {
  await listen<{ id: number; data: string }>("pty-output", (event) => {
    const tab = tabs.get(event.payload.id);
    if (tab) {
      tab.term.write(event.payload.data);
    } else {
      const backlog = pending.get(event.payload.id) ?? [];
      backlog.push(event.payload.data);
      pending.set(event.payload.id, backlog);
    }
  });
  await listen<{ id: number }>("pty-exit", (event) => {
    delete titles[event.payload.id];
    localStorage.setItem("gterm-titles", JSON.stringify(titles));
    removeTab(event.payload.id);
  });

  document.getElementById("newtab")!.addEventListener("click", () => createTab());
  const restoreBtn = document.getElementById("restore")!;
  restoreBtn.addEventListener("click", async () => {
    if (!restoreMenu.classList.contains("open")) await renderRestoreMenu();
    restoreMenu.classList.toggle("open");
  });
  document.addEventListener("mousedown", (e) => {
    const target = e.target as Node;
    if (!restoreMenu.contains(target) && target !== restoreBtn) {
      restoreMenu.classList.remove("open");
    }
  });
  window.addEventListener("keydown", (e) => {
    if (e.ctrlKey && e.shiftKey && e.key.toUpperCase() === "T") {
      e.preventDefault();
      createTab();
    }
    if (e.ctrlKey && e.shiftKey && e.key.toUpperCase() === "Z") {
      e.preventDefault();
      restoreLast();
    }
  });

  // Reattach every surviving session from the daemon; sessions the user
  // parked stay parked as pills. Fresh start otherwise.
  const sessions = await invoke<SessionInfo[]>("list_sessions").catch(() => []);
  const known = new Set(sessions.map((s) => s.id));
  for (const h of [...hidden]) {
    if (!known.has(h)) hidden.delete(h);
  }
  saveHidden();
  renderHiddenPills();
  for (const s of sessions) {
    if (!hidden.has(s.id)) await createTab(s.id);
  }
  if (tabs.size === 0) await createTab();
}

main();
