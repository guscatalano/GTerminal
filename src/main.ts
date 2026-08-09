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
  alive: boolean;
}

const tabs = new Map<number, Tab>();
// Output that arrives for a session before its tab is registered (the shell's
// first prompt or the attach replay can beat the invoke resolving).
const pending = new Map<number, string[]>();
let activeId: number | null = null;

const app = document.getElementById("app")!;
const tabbar = document.getElementById("tabbar")!;
const hiddenbar = document.getElementById("hiddenbar")!;
const panes = document.getElementById("panes")!;
const restoreMenu = document.getElementById("restore-menu")!;
const overflowBtn = document.getElementById("overflow") as HTMLButtonElement;
const overflowMenu = document.getElementById("overflow-menu")!;
const hiddenMenu = document.getElementById("hidden-menu")!;
const sidebarList = document.getElementById("sidebar-list")!;

// Sessions the user parked with "hide" — detached in the daemon but shown
// as pills (or a chip) in the tab bar. Persisted across restarts.
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
function titleOf(id: number): string {
  return titles[id] ?? `Session ${id}`;
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
  refreshChrome();
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
      if (key === "B") {
        toggleSidebar();
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
      refreshChrome();
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
    refreshChrome();
    return;
  }
  if (activeId === id) {
    const remaining = orderedIds();
    setActive(remaining[Math.min(i, remaining.length - 1)]);
  }
  refreshChrome();
}

// Closing a tab detaches: the shell keeps running in the daemon and can be
// restored from the ⟳ menu, Ctrl+Shift+Z, the sidebar, or the next launch.
function closeTab(id: number) {
  invoke("detach_session", { id }).catch(() => {});
  removeTab(id);
}

// Hiding also detaches, but parks the session visibly for one-click restore.
async function hideTab(id: number) {
  if (!tabs.has(id)) return;
  invoke("detach_session", { id }).catch(() => {});
  hidden.add(id);
  saveHidden();
  removeTab(id, false);
  if (tabs.size === 0) await createTab();
  refreshChrome();
}

async function restoreHidden(id: number) {
  const sessions = await invoke<SessionInfo[]>("list_sessions").catch(() => []);
  if (sessions.some((s) => s.id === id)) {
    await createTab(id);
  } else {
    // Session died while parked (e.g. killed elsewhere) — drop the pill.
    hidden.delete(id);
    saveHidden();
    refreshChrome();
  }
}

async function killSession(id: number) {
  await invoke("kill_session", { id }).catch(() => {});
  hidden.delete(id);
  saveHidden();
  refreshChrome();
}

// ───────────────────────── chrome: menus, pills, overflow, sidebar ──────────

function closeMenus(except?: HTMLElement) {
  for (const m of [restoreMenu, overflowMenu, hiddenMenu]) {
    if (m !== except) m.classList.remove("open");
  }
}

function menuRow(
  label: string,
  onClick: () => void,
  onKill?: () => void
): HTMLElement {
  const row = document.createElement("div");
  row.className = "menu-row";
  const span = document.createElement("span");
  span.className = "menu-label";
  span.textContent = label;
  row.appendChild(span);
  let killBtn: HTMLElement | null = null;
  if (onKill) {
    killBtn = document.createElement("button");
    killBtn.className = "menu-kill";
    killBtn.textContent = "×";
    killBtn.title = "Kill session";
    killBtn.addEventListener("click", onKill);
    row.appendChild(killBtn);
  }
  row.addEventListener("click", (e) => {
    if (killBtn && e.target === killBtn) return;
    closeMenus();
    onClick();
  });
  return row;
}

/// Browser-style overflow: tabs shrink via CSS down to a floor; tabs that
/// still don't fit are hidden and listed under a "+N ⌄" chip. The active
/// tab is always kept visible.
const MIN_TAB_PX = 104; // tab min-width + gap
const CHIP_PX = 60;
function updateTabOverflow() {
  const buttons = [...tabbar.children] as HTMLElement[];
  if (app.classList.contains("sidebar-on")) {
    overflowBtn.hidden = true;
    return;
  }
  for (const b of buttons) b.style.display = "";
  const avail = tabbar.clientWidth;
  let fit = Math.max(1, Math.floor(avail / MIN_TAB_PX));
  if (buttons.length <= fit) {
    overflowBtn.hidden = true;
    return;
  }
  fit = Math.max(1, Math.floor((avail - CHIP_PX) / MIN_TAB_PX));
  const shown = buttons.slice(0, fit);
  const activeBtn = buttons.find((b) => Number(b.dataset.id) === activeId);
  if (activeBtn && !shown.includes(activeBtn)) {
    shown[shown.length - 1] = activeBtn;
  }
  const overflowed: HTMLElement[] = [];
  for (const b of buttons) {
    if (shown.includes(b)) {
      b.style.display = "";
    } else {
      b.style.display = "none";
      overflowed.push(b);
    }
  }
  overflowBtn.hidden = false;
  overflowBtn.textContent = `+${overflowed.length} ⌄`;
  overflowMenu.innerHTML = "";
  for (const b of overflowed) {
    const id = Number(b.dataset.id);
    overflowMenu.appendChild(menuRow(titleOf(id), () => setActive(id)));
  }
}

