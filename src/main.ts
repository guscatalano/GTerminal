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
  icon: HTMLElement;
}

interface SessionInfo {
  id: number;
  created_ms: number;
  attached: boolean;
  alive: boolean;
  expires_ms: number | null;
  running: string[];
}

// Icon for whatever is running inside a session, by program name.
const ICON_RULES: Array<[RegExp, string]> = [
  [/^claude/i, "✳️"],
  [/^(vim|nvim|nano|emacs|hx)$/i, "📝"],
  [/^python/i, "🐍"],
  [/^(node|bun|deno)$/i, "🟩"],
  [/^(cargo|rustc)$/i, "🦀"],
  [/^docker/i, "🐳"],
  [/^(ssh|curl|wget|ping)$/i, "🌐"],
  [/^git/i, "🌿"],
  [/^(npm|pnpm|yarn|vite)$/i, "📦"],
  [/^(dotnet|msbuild)$/i, "🟪"],
  [/^(cl|gcc|clang|cmake|make|ninja|link)$/i, "🔨"],
];
const SHELLS = /^(pwsh|powershell|cmd|conhost)$/i;
function iconFor(running: string[]): string {
  const progs = running.filter((n) => !SHELLS.test(n));
  for (const [re, icon] of ICON_RULES) {
    for (const name of progs) if (re.test(name)) return icon;
  }
  return progs.length ? "⚙️" : "";
}

function minutesLeft(expiresMs: number): number {
  return Math.max(1, Math.ceil((expiresMs - Date.now()) / 60_000));
}
function expirySuffix(s: SessionInfo): string {
  return s.expires_ms ? ` · closes in ${minutesLeft(s.expires_ms)}m` : s.alive ? "" : " (cold)";
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

// User-given names win over shell-reported titles and never get overwritten.
const customTitles: Record<string, string> = JSON.parse(
  localStorage.getItem("gterm-names") ?? "{}"
);
function saveCustomTitles() {
  localStorage.setItem("gterm-names", JSON.stringify(customTitles));
}
function titleOf(id: number): string {
  return customTitles[id] ?? titles[id] ?? `Session ${id}`;
}

// ── tab groups (Chrome-style: colored, collapsible) ─────────────────────
interface TabGroup {
  id: string;
  name: string;
  color: string;
  collapsed: boolean;
}
const GROUP_COLORS = ["#61afef", "#98c379", "#e5c07b", "#e06c75", "#c678dd", "#56b6c2"];
const groupState: { groups: TabGroup[]; assign: Record<string, string> } = JSON.parse(
  localStorage.getItem("gterm-groups") ?? '{"groups":[],"assign":{}}'
);
function saveGroups() {
  localStorage.setItem("gterm-groups", JSON.stringify(groupState));
}
function groupById(gid: string | undefined): TabGroup | undefined {
  return groupState.groups.find((g) => g.id === gid);
}
function groupOf(id: number): TabGroup | undefined {
  return groupById(groupState.assign[id]);
}
function createGroup(): TabGroup {
  const g: TabGroup = {
    id: (crypto.randomUUID?.() ?? String(Date.now())) as string,
    name: `Group ${groupState.groups.length + 1}`,
    color: GROUP_COLORS[groupState.groups.length % GROUP_COLORS.length],
    collapsed: false,
  };
  groupState.groups.push(g);
  return g;
}
function assignToGroup(id: number, gid: string) {
  groupState.assign[id] = gid;
  saveGroups();
  refreshChrome();
}
function removeFromGroup(id: number) {
  delete groupState.assign[id];
  pruneGroups();
  saveGroups();
  refreshChrome();
}
function pruneGroups() {
  const used = new Set(Object.values(groupState.assign));
  groupState.groups = groupState.groups.filter((g) => used.has(g.id));
}

// Insertion order of tabs; grouping reorders members to sit together.
let tabOrder: number[] = [];

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
  return [...tabbar.querySelectorAll<HTMLElement>(".tab")].map((el) => Number(el.dataset.id));
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
        closeTabViaKeyboard(getId());
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

/// Two-step confirm for destructive buttons: first click arms (red "?"),
/// second click within 2s executes. A stray click does nothing.
function requireConfirm(el: HTMLElement, run: () => void) {
  const orig = el.textContent;
  let timer: number | undefined;
  el.addEventListener("click", (e) => {
    e.stopPropagation();
    if (el.classList.contains("armed")) {
      window.clearTimeout(timer);
      el.classList.remove("armed");
      el.textContent = orig;
      run();
    } else {
      el.classList.add("armed");
      el.textContent = "?";
      timer = window.setTimeout(() => {
        el.classList.remove("armed");
        el.textContent = orig;
      }, 2000);
    }
  });
}

// Ctrl+Shift+W must be pressed twice within 2s to detach.
let closeKeyId = -1;
let closeKeyAt = 0;
function closeTabViaKeyboard(id: number) {
  const now = Date.now();
  if (closeKeyId === id && now - closeKeyAt < 2000) {
    closeKeyId = -1;
    closeTab(id);
    return;
  }
  closeKeyId = id;
  closeKeyAt = now;
  const btn = tabs.get(id)?.button.querySelectorAll<HTMLElement>(".tab-close")[1];
  if (btn) {
    btn.classList.add("armed");
    window.setTimeout(() => btn.classList.remove("armed"), 2000);
  }
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
  const icon = document.createElement("span");
  icon.className = "tab-icon";
  const label = document.createElement("span");
  label.className = "tab-label";
  label.textContent = customTitles[id] ?? titles[id] ?? "PowerShell";
  const hide = document.createElement("button");
  hide.className = "tab-close";
  hide.textContent = "–";
  hide.title = "Hide tab — park it aside, still running (Ctrl+Shift+H)";
  const close = document.createElement("button");
  close.className = "tab-close";
  close.textContent = "×";
  close.title = "Detach tab — click twice to confirm (Ctrl+Shift+W ×2)";
  button.append(icon, label, hide, close);
  tabbar.appendChild(button);
  tabOrder.push(id);

  const tab: Tab = { id, term, fit, pane, button, label, icon };
  tabs.set(id, tab);

  button.addEventListener("mousedown", (e) => {
    if (e.target !== close && e.target !== hide) setActive(id);
  });
  button.addEventListener("dblclick", (e) => {
    if (e.target === label) renameTab(id);
  });
  button.addEventListener("contextmenu", (e) => {
    e.preventDefault();
    e.stopPropagation();
    showTabContextMenu(e.clientX, e.clientY, id);
  });
  hide.addEventListener("click", () => hideTab(id));
  requireConfirm(close, () => closeTab(id));

  // Right-click in the terminal: copy the selection if there is one,
  // otherwise paste — Windows Terminal behavior. (The WebView2 default
  // context menu is suppressed globally.)
  pane.addEventListener("contextmenu", (e) => {
    e.preventDefault();
    const sel = term.getSelection();
    if (sel) {
      navigator.clipboard.writeText(sel).catch(() => {});
      term.clearSelection();
    } else {
      navigator.clipboard
        .readText()
        .then((text) => text && invoke("write_session", { id, data: text }))
        .catch(() => {});
    }
  });

  term.onData((data) => {
    invoke("write_session", { id, data }).catch(() => {});
  });
  term.onTitleChange((title) => {
    if (title.trim()) {
      saveTitle(id, title);
      if (!customTitles[id]) {
        label.textContent = title;
        refreshChrome();
      }
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
  tabOrder = tabOrder.filter((t) => t !== id);
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
  delete groupState.assign[id];
  pruneGroups();
  saveGroups();
  refreshChrome();
}

// ───────────────────────── chrome: menus, pills, overflow, sidebar ──────────

const ctxMenu = document.createElement("div");
ctxMenu.className = "menu ctx";
document.body.appendChild(ctxMenu);

function closeMenus(except?: HTMLElement) {
  for (const m of [restoreMenu, overflowMenu, hiddenMenu, ctxMenu]) {
    if (m !== except) m.classList.remove("open");
  }
}

type CtxItem = { label: string; action: () => void; color?: string; confirm?: boolean } | "sep";
function showContextMenu(x: number, y: number, items: CtxItem[]) {
  ctxMenu.innerHTML = "";
  for (const it of items) {
    if (it === "sep") {
      const s = document.createElement("div");
      s.className = "menu-sep";
      ctxMenu.appendChild(s);
      continue;
    }
    let row: HTMLElement;
    if (it.confirm) {
      // Destructive items arm on first click and run on the second.
      row = document.createElement("div");
      row.className = "menu-row";
      const span = document.createElement("span");
      span.className = "menu-label";
      span.textContent = it.label;
      row.appendChild(span);
      row.addEventListener("click", () => {
        if (row.classList.contains("armed")) {
          closeMenus();
          it.action();
        } else {
          row.classList.add("armed");
          span.textContent = `${it.label} — sure?`;
          window.setTimeout(() => {
            row.classList.remove("armed");
            span.textContent = it.label;
          }, 2000);
        }
      });
    } else {
      row = menuRow(it.label, it.action);
    }
    if (it.color) {
      const dot = document.createElement("span");
      dot.className = "menu-dot";
      dot.style.background = it.color;
      row.prepend(dot);
    }
    ctxMenu.appendChild(row);
  }
  closeMenus(ctxMenu);
  ctxMenu.classList.add("open");
  ctxMenu.style.left = `${Math.min(x, window.innerWidth - ctxMenu.offsetWidth - 8)}px`;
  ctxMenu.style.top = `${Math.min(y, window.innerHeight - ctxMenu.offsetHeight - 8)}px`;
}

function showTabContextMenu(x: number, y: number, id: number) {
  const current = groupState.assign[id];
  const items: CtxItem[] = [{ label: "Rename tab", action: () => renameTab(id) }, "sep"];
  for (const g of groupState.groups) {
    if (g.id === current) continue;
    items.push({ label: `Add to "${g.name}"`, color: g.color, action: () => assignToGroup(id, g.id) });
  }
  items.push({
    label: "New group with tab",
    action: () => {
      const g = createGroup();
      assignToGroup(id, g.id);
    },
  });
  if (current) {
    items.push({ label: "Remove from group", action: () => removeFromGroup(id) });
  }
  items.push(
    "sep",
    { label: "Hide tab", action: () => hideTab(id) },
    { label: "Detach tab", action: () => closeTab(id), confirm: true },
    { label: "Kill session", action: () => killAndClose(id), confirm: true }
  );
  showContextMenu(x, y, items);
}

async function killAndClose(id: number) {
  removeTab(id, false);
  await killSession(id);
  if (tabs.size === 0) await createTab();
}

/// True while an inline rename input is open. Chrome rebuilds re-parent the
/// tab buttons, which would blur (and thus instantly commit) the input — so
/// refreshChrome() is paused for the duration.
let renameActive = false;

/// Swap an element's text for an input; commit on Enter/blur, cancel on Esc.
function inlineRename(el: HTMLElement, current: string, commit: (v: string | null) => void) {
  renameActive = true;
  const input = document.createElement("input");
  input.className = "rename-input";
  input.value = current;
  el.replaceChildren(input);
  input.focus();
  input.select();
  let done = false;
  const finish = (val: string | null) => {
    if (done) return;
    done = true;
    renameActive = false;
    commit(val);
  };
  // Clicks inside the input must not bubble into tab activation, which
  // would steal focus back to the terminal and blur-commit the rename.
  for (const ev of ["mousedown", "click", "dblclick", "contextmenu"]) {
    input.addEventListener(ev, (e) => e.stopPropagation());
  }
  input.addEventListener("keydown", (e) => {
    e.stopPropagation();
    if (e.key === "Enter") finish(input.value.trim() || null);
    if (e.key === "Escape") finish(null);
  });
  input.addEventListener("blur", () => finish(input.value.trim() || null));
}

function renameTab(id: number) {
  const tab = tabs.get(id);
  if (!tab) return;
  inlineRename(tab.label, titleOf(id), (v) => {
    if (v) {
      customTitles[id] = v;
    } else if (v === null && !customTitles[id]) {
      // cancelled, nothing to change
    }
    saveCustomTitles();
    tab.label.textContent = titleOf(id);
    refreshChrome();
  });
}

/// Rebuild the tab bar in order: ungrouped tabs stay put; a group's chip and
/// members sit together at the position of its first member. Collapsed
/// groups hide their members (except the active tab, which stays visible).
function layoutTabbar() {
  const frag = document.createDocumentFragment();
  const done = new Set<number>();
  for (const id of tabOrder) {
    if (done.has(id) || !tabs.has(id)) continue;
    const g = groupOf(id);
    if (g) {
      const members = tabOrder.filter((m) => tabs.has(m) && groupState.assign[m] === g.id);
      for (const m of members) done.add(m);
      frag.appendChild(makeGroupChip(g, members.length));
      for (const m of members) {
        const b = tabs.get(m)!.button;
        b.style.setProperty("--gc", g.color);
        b.classList.add("grouped");
        b.style.display = g.collapsed && m !== activeId ? "none" : "";
        frag.appendChild(b);
      }
    } else {
      done.add(id);
      const b = tabs.get(id)!.button;
      b.classList.remove("grouped");
      b.style.removeProperty("--gc");
      b.style.display = "";
      frag.appendChild(b);
    }
  }
  tabbar.replaceChildren(frag);
}

function makeGroupChip(g: TabGroup, count: number): HTMLElement {
  const chip = document.createElement("div");
  chip.className = "group-chip" + (g.collapsed ? " collapsed" : "");
  chip.style.setProperty("--gc", g.color);
  const name = document.createElement("span");
  name.textContent = g.collapsed ? `${g.name} (${count})` : g.name;
  chip.appendChild(name);
  chip.title = g.collapsed ? "Expand group" : "Collapse group";
  chip.addEventListener("click", () => {
    if (!g.collapsed && activeId !== null && groupState.assign[activeId] === g.id) {
      // Collapsing the active tab's group: move focus outside it first.
      const outside = orderedIds().find((id) => groupState.assign[id] !== g.id);
      if (outside !== undefined) setActive(outside);
    }
    g.collapsed = !g.collapsed;
    saveGroups();
    refreshChrome();
  });
  chip.addEventListener("contextmenu", (e) => {
    e.preventDefault();
    e.stopPropagation();
    showContextMenu(e.clientX, e.clientY, [
      {
        label: "Rename group",
        action: () =>
          inlineRename(name, g.name, (v) => {
            if (v) g.name = v;
            saveGroups();
            refreshChrome();
          }),
      },
      {
        label: "Change color",
        color: g.color,
        action: () => {
          g.color = GROUP_COLORS[(GROUP_COLORS.indexOf(g.color) + 1) % GROUP_COLORS.length];
          saveGroups();
          refreshChrome();
        },
      },
      {
        label: "Ungroup",
        action: () => {
          for (const k of Object.keys(groupState.assign)) {
            if (groupState.assign[k] === g.id) delete groupState.assign[k];
          }
          pruneGroups();
          saveGroups();
          refreshChrome();
        },
      },
    ]);
  });
  return chip;
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
    killBtn.title = "Kill session (click twice)";
    requireConfirm(killBtn, onKill);
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
  if (app.classList.contains("sidebar-on")) {
    overflowBtn.hidden = true;
    return;
  }
  // Collapsed group members are already display:none from layout and are
  // excluded; group chips eat into the available width.
  const buttons = [...tabbar.querySelectorAll<HTMLElement>(".tab")].filter(
    (b) => b.style.display !== "none"
  );
  const chipsW = [...tabbar.querySelectorAll<HTMLElement>(".group-chip")].reduce(
    (a, c) => a + c.offsetWidth + 4,
    0
  );
  const avail = tabbar.clientWidth - chipsW;
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
    kill.title = "Kill session (click twice)";
    pill.append(label, kill);
    pill.addEventListener("click", (e) => {
      if (e.target === kill) return;
      restoreHidden(id);
    });
    requireConfirm(kill, () => killSession(id));
    hiddenbar.appendChild(pill);
  }
}

/// Poll session state: update tab icons from what's running, and keep the
/// sidebar countdowns fresh.
async function updateLiveInfo() {
  const sessions = await invoke<SessionInfo[]>("list_sessions").catch(() => []);
  for (const s of sessions) {
    const tab = tabs.get(s.id);
    // `?? []` tolerates an older daemon that predates the running field.
    if (tab) tab.icon.textContent = iconFor(s.running ?? []);
  }
  renderSidebar(sessions);
}

let sidebarVersion = 0;
async function renderSidebar(prefetched?: SessionInfo[]) {
  if (!app.classList.contains("sidebar-on")) return;
  const version = ++sidebarVersion;
  const sessions =
    prefetched ?? (await invoke<SessionInfo[]>("list_sessions").catch(() => []));
  if (version !== sidebarVersion) return;

  sidebarList.innerHTML = "";
  const addRow = (
    dot: string,
    dotClass: string,
    label: string,
    isActive: boolean,
    onClick: () => void,
    actions: Array<[string, string, () => void, boolean?]>
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
    for (const [text, tip, fn, confirm] of actions) {
      const b = document.createElement("button");
      b.className = "side-act";
      b.textContent = text;
      b.title = tip;
      if (confirm) {
        requireConfirm(b, fn);
      } else {
        b.addEventListener("click", (e) => {
          e.stopPropagation();
          fn();
        });
      }
      acts.appendChild(b);
    }
    row.append(d, l, acts);
    row.addEventListener("click", onClick);
    sidebarList.appendChild(row);
  };

  const addHeader = (name: string, color?: string) => {
    const h = document.createElement("div");
    h.className = "side-header";
    if (color) {
      const dot = document.createElement("span");
      dot.className = "menu-dot";
      dot.style.background = color;
      h.appendChild(dot);
    }
    h.appendChild(document.createTextNode(name));
    sidebarList.appendChild(h);
  };

  const openRow = (id: number) =>
    addRow("●", "open", titleOf(id), id === activeId, () => setActive(id), [
      ["–", "Hide (Ctrl+Shift+H)", () => hideTab(id)],
      ["×", "Detach — click twice", () => closeTab(id), true],
    ]);
  const hiddenRow = (id: number) =>
    addRow("◌", "hidden", titleOf(id), false, () => restoreHidden(id), [
      ["×", "Kill session — click twice", () => killSession(id), true],
    ]);
  const coldRow = (s: SessionInfo) =>
    addRow(
      s.expires_ms ? "⌛" : "○",
      s.expires_ms ? "doomed" : "cold",
      `${titleOf(s.id)}${expirySuffix(s)}`,
      false,
      () => createTab(s.id),
      [["×", "Kill session — click twice", () => killSession(s.id), true]]
    );

  const inGroup = (id: number, gid: string) => groupState.assign[id] === gid;
  for (const g of groupState.groups) {
    addHeader(g.name, g.color);
    for (const id of orderedIds()) if (inGroup(id, g.id)) openRow(id);
    for (const id of hidden) if (inGroup(id, g.id)) hiddenRow(id);
    for (const s of sessions) {
      if (!tabs.has(s.id) && !hidden.has(s.id) && inGroup(s.id, g.id)) coldRow(s);
    }
  }
  const ungrouped = (id: number) => !groupById(groupState.assign[id]);
  if (groupState.groups.length) addHeader("Ungrouped");
  for (const id of orderedIds()) if (ungrouped(id)) openRow(id);
  for (const id of hidden) if (ungrouped(id)) hiddenRow(id);
  for (const s of sessions) {
    if (!tabs.has(s.id) && !hidden.has(s.id) && ungrouped(s.id)) coldRow(s);
  }
}

function refreshChrome() {
  requestAnimationFrame(() => {
    if (renameActive) return; // rebuilt on commit instead
    layoutTabbar();
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
      menuRow(`${titleOf(s.id)}${expirySuffix(s)}`, () => createTab(s.id), async () => {
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
    // Titles are kept: the session may sit in its grace window and come
    // back. Stale titles get pruned against the daemon list at startup.
    hidden.delete(event.payload.id);
    saveHidden();
    removeTab(event.payload.id);
    // Let the daemon finish its exit/trash transition, then show the
    // session's "closes in Xm" row.
    window.setTimeout(() => refreshChrome(), 500);
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
    for (const m of [restoreMenu, overflowMenu, hiddenMenu, ctxMenu]) {
      if (m.classList.contains("open") && !m.contains(target)) {
        m.classList.remove("open");
      }
    }
  });
  // Suppress the WebView2 default context menu everywhere ("Send to
  // devices", "Web capture", etc.) — the app provides its own menus.
  window.addEventListener("contextmenu", (e) => e.preventDefault());
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
  window.setInterval(updateLiveInfo, 5000);

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
  for (const k of Object.keys(groupState.assign)) {
    if (!known.has(Number(k))) delete groupState.assign[k];
  }
  pruneGroups();
  saveGroups();
  for (const s of sessions) {
    if (!hidden.has(s.id)) await createTab(s.id);
  }
  if (tabs.size === 0) await createTab();
  refreshChrome();
}

main();