function renderHiddenPills() {
  hiddenbar.innerHTML = "";
  if (app.classList.contains("sidebar-on") || hidden.size === 0) return;
  if (hidden.size > 2) {
    // Too many pills would crowd the bar — collapse into one chip.
    const chip = document.createElement("button");
    chip.className = "chip";
    chip.textContent = `◌ ${hidden.size} hidden ⌄`;
    chip.addEventListener("click", (e) => {
      e.stopPropagation();
      hiddenMenu.innerHTML = "";
      for (const id of hidden) {
        hiddenMenu.appendChild(
          menuRow(titleOf(id), () => restoreHidden(id), () => killSession(id))
        );
      }
      closeMenus(hiddenMenu);
      hiddenMenu.classList.toggle("open");
    });
    hiddenbar.appendChild(chip);
    return;
  }
  for (const id of hidden) {
    const pill = document.createElement("div");
    pill.className = "hidden-pill";
    const label = document.createElement("span");
    label.className = "hidden-pill-label";
    label.textContent = titleOf(id);
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
    kill.addEventListener("click", () => killSession(id));
    hiddenbar.appendChild(pill);
  }
}

let sidebarVersion = 0;
async function renderSidebar() {
  if (!app.classList.contains("sidebar-on")) return;
  const version = ++sidebarVersion;
  const sessions = await invoke<SessionInfo[]>("list_sessions").catch(() => []);
  if (version !== sidebarVersion) return;

  sidebarList.innerHTML = "";
  const addRow = (
    dot: string,
    dotClass: string,
    label: string,
    isActive: boolean,
    onClick: () => void,
    actions: Array<[string, string, () => void]>
  ) => {
    const row = document.createElement("div");
    row.className = "side-row" + (isActive ? " active" : "");
    const d = document.createElement("span");
    d.className = `side-dot ${dotClass}`;
    d.textContent = dot;
    const l = document.createElement("span");
    l.className = "side-label";
    l.textContent = label;
    const acts = document.createElement("span");
    acts.className = "side-actions";
    for (const [text, tip, fn] of actions) {
      const b = document.createElement("button");
      b.className = "side-act";
      b.textContent = text;
      b.title = tip;
      b.addEventListener("click", (e) => {
        e.stopPropagation();
        fn();
      });
      acts.appendChild(b);
    }
    row.append(d, l, acts);
    row.addEventListener("click", onClick);
    sidebarList.appendChild(row);
  };

  for (const id of orderedIds()) {
    addRow("●", "open", titleOf(id), id === activeId, () => setActive(id), [
      ["–", "Hide (Ctrl+Shift+H)", () => hideTab(id)],
      ["×", "Detach (Ctrl+Shift+W)", () => closeTab(id)],
    ]);
  }
  for (const id of hidden) {
    addRow("◌", "hidden", `${titleOf(id)}`, false, () => restoreHidden(id), [
      ["×", "Kill session", () => killSession(id)],
    ]);
  }
  for (const s of sessions) {
    if (tabs.has(s.id) || hidden.has(s.id)) continue;
    const suffix = s.alive ? "" : " (cold)";
    addRow("○", "cold", `${titleOf(s.id)}${suffix}`, false, () => createTab(s.id), [
      ["×", "Kill session", () => killSession(s.id)],
    ]);
  }
}

function refreshChrome() {
  requestAnimationFrame(() => {
    updateTabOverflow();
    renderHiddenPills();
    renderSidebar();
  });
}

function toggleSidebar() {
  const on = app.classList.toggle("sidebar-on");
  localStorage.setItem("gterm-sidebar", on ? "1" : "0");
  refreshChrome();
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
    restoreMenu.appendChild(
      menuRow(titleOf(s.id), () => createTab(s.id), async () => {
        await killSession(s.id);
        renderRestoreMenu();
      })
    );
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
    hidden.delete(event.payload.id);
    saveHidden();
    removeTab(event.payload.id);
  });

  document.getElementById("newtab")!.addEventListener("click", () => createTab());
  document.getElementById("sidebar-new")!.addEventListener("click", () => createTab());
  document.getElementById("sidebtn")!.addEventListener("click", toggleSidebar);
  overflowBtn.addEventListener("click", (e) => {
    e.stopPropagation();
    closeMenus(overflowMenu);
    overflowMenu.classList.toggle("open");
  });
  const restoreBtn = document.getElementById("restore")!;
  restoreBtn.addEventListener("click", async (e) => {
    e.stopPropagation();
    if (!restoreMenu.classList.contains("open")) await renderRestoreMenu();
    closeMenus(restoreMenu);
    restoreMenu.classList.toggle("open");
  });
  document.addEventListener("mousedown", (e) => {
    const target = e.target as Node;
    for (const m of [restoreMenu, overflowMenu, hiddenMenu]) {
      if (m.classList.contains("open") && !m.contains(target)) {
        m.classList.remove("open");
      }
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
    if (e.ctrlKey && e.shiftKey && e.key.toUpperCase() === "B") {
      e.preventDefault();
      toggleSidebar();
    }
  });
  new ResizeObserver(() => refreshChrome()).observe(tabbar);

  if (localStorage.getItem("gterm-sidebar") === "1") {
    app.classList.add("sidebar-on");
  }

  // Reattach every surviving session from the daemon; sessions the user
  // parked stay parked. Fresh start otherwise.
  const sessions = await invoke<SessionInfo[]>("list_sessions").catch(() => []);
  const known = new Set(sessions.map((s) => s.id));
  for (const h of [...hidden]) {
    if (!known.has(h)) hidden.delete(h);
  }
  saveHidden();
  for (const s of sessions) {
    if (!hidden.has(s.id)) await createTab(s.id);
  }
  if (tabs.size === 0) await createTab();
  refreshChrome();
}

main();
