import { invoke, convertFileSrc } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { getVersion } from "@tauri-apps/api/app";
import { openUrl } from "@tauri-apps/plugin-opener";
import { save as saveDialog, open as openDialog } from "@tauri-apps/plugin-dialog";
import { Terminal } from "@xterm/xterm";
import type { ITheme } from "@xterm/xterm";
import Anthropic from "@anthropic-ai/sdk";
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
  shellB: HTMLElement;
  webgl?: WebglAddon;
}

interface SessionInfo {
  id: number;
  created_ms: number;
  attached: boolean;
  alive: boolean;
  expires_ms: number | null;
  running: string[];
  cwd?: string;
  shell?: string;
}

// Latest per-session info from the daemon (cwd, running), for labels.
const lastInfo = new Map<number, SessionInfo>();

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

// User config (%LOCALAPPDATA%\GTerminal\config.json), loaded at startup.
// cursor_style: "bar" | "block" | "underline" (default bar, like Windows
// Terminal); cursor_blink: boolean (default true).
// A "new tab" preset: right-clicking the + button lists these. Unset
// fields fall back to the regular defaults (default_shell, default_cwd,
// automatic titles).
interface SessionTemplate {
  name: string;
  shell?: string;
  cwd?: string;
  title?: string;
}

// A workspace is a named list of template names, launched together via
// `gterminal --workspace <name>` (e.g. from a desktop shortcut).
interface Workspace {
  name: string;
  templates: string[];
}

/// A status-bar item reading one Windows performance counter by PDH path.
interface PerfStatusItem {
  id: string;
  label: string;
  path: string;
  format?: string; // raw | int | bytes | rate | pct
}

/// A status-bar item showing the first line of a shell command. Always
/// runs in the active tab's working folder.
interface CmdStatusItem {
  id: string;
  label: string;
  command: string;
  interval_s?: number;
}

interface LaunchInfo {
  args: string[];
  exe: string;
}
let launchInfo: LaunchInfo | null = null;

// A user-defined theme: a built-in base plus color/font overrides.
interface CustomTheme {
  name: string;
  base?: string;
  bg?: string;
  fg?: string;
  accent?: string;
  font?: string;
}

interface AppConfig {
  cursor_style?: CursorStyle;
  cursor_blink?: boolean;
  grace_minutes?: number;
  theme?: string;
  font_family?: string;
  font_size?: number;
  line_height?: number;
  ai_api_key?: string;
  ai_model?: string;
  ai_base_url?: string;
  ai_flavor?: string;
  ai_auto_titles?: boolean;
  default_shell?: string;
  default_cwd?: string;
  templates?: SessionTemplate[];
  workspaces?: Workspace[];
  custom_themes?: CustomTheme[];
  history_days?: number;
  prediction?: string;
  tab_width?: number;
  title_mode?: string;
  title_template?: string;
  bg_style?: string;
  bg_image?: string;
  bg_dim?: number;
  bg_transparency?: number;
  status_bar?: boolean;
  status_items?: string[];
  status_interval_ms?: number;
  status_perf?: PerfStatusItem[];
  status_custom?: CmdStatusItem[];
}

// Built-in decorative backgrounds — pure CSS, no assets.
const BG_PRESETS: Record<string, string> = {
  aurora:
    "radial-gradient(ellipse 80% 60% at 20% 0%, rgba(64,120,255,0.35), transparent 60%), radial-gradient(ellipse 70% 50% at 80% 20%, rgba(120,64,255,0.3), transparent 60%), radial-gradient(ellipse 90% 60% at 50% 100%, rgba(0,180,160,0.25), transparent 60%), linear-gradient(160deg, #070b18, #10142a)",
  nebula:
    "radial-gradient(circle at 25% 30%, rgba(190,80,255,0.28), transparent 45%), radial-gradient(circle at 75% 65%, rgba(255,80,140,0.2), transparent 50%), radial-gradient(circle at 60% 20%, rgba(80,140,255,0.22), transparent 40%), linear-gradient(180deg, #0a0714, #140b22)",
  grid:
    "repeating-linear-gradient(0deg, rgba(90,140,255,0.12) 0 1px, transparent 1px 42px), repeating-linear-gradient(90deg, rgba(90,140,255,0.12) 0 1px, transparent 1px 42px), linear-gradient(180deg, #060913, #0b1120)",
};

/// Resolve the effective background CSS: theme's built-in art by default,
/// or a preset / custom image / plain color per the Background setting.
function resolvedBgCss(): string {
  const style = config.bg_style ?? "theme";
  if (style === "none") return "";
  if (style === "theme") return currentTheme().bgArt;
  if (style === "custom") {
    const raw = config.bg_image?.trim();
    if (!raw) return "";
    const src = /^https?:/i.test(raw) ? raw : convertFileSrc(raw);
    return `url("${src.replace(/"/g, "%22")}") center / cover no-repeat fixed`;
  }
  return BG_PRESETS[style] ?? "";
}

function bgActive(): boolean {
  return !!resolvedBgCss();
}

function hexToRgba(hex: string, alpha: number): string {
  const m = hex.replace("#", "");
  const r = parseInt(m.slice(0, 2), 16);
  const g = parseInt(m.slice(2, 4), 16);
  const b = parseInt(m.slice(4, 6), 16);
  return `rgba(${r}, ${g}, ${b}, ${alpha})`;
}

function applyBackground() {
  // Painted on #app — the whole window — so the art runs edge to edge
  // behind the sidebar and tab bar too, not just the main column.
  const appEl = document.getElementById("app")!;
  const mainEl = document.getElementById("main")!;
  mainEl.style.background = ""; // art used to live here
  // The settings/history wash and the chrome wash both follow the
  // transparency setting: fully see-through terminals keep the light
  // washes, a solid terminal makes those surfaces solid as well.
  const transp = effTransparency();
  const washPct = Math.round(55 + (100 - transp) * 0.45);
  document.documentElement.style.setProperty("--wash-pct", `${washPct}%`);
  // The pane's padding has no terminal cells in it, so without this it
  // shows the art unveiled — a bright strip left of column 0. Paint the
  // padding with exactly the veil the cells carry.
  const veilAlpha = bgActive() ? (100 - transp) / 100 : 0;
  document.documentElement.style.setProperty(
    "--cell-veil",
    veilAlpha > 0 ? hexToRgba(currentTheme().xterm.background ?? "#0f1115", veilAlpha) : "transparent"
  );
  const image = resolvedBgCss();
  if (!image) {
    appEl.style.background = "";
    document.documentElement.style.setProperty("--chrome-wash", "100%");
    return;
  }
  // Sidebar and tab bar stay more opaque than the terminal: they carry
  // small text that has to stay legible over any art.
  document.documentElement.style.setProperty(
    "--chrome-wash",
    `${Math.round(80 + (100 - transp) * 0.2)}%`
  );
  // Theme-built-in art is already palette-matched and subtle; presets and
  // images get the dim overlay for readability.
  const isThemeArt = (config.bg_style ?? "theme") === "theme";
  const dim = Math.min(0.95, Math.max(0, (config.bg_dim ?? 50) / 100));
  const overlay = hexToRgba(currentTheme().xterm.background ?? "#0f1115", dim);
  appEl.style.background = isThemeArt
    ? image
    : `linear-gradient(${overlay}, ${overlay}), ${image}`;
}

const SHELL_CHOICES: Array<[string, string]> = [
  ["auto", "Auto (PowerShell 7, fallback Windows PowerShell)"],
  ["pwsh", "PowerShell 7"],
  ["powershell", "Windows PowerShell"],
  ["cmd", "Command Prompt"],
];
let config: AppConfig = {};

function minutesLeft(expiresMs: number): number {
  return Math.max(1, Math.ceil((expiresMs - Date.now()) / 60_000));
}
function remainingLabel(expiresMs: number): string {
  const total = Math.max(0, Math.round((expiresMs - Date.now()) / 1000));
  const m = Math.floor(total / 60);
  const s = total % 60;
  return `${m}:${String(s).padStart(2, "0")}`;
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
const settingsList = document.getElementById("settings-list")!;
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

// User-chosen badges: up to 3 per session (short text or emoji) replace
// the automatic shell badge. Older single-string entries migrate to
// one-element arrays on load.
const customBadges: Record<string, string[]> = (() => {
  const raw = JSON.parse(localStorage.getItem("gterm-cust-badges") ?? "{}") as Record<
    string,
    string | string[]
  >;
  const out: Record<string, string[]> = {};
  for (const k of Object.keys(raw)) {
    const v = raw[k];
    out[k] = (Array.isArray(v) ? v : [v]).filter(Boolean).slice(0, 3);
  }
  return out;
})();
function saveCustomBadges() {
  localStorage.setItem("gterm-cust-badges", JSON.stringify(customBadges));
}

// Per-tab widths from dragging a tab's right edge. A stored width
// overrides the global tab-width setting for that session only; keys
// are daemon session ids, so widths survive restarts and reboots.
const tabWidths: Record<string, number> = JSON.parse(
  localStorage.getItem("gterm-tab-widths") ?? "{}"
);
function saveTabWidths() {
  localStorage.setItem("gterm-tab-widths", JSON.stringify(tabWidths));
}
const TAB_W_MIN = 90;
const TAB_W_MAX = 400;
function applyTabWidth(button: HTMLElement, id: number) {
  const w = tabWidths[id];
  if (w) {
    button.style.flex = `0 1 ${w}px`;
    button.style.maxWidth = `${w}px`;
  } else {
    button.style.flex = "";
    button.style.maxWidth = "";
  }
}

// AI-suggested titles: outrank shell/cwd labels, lose to user renames.
const aiTitles: Record<string, string> = JSON.parse(
  localStorage.getItem("gterm-ai-titles") ?? "{}"
);
function saveAiTitles() {
  localStorage.setItem("gterm-ai-titles", JSON.stringify(aiTitles));
}
// Shell-reported titles that carry no information: the bare shell exe
// path/name (every pwsh tab reports the same one), the Administrator
// banner variant, default shell banners, or a bare filesystem path (the
// cwd-based label handles directories better). A title that merely
// CONTAINS a shell name (e.g. "Claude Code — pwsh") is kept.
const BORING_TITLE =
  /^(Administrator:\s*)?([A-Za-z]:\\[^|—-]*\\)?(pwsh|powershell|cmd)(\.exe)?$|^Windows PowerShell$|^Command Prompt$|^[A-Za-z]:\\\S*$/i;

function cwdParts(id: number): string[] {
  const cwd = lastInfo.get(id)?.cwd;
  return cwd ? cwd.replace(/[\\/]+$/, "").split(/[\\/]/).filter(Boolean) : [];
}

function shellDisplayName(id: number): string {
  switch (lastInfo.get(id)?.shell) {
    case "cmd":
      return "Command Prompt";
    case "powershell":
      return "Windows PowerShell";
    default:
      return "PowerShell";
  }
}

/// The automatic part of the label, governed by the "Title style" setting.
function autoLabel(id: number): { text: string; fromCwd: boolean } {
  const parts = cwdParts(id);
  const tail = parts[parts.length - 1];
  // The home directory's name (the username) makes a confusing label.
  const isHome = parts.length === 3 && parts[1].toLowerCase() === "users";
  const prog = (lastInfo.get(id)?.running ?? []).find((n) => !SHELLS.test(n));
  const t = titles[id];
  const interesting = t && !BORING_TITLE.test(t) ? t : "";
  const dirLabel = () =>
    tail && !isHome
      ? { text: tail, fromCwd: true }
      : { text: shellDisplayName(id), fromCwd: false };

  switch (config.title_mode ?? "smart") {
    case "dir":
      return dirLabel();
    case "program":
      return { text: prog ?? shellDisplayName(id), fromCwd: false };
    case "shelltitle":
      if (interesting) return { text: interesting, fromCwd: false };
      return dirLabel();
    case "custom": {
      const vals: Record<string, string> = {
        program: prog ?? "",
        folder: tail && !isHome ? tail : "",
        parent: parts.length >= 2 ? parts[parts.length - 2] : "",
        path: lastInfo.get(id)?.cwd ?? "",
        shell: shellDisplayName(id),
        title: interesting,
      };
      const rendered = (config.title_template ?? "{program} · {folder}")
        .replace(/\{(\w+)\}/g, (_, k: string) => vals[k] ?? "")
        .split("·")
        .map((p) => p.trim())
        .filter(Boolean)
        .join(" · ");
      return rendered
        ? { text: rendered.slice(0, 60), fromCwd: false }
        : { text: shellDisplayName(id), fromCwd: false };
    }
    default: {
      // smart: shell-set title, else program · folder, else directory.
      if (interesting) return { text: interesting, fromCwd: false };
      if (prog) {
        return { text: tail && !isHome ? `${prog} · ${tail}` : prog, fromCwd: false };
      }
      return dirLabel();
    }
  }
}

/// Badge strip for a session: the automatic shell badge (blue "PS" /
/// dark ">_"), or the user's custom badges (up to 3) when set. `el` is a
/// wrapper span; content only rebuilds when the signature changes.
function setShellBadge(el: HTMLElement, shell: string | undefined, id?: number) {
  const customs = id !== undefined ? customBadges[id] : undefined;
  if (customs?.length) {
    const sig = "c:" + customs.join(" ");
    if (el.dataset.bsig === sig) return;
    el.dataset.bsig = sig;
    el.replaceChildren(
      ...customs.slice(0, 3).map((c) => {
        const s = document.createElement("span");
        s.className = "shell-badge custom";
        s.textContent = c;
        return s;
      })
    );
    el.title = "Custom badges — right-click the tab to change them";
    return;
  }
  const isCmd = (shell ?? "").toLowerCase() === "cmd";
  const sig = isCmd ? "cmd" : "ps";
  if (el.dataset.bsig === sig) return;
  el.dataset.bsig = sig;
  const s = document.createElement("span");
  s.className = "shell-badge " + sig;
  s.textContent = isCmd ? ">_" : "PS";
  el.replaceChildren(s);
  el.title = isCmd ? "Command Prompt" : "PowerShell";
}

function mkShellBadge(shell: string | undefined, id?: number): HTMLElement {
  const b = document.createElement("span");
  b.className = "badge-wrap";
  setShellBadge(b, shell, id);
  return b;
}

/// Badge picker popup: searchable emoji choices plus free text.
const BADGE_CHOICES: Array<[string, string]> = [
  ["🚀", "rocket deploy ship release"],
  ["🔥", "fire hot urgent"],
  ["🐛", "bug debug fix"],
  ["🧪", "test lab experiment"],
  ["📦", "package box npm build bundle"],
  ["🗄️", "database db storage sql"],
  ["🌐", "web globe network http site"],
  ["📝", "docs notes writing readme"],
  ["🔑", "key auth secret token login"],
  ["🔒", "lock secure private"],
  ["☁️", "cloud aws azure gcp"],
  ["🤖", "ai bot robot claude agent"],
  ["⚙️", "gear config settings setup"],
  ["🧰", "tools toolbox utils"],
  ["🎮", "game gaming play"],
  ["🎵", "music audio sound"],
  ["💰", "money billing finance pay"],
  ["📊", "chart data analytics metrics"],
  ["⚠️", "warning alert caution danger"],
  ["⭐", "star favorite important"],
  ["🏠", "home personal"],
  ["💼", "work office job"],
  ["🔬", "research science"],
  ["🎨", "design art ui frontend"],
  ["🐳", "docker whale container"],
  ["🐙", "github git octopus repo"],
  ["⚡", "fast perf lightning power"],
  ["🧠", "brain ml model think"],
  ["📡", "server antenna remote ssh"],
  ["🖥️", "desktop machine computer"],
  ["🔧", "wrench fix repair maintain"],
  ["🚧", "wip construction progress"],
  ["❤️", "heart love"],
  ["⏰", "clock timer cron schedule"],
  ["📁", "folder files"],
  ["🍕", "pizza food lunch"],
];

function openBadgePicker(id: number) {
  document.getElementById("badge-overlay")?.remove();
  const ov = document.createElement("div");
  ov.className = "clip-overlay";
  ov.id = "badge-overlay";
  const panel = document.createElement("div");
  panel.className = "badge-panel";
  const currentRow = document.createElement("div");
  currentRow.className = "badge-current";
  const input = document.createElement("input");
  input.className = "badge-search";
  input.placeholder = "Search… or type your own badge text";
  const grid = document.createElement("div");
  grid.className = "badge-grid";

  const refreshChromeBadges = () => {
    const tab = tabs.get(id);
    if (tab) setShellBadge(tab.shellB, lastInfo.get(id)?.shell, id);
    sidebarSig = "";
    refreshChrome();
  };
  const addBadge = (v: string) => {
    const trimmed = v.slice(0, 4);
    const list = customBadges[id] ?? [];
    if (list.includes(trimmed) || list.length >= 3) return;
    customBadges[id] = [...list, trimmed];
    saveCustomBadges();
    refreshChromeBadges();
    renderCurrent();
    renderGrid();
  };
  const removeBadge = (v: string) => {
    const list = (customBadges[id] ?? []).filter((b) => b !== v);
    if (list.length) customBadges[id] = list;
    else delete customBadges[id];
    saveCustomBadges();
    refreshChromeBadges();
    renderCurrent();
    renderGrid();
  };

  const renderCurrent = () => {
    currentRow.innerHTML = "";
    const list = customBadges[id] ?? [];
    if (!list.length) {
      const hint = document.createElement("span");
      hint.className = "badge-hint";
      hint.textContent = "No custom badges — pick up to 3 below.";
      currentRow.appendChild(hint);
      return;
    }
    for (const b of list) {
      const chip = document.createElement("span");
      chip.className = "badge-chip";
      const t = document.createElement("span");
      t.className = "shell-badge custom";
      t.textContent = b;
      const x = document.createElement("button");
      x.className = "badge-chip-x";
      x.textContent = "×";
      x.title = "Remove this badge";
      x.addEventListener("click", () => removeBadge(b));
      chip.append(t, x);
      currentRow.appendChild(chip);
    }
  };
  const renderGrid = () => {
    grid.innerHTML = "";
    const q = input.value.trim().toLowerCase();
    const full = (customBadges[id] ?? []).length >= 3;
    for (const [emoji, keys] of BADGE_CHOICES) {
      if (q && !keys.includes(q)) continue;
      const b = document.createElement("button");
      b.className = "badge-opt";
      b.textContent = emoji;
      b.title = full ? "Already at 3 badges — remove one first" : keys;
      b.disabled = full;
      b.addEventListener("click", () => addBadge(emoji));
      grid.appendChild(b);
    }
    if (q && !full) {
      const custom = document.createElement("button");
      custom.className = "badge-custom";
      custom.textContent = `Add text "${input.value.trim().slice(0, 4)}"`;
      custom.addEventListener("click", () => {
        addBadge(input.value.trim());
        input.value = "";
        renderGrid();
      });
      grid.appendChild(custom);
    }
    if (customBadges[id]?.length) {
      const reset = document.createElement("button");
      reset.className = "badge-custom";
      reset.textContent = "Clear all — back to shell badge";
      reset.addEventListener("click", () => {
        delete customBadges[id];
        saveCustomBadges();
        refreshChromeBadges();
        renderCurrent();
        renderGrid();
      });
      grid.appendChild(reset);
    }
    const done = document.createElement("button");
    done.className = "badge-custom";
    done.textContent = "Done";
    done.addEventListener("click", () => ov.remove());
    grid.appendChild(done);
  };
  input.addEventListener("input", renderGrid);
  input.addEventListener("keydown", (e) => {
    e.stopPropagation();
    if (e.key === "Escape") ov.remove();
    if (e.key === "Enter") {
      grid.querySelector<HTMLElement>(".badge-opt:not([disabled]), .badge-custom")?.click();
    }
  });
  renderCurrent();
  renderGrid();
  panel.append(currentRow, input, grid);
  ov.appendChild(panel);
  ov.addEventListener("mousedown", (e) => {
    if (e.target === ov) ov.remove();
  });
  document.body.appendChild(ov);
  input.focus();
}

function clearBadge(id: number) {
  delete customBadges[id];
  saveCustomBadges();
  const tab = tabs.get(id);
  if (tab) setShellBadge(tab.shellB, lastInfo.get(id)?.shell, id);
  sidebarSig = "";
  refreshChrome();
}

function baseLabel(id: number): { text: string; fromCwd: boolean } {
  if (customTitles[id]) return { text: customTitles[id], fromCwd: false };
  if (aiTitles[id]) return { text: aiTitles[id], fromCwd: false };
  return autoLabel(id);
}

// Duplicate labels get disambiguated: different directories sharing a tail
// show their parent folder ("repos/app" vs "fork/app"); genuinely identical
// ones get stable numbering ("app", "app (2)").
const labelCache = new Map<number, string>();
function recomputeLabels() {
  labelCache.clear();
  const ids = new Set<number>([...tabs.keys(), ...hidden, ...lastInfo.keys()]);
  const groups = new Map<string, number[]>();
  for (const id of ids) {
    const b = baseLabel(id).text;
    const g = groups.get(b);
    if (g) g.push(id);
    else groups.set(b, [id]);
  }
  const order = (id: number) => {
    const i = tabOrder.indexOf(id);
    return i === -1 ? Number.MAX_SAFE_INTEGER / 2 + id : i;
  };
  for (const [base, members] of groups) {
    if (members.length === 1) {
      labelCache.set(members[0], base);
      continue;
    }
    members.sort((a, b) => order(a) - order(b));
    const parents = members.map((id) => {
      const parts = cwdParts(id);
      return baseLabel(id).fromCwd && parts.length >= 2 ? parts[parts.length - 2] : "";
    });
    const allDistinctParents =
      parents.every(Boolean) && new Set(parents).size === parents.length;
    members.forEach((id, i) => {
      if (allDistinctParents) {
        labelCache.set(id, `${parents[i]}/${base}`);
      } else {
        labelCache.set(id, i === 0 ? base : `${base} (${i + 1})`);
      }
    });
  }
}

function titleOf(id: number): string {
  return labelCache.get(id) ?? baseLabel(id).text;
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

// Insertion order of tabs; grouping reorders members to sit together and
// drag-and-drop rearranges. Persisted so ordering survives restarts.
let tabOrder: number[] = [];
function saveOrder() {
  localStorage.setItem("gterm-order", JSON.stringify(tabOrder));
}

// ── drag reordering (pointer-based) ─────────────────────────────────────
// Set when a drag completes, so the click that follows pointerup doesn't
// also activate the dropped row.
let dragSuppressClick = false;

function clearDropMarkers() {
  for (const root of [tabbar, sidebarList]) {
    for (const el of root.querySelectorAll(".drop-before, .drop-after, .drop-into, .drop-merge")) {
      el.classList.remove("drop-before", "drop-after", "drop-into", "drop-merge");
    }
  }
}

/// Pointer-based drag reordering, used by both the tab strip (axis "x")
/// and the sidebar (axis "y"). HTML5 drag-and-drop is deliberately not
/// used: inside the frameless window it fails to start drags reliably.
/// Targets are resolved by hit-testing at pointer position, so chrome
/// rebuilds mid-drag are harmless.
function beginPointerDrag(
  e: PointerEvent,
  el: HTMLElement,
  axis: "x" | "y",
  hitSelector: string,
  onDrop: (target: HTMLElement | null, before: boolean, ev: PointerEvent) => void,
  onMerge?: (target: HTMLElement) => void
) {
  if (e.button !== 0) return;
  const start = axis === "x" ? e.clientX : e.clientY;
  let dragging = false;
  const hit = (ev: PointerEvent): HTMLElement | null =>
    (document.elementFromPoint(ev.clientX, ev.clientY)?.closest(hitSelector) as HTMLElement | null);
  const fraction = (t: HTMLElement, ev: PointerEvent): number => {
    const r = t.getBoundingClientRect();
    return axis === "x" ? (ev.clientX - r.left) / r.width : (ev.clientY - r.top) / r.height;
  };
  const isBefore = (t: HTMLElement, ev: PointerEvent): boolean => fraction(t, ev) < 0.5;
  // The middle of a target means "combine", its ends mean "insert here" —
  // the same split browsers use for dropping onto a bookmark folder.
  const isMerge = (t: HTMLElement, ev: PointerEvent): boolean =>
    !!onMerge && !t.classList.contains("group-chip") && Math.abs(fraction(t, ev) - 0.5) < 0.2;
  const onMove = (ev: PointerEvent) => {
    if (!dragging) {
      if (Math.abs((axis === "x" ? ev.clientX : ev.clientY) - start) < 5) return;
      dragging = true;
      el.classList.add("dragging");
    }
    clearDropMarkers();
    const t = hit(ev);
    if (!t || t === el) return;
    if (t.classList.contains("group-chip")) {
      t.classList.add("drop-into");
      return;
    }
    if (isMerge(t, ev)) {
      t.classList.add("drop-merge");
      return;
    }
    t.classList.add(isBefore(t, ev) ? "drop-before" : "drop-after");
  };
  const onUp = (ev: PointerEvent) => {
    window.removeEventListener("pointermove", onMove);
    el.classList.remove("dragging");
    clearDropMarkers();
    if (!dragging) return;
    dragSuppressClick = true;
    const t = hit(ev);
    if (t && t !== el && onMerge && isMerge(t, ev)) {
      onMerge(t);
      return;
    }
    onDrop(t && t !== el ? t : null, t ? isBefore(t, ev) : false, ev);
  };
  window.addEventListener("pointermove", onMove);
  window.addEventListener("pointerup", onUp, { once: true });
}

/// Move `dragged` next to `refId` (or to the end when undefined), joining
/// group `gid` or leaving its group when undefined.
function moveTab(dragged: number, refId: number | undefined, before: boolean, gid?: string) {
  tabOrder = tabOrder.filter((t) => t !== dragged);
  const insertAt =
    refId === undefined
      ? tabOrder.length
      : tabOrder.indexOf(refId) + (before ? 0 : 1);
  tabOrder.splice(insertAt, 0, dragged);
  if (gid) {
    groupState.assign[dragged] = gid;
  } else {
    delete groupState.assign[dragged];
  }
  pruneGroups();
  saveGroups();
  saveOrder();
  refreshChrome();
}

type CursorStyle = "bar" | "block" | "underline";

interface ThemeDef {
  label: string;
  tint: "white" | "black"; // chrome derives by mixing bg toward this
  // A theme is a whole look, not just colors — these are its defaults,
  // each individually overridable in settings.
  font: string;
  lineHeight: number;
  cursorStyle: CursorStyle;
  /// Built-in decorative background in the theme's palette.
  bgArt: string;
  /// How much of the art shows through the terminal cells, 0-100.
  /// Busier art gets a lower value so text stays legible; omitted
  /// means 100 (fully see-through). The user setting overrides it.
  transparency?: number;
  xterm: ITheme;
}

/// Effective see-through amount: explicit user setting wins, else the
/// theme's own default, else fully see-through.
function effTransparency(): number {
  const v = config.bg_transparency ?? currentTheme().transparency ?? 100;
  return Math.min(100, Math.max(0, v));
}

function mkTheme(
  label: string,
  tint: "white" | "black",
  look: [string, number, CursorStyle],
  bgArt: string,
  bg: string,
  fg: string,
  ansi: string[]
): ThemeDef {
  return {
    label,
    tint,
    font: look[0],
    lineHeight: look[1],
    cursorStyle: look[2],
    bgArt,
    xterm: {
      background: bg,
      foreground: fg,
      cursor: fg,
      cursorAccent: bg,
      selectionBackground: `${ansi[4]}55`,
      black: ansi[0], red: ansi[1], green: ansi[2], yellow: ansi[3],
      blue: ansi[4], magenta: ansi[5], cyan: ansi[6], white: ansi[7],
      brightBlack: ansi[8], brightRed: ansi[9], brightGreen: ansi[10], brightYellow: ansi[11],
      brightBlue: ansi[12], brightMagenta: ansi[13], brightCyan: ansi[14], brightWhite: ansi[15],
    },
  };
}

const THEMES: Record<string, ThemeDef> = {
  "one-dark": mkTheme("One Dark", "white", ['"Cascadia Mono", Consolas, monospace', 1.1, "bar"], 'linear-gradient(rgba(15,17,21,0.52), rgba(15,17,21,0.66)), url("/backgrounds/onedark.png") center / cover no-repeat, linear-gradient(180deg, rgb(15,17,21), rgb(15,17,21))', "#0f1115", "#d7dae0", [
    "#1c1f26", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#d7dae0",
    "#5c6370", "#ef7d85", "#a9d387", "#f0cd8a", "#74bdf7", "#d48ce8", "#67c5d0", "#f0f2f6",
  ]),
  dracula: mkTheme("Dracula", "white", ['"Cascadia Code", "Cascadia Mono", monospace', 1.15, "block"], 'linear-gradient(rgba(40,42,54,0.5), rgba(40,42,54,0.64)), url("/backgrounds/dracula.png") center / cover no-repeat, linear-gradient(180deg, rgb(40,42,54), rgb(40,42,54))', "#282a36", "#f8f8f2", [
    "#21222c", "#ff5555", "#50fa7b", "#f1fa8c", "#bd93f9", "#ff79c6", "#8be9fd", "#f8f8f2",
    "#6272a4", "#ff6e6e", "#69ff94", "#ffffa5", "#d6acff", "#ff92df", "#a4ffff", "#ffffff",
  ]),
  nord: mkTheme("Nord", "white", ['"Cascadia Mono", Consolas, monospace', 1.2, "bar"], 'linear-gradient(rgba(46,52,64,0.52), rgba(46,52,64,0.66)), url("/backgrounds/nord.png") center / cover no-repeat, linear-gradient(180deg, rgb(46,52,64), rgb(46,52,64))', "#2e3440", "#d8dee9", [
    "#3b4252", "#bf616a", "#a3be8c", "#ebcb8b", "#81a1c1", "#b48ead", "#88c0d0", "#e5e9f0",
    "#7b88a1", "#bf616a", "#a3be8c", "#f4dda1", "#81a1c1", "#b48ead", "#8fbcbb", "#eceff4",
  ]),
  gruvbox: mkTheme("Gruvbox Dark", "white", ["Consolas, monospace", 1.1, "block"], 'linear-gradient(rgba(40,40,40,0.5), rgba(40,40,40,0.66)), url("/backgrounds/gruvbox.png") center / cover no-repeat, linear-gradient(180deg, rgb(40,40,40), rgb(40,40,40))', "#282828", "#ebdbb2", [
    "#282828", "#fb4934", "#98971a", "#d79921", "#458588", "#b16286", "#689d6a", "#a89984",
    "#928374", "#fb4934", "#b8bb26", "#fabd2f", "#83a598", "#d3869b", "#8ec07c", "#ebdbb2",
  ]),
  "tokyo-night": mkTheme("Tokyo Night", "white", ['"Cascadia Code", "Cascadia Mono", monospace', 1.15, "bar"], 'linear-gradient(rgba(26,27,38,0.5), rgba(26,27,38,0.64)), url("/backgrounds/tokyonight.png") center / cover no-repeat, linear-gradient(180deg, rgb(26,27,38), rgb(26,27,38))', "#1a1b26", "#c0caf5", [
    "#15161e", "#f7768e", "#9ece6a", "#e0af68", "#7aa2f7", "#bb9af7", "#7dcfff", "#a9b1d6",
    "#7982b4", "#f7768e", "#9ece6a", "#e0af68", "#7aa2f7", "#bb9af7", "#7dcfff", "#c0caf5",
  ]),
  catppuccin: mkTheme("Catppuccin Mocha", "white", ['"Cascadia Mono", Consolas, monospace', 1.2, "bar"], 'linear-gradient(rgba(30,30,46,0.52), rgba(30,30,46,0.66)), url("/backgrounds/catppuccin.png") center / cover no-repeat, linear-gradient(180deg, rgb(30,30,46), rgb(30,30,46))', "#1e1e2e", "#cdd6f4", [
    "#45475a", "#f38ba8", "#a6e3a1", "#f9e2af", "#89b4fa", "#f5c2e7", "#94e2d5", "#bac2de",
    "#7f849c", "#f38ba8", "#a6e3a1", "#f9e2af", "#89b4fa", "#f5c2e7", "#94e2d5", "#a6adc8",
  ]),
  "solarized-dark": mkTheme("Solarized Dark", "white", ["Consolas, monospace", 1.1, "underline"], 'linear-gradient(rgba(0,43,54,0.55), rgba(0,43,54,0.7)), url("/backgrounds/solarizeddark.png") center / cover no-repeat, linear-gradient(180deg, rgb(0,43,54), rgb(0,43,54))', "#002b36", "#839496", [
    "#073642", "#dc322f", "#859900", "#b58900", "#268bd2", "#d33682", "#2aa198", "#eee8d5",
    "#657b83", "#cb4b16", "#78909a", "#eed968", "#839496", "#6c71c4", "#93a1a1", "#fdf6e3",
  ]),
  "solarized-light": mkTheme("Solarized Light", "black", ["Consolas, monospace", 1.1, "underline"], 'linear-gradient(rgba(253,246,227,0.45), rgba(253,246,227,0.58)), url("/backgrounds/solarizedlight.png") center / cover no-repeat, linear-gradient(180deg, rgb(253,246,227), rgb(253,246,227))', "#fdf6e3", "#586e75", [
    "#073642", "#dc322f", "#6f7d00", "#8f6c00", "#268bd2", "#d33682", "#1f857c", "#eee8d5",
    "#49606a", "#b04214", "#5c727b", "#705a00", "#66787f", "#6c71c4", "#6d838b", "#fdf6e3",
  ]),
};

// Hermes (nous research style): International Klein Blue field, noise
// grain, edge vignette, chartreuse accent.
THEMES.hermes = mkTheme(
  "Hermes",
  "white",
  ['"Cascadia Mono", Consolas, monospace', 1.15, "block"],
  `url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='180' height='180'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.85' numOctaves='2'/%3E%3CfeColorMatrix values='0 0 0 0 1 0 0 0 0 1 0 0 0 0 1 0 0 0 0.05 0'/%3E%3C/filter%3E%3Crect width='180' height='180' filter='url(%23n)'/%3E%3C/svg%3E") repeat, url("/backgrounds/hermes.png") center / cover no-repeat, linear-gradient(0deg, #0000f2, #0000f2)`,
  "#0000f2",
  "#f5f5f5",
  [
    "#0000a8", "#ff7a85", "#9dffb0", "#edff45", "#9db8ff", "#e0a8ff", "#8df4ff", "#f5f5f5",
    "#8a8aff", "#ffa9b2", "#c4ffd0", "#f6ff8f", "#c0d2ff", "#eec6ff", "#c2f9ff", "#ffffff",
  ]
);
THEMES.hermes.xterm.cursor = "#edff45";
THEMES.hermes.xterm.selectionBackground = "#edff4540";

// Nous (nousresearch brand book): ink on paper — photocopy grain over
// off-white, black ink, Courier New (their lead font), and accents from
// "The Blues of Nous" cyanotype palette.
THEMES.nous = mkTheme(
  "Nous",
  "black",
  ['"Courier New", Consolas, monospace', 1.2, "block"],
  `url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='160' height='160'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.9' numOctaves='2'/%3E%3CfeColorMatrix values='0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0.06 0'/%3E%3C/filter%3E%3Crect width='160' height='160' filter='url(%23n)'/%3E%3C/svg%3E") repeat, url("/backgrounds/nous.png") center / cover no-repeat, linear-gradient(180deg, #fbfaf7, #f1efe9)`,
  "#f7f5f0",
  "#141414",
  [
    "#141414", "#b3261e", "#1d6f42", "#8a6d00", "#0471a9", "#7b2d8b", "#0e7c86", "#f7f5f0",
    "#5a5a5a", "#d64545", "#2c8f58", "#7a6000", "#2b93cc", "#9c4fae", "#157d86", "#ffffff",
  ]
);
THEMES.nous.xterm.cursor = "#0471a9";
THEMES.nous.xterm.selectionBackground = "#0471a935";

THEMES.monokai = mkTheme(
  "Monokai",
  "white",
  ["Consolas, monospace", 1.1, "block"],
  'linear-gradient(rgba(39,40,34,0.45), rgba(39,40,34,0.6)), url("/backgrounds/monokai.png") center / cover no-repeat, linear-gradient(180deg, rgb(39,40,34), rgb(39,40,34))',
  "#272822",
  "#f8f8f2",
  [
    "#272822", "#f92672", "#a6e22e", "#e6db74", "#66d9ef", "#ae81ff", "#a1efe4", "#f8f8f2",
    "#75715e", "#ff6188", "#b9f18d", "#f1e694", "#8be9ff", "#c39fff", "#c1f5ec", "#ffffff",
  ]
);

THEMES.matrix = mkTheme(
  "Matrix",
  "white",
  ["Consolas, monospace", 1.15, "block"],
  'linear-gradient(rgba(1,6,3,0.6), rgba(1,6,3,0.72)), url("/backgrounds/matrix.png") center / cover no-repeat, linear-gradient(180deg, #04140a, #010604)',
  "#020a02",
  "#00f050",
  [
    "#020a02", "#ff7a68", "#00e65c", "#b3f05a", "#33cc99", "#55e0b5", "#7dffd4", "#ccffdd",
    "#1f8f4a", "#ff9c8a", "#4dff8f", "#d0ff85", "#66d9ad", "#99ffcc", "#b3ffe6", "#eafff2",
  ]
);
THEMES.matrix.xterm.cursor = "#00ff66";
THEMES.matrix.xterm.selectionBackground = "#00ff6633";

THEMES["amber-crt"] = mkTheme(
  "Amber CRT",
  "white",
  ['"Lucida Console", Consolas, monospace', 1.1, "block"],
  'linear-gradient(rgba(16,11,0,0.5), rgba(16,11,0,0.66)), url("/backgrounds/ambercrt.png") center / cover no-repeat, linear-gradient(180deg, #140d02, #0a0600)',
  "#100b00",
  "#ffb000",
  [
    "#100b00", "#ff8c42", "#e0a500", "#ffcf40", "#d1a05a", "#ff9966", "#ffd27a", "#ffe0b3",
    "#8a6a1a", "#ffa26b", "#ffc23d", "#ffe066", "#e6b877", "#ffb98a", "#ffe2a1", "#fff2d9",
  ]
);
THEMES["amber-crt"].xterm.cursor = "#ffb000";
THEMES["amber-crt"].xterm.selectionBackground = "#ffb00033";

THEMES.synthwave = mkTheme(
  "Synthwave '84",
  "white",
  ['"Cascadia Code", "Cascadia Mono", monospace', 1.15, "block"],
  'linear-gradient(rgba(27,20,48,0.5), rgba(27,20,48,0.62)), url("/backgrounds/synthwave.png") center / cover no-repeat, linear-gradient(180deg, #1b1430 0%, #2d1f45 60%, #241b2f 100%)',
  "#241b2f",
  "#f0eff1",
  [
    "#241b2f", "#fe4450", "#72f1b8", "#fede5d", "#61b8ff", "#ff7edb", "#03edf9", "#f0eff1",
    "#8a7fb3", "#ff6b74", "#94f5cb", "#ffe97d", "#85caff", "#ff9ce6", "#66f5ff", "#ffffff",
  ]
);
THEMES.synthwave.xterm.cursor = "#ff7edb";
THEMES.synthwave.xterm.selectionBackground = "#ff7edb3d";

THEMES.everforest = mkTheme(
  "Everforest",
  "white",
  ["Consolas, monospace", 1.2, "bar"],
  'linear-gradient(rgba(45,53,59,0.5), rgba(45,53,59,0.66)), url("/backgrounds/everforest.png") center / cover no-repeat, linear-gradient(180deg, rgb(45,53,59), rgb(45,53,59))',
  "#2d353b",
  "#d3c6aa",
  [
    "#2d353b", "#e67e80", "#a7c080", "#dbbc7f", "#7fbbb3", "#d699b6", "#83c092", "#d3c6aa",
    "#7a8478", "#ec8f91", "#b4cf9a", "#e3c78f", "#93cbc4", "#e0accd", "#9ad0a9", "#ece2c8",
  ]
);

// ── pop culture pack ────────────────────────────────────────────────────

THEMES.bladerunner = mkTheme(
  "Blade Runner",
  "white",
  ["Consolas, monospace", 1.15, "bar"],
  'linear-gradient(rgba(9,14,18,0.45), rgba(9,14,18,0.58)), url("/backgrounds/bladerunner.png") center / cover no-repeat, linear-gradient(180deg, #0e1a20, #090e12)',
  "#0d1418",
  "#d9e6ea",
  [
    "#0d1418", "#ff6b4a", "#4ecfa8", "#ffb454", "#45b8d8", "#e86ab0", "#52e0e0", "#d9e6ea",
    "#5c7078", "#ff8f73", "#7fe6c6", "#ffc77d", "#79d2ec", "#f795cb", "#8cf0ef", "#f2fbfd",
  ]
);

THEMES.tron = mkTheme(
  "TRON",
  "white",
  ['"Cascadia Mono", Consolas, monospace', 1.2, "block"],
  'linear-gradient(rgba(5,8,12,0.35), rgba(5,8,12,0.5)), url("/backgrounds/tron.png") center / cover no-repeat, linear-gradient(180deg, rgb(5,8,12), rgb(5,8,12))',
  "#05080c",
  "#bfefff",
  [
    "#05080c", "#ff8836", "#5ce8b6", "#ffd35c", "#4dc4ff", "#b389ff", "#00e5ff", "#bfefff",
    "#3d5a66", "#ffa366", "#8af0d4", "#ffe08a", "#85d7ff", "#cbadff", "#66eeff", "#eafaff",
  ]
);
THEMES.tron.xterm.cursor = "#00e5ff";
THEMES.tron.xterm.selectionBackground = "#00e5ff33";

THEMES.lcars = mkTheme(
  "LCARS",
  "white",
  ['"Cascadia Mono", Consolas, monospace', 1.15, "bar"],
  'linear-gradient(rgba(0,0,0,0.3), rgba(0,0,0,0.42)), url("/backgrounds/lcars.png") center / cover no-repeat, linear-gradient(180deg, rgb(0,0,0), rgb(0,0,0))',
  "#000000",
  "#ffcc99",
  [
    "#000000", "#e07a66", "#99cc66", "#ffcc66", "#9999ff", "#cc99cc", "#99ccff", "#ffcc99",
    "#666699", "#ff9977", "#b8e086", "#ffd98c", "#b8b8ff", "#e0b8e0", "#b8dcff", "#ffe6cc",
  ]
);
THEMES.lcars.xterm.cursor = "#ff9933";
THEMES.lcars.xterm.selectionBackground = "#ff993340";

THEMES.hyperspace = mkTheme(
  "Hyperspace",
  "white",
  ["Consolas, monospace", 1.15, "block"],
  'linear-gradient(rgba(5,5,16,0.3), rgba(5,5,16,0.4)), url("/backgrounds/hyperspace.jpg") center / cover no-repeat, linear-gradient(180deg, #070716, #03030a)',
  "#050510",
  "#e8e6d8",
  [
    "#050510", "#ff4d4d", "#57e389", "#ffe81f", "#4d9fff", "#b878ff", "#66e0ff", "#e8e6d8",
    "#565b78", "#ff8080", "#85f0ac", "#fff066", "#80baff", "#d0a3ff", "#99ecff", "#ffffff",
  ]
);
THEMES.hyperspace.xterm.cursor = "#ffe81f";
THEMES.hyperspace.xterm.selectionBackground = "#ffe81f33";

THEMES.gameboy = mkTheme(
  "Game Boy",
  "white",
  ['"Lucida Console", Consolas, monospace', 1.1, "block"],
  'linear-gradient(rgba(15,56,15,0.5), rgba(15,56,15,0.64)), url("/backgrounds/gameboy.png") center / cover no-repeat, linear-gradient(180deg, rgb(15,56,15), rgb(15,56,15))',
  "#0f380f",
  "#9bbc0f",
  [
    "#0f380f", "#cc7755", "#8bac0f", "#b3bd4a", "#6fa08a", "#a08db8", "#86c9a8", "#cadc9f",
    "#5a8a5a", "#e09a80", "#a3cf3f", "#d4de7a", "#93c2a8", "#bfb0d6", "#a8e0c4", "#e6f0c8",
  ]
);
THEMES.gameboy.xterm.cursor = "#9bbc0f";
THEMES.gameboy.xterm.selectionBackground = "#9bbc0f33";

THEMES.dune = mkTheme(
  "Dune",
  "white",
  ['"Cascadia Mono", Consolas, monospace', 1.2, "underline"],
  'linear-gradient(rgba(23,15,7,0.38), rgba(23,15,7,0.52)), url("/backgrounds/dune.jpg") center / cover no-repeat, linear-gradient(180deg, #241708, #170f07)',
  "#1a120a",
  "#e8d5b0",
  [
    "#1a120a", "#d9603a", "#a8a060", "#e0a33c", "#4f9edb", "#b8798f", "#7fbfae", "#e8d5b0",
    "#7a6a52", "#f08a5f", "#c2bf7a", "#f2c266", "#7ab8f0", "#d49cb0", "#9fd9c8", "#f7ecd8",
  ]
);

THEMES.cyberpunk = mkTheme(
  "Cyberpunk",
  "white",
  ['"Cascadia Code", "Cascadia Mono", monospace', 1.15, "block"],
  'linear-gradient(rgba(10,10,18,0.35), rgba(10,10,18,0.5)), url("/backgrounds/cyberpunk.png") center / cover no-repeat, linear-gradient(180deg, #0d0d12, #16101f)',
  "#0d0d12",
  "#eaeaf0",
  [
    "#14141c", "#ff2a6d", "#05ffa1", "#fcee0a", "#00b8ff", "#ff5cf4", "#00f0ff", "#c7c7d1",
    "#7a7a92", "#ff6b95", "#6bffc4", "#fff65c", "#66d4ff", "#ff9df7", "#7dffff", "#ffffff",
  ]
);
THEMES.cyberpunk.xterm.cursor = "#fcee0a";
THEMES.cyberpunk.xterm.selectionBackground = "#00f0ff3d";

THEMES["deus-ex"] = mkTheme(
  "Deus Ex",
  "white",
  ['"Lucida Console", Consolas, monospace', 1.2, "underline"],
  'linear-gradient(rgba(10,9,6,0.42), rgba(10,9,6,0.58)), url("/backgrounds/deusex.png") center / cover no-repeat, linear-gradient(180deg, #0e0b06, #060503)',
  "#0a0906",
  "#e2cf9a",
  [
    "#12100b", "#d4522f", "#9aa762", "#e0a83a", "#7fa8c4", "#c095c6", "#7fc0b5", "#c9b985",
    "#8a7f5c", "#e57a52", "#b8c47f", "#f3c95f", "#9dc6dc", "#d6b5da", "#a4d8cf", "#f2e6c0",
  ]
);
THEMES["deus-ex"].xterm.cursor = "#e0a83a";
THEMES["deus-ex"].xterm.selectionBackground = "#e0a83a3d";

THEMES.umbrella = mkTheme(
  "Umbrella Corp",
  "white",
  ['"Cascadia Mono", Consolas, monospace', 1.15, "bar"],
  'linear-gradient(rgba(12,13,16,0.45), rgba(12,13,16,0.6)), url("/backgrounds/umbrella.png") center / cover no-repeat, linear-gradient(180deg, #0c0e11, #060608)',
  "#0c0e11",
  "#e3e6ea",
  [
    "#14171c", "#e02b2b", "#4fb477", "#d9a441", "#4d8fd6", "#c65fa8", "#56c2c9", "#b9c0c8",
    "#7a838e", "#ff5f5f", "#7ede9f", "#ffd45c", "#82b6ea", "#e394cd", "#8fdde3", "#f2f5f8",
  ]
);
THEMES.umbrella.xterm.cursor = "#e02b2b";
THEMES.umbrella.xterm.selectionBackground = "#e02b2b40";

THEMES.space = mkTheme(
  "Deep Space",
  "white",
  ['"Cascadia Mono", Consolas, monospace', 1.2, "bar"],
  'linear-gradient(rgba(7,11,22,0.38), rgba(7,11,22,0.52)), url("/backgrounds/space.png") center / cover no-repeat, linear-gradient(180deg, #060913, #0a0e1c)',
  "#070b16",
  "#d2e4f5",
  [
    "#101a2c", "#ff6b7a", "#55e6b0", "#ffd479", "#6aa6ff", "#c48aff", "#59dfff", "#d2e4f5",
    "#5d6e8c", "#ff94a0", "#8af0cb", "#ffe3a1", "#96c2ff", "#d9b3ff", "#8fe9ff", "#f0f6fc",
  ]
);
THEMES.space.xterm.cursor = "#59dfff";
THEMES.space.xterm.selectionBackground = "#59dfff33";

// Pip-Boy: monochrome phosphor-green wrist-console CRT — dial gauge,
// waveform, and meter HUD behind scanlines.
THEMES.pipboy = mkTheme(
  "Pip-Boy",
  "white",
  ['"Lucida Console", Consolas, monospace', 1.2, "block"],
  'linear-gradient(rgba(4,16,9,0.42), rgba(4,16,9,0.58)), url("/backgrounds/pipboy.png") center / cover no-repeat, linear-gradient(180deg, #08170d, #04100a)',
  "#06130a",
  "#1aff80",
  [
    "#06130a", "#ff8d7a", "#1de876", "#a9f06e", "#2fd98f", "#63e8a8", "#7dffc9", "#c4ffdf",
    "#1e7a44", "#ffab99", "#4dff9d", "#c9ff90", "#5ce8ab", "#9effc9", "#c2ffe0", "#ebfff3",
  ]
);
THEMES.pipboy.xterm.cursor = "#3aff95";
THEMES.pipboy.xterm.selectionBackground = "#1aff8033";

// NieR: the YoRHa menu look — beige paper, olive-gray ink, bronze
// accent, drop-shadowed UI bars in the backdrop.
THEMES.nier = mkTheme(
  "NieR",
  "black",
  ['"Cascadia Mono", Consolas, monospace', 1.2, "block"],
  'linear-gradient(rgba(214,209,188,0.35), rgba(214,209,188,0.48)), url("/backgrounds/nier.png") center / cover no-repeat, linear-gradient(180deg, #d6d1bc, #c7c2af)',
  "#d1ccb5",
  "#454138",
  [
    "#454138", "#a3492f", "#5f7134", "#8a6c22", "#6e5a2e", "#7d5165", "#4f7266", "#c9c4ad",
    "#5c574a", "#8a3d27", "#4d5c2a", "#66501a", "#57482a", "#684458", "#3f5d52", "#d6d1bc",
  ]
);

THEMES.nostromo = mkTheme(
  "Nostromo",
  "white",
  ['"Lucida Console", Consolas, monospace', 1.15, "block"],
  'linear-gradient(rgba(4,16,10,0.4), rgba(4,16,10,0.56)), url("/backgrounds/nostromo.png") center / cover no-repeat, linear-gradient(180deg, #04100a, #020a06)',
  "#04100a",
  "#b8e0c4",
  [
    "#04100a", "#ff8272", "#4fd087", "#a8d87a", "#4fd0a0", "#7fd8b8", "#9de8cc", "#c2e8d0",
    "#2a7a52", "#ffa090", "#72e8a8", "#c8f0a0", "#7fe0b8", "#a8f0d0", "#c8f8e0", "#e8fff2",
  ]
);
THEMES.nostromo.xterm.cursor = "#4fd087";

THEMES.c64 = mkTheme(
  "Commodore 64",
  "white",
  ['"Lucida Console", Consolas, monospace', 1.1, "block"],
  'linear-gradient(rgba(58,46,134,0.3), rgba(58,46,134,0.42)), url("/backgrounds/c64.png") center / cover no-repeat, linear-gradient(180deg, #3a2e86, #322874)',
  "#3a2e86",
  "#b8b3f0",
  [
    "#2a2066", "#e08a80", "#8fd076", "#d8e08a", "#8f86e0", "#c88ad0", "#8fd0d8", "#c4c0f0",
    "#8a80d8", "#f0a89e", "#a8e890", "#e8f0a0", "#a8a0f0", "#e0a8e8", "#a8e8f0", "#eeeaff",
  ]
);

THEMES.wargames = mkTheme(
  "WOPR",
  "white",
  ["Consolas, monospace", 1.15, "block"],
  'linear-gradient(rgba(4,7,13,0.4), rgba(4,7,13,0.56)), url("/backgrounds/wargames.png") center / cover no-repeat, linear-gradient(180deg, #04070d, #020409)',
  "#04070d",
  "#cfe2f8",
  [
    "#04070d", "#ff7f7f", "#6fe0a8", "#ffd47f", "#6ab4ff", "#b08fff", "#7fd4ff", "#c8ddf2",
    "#3a5578", "#ff9d9d", "#95f0c0", "#ffe4a8", "#8fc8ff", "#c8aaff", "#a8e4ff", "#eaf4ff",
  ]
);
THEMES.wargames.xterm.cursor = "#6ab4ff";

THEMES.macintosh = mkTheme(
  "Macintosh",
  "black",
  ["Consolas, monospace", 1.1, "block"],
  'linear-gradient(rgba(244,244,238,0.3), rgba(244,244,238,0.42)), url("/backgrounds/macintosh.png") center / cover no-repeat, linear-gradient(180deg, #f4f4ee, #ecece6)',
  "#f4f4ee",
  "#1a1a1a",
  [
    "#1a1a1a", "#a03328", "#2f6b2f", "#7a5a00", "#2f4f8f", "#6f3f8f", "#22656f", "#d8d8d0",
    "#5a5a55", "#8a2a20", "#265a26", "#665200", "#274578", "#5c3378", "#1e5560", "#ffffff",
  ]
);

THEMES.lumon = mkTheme(
  "Lumon",
  "white",
  ['"Cascadia Mono", Consolas, monospace', 1.25, "block"],
  'linear-gradient(rgba(6,20,35,0.38), rgba(6,20,35,0.54)), url("/backgrounds/lumon.png") center / cover no-repeat, linear-gradient(180deg, #061423, #040d18)',
  "#061423",
  "#a8e8e8",
  [
    "#061423", "#ff8291", "#5fe0b8", "#b8e8a0", "#45d8d8", "#7fc8f0", "#8ff0f0", "#c2e8ea",
    "#2a6070", "#ffa2ae", "#85f0cc", "#d0f8b8", "#6fe8e8", "#a0d8ff", "#b8f8f8", "#eafcfc",
  ]
);
THEMES.lumon.xterm.cursor = "#45d8d8";

THEMES.nerv = mkTheme(
  "NERV",
  "white",
  ["Consolas, monospace", 1.1, "block"],
  'linear-gradient(rgba(12,6,4,0.4), rgba(12,6,4,0.56)), url("/backgrounds/nerv.png") center / cover no-repeat, linear-gradient(180deg, #0c0604, #070302)',
  "#0c0604",
  "#ffb454",
  [
    "#0c0604", "#ff5252", "#58e05a", "#ffd23f", "#ff8c1a", "#e08aa0", "#7fd0c0", "#f0cfa0",
    "#7a4a20", "#ff7a7a", "#7ff080", "#ffe070", "#ffa64d", "#f0a8bc", "#a0e8d8", "#fff2dc",
  ]
);
THEMES.nerv.xterm.cursor = "#ff8c1a";
THEMES.nerv.xterm.selectionBackground = "#ff8c1a40";

THEMES.aperture = mkTheme(
  "Aperture",
  "black",
  ['"Cascadia Mono", Consolas, monospace', 1.2, "bar"],
  'linear-gradient(rgba(240,240,236,0.3), rgba(240,240,236,0.42)), url("/backgrounds/aperture.png") center / cover no-repeat, linear-gradient(180deg, #f0f0ec, #e6e6e0)',
  "#f0f0ec",
  "#26282a",
  [
    "#26282a", "#b03a2a", "#3f6b28", "#8a6000", "#2f6fc4", "#7a4098", "#25707a", "#d8d8d4",
    "#5c5e60", "#993322", "#33591f", "#6b4b00", "#265a9e", "#623380", "#1e5a62", "#ffffff",
  ]
);

THEMES.sheikah = mkTheme(
  "Sheikah",
  "white",
  ['"Cascadia Mono", Consolas, monospace', 1.2, "bar"],
  'linear-gradient(rgba(15,22,32,0.36), rgba(15,22,32,0.52)), url("/backgrounds/sheikah.png") center / cover no-repeat, linear-gradient(180deg, #0f1620, #0a0f16)',
  "#0f1620",
  "#8fe8d8",
  [
    "#0f1620", "#ff8a7a", "#69e8c0", "#e8c87a", "#58d8c8", "#b09af0", "#7fe0f0", "#c8e8e4",
    "#4a7276", "#ffa89a", "#8ff8d4", "#f8dc9a", "#7fe8d8", "#c8b4f8", "#a8ecf8", "#eafcf8",
  ]
);
THEMES.sheikah.xterm.cursor = "#58d8c8";

THEMES.blueprint = mkTheme(
  "Blueprint",
  "white",
  ['"Cascadia Mono", Consolas, monospace', 1.15, "bar"],
  'linear-gradient(rgba(21,63,102,0.3), rgba(21,63,102,0.42)), url("/backgrounds/blueprint.png") center / cover no-repeat, linear-gradient(180deg, #153f66, #10314f)',
  "#153f66",
  "#eaf2fb",
  [
    "#0e2c48", "#ff9d8a", "#8fe0b0", "#ffd98f", "#7fb8e8", "#c0a8f0", "#8fd8e8", "#d8e8f6",
    "#6a90b6", "#ffb8a8", "#aef0c8", "#ffe8b0", "#a0ccf0", "#d4c0f8", "#b0e8f4", "#f4f9ff",
  ]
);

THEMES.missionctl = mkTheme(
  "Mission Control",
  "white",
  ["Consolas, monospace", 1.15, "bar"],
  'linear-gradient(rgba(10,15,26,0.35), rgba(10,15,26,0.55)), url("/backgrounds/missionctl.jpg") center / cover no-repeat, linear-gradient(180deg, #0a0f1a, #0a0f1a)',
  "#0a0f1a",
  "#d2e0f0",
  [
    "#0a0f1a", "#ff7f72", "#55e0a0", "#ffce6b", "#6ab8ff", "#c493f0", "#66d8e8", "#c8d8ea",
    "#455a75", "#ff9d94", "#7ff0be", "#ffe094", "#90ccff", "#d8b0f8", "#90e8f4", "#ecf4fc",
  ]
);
THEMES.missionctl.xterm.cursor = "#6ab8ff";

THEMES.redacted = mkTheme(
  "Redacted",
  "black",
  ['"Courier New", monospace', 1.25, "underline"],
  'linear-gradient(rgba(239,236,226,0.32), rgba(239,236,226,0.44)), url("/backgrounds/redacted.png") center / cover no-repeat, linear-gradient(180deg, #efece2, #e5e1d4)',
  "#efece2",
  "#2c2822",
  [
    "#2c2822", "#a8342a", "#4a6431", "#7d5c1e", "#50617c", "#7a4a68", "#3f6b66", "#d8d4c6",
    "#5c574c", "#8f2a22", "#3d5528", "#615015", "#3f4f68", "#663d58", "#33574f", "#fbf8f0",
  ]
);

THEMES.persona = mkTheme(
  "Phantom",
  "white",
  ['"Cascadia Code", "Cascadia Mono", monospace', 1.1, "block"],
  'linear-gradient(rgba(13,5,8,0.4), rgba(13,5,8,0.55)), url("/backgrounds/persona.png") center / cover no-repeat, linear-gradient(180deg, #0d0508, #070204)',
  "#0d0508",
  "#f2e8ea",
  [
    "#0d0508", "#f03050", "#7fd070", "#f0c060", "#e8283c", "#e070a0", "#70c8d8", "#e0d4d8",
    "#6a4a52", "#ff5c74", "#a0e890", "#ffd880", "#ff5064", "#f0a0c0", "#a0e0ec", "#fdf6f8",
  ]
);
THEMES.persona.xterm.cursor = "#e8283c";
THEMES.persona.xterm.selectionBackground = "#e8283c40";

THEMES.akira = mkTheme(
  "Akira",
  "white",
  ['"Cascadia Code", "Cascadia Mono", monospace', 1.1, "block"],
  'linear-gradient(rgba(14,6,10,0.4), rgba(14,6,10,0.55)), url("/backgrounds/akira.png") center / cover no-repeat, linear-gradient(180deg, #0e060a, #070204)',
  "#0e060a",
  "#f0dcd8",
  [
    "#0e060a", "#ff5c50", "#8fd08a", "#ffca7a", "#ff4d5e", "#e08ab8", "#7fc8d8", "#e6d4d8",
    "#7a525c", "#ff7d70", "#aae8a0", "#ffdc9a", "#ff7382", "#f0a8cc", "#a0e0ec", "#fbf0f2",
  ]
);
THEMES.akira.xterm.cursor = "#ff4d5e";
THEMES.akira.xterm.selectionBackground = "#ff4d5e40";

THEMES.bebop = mkTheme(
  "Bebop",
  "white",
  ["Consolas, monospace", 1.2, "bar"],
  'linear-gradient(rgba(10,15,28,0.38), rgba(10,15,28,0.54)), url("/backgrounds/bebop.png") center / cover no-repeat, linear-gradient(180deg, #0a0f1c, #060a14)',
  "#0a0f1c",
  "#e8dcc0",
  [
    "#0a0f1c", "#ff7a6b", "#8fd0a0", "#ffce6b", "#e8a83c", "#c08ad0", "#7fc8d0", "#dcd2b8",
    "#4c5670", "#ff9c90", "#aae8bc", "#ffe094", "#f0c068", "#d8aae0", "#a0e0e8", "#f6efe0",
  ]
);
THEMES.bebop.xterm.cursor = "#e8a83c";

THEMES.scouter = mkTheme(
  "Scouter",
  "white",
  ['"Lucida Console", Consolas, monospace', 1.1, "block"],
  'linear-gradient(rgba(8,18,8,0.4), rgba(8,18,8,0.56)), url("/backgrounds/scouter.png") center / cover no-repeat, linear-gradient(180deg, #081208, #040a04)',
  "#081208",
  "#9df08f",
  [
    "#081208", "#ff6b5e", "#6fe060", "#d8e87a", "#55d848", "#a0d890", "#8ff0c0", "#c8f0c0",
    "#3f7a3c", "#ff8d80", "#8ff080", "#ecf89a", "#7de86e", "#c0e8b0", "#b0f8d8", "#eafce8",
  ]
);
THEMES.scouter.xterm.cursor = "#6fe060";
THEMES.scouter.xterm.selectionBackground = "#55d84840";

THEMES.backrooms = mkTheme(
  "Backrooms",
  "black",
  ['"Lucida Console", Consolas, monospace', 1.2, "block"],
  'linear-gradient(rgba(213,201,138,0.28), rgba(213,201,138,0.4)), url("/backgrounds/backrooms.png") center / cover no-repeat, linear-gradient(180deg, #d5c98a, #c4b878)',
  "#d5c98a",
  "#3a3418",
  [
    "#3a3418", "#9c3a28", "#4f6626", "#7a5c14", "#6b5e1e", "#7a4a58", "#3f6858", "#c2b678",
    "#5f5738", "#86301f", "#425420", "#5c4a0e", "#4c4a22", "#663d4a", "#335548", "#e8dfae",
  ]
);

THEMES.swordfish = mkTheme(
  "Swordfish",
  "white",
  ['"Cascadia Mono", Consolas, monospace', 1.15, "bar"],
  'linear-gradient(rgba(5,11,20,0.38), rgba(5,11,20,0.54)), url("/backgrounds/swordfish.png") center / cover no-repeat, linear-gradient(180deg, #050b14, #03060c)',
  "#050b14",
  "#c8e8f8",
  [
    "#050b14", "#ff6e7a", "#5ee8b0", "#ffd47f", "#4fd8ff", "#b48aff", "#7fe8ff", "#cfe0ee",
    "#3c5a72", "#ff93a0", "#88f0c8", "#ffe4a8", "#7fe0ff", "#cbaaff", "#a8f0ff", "#ecf6fc",
  ]
);
THEMES.swordfish.xterm.cursor = "#4fd8ff";

THEMES.hackers = mkTheme(
  "Hackers",
  "white",
  ['"Cascadia Code", "Cascadia Mono", monospace', 1.1, "block"],
  'linear-gradient(rgba(10,6,18,0.4), rgba(10,6,18,0.55)), url("/backgrounds/hackers.png") center / cover no-repeat, linear-gradient(180deg, #0a0612, #05030a)',
  "#0a0612",
  "#c0f0d0",
  [
    "#0a0612", "#ff5c74", "#39e878", "#e8e060", "#ff4dd8", "#c86aff", "#5ee8e8", "#d0e8d8",
    "#5a4a6e", "#ff85a0", "#66ff9d", "#f0ec8a", "#ff7de4", "#d898ff", "#8af0f0", "#f0fcf4",
  ]
);
THEMES.hackers.xterm.cursor = "#39e878";
THEMES.hackers.xterm.selectionBackground = "#ff4dd840";

THEMES.galactica = mkTheme(
  "Galactica",
  "white",
  ["Consolas, monospace", 1.15, "block"],
  'linear-gradient(rgba(13,10,6,0.38), rgba(13,10,6,0.54)), url("/backgrounds/galactica.png") center / cover no-repeat, linear-gradient(180deg, #0d0a06, #070503)',
  "#0d0a06",
  "#e8d4ac",
  [
    "#0d0a06", "#ff6b5e", "#9dd07f", "#ffce7a", "#d8a850", "#c89ad0", "#8fc8c0", "#e0d0b0",
    "#6e5c3e", "#ff8d80", "#bce89d", "#ffe0a0", "#e8c070", "#e0b8e8", "#a8e0d8", "#f8ecd8",
  ]
);
THEMES.galactica.xterm.cursor = "#d8a850";

THEMES.skicabin = mkTheme(
  "Ski Cabin",
  "white",
  ['"Cascadia Mono", Consolas, monospace', 1.2, "bar"],
  'linear-gradient(rgba(36,26,18,0.4), rgba(36,26,18,0.55)), url("/backgrounds/skicabin.png") center / cover no-repeat, linear-gradient(180deg, #241a12, #1a120c)',
  "#241a12",
  "#ecdcc4",
  [
    "#241a12", "#ff8a70", "#a8c87f", "#f0c078", "#e0954a", "#d8a0b8", "#8fc8d8", "#e2d4bc",
    "#7a6650", "#ffa890", "#c4e09d", "#ffd89a", "#f0b070", "#ecc0d0", "#b0e0ec", "#f8f0e0",
  ]
);
THEMES.skicabin.xterm.cursor = "#e0954a";

THEMES.rave = mkTheme(
  "Rave",
  "white",
  ['"Cascadia Code", "Cascadia Mono", monospace', 1.1, "bar"],
  'linear-gradient(rgba(8,3,12,0.42), rgba(8,3,12,0.58)), url("/backgrounds/rave.png") center / cover no-repeat, linear-gradient(180deg, #070309, #040106)',
  "#070309",
  "#eae0f4",
  [
    "#070309", "#ff4d6e", "#8fe83c", "#ffe23c", "#ff3de8", "#c86aff", "#3ee8e8", "#dcd4e8",
    "#5c4a70", "#ff7a94", "#b0ff66", "#fff07a", "#ff70f0", "#dc98ff", "#7af8f8", "#f8f2fc",
  ]
);
THEMES.rave.xterm.cursor = "#ff3de8";
THEMES.rave.xterm.selectionBackground = "#ff3de840";

THEMES.datacenter = mkTheme(
  "Datacenter",
  "white",
  ["Consolas, monospace", 1.15, "bar"],
  'linear-gradient(rgba(8,12,17,0.38), rgba(8,12,17,0.54)), url("/backgrounds/datacenter.png") center / cover no-repeat, linear-gradient(180deg, #070b10, #04070a)',
  "#070b10",
  "#cfe0e8",
  [
    "#070b10", "#ff7a72", "#4fe08a", "#ffce6b", "#5fb8e8", "#b89af0", "#6fd8d8", "#ccdae2",
    "#3e5566", "#ff9c94", "#7cf0ac", "#ffe094", "#88ccf0", "#ccb0f8", "#98e8e8", "#eef6fa",
  ]
);
THEMES.datacenter.xterm.cursor = "#4fe08a";

THEMES.sakura = mkTheme(
  "Sakura",
  "black",
  ['"Cascadia Mono", Consolas, monospace', 1.2, "bar"],
  'linear-gradient(rgba(246,233,238,0.3), rgba(246,233,238,0.42)), url("/backgrounds/sakura.png") center / cover no-repeat, linear-gradient(180deg, #f6e9ee, #eeD8e2)',
  "#f6e9ee",
  "#4a3540",
  [
    "#4a3540", "#b03a4c", "#4f7a4a", "#8a6224", "#c25d84", "#8a4a78", "#3f7a72", "#e8d2da",
    "#6e5560", "#963142", "#42663e", "#6e4e1c", "#a04a6e", "#744064", "#356861", "#fdf6f8",
  ]
);
THEMES.sakura.xterm.cursor = "#c25d84";

THEMES.pride = mkTheme(
  "Pride",
  "white",
  ['"Cascadia Code", "Cascadia Mono", monospace', 1.15, "bar"],
  'linear-gradient(rgba(18,16,26,0.4), rgba(18,16,26,0.55)), url("/backgrounds/pride.png") center / cover no-repeat, linear-gradient(180deg, #12101a, #09080e)',
  "#12101a",
  "#eae4f0",
  [
    "#12101a", "#e43c3c", "#46c85a", "#fad23c", "#4682f0", "#9646d2", "#3cc8c8", "#ded6e8",
    "#5a5270", "#ff6b6b", "#6ee87f", "#ffe470", "#79a8ff", "#c07ae8", "#70e8e8", "#f8f2fc",
  ]
);
THEMES.pride.xterm.cursor = "#fad23c";

THEMES.valorant = mkTheme(
  "Valorant",
  "black",
  ['"Cascadia Mono", Consolas, monospace', 1.15, "block"],
  'linear-gradient(rgba(236,232,225,0.3), rgba(236,232,225,0.42)), url("/backgrounds/valorant.png") center / cover no-repeat, linear-gradient(180deg, #ece8e1, #e2ddd4)',
  "#ece8e1",
  "#1f2326",
  [
    "#1f2326", "#c22638", "#3f6b3a", "#7a5a10", "#2f5f96", "#7a3f6b", "#26686b", "#d8d4cc",
    "#55595c", "#a81e2e", "#33582f", "#61480a", "#264e7c", "#653257", "#1d5457", "#fbf9f5",
  ]
);

THEMES.csgo = mkTheme(
  "Counter-Strike",
  "white",
  ["Consolas, monospace", 1.15, "bar"],
  'linear-gradient(rgba(16,20,27,0.38), rgba(16,20,27,0.54)), url("/backgrounds/csgo.png") center / cover no-repeat, linear-gradient(180deg, #10141b, #080b10)',
  "#10141b",
  "#d6dde5",
  [
    "#10141b", "#ff6f61", "#5ae06f", "#de9b35", "#78aaf0", "#b48ae0", "#6fd0d8", "#ccd4dc",
    "#5c6d80", "#ff9084", "#84f095", "#ffc35e", "#9cc4f8", "#ccaaf0", "#96e4ea", "#eef3f8",
  ]
);
THEMES.csgo.xterm.cursor = "#de9b35";

THEMES.dbd = mkTheme(
  "Dead by Daylight",
  "white",
  ['"Lucida Console", Consolas, monospace', 1.2, "block"],
  'linear-gradient(rgba(12,10,14,0.4), rgba(12,10,14,0.55)), url("/backgrounds/dbd.png") center / cover no-repeat, linear-gradient(180deg, #0c0a0e, #060508)',
  "#0c0a0e",
  "#d4ccd2",
  [
    "#0c0a0e", "#c8404a", "#6f9c72", "#c89a4a", "#5f7f9c", "#8f6f9c", "#5f9c96", "#cac2c8",
    "#635b68", "#e25c66", "#8fbc92", "#e8bc6c", "#82a4c2", "#b092c2", "#84c2bc", "#efe9ee",
  ]
);
THEMES.dbd.xterm.cursor = "#c8404a";
THEMES.dbd.xterm.selectionBackground = "#c8404a40";

THEMES.library = mkTheme(
  "Library",
  "white",
  ['"Cascadia Mono", Consolas, monospace', 1.15, "bar"],
  'linear-gradient(rgba(27,40,56,0.36), rgba(27,40,56,0.52)), url("/backgrounds/library.png") center / cover no-repeat, linear-gradient(180deg, #1b2838, #101720)',
  "#1b2838",
  "#c7d5e0",
  [
    "#1b2838", "#e07a72", "#6cc290", "#e0b568", "#66c0f4", "#a88ae0", "#6fc4d0", "#c0cdd8",
    "#516b82", "#f0968e", "#8ee0ac", "#f5d086", "#8ad4ff", "#c4a8f0", "#92e0ea", "#e8f0f6",
  ]
);
THEMES.library.xterm.cursor = "#66c0f4";

THEMES.blade = mkTheme(
  "Blade",
  "white",
  ["Consolas, monospace", 1.15, "block"],
  'linear-gradient(rgba(8,22,16,0.4), rgba(8,22,16,0.56)), url("/backgrounds/blade.png") center / cover no-repeat, linear-gradient(180deg, #081610, #040c08)',
  "#081610",
  "#cfe8bc",
  [
    "#081610", "#ff7a6b", "#76e03c", "#d0e05a", "#5ad07f", "#a8d86f", "#6fd8b0", "#c6dcb6",
    "#3f6b3c", "#ff9a8c", "#9bf00b", "#e4f07a", "#7fe8a0", "#c8f090", "#96ecd0", "#eefae0",
  ]
);
THEMES.blade.xterm.cursor = "#9bf00b";

THEMES.cartridge = mkTheme(
  "Cartridge",
  "black",
  ['"Lucida Console", Consolas, monospace', 1.15, "block"],
  'linear-gradient(rgba(246,240,232,0.3), rgba(246,240,232,0.42)), url("/backgrounds/cartridge.png") center / cover no-repeat, linear-gradient(180deg, #f6f0e8, #ece4da)',
  "#f6f0e8",
  "#2c282c",
  [
    "#2c282c", "#c0182a", "#3f6b2a", "#7a5a0a", "#2a5c9c", "#77367f", "#1f6a68", "#dcd4ca",
    "#5c565c", "#a61020", "#345824", "#614707", "#204b80", "#622b68", "#175552", "#fdfaf6",
  ]
);

THEMES.polygon = mkTheme(
  "Polygon",
  "white",
  ['"Cascadia Mono", Consolas, monospace', 1.2, "bar"],
  'linear-gradient(rgba(6,18,54,0.36), rgba(6,18,54,0.52)), url("/backgrounds/polygon.png") center / cover no-repeat, linear-gradient(180deg, #061236, #030a20)',
  "#061236",
  "#d0e0f8",
  [
    "#061236", "#ff7d8a", "#5ad8a0", "#ffd07a", "#6aa8ff", "#b48af0", "#6fd8ea", "#c8d8f0",
    "#556da0", "#ff9ba6", "#82e8ba", "#ffe0a2", "#8cc0ff", "#ccaaf8", "#96e8f4", "#eef4fd",
  ]
);
THEMES.polygon.xterm.cursor = "#6aa8ff";

THEMES.nightclub = mkTheme(
  "Nightclub",
  "white",
  ['"Cascadia Code", "Cascadia Mono", monospace', 1.15, "bar"],
  'linear-gradient(rgba(16,6,26,0.4), rgba(16,6,26,0.55)), url("/backgrounds/nightclub.png") center / cover no-repeat, linear-gradient(180deg, #10061a, #08030f)',
  "#10061a",
  "#ecdcf4",
  [
    "#10061a", "#ff5c8a", "#5ad8b0", "#ffb43c", "#ff46b4", "#785aff", "#3cdcdc", "#dccae8",
    "#70558c", "#ff85a8", "#82e8c8", "#ffcc70", "#ff7ccc", "#a08cff", "#70e8e8", "#f8effc",
  ]
);
THEMES.nightclub.xterm.cursor = "#ff46b4";
THEMES.nightclub.xterm.selectionBackground = "#ff46b440";

THEMES.speakeasy = mkTheme(
  "Speakeasy",
  "white",
  ['"Cascadia Mono", Consolas, monospace', 1.2, "bar"],
  'linear-gradient(rgba(34,22,16,0.4), rgba(34,22,16,0.55)), url("/backgrounds/speakeasy.png") center / cover no-repeat, linear-gradient(180deg, #221610, #150d09)',
  "#221610",
  "#f0dcc0",
  [
    "#221610", "#e0705c", "#9cb86a", "#e0aa50", "#c68a3c", "#c08a9c", "#7fb8ac", "#e2d2ba",
    "#6e5442", "#f0907c", "#bcd88a", "#f5c878", "#e0a860", "#d8a8b8", "#a0d8cc", "#faf0e0",
  ]
);
THEMES.speakeasy.xterm.cursor = "#e0aa50";

THEMES.penguin = mkTheme(
  "Penguin",
  "white",
  ['"Cascadia Mono", Consolas, monospace', 1.15, "block"],
  'linear-gradient(rgba(18,20,26,0.36), rgba(18,20,26,0.52)), url("/backgrounds/penguin.png") center / cover no-repeat, linear-gradient(180deg, #12141a, #0a0b0f)',
  "#12141a",
  "#d4dae6",
  [
    "#12141a", "#e86f6f", "#7fc86f", "#e8a03c", "#6f9fe8", "#b48ae0", "#5fc4c4", "#ccd2de",
    "#5a6270", "#ff8f8f", "#a0e08f", "#f5bc63", "#8fbcf5", "#ccaaf0", "#8fdcdc", "#eef2f8",
  ]
);
THEMES.penguin.xterm.cursor = "#e8a03c";

THEMES.cupertino = mkTheme(
  "Cupertino",
  "white",
  ['"Cascadia Mono", Consolas, monospace', 1.2, "bar"],
  'linear-gradient(rgba(26,18,48,0.36), rgba(26,18,48,0.52)), url("/backgrounds/cupertino.png") center / cover no-repeat, linear-gradient(180deg, #1a1230, #100a20)',
  "#1a1230",
  "#e6e2f0",
  [
    "#1a1230", "#ff6f61", "#5ad880", "#ffcc4d", "#0a84ff", "#bf5af2", "#5ac8d8", "#dcd6ea",
    "#5e5480", "#ff8f84", "#82e8a4", "#ffdd80", "#5aa8ff", "#d68cf7", "#82dce8", "#f6f2fc",
  ]
);
THEMES.cupertino.xterm.cursor = "#0a84ff";

THEMES.material = mkTheme(
  "Material",
  "white",
  ["Consolas, monospace", 1.15, "bar"],
  'linear-gradient(rgba(18,20,19,0.36), rgba(18,20,19,0.52)), url("/backgrounds/material.png") center / cover no-repeat, linear-gradient(180deg, #121413, #0a0c0b)',
  "#121413",
  "#e0e8e2",
  [
    "#121413", "#ef5350", "#3ddc84", "#ffca28", "#42a5f5", "#ab47bc", "#26c6da", "#d6ded8",
    "#5a6460", "#ff7b78", "#69f0a4", "#ffdd5c", "#6fc0ff", "#ce7ade", "#5ce0ec", "#f2faf4",
  ]
);
THEMES.material.xterm.cursor = "#3ddc84";

THEMES.chicago = mkTheme(
  "Chicago",
  "black",
  ['"Lucida Console", Consolas, monospace', 1.1, "block"],
  'linear-gradient(rgba(192,192,192,0.3), rgba(192,192,192,0.42)), url("/backgrounds/chicago.png") center / cover no-repeat, linear-gradient(180deg, #c0c0c0, #b4b4b4)',
  "#c0c0c0",
  "#000000",
  [
    "#000000", "#8a0000", "#006100", "#4a3a00", "#000080", "#6a0068", "#005a5a", "#3f3f3f",
    "#565656", "#a80000", "#00730d", "#5c4600", "#0000b4", "#7c0078", "#006e6e", "#ffffff",
  ]
);
THEMES.chicago.xterm.cursor = "#000080";

THEMES.aero = mkTheme(
  "Aero",
  "white",
  ['"Cascadia Mono", Consolas, monospace', 1.2, "bar"],
  'linear-gradient(rgba(12,46,96,0.32), rgba(12,46,96,0.46)), url("/backgrounds/aero.png") center / cover no-repeat, linear-gradient(180deg, #0c2e60, #061a3c)',
  "#0c2e60",
  "#e2eefc",
  [
    "#0c2e60", "#ff8a80", "#7fe0a8", "#ffd782", "#6ab8f0", "#c0a0f0", "#7fdcec", "#d8e4f4",
    "#5c7aa8", "#ffa8a0", "#a0f0c4", "#ffe4a8", "#96d0ff", "#d8bcff", "#a4ecf8", "#f4f9ff",
  ]
);
THEMES.aero.xterm.cursor = "#6ab8f0";

THEMES.fluent = mkTheme(
  "Fluent",
  "white",
  ['"Cascadia Mono", Consolas, monospace', 1.15, "bar"],
  'linear-gradient(rgba(16,20,26,0.36), rgba(16,20,26,0.52)), url("/backgrounds/fluent.png") center / cover no-repeat, linear-gradient(180deg, #10141a, #090c10)',
  "#10141a",
  "#dfe6ee",
  [
    "#10141a", "#e8646e", "#4fc98a", "#e8a33c", "#3aa0ee", "#a97ce0", "#3fc8d8", "#d2dae4",
    "#5a6675", "#ff8288", "#72e0a6", "#f5bf62", "#68bcff", "#c69cf0", "#68e0ec", "#f0f6fc",
  ]
);
THEMES.fluent.xterm.cursor = "#3aa0ee";

// DOS: the 16-colour CGA/EGA palette. Red and blue are lifted off
// their historical values (#aa0000 / #0000aa) - on black those are
// famously unreadable and fail the contrast audit.
THEMES.dos = mkTheme(
  "DOS",
  "white",
  ['"Lucida Console", Consolas, monospace', 1.1, "block"],
  'linear-gradient(rgba(0,0,0,0.34), rgba(0,0,0,0.5)), url("/backgrounds/dos.png") center / cover no-repeat, linear-gradient(180deg, #000000, #000000)',
  "#000000",
  "#aaaaaa",
  [
    "#000000", "#d43535", "#00aa00", "#aa5500", "#5878e8", "#aa00aa", "#00aaaa", "#aaaaaa",
    "#555555", "#ff5555", "#55ff55", "#ffff55", "#5555ff", "#ff55ff", "#55ffff", "#ffffff",
  ]
);
THEMES.dos.xterm.cursor = "#aaaaaa";

THEMES.coral = mkTheme(
  "Coral",
  "black",
  ['"Cascadia Mono", Consolas, monospace', 1.2, "bar"],
  'linear-gradient(rgba(242,240,233,0.3), rgba(242,240,233,0.42)), url("/backgrounds/coral.png") center / cover no-repeat, linear-gradient(180deg, #f2f0e9, #e8e4da)',
  "#f2f0e9",
  "#3d3929",
  [
    "#3d3929", "#b04a2a", "#4a6b34", "#7a5a14", "#39618f", "#7a447a", "#2a6a66", "#ddd8cb",
    "#5f5a48", "#94381c", "#3b5626", "#61470b", "#2c4e75", "#623562", "#1f5450", "#fdfbf6",
  ]
);
THEMES.coral.xterm.cursor = "#c25f3d";

THEMES.monochrome = mkTheme(
  "Monochrome",
  "white",
  ['"Cascadia Mono", Consolas, monospace', 1.2, "bar"],
  'linear-gradient(rgba(10,10,10,0.34), rgba(10,10,10,0.5)), url("/backgrounds/monochrome.png") center / cover no-repeat, linear-gradient(180deg, #0a0a0a, #050505)',
  "#0a0a0a",
  "#e8e8e8",
  [
    "#0a0a0a", "#c99a9a", "#9ec49e", "#c9c19a", "#9aaec9", "#c09ac0", "#9ac6c6", "#d2d2d2",
    "#606060", "#e0b4b4", "#bce0bc", "#e6dcb4", "#b8c8e6", "#dcb8dc", "#b4e0e0", "#fafafa",
  ]
);
THEMES.monochrome.xterm.cursor = "#f2f2f2";

THEMES.git = mkTheme(
  "Git",
  "white",
  ['"Cascadia Mono", Consolas, monospace', 1.15, "bar"],
  'linear-gradient(rgba(20,23,28,0.36), rgba(20,23,28,0.52)), url("/backgrounds/git.png") center / cover no-repeat, linear-gradient(180deg, #14171c, #0c0e12)',
  "#14171c",
  "#d6dbe1",
  [
    "#14171c", "#f05033", "#3fb950", "#d29922", "#58a6ff", "#bc8cff", "#56cfd8", "#ccd3da",
    "#59626d", "#ff7a5c", "#68d97c", "#f0be4c", "#82c0ff", "#d4b0ff", "#82e4ec", "#eef3f8",
  ]
);
THEMES.git.xterm.cursor = "#f05033";

THEMES.circuit = mkTheme(
  "Circuit",
  "white",
  ["Consolas, monospace", 1.15, "block"],
  'linear-gradient(rgba(10,32,20,0.36), rgba(10,32,20,0.52)), url("/backgrounds/circuit.png") center / cover no-repeat, linear-gradient(180deg, #0a2014, #06150d)',
  "#0a2014",
  "#d4e6cc",
  [
    "#0a2014", "#e07a5f", "#6fc46f", "#c69c3e", "#5fae9c", "#b08ac4", "#5fc0b4", "#c8dcc0",
    "#4a6b52", "#f09a80", "#92dc92", "#f2d888", "#84ccbc", "#ccaadc", "#84dcd0", "#e8f4e0",
  ]
);
THEMES.circuit.xterm.cursor = "#c69c3e";

THEMES.whiteboard = mkTheme(
  "Whiteboard",
  "black",
  ['"Cascadia Mono", Consolas, monospace', 1.2, "bar"],
  'linear-gradient(rgba(250,250,248,0.3), rgba(250,250,248,0.42)), url("/backgrounds/whiteboard.png") center / cover no-repeat, linear-gradient(180deg, #fafaf8, #f0f0ee)',
  "#fafaf8",
  "#2a2a2c",
  [
    "#2a2a2c", "#c03636", "#2f7a46", "#7a5a10", "#2f6fd0", "#7a3f96", "#1f6f7a", "#dcdcda",
    "#5c5c5e", "#a52828", "#256237", "#61470a", "#2456a4", "#61307a", "#175961", "#ffffff",
  ]
);
THEMES.whiteboard.xterm.cursor = "#2f6fd0";

THEMES.panic = mkTheme(
  "Kernel Panic",
  "white",
  ['"Lucida Console", Consolas, monospace', 1.15, "block"],
  'linear-gradient(rgba(14,3,3,0.36), rgba(14,3,3,0.52)), url("/backgrounds/panic.png") center / cover no-repeat, linear-gradient(180deg, #0e0303, #070101)',
  "#0e0303",
  "#e8d0d0",
  [
    "#0e0303", "#ff4646", "#8fc48f", "#e0a860", "#8fa8d8", "#d08ac0", "#7fc4c4", "#dcc8c8",
    "#6b4a4a", "#ff7070", "#b0e0b0", "#f5c684", "#b0c8f0", "#e8aad8", "#a4e0e0", "#fdeeee",
  ]
);
THEMES.panic.xterm.cursor = "#ff4646";
THEMES.panic.xterm.selectionBackground = "#ff464640";

// E-Ink: near-grayscale on purpose. The hues are only strong enough to
// tell the ANSI slots apart — 16 identical grays would be unusable.
THEMES.eink = mkTheme(
  "E-Ink",
  "black",
  ['"Cascadia Mono", Consolas, monospace', 1.25, "block"],
  'linear-gradient(rgba(237,236,232,0.3), rgba(237,236,232,0.42)), url("/backgrounds/eink.png") center / cover no-repeat, linear-gradient(180deg, #edece8, #e2e1dc)',
  "#edece8",
  "#2b2b2b",
  [
    "#2b2b2b", "#6b4a4a", "#44543f", "#5c5330", "#3f4a5c", "#544458", "#3d5252", "#cfcecb",
    "#5e5e5e", "#523636", "#33422f", "#463f22", "#2e374a", "#403244", "#2c3f3f", "#ffffff",
  ]
);

THEMES.punchcard = mkTheme(
  "Punch Card",
  "black",
  ['"Lucida Console", Consolas, monospace', 1.15, "block"],
  'linear-gradient(rgba(232,223,198,0.3), rgba(232,223,198,0.42)), url("/backgrounds/punchcard.png") center / cover no-repeat, linear-gradient(180deg, #e8dfc6, #ded4b8)',
  "#e8dfc6",
  "#3c3628",
  [
    "#3c3628", "#a03a24", "#46602c", "#71570e", "#35577f", "#6f3f6b", "#2a635c", "#d2c8ac",
    "#5e5744", "#853018", "#374d21", "#5b4508", "#284467", "#583154", "#1f4e48", "#fbf6e8",
  ]
);

THEMES.mainframe = mkTheme(
  "Mainframe",
  "white",
  ['"Lucida Console", Consolas, monospace', 1.15, "block"],
  'linear-gradient(rgba(0,20,0,0.34), rgba(0,20,0,0.5)), url("/backgrounds/mainframe.png") center / cover no-repeat, linear-gradient(180deg, #001400, #000a00)',
  "#001400",
  "#33ff33",
  [
    "#001400", "#ff6b6b", "#33ff33", "#e0e04a", "#5ad8d8", "#d88ad8", "#5affd8", "#c8e8c8",
    "#2a7a2a", "#ff9090", "#7cff7c", "#f0f080", "#8ae8e8", "#e8aae8", "#90ffe4", "#eaffea",
  ]
);
THEMES.mainframe.xterm.cursor = "#33ff33";

THEMES.duck = mkTheme(
  "Rubber Duck",
  "black",
  ['"Cascadia Code", "Cascadia Mono", monospace', 1.2, "block"],
  'linear-gradient(rgba(253,244,214,0.3), rgba(253,244,214,0.42)), url("/backgrounds/duck.png") center / cover no-repeat, linear-gradient(180deg, #fdf4d6, #f4e9c2)',
  "#fdf4d6",
  "#453c1c",
  [
    "#453c1c", "#b0431f", "#4a6624", "#7d5a06", "#2f5f8f", "#77406f", "#256863", "#e0d5b0",
    "#66593a", "#953313", "#3a521a", "#634603", "#245176", "#5f3159", "#1b524e", "#fffdf4",
  ]
);
THEMES.duck.xterm.cursor = "#d99a10";

// Zenburn: the classic low-contrast palette, unchanged.
THEMES.zenburn = mkTheme(
  "Zenburn",
  "white",
  ['"Cascadia Mono", Consolas, monospace', 1.2, "bar"],
  'linear-gradient(rgba(63,63,63,0.3), rgba(63,63,63,0.44)), url("/backgrounds/zenburn.png") center / cover no-repeat, linear-gradient(180deg, #3f3f3f, #363636)',
  "#3f3f3f",
  "#dcdccc",
  [
    "#3f3f3f", "#cc9393", "#7f9f7f", "#d0bf8f", "#6ca0a3", "#dc8cc3", "#93e0e3", "#dcdccc",
    "#709080", "#dca3a3", "#bfebbf", "#f0dfaf", "#8cd0d3", "#ec93d3", "#93e0e3", "#ffffff",
  ]
);
THEMES.zenburn.xterm.cursor = "#8cd0d3";

THEMES.containers = mkTheme(
  "Containers",
  "white",
  ['"Cascadia Mono", Consolas, monospace', 1.15, "bar"],
  'linear-gradient(rgba(10,40,64,0.34), rgba(10,40,64,0.5)), url("/backgrounds/containers.png") center / cover no-repeat, linear-gradient(180deg, #0a2840, #061a2a)',
  "#0a2840",
  "#cfe4f2",
  [
    "#0a2840", "#ff7f72", "#4fd08a", "#e8b45a", "#2496ed", "#a88ae8", "#5fc8dc", "#c4d8e8",
    "#58809e", "#ff9d92", "#7ce8ac", "#f5cc80", "#5fb4ff", "#c4aaf5", "#88e0f0", "#eaf4fc",
  ]
);
THEMES.containers.xterm.cursor = "#2496ed";

THEMES.helm = mkTheme(
  "Helm",
  "white",
  ['"Cascadia Mono", Consolas, monospace', 1.15, "bar"],
  'linear-gradient(rgba(12,26,62,0.34), rgba(12,26,62,0.5)), url("/backgrounds/helm.png") center / cover no-repeat, linear-gradient(180deg, #0c1a3e, #071026)',
  "#0c1a3e",
  "#d4dcf0",
  [
    "#0c1a3e", "#ff8080", "#5ad8a0", "#e8c46a", "#5a8cf5", "#ac8af0", "#5fc8e0", "#c8d4ec",
    "#4a5c88", "#ff9e9e", "#82e8bc", "#f5d894", "#88b0ff", "#c8aaf8", "#8ae0f0", "#eef2fc",
  ]
);
THEMES.helm.xterm.cursor = "#5a8cf5";

// Per-theme see-through defaults. Busy or bright backdrops (dense text,
// white UI panels, lit floors) veil themselves more so the terminal
// stays legible; sparse dark art keeps the full 100.
for (const [k, v] of Object.entries({
  chicago: 50, macintosh: 55, fluent: 55, aero: 58, library: 58, dos: 60,
  nightclub: 60, cupertino: 62, material: 62, cartridge: 62, penguin: 65,
  rave: 65, valorant: 68, backrooms: 68, lumon: 70, nostromo: 70,
  redacted: 70, nier: 72, "solarized-light": 75, blueprint: 75, swordfish: 75,
  hackers: 75, speakeasy: 75, sakura: 78, matrix: 80, pride: 80,
  skicabin: 80, gameboy: 80, pipboy: 82, csgo: 85, wargames: 85,
  galactica: 85, polygon: 85, bebop: 85, akira: 88, scouter: 88,
  aperture: 88, c64: 88,
  eink: 55, whiteboard: 58, punchcard: 60, circuit: 66, mainframe: 68,
  panic: 70, git: 72, duck: 80, coral: 82, containers: 82, helm: 85,
  monochrome: 88, zenburn: 95,
})) {
  if (THEMES[k]) THEMES[k].transparency = v;
}

let themeKey = "one-dark";
function currentTheme(): ThemeDef {
  return THEMES[themeKey] ?? THEMES["one-dark"];
}

// ── user-defined themes ─────────────────────────────────────────────────
// A custom theme picks a built-in as its base (palette, font, art) and
// overrides background, text, accent, and font. Stored in config.json
// under custom_themes; keys are "custom-<index>".
const builtinThemeKeys = Object.keys(THEMES);
function registerCustomThemes() {
  for (const k of Object.keys(THEMES)) {
    if (k.startsWith("custom-")) delete THEMES[k];
  }
  (config.custom_themes ?? []).forEach((ct, i) => {
    const base = THEMES[ct.base ?? "one-dark"] ?? THEMES["one-dark"];
    const x = base.xterm;
    const bg = ct.bg ?? x.background!;
    const fg = ct.fg ?? x.foreground!;
    const ansi = [
      x.black!, x.red!, x.green!, x.yellow!, x.blue!, x.magenta!, x.cyan!, x.white!,
      x.brightBlack!, x.brightRed!, x.brightGreen!, x.brightYellow!,
      x.brightBlue!, x.brightMagenta!, x.brightCyan!, x.brightWhite!,
    ];
    // A changed background keeps things predictable: flat color instead
    // of base art that was palette-matched to different colors.
    const bgArt = ct.bg ? `linear-gradient(0deg, ${bg}, ${bg})` : base.bgArt;
    const t = mkTheme(
      ct.name || `Custom ${i + 1}`,
      base.tint,
      [ct.font || base.font, base.lineHeight, base.cursorStyle],
      bgArt,
      bg,
      fg,
      ansi
    );
    if (ct.accent) {
      t.xterm.blue = ct.accent;
      t.xterm.selectionBackground = `${ct.accent}55`;
    }
    THEMES[`custom-${i}`] = t;
  });
}

// Effective appearance: explicit setting > theme default > baseline.
function effFont(): string {
  return config.font_family || currentTheme().font;
}
function effFontSize(): number {
  return config.font_size || 14;
}
function effLineHeight(): number {
  return config.line_height || currentTheme().lineHeight;
}
function effCursorStyle(): CursorStyle {
  return config.cursor_style || currentTheme().cursorStyle;
}
function effCursorBlink(): boolean {
  return config.cursor_blink ?? true;
}

let saveTimer: number | undefined;
function saveConfig() {
  window.clearTimeout(saveTimer);
  saveTimer = window.setTimeout(() => {
    invoke("set_config", { value: config }).catch(() => {});
  }, 300);
}

/// Terminal color theme, with a transparent background when a decorative
/// background is active so it shows through the cells.
function effXtermTheme(): ITheme {
  const t = currentTheme().xterm;
  if (!bgActive()) return t;
  // Cells stay fully transparent and the veil lives on the pane instead
  // (--cell-veil). Veiling the cells themselves leaves every pixel that
  // isn't a cell — the gutter, and the remainder where the row grid does
  // not divide evenly into the pane — showing the art at full strength.
  // Hex8 form: xterm's colour parser handles it reliably everywhere.
  return { ...t, background: "#00000000" };
}

/// Push current appearance settings into every open terminal, switching
/// renderers live: WebGL can't composite transparency, so tabs move to the
/// DOM renderer while a background is active and back to WebGL without one.
function applyAppearance() {
  applyBackground();
  // Keep the chrome font in sync with the effective terminal font (theme
  // font, or the user's font-family override).
  document.documentElement.style.setProperty("--ui-font", effFont());
  document.documentElement.style.setProperty("--tab-w", `${config.tab_width ?? 220}px`);
  // A different UI font means different text widths, so the status bar's
  // reserved sizes no longer mean anything.
  statusWidths.clear();
  statusDetailSizes.clear();
  const t = { xterm: effXtermTheme() };
  const bg = bgActive();
  for (const tab of tabs.values()) {
    if (bg && tab.webgl) {
      tab.webgl.dispose();
      tab.webgl = undefined;
    } else if (!bg && !tab.webgl) {
      try {
        tab.webgl = new WebglAddon();
        tab.term.loadAddon(tab.webgl);
      } catch {
        tab.webgl = undefined;
      }
    }
    tab.term.options.theme = t.xterm;
    tab.term.options.fontFamily = effFont();
    tab.term.options.fontSize = effFontSize();
    tab.term.options.lineHeight = effLineHeight();
    tab.term.options.cursorStyle = effCursorStyle();
    tab.term.options.cursorBlink = effCursorBlink();
    if (tab.id === activeId) fitTab(tab);
  }
}

function applyTheme(key: string) {
  themeKey = THEMES[key] ? key : "one-dark";
  const t = currentTheme();
  const root = document.documentElement.style;
  root.setProperty("--bg", t.xterm.background!);
  root.setProperty("--text", t.xterm.foreground!);
  root.setProperty("--tint", t.tint);
  root.setProperty("--accent", t.xterm.blue!);
  root.setProperty("--danger", t.xterm.red!);
  applyAppearance(); // also refreshes --ui-font from the theme's font
  config.theme = themeKey;
  saveConfig();
}

function orderedIds(): number[] {
  return [...tabbar.querySelectorAll<HTMLElement>(".tab")].map((el) => Number(el.dataset.id));
}

// ── tiling: a tab is a tree of panes ────────────────────────────────────
// Leaves are sessions, splits divide their space in two at a ratio. This
// is a guillotine model — the same one tmux and i3 use — so any layout
// reachable by repeatedly cutting a rectangle in two is representable,
// and nothing else is (see docs/tiling-panes.md).
//
// A tab is identified by the session it was opened with. If that pane
// closes while others remain, the key moves to a surviving leaf, taking
// the per-tab state (order, group, width) with it.

type LayoutNode =
  | { kind: "leaf"; id: number }
  | { kind: "split"; dir: "row" | "col"; ratio: number; a: LayoutNode; b: LayoutNode };

const layouts = new Map<number, LayoutNode>(); // tabKey -> tree
const paneTab = new Map<number, number>(); // session -> tabKey
const tabFocus = new Map<number, number>(); // tabKey -> focused session
const tabRoots = new Map<number, HTMLElement>(); // tabKey -> container in #panes

/// Smallest a pane may be dragged to, in pixels.
const MIN_PANE = 90;

function leavesOf(n: LayoutNode): number[] {
  return n.kind === "leaf" ? [n.id] : [...leavesOf(n.a), ...leavesOf(n.b)];
}

function replaceLeaf(n: LayoutNode, id: number, repl: LayoutNode): LayoutNode {
  if (n.kind === "leaf") return n.id === id ? repl : n;
  return { ...n, a: replaceLeaf(n.a, id, repl), b: replaceLeaf(n.b, id, repl) };
}

/// Remove a leaf and collapse the split that held it; null when the tree
/// was nothing but that leaf.
function dropLeaf(n: LayoutNode, id: number): LayoutNode | null {
  if (n.kind === "leaf") return n.id === id ? null : n;
  const a = dropLeaf(n.a, id);
  const b = dropLeaf(n.b, id);
  if (!a) return b;
  if (!b) return a;
  return { ...n, a, b };
}

function treeOf(key: number): LayoutNode {
  return layouts.get(key) ?? { kind: "leaf", id: key };
}

function activeTabKey(): number | undefined {
  return activeId === null ? undefined : paneTab.get(activeId);
}

function focusedOf(key: number): number {
  return tabFocus.get(key) ?? key;
}

/// Number of tabs, which is no longer the same as the number of sessions.
function tabCount(): number {
  return layouts.size;
}

function isSplit(key: number): boolean {
  return treeOf(key).kind === "split";
}

function buildLayoutDom(node: LayoutNode): HTMLElement {
  if (node.kind === "leaf") {
    const el = tabs.get(node.id)?.pane;
    if (el) {
      el.style.flex = "";
      return el;
    }
    // A leaf whose session has gone: keep the shape so the rest of the
    // tree still lays out. Pruned the next time the layout is saved.
    const gap = document.createElement("div");
    gap.className = "pane";
    return gap;
  }
  const box = document.createElement("div");
  box.className = `split ${node.dir}`;
  const a = buildLayoutDom(node.a);
  const b = buildLayoutDom(node.b);
  a.style.flex = `${node.ratio} 1 0`;
  b.style.flex = `${1 - node.ratio} 1 0`;
  const bar = document.createElement("div");
  bar.className = "divider";
  bar.title = "Drag to resize — double-click to even out";
  bar.addEventListener("pointerdown", (e) => beginDividerDrag(e, node, box));
  bar.addEventListener("dblclick", () => {
    node.ratio = 0.5;
    (box.children[0] as HTMLElement).style.flex = "0.5 1 0";
    (box.children[2] as HTMLElement).style.flex = "0.5 1 0";
    const key = activeTabKey();
    if (key !== undefined) fitPanes(key);
    saveLayouts();
  });
  box.append(a, bar, b);
  return box;
}

function beginDividerDrag(e: PointerEvent, node: LayoutNode, box: HTMLElement) {
  if (e.button !== 0 || node.kind !== "split") return;
  e.preventDefault();
  e.stopPropagation();
  const horizontal = node.dir === "row";
  const rect = box.getBoundingClientRect();
  const total = horizontal ? rect.width : rect.height;
  if (total <= 0) return;
  const start = horizontal ? e.clientX : e.clientY;
  const from = node.ratio;
  const first = box.children[0] as HTMLElement;
  const second = box.children[2] as HTMLElement;
  const limit = MIN_PANE / total;
  const onMove = (ev: PointerEvent) => {
    const delta = (horizontal ? ev.clientX : ev.clientY) - start;
    node.ratio = Math.min(1 - limit, Math.max(limit, from + delta / total));
    first.style.flex = `${node.ratio} 1 0`;
    second.style.flex = `${1 - node.ratio} 1 0`;
  };
  const onUp = () => {
    window.removeEventListener("pointermove", onMove);
    const key = activeTabKey();
    if (key !== undefined) fitPanes(key);
    saveLayouts();
  };
  window.addEventListener("pointermove", onMove);
  window.addEventListener("pointerup", onUp, { once: true });
}

function renderLayout(key: number) {
  const root = tabRoots.get(key);
  if (!root) return;
  root.replaceChildren(buildLayoutDom(treeOf(key)));
  // Pane grips and the focus ring only make sense once there are two.
  root.classList.toggle("multi", isSplit(key));
  markFocus(key);
}

/// Ring the focused pane, but only when there is more than one to tell
/// apart — a lone pane with a highlight border just looks like chrome.
function markFocus(key: number) {
  const focused = focusedOf(key);
  const many = isSplit(key);
  for (const leaf of leavesOf(treeOf(key))) {
    tabs.get(leaf)?.pane.classList.toggle("focused", many && leaf === focused);
  }
}

function fitPanes(key: number) {
  for (const leaf of leavesOf(treeOf(key))) {
    const t = tabs.get(leaf);
    if (t) fitTab(t);
  }
}

function focusPane(id: number) {
  const key = paneTab.get(id);
  if (key === undefined) return;
  tabFocus.set(key, id);
  activeId = id;
  markFocus(key);
  tabs.get(id)?.term.focus();
  saveLayouts();
  refreshChrome();
}

/// Split the focused pane, giving the new session the same folder — the
/// tmux behaviour, and what makes splitting useful mid-task.
async function splitPane(dir: "row" | "col") {
  const key = activeTabKey();
  if (key === undefined) return;
  const from = focusedOf(key);
  const cwd = lastInfo.get(from)?.cwd;
  const shell = lastInfo.get(from)?.shell;
  const id = await createTab(undefined, shell, cwd, undefined, from);
  if (id === undefined) return;
  layouts.set(
    key,
    replaceLeaf(treeOf(key), from, {
      kind: "split",
      dir,
      ratio: 0.5,
      a: { kind: "leaf", id: from },
      b: { kind: "leaf", id },
    })
  );
  paneTab.set(id, key);
  renderLayout(key);
  fitPanes(key);
  focusPane(id);
}

/// The pane next to `from` in a direction. Picked by geometry rather than
/// tree position, so it behaves the way the layout looks.
function neighbourOf(
  key: number,
  from: number,
  dir: "left" | "right" | "up" | "down"
): number | undefined {
  const here = tabs.get(from)?.pane.getBoundingClientRect();
  if (!here) return undefined;
  let best: { id: number; score: number } | undefined;
  for (const leaf of leavesOf(treeOf(key))) {
    if (leaf === from) continue;
    const r = tabs.get(leaf)?.pane.getBoundingClientRect();
    if (!r) continue;
    const along =
      dir === "left" ? here.left - r.right
      : dir === "right" ? r.left - here.right
      : dir === "up" ? here.top - r.bottom
      : r.top - here.bottom;
    if (along < -1) continue; // not on that side at all
    const across =
      dir === "left" || dir === "right"
        ? Math.abs(r.top + r.height / 2 - (here.top + here.height / 2))
        : Math.abs(r.left + r.width / 2 - (here.left + here.width / 2));
    const score = along + across;
    if (!best || score < best.score) best = { id: leaf, score };
  }
  return best?.id;
}

function focusNeighbour(dir: "left" | "right" | "up" | "down") {
  const key = activeTabKey();
  if (key === undefined || !isSplit(key)) return;
  const id = neighbourOf(key, focusedOf(key), dir);
  if (id !== undefined) focusPane(id);
}

/// Blow the focused pane up to fill the tab, keeping the layout intact
/// underneath. Toggles back to the same arrangement.
const zoomed = new Map<number, LayoutNode>();
function toggleZoom() {
  const key = activeTabKey();
  if (key === undefined) return;
  const stashed = zoomed.get(key);
  if (stashed) {
    layouts.set(key, stashed);
    zoomed.delete(key);
  } else {
    if (!isSplit(key)) return;
    zoomed.set(key, treeOf(key));
    layouts.set(key, { kind: "leaf", id: focusedOf(key) });
  }
  renderLayout(key);
  fitPanes(key);
  tabs.get(focusedOf(key))?.term.focus();
  refreshChrome();
}

type DropSide = "left" | "right" | "top" | "bottom" | "swap";

/// Panes of a tab in reading order — top to bottom, left to right — which
/// is the order the numbers overlay and the layout presets both use.
function panesInOrder(key: number): number[] {
  return leavesOf(treeOf(key))
    .map((id) => ({ id, r: tabs.get(id)?.pane.getBoundingClientRect() }))
    .filter((p): p is { id: number; r: DOMRect } => !!p.r)
    .sort((a, b) => a.r.top - b.r.top || a.r.left - b.r.left)
    .map((p) => p.id);
}

/// Move a pane next to another inside the same tab, or exchange the two.
/// Removing the source can collapse a split, so the target is re-found in
/// the pruned tree rather than in the original.
function movePaneWithin(key: number, src: number, target: number, side: DropSide) {
  if (src === target) return;
  const tree = treeOf(key);
  if (side === "swap") {
    const swap = (n: LayoutNode): LayoutNode =>
      n.kind === "leaf"
        ? { kind: "leaf", id: n.id === src ? target : n.id === target ? src : n.id }
        : { ...n, a: swap(n.a), b: swap(n.b) };
    layouts.set(key, swap(tree));
  } else {
    const without = dropLeaf(tree, src);
    if (!without) return;
    const dir: "row" | "col" = side === "left" || side === "right" ? "row" : "col";
    const first = side === "left" || side === "top";
    layouts.set(
      key,
      replaceLeaf(without, target, {
        kind: "split",
        dir,
        ratio: 0.5,
        a: { kind: "leaf", id: first ? src : target },
        b: { kind: "leaf", id: first ? target : src },
      })
    );
  }
  renderLayout(key);
  fitPanes(key);
  focusPane(src);
}

/// Swap the focused pane with its neighbour in a direction — the
/// keyboard counterpart of dragging it there.
function movePaneDir(dir: "left" | "right" | "up" | "down") {
  const key = activeTabKey();
  if (key === undefined || !isSplit(key)) return;
  const neighbour = neighbourOf(key, focusedOf(key), dir);
  if (neighbour !== undefined) movePaneWithin(key, focusedOf(key), neighbour, "swap");
}

/// Pull a pane out of its tab into a tab of its own. Every pane already
/// carries an unused tab button for exactly this.
function promotePane(src: number) {
  const key = paneTab.get(src);
  if (key === undefined || !isSplit(key)) return;
  const without = dropLeaf(treeOf(key), src);
  if (!without) return;
  layouts.set(key, without);
  zoomed.delete(key);
  if (focusedOf(key) === src) tabFocus.set(key, leavesOf(without)[0]);
  // The old tab keeps its identity unless the promoted pane was carrying
  // it, in which case a survivor takes over.
  if (src === key) retagTab(key, leavesOf(without)[0]);
  const stayKey = paneTab.get(leavesOf(without)[0]);
  if (stayKey !== undefined) {
    renderLayout(stayKey);
    fitPanes(stayKey);
  }

  const tab = tabs.get(src);
  if (!tab) return;
  const root = document.createElement("div");
  root.className = "tab-root";
  panes.appendChild(root);
  tabRoots.set(src, root);
  layouts.set(src, { kind: "leaf", id: src });
  paneTab.set(src, src);
  tabFocus.set(src, src);
  if (!tab.button.isConnected) tabbar.appendChild(tab.button);
  if (!tabOrder.includes(src)) tabOrder.push(src);
  saveOrder();
  renderLayout(src);
  setActive(src);
  saveLayouts();
}

/// Fold one tab into another as a split — the inverse of `promotePane`,
/// and how splitting is meant to be discovered: drag a tab onto the middle
/// of another. The source's whole tree comes along, so merging a tab that
/// is itself split keeps its arrangement intact.
function mergeTabInto(srcKey: number, dstKey: number) {
  if (srcKey === dstKey || !layouts.has(srcKey) || !layouts.has(dstKey)) return;
  // Zoom is a view state rather than a layout. Un-zoom both ends first, or
  // the stashed tree is stranded on a tab that no longer exists.
  for (const k of [srcKey, dstKey]) {
    const stashed = zoomed.get(k);
    if (stashed) {
      layouts.set(k, stashed);
      zoomed.delete(k);
    }
  }
  const srcTree = treeOf(srcKey);
  // Show the destination before measuring: a hidden tab-root is
  // display:none, so its panes have no geometry to split along.
  setActive(dstKey);
  const anchor = focusedOf(dstKey);
  const r = tabs.get(anchor)?.pane.getBoundingClientRect();
  // Cut the anchor along its longer axis, so the result stays roughly
  // square instead of producing ever-thinner columns.
  const dir: "row" | "col" = !r || r.width >= r.height ? "row" : "col";
  layouts.set(
    dstKey,
    replaceLeaf(treeOf(dstKey), anchor, {
      kind: "split",
      dir,
      ratio: 0.5,
      a: { kind: "leaf", id: anchor },
      b: srcTree,
    })
  );
  for (const leaf of leavesOf(srcTree)) paneTab.set(leaf, dstKey);

  // The source is no longer a tab: drop its bar button, its root, and the
  // per-tab state keyed by it.
  tabs.get(srcKey)?.button.remove();
  layouts.delete(srcKey);
  tabFocus.delete(srcKey);
  tabRoots.get(srcKey)?.remove();
  tabRoots.delete(srcKey);
  tabOrder = tabOrder.filter((t) => t !== srcKey);
  saveOrder();
  if (groupState.assign[srcKey]) {
    delete groupState.assign[srcKey];
    saveGroups();
  }
  if (tabWidths[srcKey] !== undefined) {
    delete tabWidths[srcKey];
    saveTabWidths();
  }

  renderLayout(dstKey);
  fitPanes(dstKey);
  focusPane(leavesOf(srcTree)[0]);
  saveLayouts();
  refreshChrome();
}

// ── layout presets ──────────────────────────────────────────────────────

/// Even chain of leaves in one direction: ratios shrink so every pane
/// ends up the same size.
function evenChain(ids: number[], dir: "row" | "col"): LayoutNode {
  if (ids.length === 1) return { kind: "leaf", id: ids[0] };
  return {
    kind: "split",
    dir,
    ratio: 1 / ids.length,
    a: { kind: "leaf", id: ids[0] },
    b: evenChain(ids.slice(1), dir),
  };
}

/// Balanced split, alternating direction — roughly square cells.
function tiled(ids: number[], dir: "row" | "col" = "row"): LayoutNode {
  if (ids.length === 1) return { kind: "leaf", id: ids[0] };
  const half = Math.ceil(ids.length / 2);
  const next = dir === "row" ? "col" : "row";
  return {
    kind: "split",
    dir,
    ratio: half / ids.length,
    a: tiled(ids.slice(0, half), next),
    b: tiled(ids.slice(half), next),
  };
}

type PresetKind = "even-cols" | "even-rows" | "main-stack" | "quad";

function applyPreset(kind: PresetKind) {
  const key = activeTabKey();
  if (key === undefined) return;
  const ids = panesInOrder(key);
  if (ids.length < 2) return;
  zoomed.delete(key);
  let tree: LayoutNode;
  switch (kind) {
    case "even-cols":
      tree = evenChain(ids, "row");
      break;
    case "even-rows":
      tree = evenChain(ids, "col");
      break;
    case "main-stack":
      tree =
        ids.length === 1
          ? { kind: "leaf", id: ids[0] }
          : {
              kind: "split",
              dir: "row",
              ratio: 0.6,
              a: { kind: "leaf", id: ids[0] },
              b: evenChain(ids.slice(1), "col"),
            };
      break;
    case "quad":
      tree = tiled(ids);
      break;
  }
  layouts.set(key, tree);
  renderLayout(key);
  fitPanes(key);
  saveLayouts();
}

// ── pane numbers ────────────────────────────────────────────────────────

/// Holding Alt labels each pane, tmux's display-panes: Alt+<n> jumps.
let numbersShown = false;
function showPaneNumbers(on: boolean) {
  const key = activeTabKey();
  if (on && (key === undefined || !isSplit(key))) return;
  if (numbersShown === on) return;
  numbersShown = on;
  document.querySelectorAll(".pane-number").forEach((n) => n.remove());
  if (!on || key === undefined) return;
  panesInOrder(key).forEach((id, i) => {
    const pane = tabs.get(id)?.pane;
    if (!pane || i > 8) return;
    const badge = document.createElement("div");
    badge.className = "pane-number";
    badge.textContent = String(i + 1);
    pane.appendChild(badge);
  });
}

function focusPaneByNumber(n: number) {
  const key = activeTabKey();
  if (key === undefined) return false;
  const id = panesInOrder(key)[n - 1];
  if (id === undefined) return false;
  focusPane(id);
  return true;
}

// ── dragging a pane ─────────────────────────────────────────────────────

/// Which part of a pane the pointer is over: the middle means "swap", the
/// outer bands mean "put it on that side".
function dropSideAt(r: DOMRect, x: number, y: number): DropSide {
  const fx = (x - r.left) / r.width;
  const fy = (y - r.top) / r.height;
  if (fx > 0.3 && fx < 0.7 && fy > 0.3 && fy < 0.7) return "swap";
  // Nearest edge measured in fractions, so tall and wide panes behave alike.
  const d: Array<[DropSide, number]> = [
    ["left", fx],
    ["right", 1 - fx],
    ["top", fy],
    ["bottom", 1 - fy],
  ];
  d.sort((a, b) => a[1] - b[1]);
  return d[0][0];
}

/// Drag a pane by its grip onto another pane to rearrange it, or onto the
/// tab strip to give it a tab of its own. Pointer events rather than HTML5
/// drag, which is unreliable inside the frameless window.
function beginPaneDrag(e: PointerEvent, src: number) {
  if (e.button !== 0) return;
  e.preventDefault();
  e.stopPropagation();
  const key = paneTab.get(src);
  const root = key === undefined ? undefined : tabRoots.get(key);
  if (key === undefined || !root || !isSplit(key)) return;
  app.classList.add("pane-dragging");
  const hint = document.createElement("div");
  hint.className = "drop-hint";
  root.appendChild(hint);
  let drop: { target: number; side: DropSide } | "tab" | null = null;

  const place = (left: number, top: number, width: number, height: number, cls: string) => {
    const rootR = root.getBoundingClientRect();
    hint.className = `drop-hint ${cls}`;
    hint.style.left = `${left - rootR.left}px`;
    hint.style.top = `${top - rootR.top}px`;
    hint.style.width = `${width}px`;
    hint.style.height = `${height}px`;
  };

  const onMove = (ev: PointerEvent) => {
    const under = document.elementFromPoint(ev.clientX, ev.clientY);
    const overTabs = under?.closest("#tabbar-row");
    if (overTabs) {
      drop = "tab";
      const r = overTabs.getBoundingClientRect();
      place(r.left, r.top, r.width, r.height, "show tab");
      return;
    }
    const el = under?.closest(".pane");
    const targetId = el instanceof HTMLElement ? Number(el.dataset.session) : NaN;
    if (!el || !Number.isFinite(targetId) || targetId === src || !tabs.has(targetId)) {
      drop = null;
      hint.className = "drop-hint";
      return;
    }
    const r = el.getBoundingClientRect();
    const side = dropSideAt(r, ev.clientX, ev.clientY);
    drop = { target: targetId, side };
    // Preview the space the pane would actually occupy.
    let [left, top, width, height] = [r.left, r.top, r.width, r.height];
    if (side === "left" || side === "right") {
      width = r.width / 2;
      if (side === "right") left += r.width / 2;
    } else if (side === "top" || side === "bottom") {
      height = r.height / 2;
      if (side === "bottom") top += r.height / 2;
    }
    place(left, top, width, height, side === "swap" ? "show swap" : "show");
  };

  const onUp = () => {
    window.removeEventListener("pointermove", onMove);
    app.classList.remove("pane-dragging");
    hint.remove();
    if (drop === "tab") promotePane(src);
    else if (drop) movePaneWithin(key, src, drop.target, drop.side);
    saveLayouts();
  };

  window.addEventListener("pointermove", onMove);
  window.addEventListener("pointerup", onUp, { once: true });
}

// ── arrange mode ────────────────────────────────────────────────────────

/// Rearranging panes has one hard constraint: dragging inside a terminal
/// already means "select text", so the only handle a pane can offer is a
/// small grip you have to go hunting for. This trades that for a mode —
/// terminals go inert, and every pane gets a drop target the size of the
/// pane itself. Dividers still poke through between the boxes, so
/// resizing keeps working without leaving.
let arrangeKey: number | undefined;

function toggleArrange() {
  if (arrangeKey !== undefined) closeArrange();
  else openArrange();
}

function openArrange() {
  const key = activeTabKey();
  if (key === undefined || !isSplit(key)) return;
  arrangeKey = key;
  app.classList.add("arranging");
  // Out of the terminal, so stray keys don't reach the shell and Escape
  // reaches the window handler.
  (document.activeElement as HTMLElement | null)?.blur();
  renderArrange();
  window.addEventListener("resize", renderArrange);
}

function closeArrange() {
  if (arrangeKey === undefined) return;
  const key = arrangeKey;
  arrangeKey = undefined;
  window.removeEventListener("resize", renderArrange);
  app.classList.remove("arranging");
  document.getElementById("arrange")?.remove();
  saveLayouts();
  tabs.get(focusedOf(key))?.term.focus();
}

/// The boxes mirror the real pane rectangles rather than a schematic of
/// them, so what you drag is exactly what you are looking at.
function renderArrange() {
  if (arrangeKey === undefined) return;
  const key = arrangeKey;
  const root = tabRoots.get(key);
  if (!root || !isSplit(key)) {
    closeArrange();
    return;
  }
  document.getElementById("arrange")?.remove();
  const ov = document.createElement("div");
  ov.id = "arrange";
  const rootR = root.getBoundingClientRect();
  panesInOrder(key).forEach((id, i) => {
    const pane = tabs.get(id)?.pane;
    if (!pane) return;
    const r = pane.getBoundingClientRect();
    const box = document.createElement("div");
    box.className = "arrange-box";
    box.dataset.session = String(id);
    box.style.left = `${r.left - rootR.left}px`;
    box.style.top = `${r.top - rootR.top}px`;
    box.style.width = `${r.width}px`;
    box.style.height = `${r.height}px`;
    const n = document.createElement("div");
    n.className = "arrange-n";
    n.textContent = String(i + 1);
    const t = document.createElement("div");
    t.className = "arrange-title";
    t.textContent = titleOf(id);
    box.append(n, t);
    box.addEventListener("pointerdown", (e) => beginArrangeDrag(e, id));
    ov.appendChild(box);
  });
  ov.appendChild(arrangeBar());
  root.appendChild(ov);
}

function arrangeBar(): HTMLElement {
  const bar = document.createElement("div");
  bar.className = "arrange-bar";
  const hint = document.createElement("span");
  hint.className = "arrange-hint";
  hint.textContent = "Drag a pane onto another — edges place it, middle swaps";
  bar.appendChild(hint);
  const presets: Array<[PresetKind, string, string]> = [
    ["even-cols", "▯▯", "Even columns"],
    ["even-rows", "▤", "Even rows"],
    ["main-stack", "▙", "Main + stack"],
    ["quad", "▦", "Tiled"],
  ];
  for (const [kind, glyph, label] of presets) {
    const b = document.createElement("button");
    b.textContent = glyph;
    b.title = label;
    b.addEventListener("click", () => {
      applyPreset(kind);
      requestAnimationFrame(renderArrange);
    });
    bar.appendChild(b);
  }
  const done = document.createElement("button");
  done.className = "arrange-done";
  done.textContent = "Done";
  done.title = "Finish arranging (Esc)";
  done.addEventListener("click", closeArrange);
  bar.appendChild(done);
  return bar;
}

function beginArrangeDrag(e: PointerEvent, src: number) {
  if (e.button !== 0 || arrangeKey === undefined) return;
  e.preventDefault();
  const key = arrangeKey;
  const root = tabRoots.get(key);
  const ov = document.getElementById("arrange");
  if (!root || !ov) return;
  const srcBox = ov.querySelector<HTMLElement>(`.arrange-box[data-session="${src}"]`);
  const hint = document.createElement("div");
  hint.className = "drop-hint";
  ov.appendChild(hint);
  const rootR = root.getBoundingClientRect();
  let drop: { target: number; side: DropSide } | null = null;
  let moved = false;

  const onMove = (ev: PointerEvent) => {
    if (!moved) {
      if (Math.abs(ev.clientX - e.clientX) < 4 && Math.abs(ev.clientY - e.clientY) < 4) return;
      moved = true;
      srcBox?.classList.add("dragging");
    }
    const el = document.elementFromPoint(ev.clientX, ev.clientY)?.closest(".arrange-box");
    const targetId = el instanceof HTMLElement ? Number(el.dataset.session) : NaN;
    if (!el || !Number.isFinite(targetId) || targetId === src) {
      drop = null;
      hint.className = "drop-hint";
      return;
    }
    const r = el.getBoundingClientRect();
    const side = dropSideAt(r, ev.clientX, ev.clientY);
    drop = { target: targetId, side };
    // Preview the space the pane would actually occupy.
    let [left, top, width, height] = [r.left, r.top, r.width, r.height];
    if (side === "left" || side === "right") {
      width = r.width / 2;
      if (side === "right") left += r.width / 2;
    } else if (side === "top" || side === "bottom") {
      height = r.height / 2;
      if (side === "bottom") top += r.height / 2;
    }
    hint.className = `drop-hint show${side === "swap" ? " swap" : ""}`;
    hint.style.left = `${left - rootR.left}px`;
    hint.style.top = `${top - rootR.top}px`;
    hint.style.width = `${width}px`;
    hint.style.height = `${height}px`;
  };

  const onUp = () => {
    window.removeEventListener("pointermove", onMove);
    hint.remove();
    srcBox?.classList.remove("dragging");
    // A click that never moved just picks the pane to work on.
    if (!moved || !drop) {
      focusPane(src);
      return;
    }
    movePaneWithin(key, src, drop.target, drop.side);
    // renderLayout replaced the root's children, taking the overlay with
    // it; rebuild once the new rectangles have settled.
    requestAnimationFrame(renderArrange);
    saveLayouts();
  };

  window.addEventListener("pointermove", onMove);
  window.addEventListener("pointerup", onUp, { once: true });
}

/// Per-tab layouts, pruned against the sessions the daemon still has.
function saveLayouts() {
  const out: Record<string, { root: LayoutNode; focus: number }> = {};
  for (const [key, root] of layouts) {
    out[key] = { root: zoomed.get(key) ?? root, focus: focusedOf(key) };
  }
  localStorage.setItem("gterm-layouts", JSON.stringify(out));
}

function loadLayouts(): Record<string, { root: LayoutNode; focus: number }> {
  try {
    return JSON.parse(localStorage.getItem("gterm-layouts") ?? "{}");
  } catch {
    return {};
  }
}

/// Keep only leaves whose sessions exist; returns null if none survive.
function pruneTree(n: LayoutNode, alive: Set<number>): LayoutNode | null {
  if (n.kind === "leaf") return alive.has(n.id) ? n : null;
  const a = pruneTree(n.a, alive);
  const b = pruneTree(n.b, alive);
  if (!a) return b;
  if (!b) return a;
  return { ...n, a, b };
}

/// Hand a tab's identity to another of its panes, carrying the per-tab
/// state that is keyed by session id.
function retagTab(oldKey: number, newKey: number) {
  const tree = layouts.get(oldKey);
  if (!tree) return;
  layouts.delete(oldKey);
  layouts.set(newKey, tree);
  const root = tabRoots.get(oldKey);
  if (root) {
    tabRoots.delete(oldKey);
    tabRoots.set(newKey, root);
  }
  const zoom = zoomed.get(oldKey);
  if (zoom) {
    zoomed.delete(oldKey);
    zoomed.set(newKey, zoom);
  }
  tabFocus.delete(oldKey);
  for (const leaf of leavesOf(tree)) paneTab.set(leaf, newKey);
  tabOrder = tabOrder.map((t) => (t === oldKey ? newKey : t));
  saveOrder();
  const group = groupState.assign[oldKey];
  if (group) {
    delete groupState.assign[oldKey];
    groupState.assign[newKey] = group;
    saveGroups();
  }
  if (tabWidths[oldKey] !== undefined) {
    tabWidths[newKey] = tabWidths[oldKey];
    delete tabWidths[oldKey];
    saveTabWidths();
  }
  // The surviving pane's own button becomes the tab's button.
  const btn = tabs.get(newKey)?.button;
  if (btn && !btn.isConnected) {
    const old = tabs.get(oldKey)?.button;
    if (old?.isConnected) old.replaceWith(btn);
    else tabbar.appendChild(btn);
    applyTabWidth(btn, newKey);
  }
}

function setActive(id: number) {
  const tab = tabs.get(id);
  if (!tab) return;
  const key = paneTab.get(id) ?? id;
  // The arrange overlay belongs to one tab's panes; leaving that tab
  // leaves the mode.
  if (arrangeKey !== undefined && arrangeKey !== key) closeArrange();
  closeSettings();
  // Activating a tab restores whichever pane had focus there; activating
  // a specific pane (from the sidebar, say) focuses that one.
  const focused = id === key ? focusedOf(key) : id;
  activeId = focused;
  tabFocus.set(key, focused);
  for (const [k, root] of tabRoots) root.classList.toggle("active", k === key);
  for (const [tid, t] of tabs) t.button.classList.toggle("active", tid === key);
  fitPanes(key);
  markFocus(key);
  const focusedTerm = tabs.get(focused)?.term;
  focusedTerm?.focus();
  refreshChrome();
  // Re-assert focus after the chrome rebuild settles so a click in the
  // sidebar (or anywhere in the bar) always ends with the terminal ready
  // to type into.
  requestAnimationFrame(() => {
    if (activeId === focused && !renameActive) focusedTerm?.focus();
  });
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
    // Arrange mode blurs the terminal, but a click back into one can
    // return focus — Escape must still leave the mode rather than reach
    // the shell.
    if (arrangeKey !== undefined && e.key === "Escape") {
      closeArrange();
      return false;
    }
    if (e.key === "F11") {
      void toggleZen();
      return false;
    }
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
      if (key === "S") {
        toggleStatusBar();
        return false;
      }
      if (key === "D") {
        void splitPane("row"); // side by side
        return false;
      }
      if (key === "E") {
        void splitPane("col"); // one above the other
        return false;
      }
      if (key === "M") {
        toggleZoom();
        return false;
      }
      if (key === "A") {
        toggleArrange();
        return false;
      }
      if (key === "Z") {
        restoreLast();
        return false;
      }
      if (key === "C") {
        const tab = tabs.get(getId());
        const sel = tab?.term.getSelection();
        if (sel) {
          pushClip(sel);
          navigator.clipboard.writeText(sel).catch(() => {});
        }
        return false;
      }
      if (key === "V") {
        navigator.clipboard
          .readText()
          .then((text) => {
            if (!text) return;
            pushClip(text);
            return invoke("write_session", { id: getId(), data: text });
          })
          .catch(() => {});
        return false;
      }
    }
    if (e.ctrlKey && !e.altKey && e.key === "Tab") {
      cycleTab(e.shiftKey ? -1 : 1);
      return false;
    }
    // Pane navigation. All of it is only swallowed while the tab is
    // actually split, so an unsplit terminal still receives these keys.
    const key = activeTabKey();
    const split = key !== undefined && isSplit(key);
    const arrow =
      e.key === "ArrowLeft" ? "left"
      : e.key === "ArrowRight" ? "right"
      : e.key === "ArrowUp" ? "up"
      : e.key === "ArrowDown" ? "down"
      : undefined;
    if (split && arrow && e.altKey && e.ctrlKey && e.shiftKey) {
      movePaneDir(arrow);
      return false;
    }
    if (split && arrow && e.altKey && !e.ctrlKey && !e.shiftKey) {
      focusNeighbour(arrow);
      return false;
    }
    // Alt+<n> jumps to a numbered pane, matching the overlay Alt shows.
    if (split && e.altKey && !e.ctrlKey && !e.shiftKey && /^[1-9]$/.test(e.key)) {
      if (focusPaneByNumber(Number(e.key))) {
        showPaneNumbers(false);
        return false;
      }
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
  const key = activeTabKey();
  if (ids.length < 2 || key === undefined) return;
  const i = ids.indexOf(key);
  setActive(ids[(i + dir + ids.length) % ids.length]);
}

// Clipboard history for the paste picker: recent texts seen on the
// clipboard (in-app copies plus whatever's current when the terminal
// menu opens). Newest first, deduped, capped.
const CLIP_MAX = 3;
const clipHist: string[] = JSON.parse(localStorage.getItem("gterm-cliphist") ?? "[]");
function saveClipHist() {
  localStorage.setItem("gterm-cliphist", JSON.stringify(clipHist));
}
function pushClip(text: string) {
  if (!text) return;
  const i = clipHist.indexOf(text);
  if (i === 0) return;
  if (i > 0) clipHist.splice(i, 1);
  clipHist.unshift(text);
  if (clipHist.length > CLIP_MAX) clipHist.length = CLIP_MAX;
  saveClipHist();
}
function clipPreview(text: string): string {
  const t = text.replace(/\r?\n/g, " ⏎ ").replace(/\t/g, " ").trim();
  return t.length > 46 ? t.slice(0, 45) + "…" : t;
}

/// Full clipboard-history viewer (from the terminal context menu):
/// multi-line previews with paste / copy / remove per entry.
function closeClipViewer() {
  document.getElementById("clip-overlay")?.remove();
}
function openClipViewer(id: number, term: Terminal) {
  closeClipViewer();
  const ov = document.createElement("div");
  ov.className = "clip-overlay";
  ov.id = "clip-overlay";
  const panel = document.createElement("div");
  panel.className = "clip-panel";
  const head = document.createElement("div");
  head.className = "clip-h";
  const title = document.createElement("span");
  title.textContent = "Clipboard history";
  const x = document.createElement("button");
  x.className = "clip-x";
  x.textContent = "×";
  x.addEventListener("click", closeClipViewer);
  head.append(title, x);
  panel.appendChild(head);
  if (!clipHist.length) {
    const empty = document.createElement("div");
    empty.className = "clip-empty";
    empty.textContent = "Nothing here yet — copy something first.";
    panel.appendChild(empty);
  }
  for (const text of [...clipHist]) {
    const row = document.createElement("div");
    row.className = "clip-row";
    const pre = document.createElement("pre");
    pre.className = "clip-text";
    pre.textContent = text.length > 2000 ? text.slice(0, 2000) + "…" : text;
    const acts = document.createElement("div");
    acts.className = "clip-acts";
    const mkBtn = (label: string, fn: () => void) => {
      const b = document.createElement("button");
      b.className = "clip-btn";
      b.textContent = label;
      b.addEventListener("click", fn);
      return b;
    };
    acts.append(
      mkBtn("Paste", () => {
        invoke("write_session", { id, data: text }).catch(() => {});
        closeClipViewer();
        term.focus();
      }),
      mkBtn("Copy", () => {
        pushClip(text);
        navigator.clipboard.writeText(text).catch(() => {});
      }),
      mkBtn("✕", () => {
        const i = clipHist.indexOf(text);
        if (i >= 0) clipHist.splice(i, 1);
        saveClipHist();
        openClipViewer(id, term); // rebuild
      })
    );
    row.append(pre, acts);
    panel.appendChild(row);
  }
  ov.appendChild(panel);
  ov.addEventListener("mousedown", (e) => {
    if (e.target === ov) closeClipViewer();
  });
  document.body.appendChild(ov);
}

/// Open a session and give it a pane. Without `splitFrom` that pane
/// becomes a new tab; with it the caller is splitting an existing tab and
/// places the pane in that tab's tree instead. Returns the session id.
async function createTab(
  attachId?: number,
  shell?: string,
  cwd?: string,
  title?: string,
  splitFrom?: number
): Promise<number | undefined> {
  const pane = document.createElement("div");
  pane.className = "pane";
  // The first fit() decides the session's initial cols/rows, and a
  // detached element measures as nothing — so the pane needs a home with
  // real dimensions before that. A split joins its tab's existing (and
  // visible) root; a new tab gets a staged root, laid out but invisible,
  // which is revealed by setActive once the session is up.
  const hostKey = splitFrom === undefined ? undefined : paneTab.get(splitFrom);
  const host = hostKey === undefined ? undefined : tabRoots.get(hostKey);
  let freshRoot: HTMLElement | undefined;
  if (host) {
    host.appendChild(pane);
  } else {
    freshRoot = document.createElement("div");
    freshRoot.className = "tab-root staging";
    freshRoot.appendChild(pane);
    panes.appendChild(freshRoot);
  }

  const term = new Terminal({
    fontFamily: effFont(),
    fontSize: effFontSize(),
    lineHeight: effLineHeight(),
    cursorStyle: effCursorStyle(),
    cursorBlink: effCursorBlink(),
    scrollback: 10000,
    theme: effXtermTheme(),
    allowTransparency: true,
    // Auto-corrects unreadable foregrounds at render time — including
    // 24-bit colors apps emit that assume a dark background.
    minimumContrastRatio: 4.5,
    allowProposedApi: true,
  });
  const fit = new FitAddon();
  term.loadAddon(fit);
  term.open(pane);
  // The WebGL renderer can't composite transparency over a decorative
  // background; those tabs use the DOM renderer instead.
  let webgl: WebglAddon | undefined;
  if (!bgActive()) {
    try {
      webgl = new WebglAddon();
      term.loadAddon(webgl);
    } catch {
      webgl = undefined; // WebGL unavailable; DOM renderer fallback.
    }
  }
  fit.fit();

  let id: number;
  try {
    if (attachId !== undefined) {
      id = attachId;
      await invoke("attach_session", { id, cols: term.cols, rows: term.rows });
    } else {
      id = await invoke<number>("create_session", {
        cols: term.cols,
        rows: term.rows,
        shell: shell ?? config.default_shell ?? null,
        cwd: cwd ?? null,
      });
    }
  } catch (err) {
    console.error(`Failed to ${attachId !== undefined ? "restore" : "start"} session:`, err);
    term.dispose();
    pane.remove();
    freshRoot?.remove(); // don't leave a staged root behind
    return;
  }

  // Template-given titles behave like a user rename: they stick and are
  // never overwritten by auto labels. Set before the tab label renders.
  if (title && !customTitles[id]) {
    customTitles[id] = title;
    saveCustomTitles();
  }

  if (hidden.delete(id)) {
    saveHidden();
  }

  const button = document.createElement("div");
  button.className = "tab";
  button.dataset.id = String(id);
  const shellB = mkShellBadge(shell ?? config.default_shell, id);
  const icon = document.createElement("span");
  icon.className = "tab-icon";
  const label = document.createElement("span");
  label.className = "tab-label";
  label.textContent = titleOf(id);
  const hide = document.createElement("button");
  hide.className = "tab-close";
  hide.textContent = "–";
  hide.title = "Hide tab — park it aside, still running (Ctrl+Shift+H)";
  const close = document.createElement("button");
  close.className = "tab-close";
  close.textContent = "×";
  close.title = "Close tab — restorable from Closing soon until its timer runs out (Ctrl+Shift+W ×2)";
  const resize = document.createElement("span");
  resize.className = "tab-resize";
  resize.title = "Drag to resize this tab — double-click to reset";
  button.append(shellB, icon, label, hide, close, resize);
  applyTabWidth(button, id);
  // A split pane still gets a button — it may inherit the tab later, via
  // retagTab — but only a tab owner's button lives in the strip.
  if (splitFrom === undefined) {
    tabbar.appendChild(button);
    tabOrder.push(id);
    saveOrder();
    const root = freshRoot ?? document.createElement("div");
    root.className = "tab-root";
    if (!root.isConnected) panes.appendChild(root);
    tabRoots.set(id, root);
    layouts.set(id, { kind: "leaf", id });
    paneTab.set(id, id);
    tabFocus.set(id, id);
  }

  const tab: Tab = { id, term, fit, pane, button, label, icon, shellB, webgl };
  tabs.set(id, tab);

  button.addEventListener("mousedown", (e) => {
    if (e.target !== close && e.target !== hide && e.target !== resize) setActive(id);
  });
  // Dragging the right-edge handle resizes just this tab; the handle
  // stops propagation so the reorder drag below never starts from it.
  resize.addEventListener("pointerdown", (e) => {
    if (e.button !== 0) return;
    e.stopPropagation();
    e.preventDefault();
    const startX = e.clientX;
    const startW = button.getBoundingClientRect().width;
    let resized = false;
    const onMove = (ev: PointerEvent) => {
      if (!resized && Math.abs(ev.clientX - startX) < 3) return;
      resized = true;
      tabWidths[id] = Math.min(TAB_W_MAX, Math.max(TAB_W_MIN, Math.round(startW + ev.clientX - startX)));
      applyTabWidth(button, id);
    };
    const onUp = () => {
      window.removeEventListener("pointermove", onMove);
      if (resized) saveTabWidths();
    };
    window.addEventListener("pointermove", onMove);
    window.addEventListener("pointerup", onUp, { once: true });
  });
  resize.addEventListener("dblclick", (e) => {
    e.stopPropagation();
    delete tabWidths[id];
    applyTabWidth(button, id);
    saveTabWidths();
  });
  button.addEventListener("dblclick", (e) => {
    if (e.target === label) renameTab(id);
  });
  // Drag to reorder within the tab strip; dropping onto a group chip
  // joins that group at its front, past a group's last member leaves it.
  // Dropping on the middle of another tab splits into it instead.
  button.addEventListener("pointerdown", (e) => {
    if (e.target === close || e.target === hide) return;
    beginPointerDrag(
      e,
      button,
      "x",
      ".tab, .group-chip",
      (target, before, ev) => {
        if (!target) {
          const bar = tabbar.getBoundingClientRect();
          const inBar =
            ev.clientX >= bar.left && ev.clientX <= bar.right &&
            ev.clientY >= bar.top && ev.clientY <= bar.bottom;
          if (inBar) moveTab(id, undefined, false);
          return;
        }
        if (target.classList.contains("group-chip")) {
          const gid = target.dataset.gid!;
          const first = tabOrder.find((m) => groupState.assign[m] === gid);
          moveTab(id, first, true, gid);
          return;
        }
        const refId = Number(target.dataset.id);
        if (!tabs.has(refId) || refId === id) return;
        const gid = groupState.assign[refId];
        let joinGroup: string | undefined = gid;
        if (gid) {
          const members = tabOrder.filter((m) => groupState.assign[m] === gid);
          if (!before && members[members.length - 1] === refId) joinGroup = undefined;
        }
        moveTab(id, refId, before, joinGroup);
      },
      (target) => {
        const refId = Number(target.dataset.id);
        if (tabs.has(refId) && refId !== id) mergeTabInto(id, refId);
      }
    );
  });
  button.addEventListener("contextmenu", (e) => {
    e.preventDefault();
    e.stopPropagation();
    showTabContextMenu(e.clientX, e.clientY, id);
  });
  hide.addEventListener("click", () => hideTab(id));
  requireConfirm(close, () => closeTab(id));

  // Right-click in the terminal opens a copy/paste menu. (The WebView2
  // default context menu is suppressed globally.)
  const paste = () =>
    navigator.clipboard
      .readText()
      .then((text) => text && invoke("write_session", { id, data: text }))
      .catch(() => {});
  pane.addEventListener("contextmenu", (e) => {
    e.preventDefault();
    const x = e.clientX;
    const y = e.clientY;
    void (async () => {
      const sel = term.getSelection();
      // Never let the clipboard hold the menu hostage. readText() can hang
      // forever in WebView2 when another process has the clipboard locked —
      // and everything below is what builds the menu, so a stalled promise
      // means right-click silently does nothing. Race it; a missing paste
      // preview is a far smaller loss than no menu.
      const current = await Promise.race([
        navigator.clipboard.readText().catch(() => ""),
        new Promise<string>((r) => window.setTimeout(() => r(""), 150)),
      ]);
      if (current) pushClip(current);
      const items: CtxItem[] = [];
      if (sel) {
        items.push({
          label: "Copy",
          action: () => {
            pushClip(sel);
            navigator.clipboard.writeText(sel).catch(() => {});
            term.clearSelection();
            term.focus();
          },
        });
      }
      // Focus returns to the terminal after every menu action so typing
      // (especially right after a paste) lands where it belongs.
      const writePaste = (text: string) => {
        pushClip(text);
        invoke("write_session", { id, data: text }).catch(() => {});
        term.focus();
      };
      if (current) {
        items.push({ label: `Paste: ${clipPreview(current)}`, action: () => writePaste(current) });
      } else {
        items.push({
          label: "Paste",
          action: () => {
            void paste();
            term.focus();
          },
        });
      }
      // Older clipboard entries: pick anything recently copied.
      const rest = clipHist.filter((t) => t !== current).slice(0, 3);
      if (rest.length) {
        items.push("sep");
        for (const t of rest) {
          items.push({ label: `Paste: ${clipPreview(t)}`, action: () => writePaste(t) });
        }
      }
      items.push("sep", { label: "Clipboard history…", action: () => openClipViewer(id, term) });
      items.push({
        label: "Select all",
        action: () => {
          term.selectAll();
          term.focus();
        },
      });
      const paneKey = paneTab.get(id);
      if (paneKey !== undefined && isSplit(paneKey)) {
        // Arranging is a mode now, not eight menu rows: the presets and
        // every move live in there, with targets the size of a pane.
        items.push("sep");
        items.push({ label: "Arrange panes… (Ctrl+Shift+A)", action: () => openArrange() });
        items.push({ label: "Zoom pane (Ctrl+Shift+M)", action: () => toggleZoom() });
        items.push({ label: "Move pane to its own tab", action: () => promotePane(id) });
        items.push("sep");
        items.push({
          label: "Close pane",
          action: () => closeTab(id),
          color: "var(--danger)",
        });
      }
      showContextMenu(x, y, items);
    })();
  });

  term.onData((data) => {
    invoke("write_session", { id, data }).catch(() => {});
  });
  term.onTitleChange((title) => {
    if (title.trim()) {
      saveTitle(id, title);
      const next = titleOf(id);
      if (label.textContent !== next) {
        label.textContent = next;
        refreshChrome();
      }
    }
  });
  term.attachCustomKeyEventHandler(makeShortcutHandler(() => id));

  // Every pane of the visible tab needs refitting, not just the focused
  // one — a split resizes its neighbours too.
  const observer = new ResizeObserver(() => {
    if (paneTab.get(id) === activeTabKey()) fitTab(tab);
  });
  observer.observe(pane);

  // Click anywhere in a pane to focus it.
  pane.addEventListener("pointerdown", () => {
    if (activeId !== id) focusPane(id);
  });

  // Grip and close, shown on hover and only once a tab holds more than
  // one pane. The grip is the drag source: dragging inside the terminal
  // itself already means "select text".
  pane.dataset.session = String(id);
  const tools = document.createElement("div");
  tools.className = "pane-tools";
  const grip = document.createElement("button");
  grip.className = "pane-grip";
  grip.textContent = "⠿";
  grip.title = "Drag to move this pane — drop on the tab bar for its own tab";
  grip.addEventListener("pointerdown", (ev) => beginPaneDrag(ev, id));
  // Leaves the split rather than closing: nothing in this app destroys a
  // session by accident, and popping back out is the undo for having
  // dragged a tab in. Closing is still Ctrl+Shift+W or the menu.
  const paneOut = document.createElement("button");
  paneOut.className = "pane-out";
  paneOut.textContent = "⧉";
  paneOut.title = "Take this pane out of the split, back to its own tab";
  paneOut.addEventListener("click", () => promotePane(id));
  tools.append(grip, paneOut);
  pane.appendChild(tools);

  const backlog = pending.get(id);
  if (backlog) {
    pending.delete(id);
    for (const chunk of backlog) term.write(chunk);
  }

  if (splitFrom === undefined) {
    renderLayout(id);
    setActive(id);
  }
  return id;
}

/// Remove one pane. When it is the last pane of its tab the tab goes with
/// it; otherwise the split collapses and a neighbour takes focus.
function removeTab(id: number, closeWindowIfLast = true) {
  const tab = tabs.get(id);
  if (!tab) return;
  const key = paneTab.get(id) ?? id;
  const remaining = dropLeaf(treeOf(key), id);
  tabs.delete(id);
  paneTab.delete(id);
  tab.term.dispose();
  tab.pane.remove();

  if (remaining) {
    // The tab lives on. If the pane that closed was carrying the tab's
    // identity, hand it to a survivor.
    layouts.set(key, remaining);
    zoomed.delete(key);
    const survivors = leavesOf(remaining);
    if (id === key) {
      tab.button.remove();
      retagTab(key, survivors[0]);
    }
    const newKey = id === key ? survivors[0] : key;
    if (tabFocus.get(newKey) === id || activeId === id) {
      tabFocus.set(newKey, survivors[0]);
    }
    renderLayout(newKey);
    fitPanes(newKey);
    if (activeId === id) setActive(focusedOf(newKey));
    saveLayouts();
    refreshChrome();
    return;
  }

  // Last pane: the tab goes away.
  const ids = orderedIds();
  const i = ids.indexOf(key);
  tab.button.remove();
  layouts.delete(key);
  tabFocus.delete(key);
  zoomed.delete(key);
  tabRoots.get(key)?.remove();
  tabRoots.delete(key);
  tabOrder = tabOrder.filter((t) => t !== key);
  saveOrder();
  saveLayouts();
  if (tabCount() === 0) {
    if (closeWindowIfLast) getCurrentWindow().close();
    refreshChrome();
    return;
  }
  if (activeId === id) {
    const rest = orderedIds();
    setActive(rest[Math.min(i, rest.length - 1)]);
  }
  refreshChrome();
}

// Closing a tab starts its grace window: the session lands in "Closing
// soon" with a countdown, restorable (from the sidebar, ⟳ menu, or
// Ctrl+Shift+Z) until the timer runs out — then it actually dies.
function closeTab(id: number) {
  invoke("kill_session", { id }).catch(() => {});
  removeTab(id);
  window.setTimeout(() => refreshChrome(), 500);
}

// Hiding also detaches, but parks the session visibly for one-click restore.
async function hideTab(id: number) {
  if (!tabs.has(id)) return;
  invoke("detach_session", { id }).catch(() => {});
  hidden.add(id);
  saveHidden();
  removeTab(id, false);
  if (tabCount() === 0) await createTab();
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
  // Kill means NOW: the daemon's first kill on a live session is soft
  // (grace window) — that's what tab-close uses. This button is armed
  // with a two-step confirm, so send the second kill too and skip the
  // "Closing soon" stop entirely.
  await invoke("kill_session", { id }).catch(() => {});
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

function settingsOpen(): boolean {
  return app.classList.contains("settings-on");
}

const settingsSearch = document.getElementById("settings-search") as HTMLInputElement;

// Live filter: a row stays visible when the query matches its title,
// description, or section heading; headings hide when every row under
// them is hidden. The About block only matches on its own text.
function filterSettings() {
  const q = settingsSearch.value.trim().toLowerCase();
  const kids = Array.from(settingsList.children) as HTMLElement[];
  let section = "";
  let sectionEl: HTMLElement | null = null;
  let sectionHasHit = false;
  const closeSection = () => {
    if (sectionEl) sectionEl.hidden = !sectionHasHit;
  };
  for (const el of kids) {
    if (el.classList.contains("settings-section-title")) {
      closeSection();
      section = (el.textContent ?? "").toLowerCase();
      sectionEl = el;
      sectionHasHit = false;
      continue;
    }
    const text = ((el.textContent ?? "") + " " + section).toLowerCase();
    const hit = !q || text.includes(q);
    el.hidden = !hit;
    if (hit) sectionHasHit = true;
  }
  closeSection();
}

settingsSearch.addEventListener("input", filterSettings);
settingsSearch.addEventListener("keydown", (e) => {
  // Esc clears the query first; only an empty box lets the global
  // handler close the settings page.
  if (e.key === "Escape" && settingsSearch.value) {
    e.stopPropagation();
    settingsSearch.value = "";
    filterSettings();
  }
});

function openSettings() {
  buildSettingsPage();
  app.classList.add("settings-on");
  settingsSearch.focus();
  settingsSearch.select();
}

function closeSettings() {
  if (!settingsOpen()) return;
  app.classList.remove("settings-on");
  const tab = activeId !== null ? tabs.get(activeId) : undefined;
  if (tab) {
    fitTab(tab);
    tab.term.focus();
  }
}

// ── history page: durable transcripts of past sessions ─────────────────

interface HistoryEntry {
  stem: string;
  id: number;
  created_ms: number;
  ended_ms: number | null;
  cwd: string;
  shell: string;
  bytes: number;
}

// Same escape-mode cleanup the daemon uses for resurrection replays: a
// transcript can contain a TUI's mouse/altscreen mode enables.
const VIEWER_MODE_RESET =
  "\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1005l\x1b[?1006l\x1b[?2004l\x1b[?1l\x1b[?1049l\x1b[?47l\x1b[?1004l\x1b[?9001l\x1b[?25h\x1b[0m\r\n";

function stripAnsiText(s: string): string {
  return s
    .replace(/\u001b\][^\u0007\u001b]*(\u0007|\u001b\\)/g, "")
    .replace(/\u001b\[[0-9;?]*[A-Za-z]/g, "")
    .replace(/\u001b[=>]/g, "");
}

function fmtStamp(ms: number): string {
  return new Date(ms).toLocaleString([], {
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
  });
}

function fmtSize(b: number): string {
  return b >= 1048576 ? `${(b / 1048576).toFixed(1)} MB` : `${Math.max(1, Math.round(b / 1024))} KB`;
}

function historyOpen(): boolean {
  return app.classList.contains("history-on");
}

function openHistory() {
  app.classList.remove("settings-on");
  app.classList.add("history-on");
  void buildHistoryPage();
}

function closeHistory() {
  if (!historyOpen()) return;
  app.classList.remove("history-on");
  const tab = activeId !== null ? tabs.get(activeId) : undefined;
  if (tab) {
    fitTab(tab);
    tab.term.focus();
  }
}

async function buildHistoryPage(filter?: string) {
  const list = document.getElementById("history-list")!;
  list.innerHTML = "";
  let entries: HistoryEntry[] = [];
  try {
    entries = await invoke<HistoryEntry[]>("history_list");
  } catch (err) {
    console.error("history_list failed:", err);
  }
  const needle = filter?.trim().toLowerCase();
  const shown: HistoryEntry[] = [];
  for (const en of entries) {
    if (needle) {
      let match = `${en.cwd} ${en.shell}`.toLowerCase().includes(needle);
      if (!match) {
        try {
          const text = stripAnsiText(await invoke<string>("history_read", { stem: en.stem }));
          match = text.toLowerCase().includes(needle);
        } catch {
          match = false;
        }
      }
      if (!match) continue;
    }
    shown.push(en);
  }
  if (!shown.length) {
    const empty = document.createElement("div");
    empty.className = "hist-empty";
    empty.textContent = needle
      ? "No transcripts match that search."
      : (config.history_days ?? 14) === 0
        ? "History recording is disabled (Settings → Sessions → Keep history)."
        : "No transcripts yet — history builds up as sessions run.";
    list.appendChild(empty);
    return;
  }
  for (const en of shown) {
    const row = document.createElement("div");
    row.className = "hist-row";
    const when = document.createElement("span");
    when.className = "hist-when";
    when.textContent = en.ended_ms
      ? `${fmtStamp(en.created_ms)} → ${fmtStamp(en.ended_ms)}`
      : fmtStamp(en.created_ms);
    const cwd = document.createElement("span");
    cwd.className = "hist-cwd";
    cwd.textContent = en.cwd;
    cwd.title = en.cwd;
    const shell = document.createElement("span");
    shell.className = "hist-shell";
    shell.textContent = en.shell;
    const size = document.createElement("span");
    size.className = "hist-size";
    size.textContent = fmtSize(en.bytes);
    row.append(when, cwd, shell, size);
    if (!en.ended_ms) {
      const live = document.createElement("span");
      live.className = "hist-live";
      live.textContent = "● live";
      row.appendChild(live);
    }
    row.addEventListener("click", () => void openTranscript(en));
    list.appendChild(row);
  }
}

let viewerTerm: Terminal | null = null;
let viewerFit: FitAddon | null = null;

async function openTranscript(en: HistoryEntry) {
  let data: string;
  try {
    data = await invoke<string>("history_read", { stem: en.stem });
  } catch (err) {
    console.error("history_read failed:", err);
    return;
  }
  const viewer = document.getElementById("history-viewer")!;
  document.getElementById("history-viewer-title")!.textContent =
    `${fmtStamp(en.created_ms)} · ${en.shell} · ${en.cwd}`;
  viewer.classList.add("open");
  closeTranscriptTerm();
  const term = new Terminal({
    fontFamily: effFont(),
    fontSize: effFontSize(),
    lineHeight: effLineHeight(),
    scrollback: 200000,
    theme: effXtermTheme(),
    allowTransparency: true,
    minimumContrastRatio: 4.5,
    disableStdin: true,
    allowProposedApi: true,
  });
  viewerTerm = term;
  viewerFit = new FitAddon();
  term.loadAddon(viewerFit);
  term.open(document.getElementById("history-term")!);
  viewerFit.fit();
  term.write(data + VIEWER_MODE_RESET);
}

function closeTranscriptTerm() {
  viewerTerm?.dispose();
  viewerTerm = null;
  viewerFit = null;
  document.getElementById("history-term")!.innerHTML = "";
}

function closeViewer() {
  document.getElementById("history-viewer")!.classList.remove("open");
  closeTranscriptTerm();
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
  placeFloating(ctxMenu, x, y);
}

/// Position a floating element at a point, kept wholly inside the window.
/// Flips above the point when there is more room there, and clamps on
/// both axes so nothing can end up off-screen and unreachable.
function placeFloating(el: HTMLElement, x: number, y: number) {
  const margin = 8;
  const w = el.offsetWidth;
  const h = el.offsetHeight;
  const roomBelow = window.innerHeight - y;
  const top =
    h + margin > roomBelow && y > roomBelow
      ? Math.max(margin, y - h) // flip above the anchor point
      : Math.min(y, window.innerHeight - h - margin);
  el.style.left = `${Math.max(margin, Math.min(x, window.innerWidth - w - margin))}px`;
  el.style.top = `${Math.max(margin, top)}px`;
}

/// Rename wherever the tab is actually visible: the sidebar row when the
/// sidebar is on (the tab bar is display:none there — editing its hidden
/// label looks like nothing happened), the tab button otherwise.
function renameTabAnywhere(id: number) {
  if (app.classList.contains("sidebar-on")) {
    const el = sidebarList.querySelector<HTMLElement>(
      `.side-row[data-id="${id}"] .side-label`
    );
    if (el) {
      renameSession(id, el);
      return;
    }
  }
  renameTab(id);
}

function showTabContextMenu(x: number, y: number, id: number) {
  const current = groupState.assign[id];
  const items: CtxItem[] = [{ label: "Rename tab", action: () => renameTabAnywhere(id) }];
  items.push({ label: "Suggest title…", action: () => suggestTitles(id) });
  items.push({ label: "Set badge…", action: () => openBadgePicker(id) });
  if (customBadges[id]) {
    items.push({ label: "Reset badge to shell", action: () => clearBadge(id) });
  }
  items.push("sep");
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
    { label: "Close tab", action: () => closeTab(id), confirm: true },
    { label: "Kill session", action: () => killAndClose(id), confirm: true }
  );
  showContextMenu(x, y, items);
}

async function killAndClose(id: number) {
  removeTab(id, false);
  await killSession(id);
  if (tabCount() === 0) await createTab();
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

/// Rename any session (open or not) by editing a label element in place.
function renameSession(id: number, el: HTMLElement) {
  inlineRename(el, baseLabel(id).text, (v) => {
    if (v) customTitles[id] = v;
    saveCustomTitles();
    sidebarSig = "";
    const tab = tabs.get(id);
    if (tab) tab.label.textContent = titleOf(id);
    refreshChrome();
  });
}

function renameTab(id: number) {
  const tab = tabs.get(id);
  if (!tab) return;
  // Edit the base name, not the "(2)" disambiguation suffix.
  inlineRename(tab.label, baseLabel(id).text, (v) => {
    if (v) {
      customTitles[id] = v;
      delete aiTitles[id]; // user rename supersedes any AI suggestion
      saveAiTitles();
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
  chip.dataset.gid = g.id;
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
    showContextMenu(e.clientX, e.clientY, groupMenuItems(g, name));
  });
  return chip;
}

/// Shared group actions (tab-bar chip and sidebar header). "Ungroup"
/// deletes the group; its tabs stay open, just ungrouped.
function groupMenuItems(g: TabGroup, nameEl: HTMLElement): CtxItem[] {
  return [
    {
      label: "Rename group",
      action: () =>
        inlineRename(nameEl, g.name, (v) => {
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
      label: "Ungroup (delete group)",
      action: () => {
        for (const k of Object.keys(groupState.assign)) {
          if (groupState.assign[k] === g.id) delete groupState.assign[k];
        }
        pruneGroups();
        saveGroups();
        refreshChrome();
      },
    },
  ];
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

// ── title suggestions: local heuristics + optional AI ───────────────────

/// Last ~N meaningful lines of a terminal's buffer, as plain text.
function terminalTail(term: Terminal, maxLines = 30): string {
  const buf = term.buffer.active;
  const end = buf.baseY + buf.cursorY;
  const lines: string[] = [];
  for (let i = Math.max(0, end - 80); i <= end; i++) {
    const line = buf.getLine(i)?.translateToString(true).trimEnd();
    if (line) lines.push(line.slice(0, 200));
  }
  return lines.slice(-maxLines).join("\n");
}

function aiEnabled(): boolean {
  return !!config.ai_base_url?.trim();
}

/// Title candidates computed locally from what's on the terminal:
/// running program, last command typed, directory, shell title.
function heuristicTitles(id: number): string[] {
  const out: string[] = [];
  const push = (t: string | undefined | null) => {
    const v = t?.trim().slice(0, 40);
    if (v && !out.some((o) => o.toLowerCase() === v.toLowerCase())) out.push(v);
  };
  const info = lastInfo.get(id);
  const parts = cwdParts(id);
  const tail = parts[parts.length - 1];
  const prog = (info?.running ?? []).find((n) => !SHELLS.test(n));

  if (prog && tail) push(`${prog} · ${tail}`);
  push(prog);

  // Last command typed at a prompt (PowerShell "PS ...>" or cmd "C:\...>").
  const tab = tabs.get(id);
  if (tab) {
    const lines = terminalTail(tab.term, 30).split("\n");
    for (let i = lines.length - 1; i >= 0; i--) {
      const m = lines[i].match(/^(?:PS\s+)?[A-Za-z]:[^>]*>\s*(\S.*)$/);
      if (m && m[1] && !/^(exit|cls|clear)\b/i.test(m[1])) {
        push(m[1].split(/\s+/).slice(0, 3).join(" "));
        break;
      }
    }
  }

  push(tail);
  if (parts.length >= 2) push(`${parts[parts.length - 2]}/${tail}`);
  const t = titles[id];
  if (t && !BORING_TITLE.test(t)) push(t);
  return out.slice(0, 5);
}

const aiTitleInFlight = new Set<number>();
const aiTitleLastRun = new Map<number, { at: number; tail: string }>();

/// Fetch candidate titles from the configured endpoint (Anthropic- or
/// OpenAI-compatible). Blank endpoint = AI disabled, never called.
async function fetchAiCandidates(id: number): Promise<string[]> {
  const tab = tabs.get(id);
  const base = config.ai_base_url?.trim().replace(/\/+$/, "");
  if (!tab || !base) return [];
  const key = config.ai_api_key?.trim() ?? "";
  const model = config.ai_model?.trim() || "claude-opus-5";
  const info = lastInfo.get(id);
  const context = [
    `Working directory: ${info?.cwd ?? "unknown"}`,
    `Running programs: ${(info?.running ?? []).join(", ") || "just the shell"}`,
    "Recent terminal output:",
    terminalTail(tab.term) || "(no output yet)",
  ].join("\n");
  const system =
    "You name terminal tabs. Reply with exactly 5 candidate titles, one per line. Each is 2-4 words describing what this terminal session is being used for. No numbering, no quotes, no other text.";

  let raw = "";
  if (config.ai_flavor === "openai") {
    const url = /\/v\d+$/.test(base) ? `${base}/chat/completions` : `${base}/v1/chat/completions`;
    const res = await fetch(url, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        ...(key ? { authorization: `Bearer ${key}` } : {}),
      },
      body: JSON.stringify({
        model,
        max_tokens: 2000,
        messages: [
          { role: "system", content: system },
          { role: "user", content: context },
        ],
      }),
    });
    if (!res.ok) throw new Error(`${res.status}: ${await res.text()}`);
    const data = await res.json();
    raw = data.choices?.[0]?.message?.content ?? "";
  } else {
    const client = new Anthropic({
      apiKey: key || "none",
      baseURL: base,
      dangerouslyAllowBrowser: true,
    });
    const response = await client.messages.create({
      model,
      max_tokens: 2000,
      system,
      messages: [{ role: "user", content: context }],
    });
    if (response.stop_reason === "refusal") return [];
    const text = response.content.find(
      (b): b is Anthropic.TextBlock => b.type === "text"
    );
    raw = text?.text ?? "";
  }
  return raw
    .split("\n")
    .map((l) => l.trim().replace(/^[-*\d.)\s]+/, "").replace(/^["']|["']$/g, "").trim())
    .filter(Boolean)
    .slice(0, 5)
    .map((t) => t.slice(0, 40));
}

function applyPickedTitle(id: number, title: string) {
  // Picking a suggestion is an explicit user choice, so it lands in
  // customTitles like a rename — otherwise an earlier manual rename
  // (customTitles outranks aiTitles) would silently swallow the pick.
  customTitles[id] = title;
  saveCustomTitles();
  delete aiTitles[id];
  saveAiTitles();
  const tab = tabs.get(id);
  if (tab) tab.label.textContent = titleOf(id);
  sidebarSig = "";
  refreshChrome();
}

function anchorForTab(id: number): { x: number; y: number } {
  const btn = tabs.get(id)?.button;
  if (btn && btn.offsetParent) {
    const r = btn.getBoundingClientRect();
    return { x: r.left, y: r.bottom + 4 };
  }
  const row = sidebarList.querySelector(`.side-row[data-id="${id}"]`);
  if (row) {
    const r = row.getBoundingClientRect();
    return { x: r.right + 4, y: r.top };
  }
  return { x: 120, y: 60 };
}

/// The picker: local heuristic candidates immediately, plus an "Ask AI"
/// entry when an endpoint is configured.
function suggestTitles(id: number) {
  const { x, y } = anchorForTab(id);
  const items: CtxItem[] = heuristicTitles(id).map((t) => ({
    label: t,
    action: () => applyPickedTitle(id, t),
  }));
  if (aiEnabled()) {
    if (items.length) items.push("sep");
    items.push({
      label: "✨ Ask AI for titles…",
      action: async () => {
        if (aiTitleInFlight.has(id)) return;
        aiTitleInFlight.add(id);
        try {
          const candidates = await fetchAiCandidates(id);
          if (!candidates.length) return;
          const a = anchorForTab(id);
          showContextMenu(
            a.x,
            a.y,
            candidates.map((t) => ({ label: t, action: () => applyPickedTitle(id, t) }))
          );
        } catch (err) {
          console.error("AI titles failed:", err);
        } finally {
          aiTitleInFlight.delete(id);
        }
      },
    });
  }
  if (items.length) showContextMenu(x, y, items);
}

/// Auto mode: every tick, AI-title at most one open tab that has no
/// custom name and whose content changed since its last pass.
async function aiAutoTitleTick() {
  if (!config.ai_auto_titles || !aiEnabled()) return;
  const now = Date.now();
  for (const id of orderedIds()) {
    if (customTitles[id]) continue;
    const tab = tabs.get(id);
    if (!tab) continue;
    const tail = terminalTail(tab.term, 10);
    if (!tail) continue;
    const last = aiTitleLastRun.get(id);
    if (last && (now - last.at < 5 * 60_000 || last.tail === tail)) continue;
    aiTitleLastRun.set(id, { at: now, tail });
    if (aiTitleInFlight.has(id)) continue;
    aiTitleInFlight.add(id);
    try {
      const candidates = await fetchAiCandidates(id);
      if (candidates.length) applyPickedTitle(id, candidates[0]);
    } catch (err) {
      console.error("AI auto-title failed:", err);
    } finally {
      aiTitleInFlight.delete(id);
    }
    return; // one per tick keeps cost bounded
  }
}

/// Poll session state: update tab icons from what's running, and keep the
/// sidebar countdowns fresh.
async function updateLiveInfo() {
  const sessions = await invoke<SessionInfo[]>("list_sessions").catch(() => []);
  lastInfo.clear();
  for (const s of sessions) lastInfo.set(s.id, s);
  recomputeLabels();
  for (const s of sessions) {
    const tab = tabs.get(s.id);
    if (!tab) continue;
    // `?? []` tolerates an older daemon that predates the running field.
    const icon = iconFor(s.running ?? []);
    // Only mutate on change: rewriting things every poll invalidates
    // layout, resizes the pane, and makes the terminal caret stutter.
    if (tab.icon.textContent !== icon) tab.icon.textContent = icon;
    setShellBadge(tab.shellB, s.shell, s.id);
    const label = titleOf(s.id);
    if (tab.label.textContent !== label && !renameActive) {
      tab.label.textContent = label;
    }
  }
  renderSidebar(sessions);
}

let sidebarVersion = 0;
let sidebarSig = "";
async function renderSidebar(prefetched?: SessionInfo[]) {
  if (!app.classList.contains("sidebar-on")) return;
  if (renameActive) return; // don't destroy an in-progress rename input
  const version = ++sidebarVersion;
  const sessions =
    prefetched ?? (await invoke<SessionInfo[]>("list_sessions").catch(() => []));
  if (version !== sidebarVersion) return;
  // Re-check after the await: a rename may have started while fetching,
  // and rebuilding now would destroy its input mid-edit.
  if (renameActive) return;

  // Skip the DOM rebuild when nothing changed — the 5s poll would
  // otherwise churn the sidebar (and hitch the renderer) while typing.
  // Countdown labels are part of the signature so ticking still renders.
  const countdowns = sessions
    .filter((s) => s.expires_ms)
    .map((s) => remainingLabel(s.expires_ms!));
  const sig = JSON.stringify([activeId, orderedIds(), [...hidden], sessions, groupState, titles, customTitles, countdowns]);
  if (sig === sidebarSig) return;
  sidebarSig = sig;

  sidebarList.innerHTML = "";
  const addRow = (
    dot: string,
    dotClass: string,
    id: number,
    label: string,
    isActive: boolean,
    onClick: () => void,
    actions: Array<[string, string, () => void, boolean?]>
  ) => {
    const row = document.createElement("div");
    row.className = "side-row" + (isActive ? " active" : "");
    row.dataset.id = String(id);
    const d = document.createElement("span");
    d.className = `side-dot ${dotClass}`;
    d.textContent = dot;
    d.title = {
      open: "Open in a tab",
      hidden: "Hidden (parked) — click to restore",
      cold: "Detached, still running or restorable — click to restore",
      doomed: "Closing soon — click to restore before the timer runs out",
    }[dotClass] ?? "";
    const l = document.createElement("span");
    l.className = "side-label";
    l.textContent = label;
    if (tabs.has(id)) {
      // Double-click renames; safe here because row clicks just activate.
      l.addEventListener("dblclick", (e) => {
        e.stopPropagation();
        renameSession(id, l);
      });
      // Open tabs reorder by pointer drag (not HTML5 DnD — that fights
      // the row rebuilds and the frameless-window drag handling).
      row.addEventListener("pointerdown", (e) => {
        if ((e.target as HTMLElement).closest(".side-act")) return;
        beginPointerDrag(e, row, "y", ".side-row", (target, before) => {
          const tid = target ? Number(target.dataset.id) : NaN;
          if (!target || tid === id || !tabs.has(tid)) return;
          moveTab(id, tid, before, groupState.assign[tid]);
        });
      });
    }
    row.addEventListener("contextmenu", (e) => {
      e.preventDefault();
      e.stopPropagation();
      if (tabs.has(id)) {
        showTabContextMenu(e.clientX, e.clientY, id);
      } else {
        showContextMenu(e.clientX, e.clientY, [
          { label: "Rename", action: () => renameSession(id, l) },
          { label: "Restore", action: onClick },
          "sep",
          { label: "Kill session", action: () => killSession(id), confirm: true },
        ]);
      }
    });
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
    const info = sessions.find((s) => s.id === id);
    row.append(d, mkShellBadge(info?.shell, id), l, acts);
    row.addEventListener("click", () => {
      if (dragSuppressClick) {
        dragSuppressClick = false;
        return;
      }
      onClick();
    });
    sidebarList.appendChild(row);
  };

  const addHeader = (name: string, color?: string, g?: TabGroup) => {
    const h = document.createElement("div");
    h.className = "side-header";
    if (color) {
      const dot = document.createElement("span");
      dot.className = "menu-dot";
      dot.style.background = color;
      h.appendChild(dot);
    }
    const label = document.createElement("span");
    label.textContent = name;
    h.appendChild(label);
    if (g) {
      h.title = "Right-click for group actions (rename, color, ungroup)";
      h.addEventListener("contextmenu", (e) => {
        e.preventDefault();
        e.stopPropagation();
        showContextMenu(e.clientX, e.clientY, groupMenuItems(g, label));
      });
    }
    sidebarList.appendChild(h);
  };

  const openRow = (id: number) =>
    addRow("●", "open", id, titleOf(id), id === activeId, () => setActive(id), [
      ["–", "Hide (Ctrl+Shift+H)", () => hideTab(id)],
      ["×", "Close — click twice", () => closeTab(id), true],
    ]);
  const hiddenRow = (id: number) =>
    addRow("◌", "hidden", id, titleOf(id), false, () => restoreHidden(id), [
      ["×", "Kill session — click twice", () => killSession(id), true],
    ]);
  const coldRow = (s: SessionInfo) =>
    addRow(
      s.expires_ms ? "⌛" : "○",
      s.expires_ms ? "doomed" : "cold",
      s.id,
      `${titleOf(s.id)}${expirySuffix(s)}`,
      false,
      () => createTab(s.id),
      [["×", "Kill session — click twice", () => killSession(s.id), true]]
    );

  // Sessions in their grace window get their own section with a live
  // countdown; everything else renders under its group as usual.
  const closing = sessions.filter((s) => s.expires_ms && !tabs.has(s.id));
  const isClosing = (id: number) => closing.some((s) => s.id === id);

  const inGroup = (id: number, gid: string) => groupState.assign[id] === gid;
  for (const g of groupState.groups) {
    addHeader(g.name, g.color, g);
    for (const id of orderedIds()) if (inGroup(id, g.id)) openRow(id);
    for (const id of hidden) if (inGroup(id, g.id) && !isClosing(id)) hiddenRow(id);
    for (const s of sessions) {
      if (!tabs.has(s.id) && !hidden.has(s.id) && !isClosing(s.id) && inGroup(s.id, g.id)) coldRow(s);
    }
  }
  const ungrouped = (id: number) => !groupById(groupState.assign[id]);
  if (groupState.groups.length) addHeader("Ungrouped");
  for (const id of orderedIds()) if (ungrouped(id)) openRow(id);
  for (const id of hidden) if (ungrouped(id) && !isClosing(id)) hiddenRow(id);
  for (const s of sessions) {
    if (!tabs.has(s.id) && !hidden.has(s.id) && !isClosing(s.id) && ungrouped(s.id)) coldRow(s);
  }

  if (closing.length) {
    addHeader("Closing soon");
    for (const s of closing) {
      addRow(
        "⌛",
        "doomed",
        s.id,
        `${titleOf(s.id)} · ${remainingLabel(s.expires_ms!)}`,
        false,
        () => createTab(s.id),
        [["×", "Kill now — click twice", () => killSession(s.id), true]]
      );
    }
  }
}

function refreshChrome() {
  requestAnimationFrame(() => {
    if (renameActive) return; // rebuilt on commit instead
    recomputeLabels();
    layoutTabbar();
    updateTabOverflow();
    renderHiddenPills();
    renderSidebar();
  });
}

function toggleSidebar() {
  const on = app.classList.toggle("sidebar-on");
  localStorage.setItem("gterm-sidebar", on ? "1" : "0");
  sidebarSig = ""; // force a fresh render on re-open
  refreshChrome();
  const tab = activeId !== null ? tabs.get(activeId) : undefined;
  if (tab) fitTab(tab);
}

// Zen full-screen: chrome hidden, OS fullscreen, terminal fills
// everything. A small draggable pill overlay is the way back out.
let zenSonarTimer = 0;
async function toggleZen() {
  const on = app.classList.toggle("zen-on");
  // sonar ping for 10s so the exit pill announces itself, then settles
  const pill = document.getElementById("zen-pill")!;
  window.clearTimeout(zenSonarTimer);
  if (on) {
    pill.classList.add("sonar");
    zenSonarTimer = window.setTimeout(() => pill.classList.remove("sonar"), 10_000);
  } else {
    pill.classList.remove("sonar");
  }
  try {
    await getCurrentWindow().setFullscreen(on);
  } catch {}
  // refit after the window transition settles (fires twice: fast + safe)
  const refit = () => {
    const tab = activeId !== null ? tabs.get(activeId) : undefined;
    if (tab) {
      fitTab(tab);
      tab.term.focus();
    }
  };
  window.setTimeout(refit, 120);
  window.setTimeout(refit, 450);
}

function initZenPill() {
  const pill = document.getElementById("zen-pill")!;
  // restore saved position (clamped into the viewport)
  const saved = localStorage.getItem("gterm-zen-pos");
  if (saved) {
    try {
      const [px, py] = JSON.parse(saved) as [number, number];
      pill.style.left = `${Math.min(Math.max(px, 4), window.innerWidth - 40)}px`;
      pill.style.top = `${Math.min(Math.max(py, 4), window.innerHeight - 40)}px`;
      pill.style.right = "auto";
      pill.style.bottom = "auto";
    } catch {}
  }
  pill.addEventListener("pointerdown", (e) => {
    if (e.button !== 0) return;
    e.preventDefault();
    const startX = e.clientX;
    const startY = e.clientY;
    const rect = pill.getBoundingClientRect();
    let dragging = false;
    pill.setPointerCapture(e.pointerId);
    const onMove = (ev: PointerEvent) => {
      if (!dragging && Math.abs(ev.clientX - startX) < 5 && Math.abs(ev.clientY - startY) < 5) return;
      dragging = true;
      const nx = Math.min(Math.max(rect.left + (ev.clientX - startX), 4), window.innerWidth - 40);
      const ny = Math.min(Math.max(rect.top + (ev.clientY - startY), 4), window.innerHeight - 40);
      pill.style.left = `${nx}px`;
      pill.style.top = `${ny}px`;
      pill.style.right = "auto";
      pill.style.bottom = "auto";
    };
    const onUp = () => {
      pill.removeEventListener("pointermove", onMove);
      if (dragging) {
        const r = pill.getBoundingClientRect();
        localStorage.setItem("gterm-zen-pos", JSON.stringify([Math.round(r.left), Math.round(r.top)]));
      } else {
        void toggleZen(); // plain click exits
      }
    };
    pill.addEventListener("pointermove", onMove);
    pill.addEventListener("pointerup", onUp, { once: true });
  });
}

// Sidebar width: draggable via the edge handle, persisted, terminal
// refit live so the pane always fills the remaining space.
function initSidebarResize() {
  const saved = Number(localStorage.getItem("gterm-sidebar-w"));
  if (saved >= 150 && saved <= 520) {
    document.documentElement.style.setProperty("--sidebar-w", `${saved}px`);
  }
  const handle = document.getElementById("sidebar-resize")!;
  handle.addEventListener("pointerdown", (e) => {
    if (e.button !== 0) return;
    e.preventDefault();
    handle.classList.add("dragging");
    handle.setPointerCapture(e.pointerId);
    let raf = 0;
    const onMove = (ev: PointerEvent) => {
      const wpx = Math.min(520, Math.max(150, Math.round(ev.clientX)));
      document.documentElement.style.setProperty("--sidebar-w", `${wpx}px`);
      if (!raf) {
        raf = requestAnimationFrame(() => {
          raf = 0;
          const tab = activeId !== null ? tabs.get(activeId) : undefined;
          if (tab) fitTab(tab);
        });
      }
    };
    const onUp = (ev: PointerEvent) => {
      handle.removeEventListener("pointermove", onMove);
      handle.classList.remove("dragging");
      const wpx = Math.min(520, Math.max(150, Math.round(ev.clientX)));
      localStorage.setItem("gterm-sidebar-w", String(wpx));
      const tab = activeId !== null ? tabs.get(activeId) : undefined;
      if (tab) fitTab(tab);
    };
    handle.addEventListener("pointermove", onMove);
    handle.addEventListener("pointerup", onUp, { once: true });
  });
  handle.addEventListener("dblclick", toggleSidebar);
  document.getElementById("sidebar-collapse")!.addEventListener("click", toggleSidebar);
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

// Theme picker categories: keys not listed here (and custom themes)
// land in their own groups, so nothing can silently vanish.
const THEME_GROUPS: Array<[string, string[]]> = [
  ["Classics", ["one-dark", "dracula", "nord", "gruvbox", "tokyo-night", "catppuccin", "solarized-dark", "solarized-light", "monokai", "everforest", "zenburn"]],
  ["Dev & tooling", ["coral", "monochrome", "git", "circuit", "containers", "helm", "mainframe", "punchcard", "panic", "whiteboard", "eink", "duck"]],
  ["Retro hardware", ["amber-crt", "gameboy", "c64"]],
  ["Operating systems", ["dos", "penguin", "cupertino", "material", "macintosh", "chicago", "aero", "fluent"]],
  ["Film & TV", ["matrix", "bladerunner", "tron", "lcars", "dune", "umbrella", "nostromo", "wargames", "lumon", "swordfish", "hackers", "galactica"]],
  ["Games", ["cyberpunk", "deus-ex", "pipboy", "nier", "sheikah", "aperture", "persona", "valorant", "csgo", "dbd"]],
  ["Consoles", ["library", "blade", "cartridge", "polygon"]],
  ["Anime", ["akira", "bebop", "scouter", "nerv"]],
  ["Space", ["hyperspace", "space", "missionctl"]],
  ["Places & vibes", ["skicabin", "rave", "nightclub", "speakeasy", "datacenter", "backrooms"]],
  ["Art & liminal", ["hermes", "nous", "synthwave", "blueprint", "redacted", "sakura", "pride"]],
];

/// Grouped theme select: optgroups per category, then Custom, then any
/// keys the taxonomy missed.
function mkThemeSelect(value: string, onChange: (v: string) => void): HTMLSelectElement {
  const sel = document.createElement("select");
  sel.className = "set-control";
  const listed = new Set<string>();
  const addGroup = (label: string, keys: string[]) => {
    const valid = keys.filter((k) => THEMES[k]);
    if (!valid.length) return;
    const grp = document.createElement("optgroup");
    grp.label = label;
    for (const k of valid) {
      const o = document.createElement("option");
      o.value = k;
      o.textContent = THEMES[k].label;
      grp.appendChild(o);
      listed.add(k);
    }
    sel.appendChild(grp);
  };
  for (const [label, keys] of THEME_GROUPS) addGroup(label, keys);
  addGroup("Custom", Object.keys(THEMES).filter((k) => k.startsWith("custom-")));
  addGroup("Other", Object.keys(THEMES).filter((k) => !listed.has(k) && !k.startsWith("custom-")));
  sel.value = value;
  sel.addEventListener("change", () => onChange(sel.value));
  return sel;
}

function mkSelect(
  options: Array<[string, string]>,
  value: string,
  onChange: (v: string) => void
): HTMLSelectElement {
  const sel = document.createElement("select");
  sel.className = "set-control";
  for (const [v, label] of options) {
    const o = document.createElement("option");
    o.value = v;
    o.textContent = label;
    sel.appendChild(o);
  }
  sel.value = value;
  sel.addEventListener("change", () => onChange(sel.value));
  return sel;
}

function mkNumber(
  value: number,
  min: number,
  max: number,
  onChange: (v: number) => void
): HTMLInputElement {
  const input = document.createElement("input");
  input.className = "set-control";
  input.type = "number";
  input.min = String(min);
  input.max = String(max);
  input.value = String(value);
  input.addEventListener("change", () => {
    const v = Math.min(max, Math.max(min, Number(input.value) || min));
    input.value = String(v);
    onChange(v);
  });
  return input;
}

function settingsSection(title: string): HTMLElement {
  const h = document.createElement("div");
  h.className = "settings-section-title";
  h.textContent = title;
  settingsList.appendChild(h);
  return h;
}

function settingRow(title: string, desc: string, control: HTMLElement) {
  const row = document.createElement("div");
  row.className = "setting";
  const meta = document.createElement("div");
  meta.className = "setting-meta";
  const t = document.createElement("div");
  t.className = "setting-title";
  t.textContent = title;
  meta.appendChild(t);
  if (desc) {
    const d = document.createElement("div");
    d.className = "setting-desc";
    d.textContent = desc;
    meta.appendChild(d);
  }
  row.append(meta, control);
  settingsList.appendChild(row);
}

function buildSettingsPage() {
  // Conditional rows rebuild the page; keep the scroll position stable.
  const scroller = document.getElementById("settings-page")!;
  const scrollAt = scroller.scrollTop;
  settingsList.innerHTML = "";
  const changed = () => {
    applyAppearance();
    saveConfig();
  };
  // Native file/folder picker attached to a text input: picking fills
  // the input and fires its change handler; typing still works.
  const browseInto = async (
    input: HTMLInputElement,
    folder: boolean,
    filters?: { name: string; extensions: string[] }[]
  ) => {
    const picked = await openDialog({ directory: folder, multiple: false, filters }).catch(() => null);
    if (typeof picked === "string" && picked) {
      input.value = picked;
      input.dispatchEvent(new Event("change"));
    }
  };
  // Compact text input used by every multi-column row block below.
  const mkTplInput = (ph: string, value: string, onChange: (v: string) => void) => {
    const input = document.createElement("input");
    input.className = "set-control";
    input.type = "text";
    input.placeholder = ph;
    input.value = value;
    input.addEventListener("change", () => onChange(input.value.trim()));
    return input;
  };
  const withBrowse = (
    input: HTMLInputElement,
    folder: boolean,
    filters?: { name: string; extensions: string[] }[]
  ) => {
    const wrap = document.createElement("div");
    wrap.className = "path-wrap";
    const btn = document.createElement("button");
    btn.className = "set-btn";
    btn.textContent = "Browse…";
    btn.addEventListener("click", () => void browseInto(input, folder, filters));
    wrap.append(input, btn);
    return wrap;
  };

  settingsSection("Appearance");
  const themeSel = mkThemeSelect(
    themeKey,
    (v) => {
      applyTheme(v);
      buildSettingsPage();
      // The rebuild replaced the select; put keyboard focus back on the
      // new one so arrow keys keep previewing themes.
      (settingsList.querySelector('select[data-role="theme"]') as HTMLSelectElement | null)?.focus();
    }
  );
  themeSel.dataset.role = "theme";
  settingRow(
    "Theme",
    "Colors, plus each theme's default font, spacing, and cursor personality. Focus the dropdown and use Up/Down to preview.",
    themeSel
  );

  // Custom themes: base + color/font overrides, editable in place.
  const ctInput = (ph: string, value: string, onChange: (v: string) => void) => {
    const input = document.createElement("input");
    input.className = "set-control";
    input.type = "text";
    input.placeholder = ph;
    input.value = value;
    input.addEventListener("change", () => onChange(input.value.trim()));
    return input;
  };
  const ctColor = (value: string, title: string, onChange: (v: string) => void) => {
    const input = document.createElement("input");
    input.className = "ct-color";
    input.type = "color";
    input.title = title;
    input.value = value;
    input.addEventListener("change", () => onChange(input.value));
    return input;
  };
  const ctCommit = (reopen = true) => {
    saveConfig();
    registerCustomThemes();
    if (THEMES[themeKey] === undefined) applyTheme("one-dark");
    else if (themeKey.startsWith("custom-")) applyTheme(themeKey);
    if (reopen) buildSettingsPage();
  };
  const ctBlock = document.createElement("div");
  ctBlock.className = "tpl-list";
  (config.custom_themes ?? []).forEach((ct, i) => {
    const row = document.createElement("div");
    row.className = "tpl-row ct-row";
    const base = THEMES[ct.base ?? "one-dark"] ?? THEMES["one-dark"];
    const name = ctInput("Name", ct.name, (v) => {
      ct.name = v || `Custom ${i + 1}`;
      ctCommit();
    });
    const baseSel = mkSelect(
      builtinThemeKeys.map((k) => [k, THEMES[k].label] as [string, string]),
      ct.base ?? "one-dark",
      (v) => {
        ct.base = v;
        ctCommit();
      }
    );
    const bgC = ctColor(ct.bg ?? base.xterm.background!, "Background color", (v) => {
      ct.bg = v;
      ctCommit();
    });
    const fgC = ctColor(ct.fg ?? base.xterm.foreground!, "Text color", (v) => {
      ct.fg = v;
      ctCommit();
    });
    const acC = ctColor(ct.accent ?? base.xterm.blue!, "Accent color", (v) => {
      ct.accent = v;
      ctCommit();
    });
    const use = document.createElement("button");
    use.className = "set-btn";
    use.textContent = themeKey === `custom-${i}` ? "Active" : "Use";
    use.addEventListener("click", () => {
      applyTheme(`custom-${i}`);
      buildSettingsPage();
    });
    const del = document.createElement("button");
    del.className = "tpl-del";
    del.textContent = "✕";
    del.title = "Remove custom theme";
    del.addEventListener("click", () => {
      config.custom_themes!.splice(i, 1);
      if (!config.custom_themes!.length) config.custom_themes = undefined;
      // Keys shift down past the removed index; keep the active theme.
      const m = /^custom-(\d+)$/.exec(themeKey);
      if (m) {
        const idx = Number(m[1]);
        if (idx === i) themeKey = "one-dark";
        else if (idx > i) themeKey = `custom-${idx - 1}`;
      }
      saveConfig();
      registerCustomThemes();
      applyTheme(THEMES[themeKey] ? themeKey : "one-dark");
      buildSettingsPage();
    });
    row.append(name, baseSel, bgC, fgC, acC, use, del);
    ctBlock.appendChild(row);
  });
  const ctAdd = document.createElement("button");
  ctAdd.className = "set-btn";
  ctAdd.textContent = "+ New theme from current";
  ctAdd.addEventListener("click", () => {
    const cur = currentTheme();
    const curBase = /^custom-(\d+)$/.test(themeKey)
      ? config.custom_themes?.[Number(/^custom-(\d+)$/.exec(themeKey)![1])]?.base ?? "one-dark"
      : themeKey;
    config.custom_themes = [
      ...(config.custom_themes ?? []),
      {
        name: `My ${cur.label}`,
        base: curBase,
        bg: cur.xterm.background,
        fg: cur.xterm.foreground,
        accent: cur.xterm.blue,
      },
    ];
    ctCommit();
  });
  ctBlock.appendChild(ctAdd);
  settingRow(
    "Custom themes",
    "Your own themes: pick a built-in as the base, then override background, text, and accent colors. Changing the background swaps the base's art for a flat color.",
    ctBlock
  );
  settingRow(
    "Font",
    "Overrides the theme's font for all terminals.",
    mkSelect(
      [
        ["", "Theme default"],
        ['"Cascadia Mono", Consolas, monospace', "Cascadia Mono"],
        ['"Cascadia Code", "Cascadia Mono", monospace', "Cascadia Code"],
        ["Consolas, monospace", "Consolas"],
        ['"Lucida Console", monospace', "Lucida Console"],
        ['"Courier New", monospace', "Courier New"],
      ],
      config.font_family ?? "",
      (v) => {
        config.font_family = v || undefined;
        changed();
      }
    )
  );
  settingRow(
    "Font size",
    "Terminal text size in pixels.",
    mkNumber(effFontSize(), 9, 24, (v) => {
      config.font_size = v;
      changed();
    })
  );
  settingRow(
    "Line height",
    "Vertical spacing between terminal lines.",
    mkSelect(
      [["", "Theme default"], ["1", "1.0"], ["1.1", "1.1"], ["1.2", "1.2"], ["1.3", "1.3"], ["1.4", "1.4"]],
      config.line_height ? String(config.line_height) : "",
      (v) => {
        config.line_height = v ? Number(v) : undefined;
        changed();
      }
    )
  );
  settingRow(
    "Cursor style",
    "Bar is the Windows Terminal look; block is classic.",
    mkSelect(
      [["", "Theme default"], ["bar", "Bar"], ["block", "Block"], ["underline", "Underline"]],
      config.cursor_style ?? "",
      (v) => {
        config.cursor_style = (v || undefined) as CursorStyle | undefined;
        changed();
      }
    )
  );
  settingRow(
    "Cursor blink",
    "Whether the terminal cursor blinks.",
    mkSelect([["on", "On"], ["off", "Off"]], effCursorBlink() ? "on" : "off", (v) => {
      config.cursor_blink = v === "on";
      changed();
    })
  );
  settingRow(
    "Tab width (px)",
    "Maximum width of tabs in the tab bar. Ctrl+scroll over the tab bar also resizes. Dragging one tab's edge sizes just that tab.",
    mkNumber(config.tab_width ?? 220, 110, 400, (v) => {
      config.tab_width = v;
      changed();
    })
  );
  const bgStyle = config.bg_style ?? "theme";
  settingRow(
    "Background",
    "Each theme ships its own background art (the default). New tabs render transparently over it; already-open tabs keep a solid background until reopened.",
    mkSelect(
      [
        ["theme", "Theme default"],
        ["none", "Plain color"],
        ["aurora", "Aurora"],
        ["nebula", "Nebula"],
        ["grid", "Synth grid"],
        ["custom", "Custom image"],
      ],
      bgStyle,
      (v) => {
        config.bg_style = v === "theme" ? undefined : v;
        changed();
        buildSettingsPage(); // image/dim rows only show when relevant
      }
    )
  );
  if (bgStyle === "custom") {
    const bgInput = document.createElement("input");
    bgInput.className = "set-control set-wide";
    bgInput.type = "text";
    bgInput.placeholder = "C:\\path\\to\\image.jpg or https://…";
    bgInput.value = config.bg_image ?? "";
    bgInput.addEventListener("change", () => {
      config.bg_image = bgInput.value.trim() || undefined;
      changed();
    });
    settingRow(
      "Background image",
      "Local image file or URL.",
      withBrowse(bgInput, false, [
        { name: "Images", extensions: ["png", "jpg", "jpeg", "gif", "webp", "bmp"] },
      ])
    );
  }
  if (["aurora", "nebula", "grid", "custom"].includes(bgStyle)) {
    settingRow(
      "Background dim (%)",
      "How strongly the theme color covers the background — higher keeps text more readable.",
      mkNumber(config.bg_dim ?? 50, 0, 95, (v) => {
        config.bg_dim = v;
        changed();
      })
    );
  }
  if (bgStyle !== "none") {
    const themeDefault = currentTheme().transparency ?? 100;
    settingRow(
      "Background transparency (%)",
      `How much the background shows through the terminal itself. 100 = fully see-through cells, 0 = solid terminal background. Each theme sets its own default (${themeDefault}% here) — busier art veils itself more; set it back to that value to follow the theme again.`,
      mkNumber(effTransparency(), 0, 100, (v) => {
        config.bg_transparency = v === themeDefault ? undefined : v;
        changed();
      })
    );
  }

  settingsSection("Status bar");
  settingRow(
    "Status bar",
    "A thin strip of counters along the bottom. Ctrl+Shift+S toggles it; it stays visible in full screen. Click any item for detail.",
    mkSelect([["on", "On"], ["off", "Off"]], (config.status_bar ?? true) ? "on" : "off", (v) => {
      config.status_bar = v === "on";
      saveConfig();
      applyStatusBar();
    })
  );
  if (config.status_bar ?? true) {
    settingRow(
      "Refresh (ms)",
      "How often the counters resample. Command items keep their own slower cadence.",
      mkNumber(config.status_interval_ms ?? 2000, 250, 60000, (v) => {
        config.status_interval_ms = v;
        saveConfig();
        applyStatusBar();
      })
    );

    // Items: an ordered list; the select offers built-ins plus anything
    // defined below, so a new counter or command shows up here at once.
    const itemChoices = (): Array<[string, string]> => [
      ...Object.entries(STATUS_BUILTINS).map(([k, v]) => [k, v.label] as [string, string]),
      ...(config.status_perf ?? []).map((p) => [p.id, `${p.label || p.path} (counter)`] as [string, string]),
      ...(config.status_custom ?? []).map((c) => [c.id, `${c.label || c.command} (command)`] as [string, string]),
    ];
    const itemsBlock = document.createElement("div");
    itemsBlock.className = "tpl-list";
    const renderItems = () => {
      itemsBlock.innerHTML = "";
      const ids = statusItemIds();
      /// Move an item within the bar; out-of-range targets are no-ops so
      /// the end buttons simply do nothing rather than wrapping around.
      const move = (from: number, to: number) => {
        const next = [...statusItemIds()];
        if (to < 0 || to >= next.length) return;
        const [moved] = next.splice(from, 1);
        next.splice(to, 0, moved);
        config.status_items = next;
        saveConfig();
        applyStatusBar();
        renderItems();
      };
      ids.forEach((id, i) => {
        const row = document.createElement("div");
        row.className = "tpl-row sb-row";
        const sel = mkSelect(itemChoices(), id, (v) => {
          const next = [...statusItemIds()];
          next[i] = v;
          config.status_items = next;
          saveConfig();
          applyStatusBar();
          renderItems();
        });
        const up = document.createElement("button");
        up.className = "row-move";
        up.textContent = "↑";
        up.title = "Move left along the bar";
        up.disabled = i === 0;
        up.addEventListener("click", () => move(i, i - 1));
        const down = document.createElement("button");
        down.className = "row-move";
        down.textContent = "↓";
        down.title = "Move right along the bar";
        down.disabled = i === ids.length - 1;
        down.addEventListener("click", () => move(i, i + 1));
        const del = document.createElement("button");
        del.className = "tpl-del";
        del.textContent = "✕";
        del.title = "Remove from the bar";
        del.addEventListener("click", () => {
          config.status_items = statusItemIds().filter((_, j) => j !== i);
          saveConfig();
          applyStatusBar();
          renderItems();
        });
        row.append(sel, up, down, del);
        itemsBlock.appendChild(row);
      });
      const add = document.createElement("button");
      add.className = "set-btn";
      add.textContent = "+ Add item";
      add.addEventListener("click", () => {
        const first = itemChoices()[0]?.[0];
        if (!first) return;
        config.status_items = [...statusItemIds(), first];
        saveConfig();
        applyStatusBar();
        renderItems();
      });
      itemsBlock.appendChild(add);
    };
    renderItems();
    settingRow(
      "Items",
      "Shown left to right in this order — use ↑ and ↓ to rearrange. The bar splits around the middle of the list.",
      itemsBlock
    );

    // Performance counters: any PDH path this machine exposes.
    const perfBlock = document.createElement("div");
    perfBlock.className = "tpl-list";
    const renderPerf = () => {
      perfBlock.innerHTML = "";
      (config.status_perf ?? []).forEach((p, i) => {
        const row = document.createElement("div");
        row.className = "tpl-row perf-row";
        const label = mkTplInput("Label", p.label, (v) => {
          p.label = v;
          saveConfig();
          applyStatusBar();
        });
        const path = mkTplInput("\\Object(Instance)\\Counter", p.path, (v) => {
          p.path = v;
          saveConfig();
          applyStatusBar();
        });
        const fmt = mkSelect(
          [["raw", "Number"], ["int", "Integer"], ["pct", "Percent"], ["bytes", "Bytes"], ["rate", "Bytes/s"]],
          p.format ?? "raw",
          (v) => {
            p.format = v;
            saveConfig();
            applyStatusBar();
          }
        );
        const del = document.createElement("button");
        del.className = "tpl-del";
        del.textContent = "✕";
        del.addEventListener("click", () => {
          config.status_perf = (config.status_perf ?? []).filter((_, j) => j !== i);
          config.status_items = statusItemIds().filter((x) => x !== p.id);
          if (!config.status_perf.length) config.status_perf = undefined;
          saveConfig();
          applyStatusBar();
          buildSettingsPage();
        });
        row.append(label, path, fmt, del);
        perfBlock.appendChild(row);
      });
      const browse = document.createElement("button");
      browse.className = "set-btn";
      browse.textContent = "Browse counters…";
      browse.addEventListener("click", () => void openPerfBrowser());
      perfBlock.appendChild(browse);
    };
    renderPerf();
    settingRow(
      "Performance counters",
      "Any counter Windows exposes, read through PDH — the same source as Performance Monitor. Browse picks the object, instance, and counter for you.",
      perfBlock
    );

    // Command items: the no-rebuild escape hatch.
    const cmdBlock = document.createElement("div");
    cmdBlock.className = "tpl-list";
    const renderCmds = () => {
      cmdBlock.innerHTML = "";
      (config.status_custom ?? []).forEach((c, i) => {
        const row = document.createElement("div");
        row.className = "tpl-row cmd-row";
        const label = mkTplInput("Label", c.label, (v) => {
          c.label = v;
          saveConfig();
          applyStatusBar();
        });
        const command = mkTplInput("PowerShell command", c.command, (v) => {
          c.command = v;
          saveConfig();
          applyStatusBar();
        });
        // A bare number in a row of text fields tells you nothing, so it
        // carries its own unit.
        const every = document.createElement("label");
        every.className = "unit-field";
        every.title = "How often to run this command, in seconds";
        const everyPre = document.createElement("span");
        everyPre.textContent = "every";
        const everyNum = mkNumber(c.interval_s ?? 10, 2, 3600, (v) => {
          c.interval_s = v;
          saveConfig();
        });
        const everyPost = document.createElement("span");
        everyPost.textContent = "s";
        every.append(everyPre, everyNum, everyPost);
        const del = document.createElement("button");
        del.className = "tpl-del";
        del.textContent = "✕";
        del.addEventListener("click", () => {
          config.status_custom = (config.status_custom ?? []).filter((_, j) => j !== i);
          config.status_items = statusItemIds().filter((x) => x !== c.id);
          if (!config.status_custom.length) config.status_custom = undefined;
          saveConfig();
          applyStatusBar();
          buildSettingsPage();
        });
        row.append(label, command, every, del);
        cmdBlock.appendChild(row);
      });
      const add = document.createElement("button");
      add.className = "set-btn";
      add.textContent = "+ Add command";
      add.addEventListener("click", () => {
        const id = `cmd-${Date.now().toString(36)}`;
        config.status_custom = [
          ...(config.status_custom ?? []),
          { id, label: "branch", command: "git branch --show-current", interval_s: 10 },
        ];
        config.status_items = [...statusItemIds(), id];
        saveConfig();
        applyStatusBar();
        buildSettingsPage();
      });
      cmdBlock.appendChild(add);
    };
    renderCmds();
    settingRow(
      "Command items",
      "First line of a PowerShell command, on its own timer. Each one runs in the active tab's current working folder, so directory-sensitive commands like git report on whatever you're looking at. New items default to showing the current branch.",
      cmdBlock
    );
  }

  settingsSection("Tab titles");
  settingRow(
    "Title style",
    "How tabs are labeled automatically. Your renames and AI-picked titles always override this.",
    mkSelect(
      [
        ["smart", "Smart (program · folder, then directory)"],
        ["dir", "Directory name"],
        ["program", "Running program"],
        ["shelltitle", "Shell-reported title"],
        ["custom", "Custom template"],
      ],
      config.title_mode ?? "smart",
      (v) => {
        config.title_mode = v === "smart" ? undefined : v;
        saveConfig();
        updateLiveInfo();
        buildSettingsPage(); // template row only shows for Custom
      }
    )
  );
  if (config.title_mode === "custom") {
    const tplInput = document.createElement("input");
    tplInput.className = "set-control set-wide";
    tplInput.type = "text";
    tplInput.placeholder = "{program} · {folder}";
    tplInput.value = config.title_template ?? "";
    tplInput.addEventListener("change", () => {
      config.title_template = tplInput.value.trim() || undefined;
      saveConfig();
      updateLiveInfo();
    });
    settingRow(
      "Custom template",
      "Placeholders: {program} {folder} {parent} {path} {shell} {title}. Join parts with ·",
      tplInput
    );
  }

  settingsSection("Sessions");
  settingRow(
    "Default shell",
    "Shell for new tabs. Right-click the + button to open a one-off tab in a different shell.",
    mkSelect(SHELL_CHOICES, config.default_shell ?? "auto", (v) => {
      config.default_shell = v === "auto" ? undefined : v;
      saveConfig();
    })
  );
  const cwdInput = document.createElement("input");
  cwdInput.className = "set-control set-wide";
  cwdInput.type = "text";
  cwdInput.placeholder = "blank = home directory";
  cwdInput.value = config.default_cwd ?? "";
  cwdInput.addEventListener("change", () => {
    config.default_cwd = cwdInput.value.trim() || undefined;
    saveConfig();
  });
  settingRow(
    "Default directory",
    "New tabs start in this folder. Falls back to your home directory if the path doesn't exist.",
    withBrowse(cwdInput, true)
  );
  // Session templates: named presets combining shell, folder, and title.
  const tplBlock = document.createElement("div");
  tplBlock.className = "tpl-list";
  const renderTemplates = () => {
    tplBlock.innerHTML = "";
    (config.templates ?? []).forEach((t, i) => {
      const row = document.createElement("div");
      row.className = "tpl-row";
      const name = mkTplInput("Name", t.name, (v) => {
        t.name = v;
        saveConfig();
      });
      const shellSel = mkSelect(
        [["auto", "Default shell"], ...SHELL_CHOICES.filter(([v]) => v !== "auto")],
        t.shell ?? "auto",
        (v) => {
          t.shell = v === "auto" ? undefined : v;
          saveConfig();
        }
      );
      const cwd = mkTplInput("Start folder (blank = default)", t.cwd ?? "", (v) => {
        t.cwd = v || undefined;
        saveConfig();
      });
      const cwdCell = document.createElement("div");
      cwdCell.className = "tpl-cell";
      const cwdBrowse = document.createElement("button");
      cwdBrowse.className = "browse-mini";
      cwdBrowse.textContent = "…";
      cwdBrowse.title = "Browse for a folder";
      cwdBrowse.addEventListener("click", () => void browseInto(cwd, true));
      cwdCell.append(cwd, cwdBrowse);
      const title = mkTplInput("Tab title (blank = automatic)", t.title ?? "", (v) => {
        t.title = v || undefined;
        saveConfig();
      });
      const del = document.createElement("button");
      del.className = "tpl-del";
      del.textContent = "✕";
      del.title = "Remove template";
      del.addEventListener("click", () => {
        config.templates!.splice(i, 1);
        if (!config.templates!.length) config.templates = undefined;
        saveConfig();
        renderTemplates();
      });
      row.append(name, shellSel, cwdCell, title, del);
      tplBlock.appendChild(row);
    });
    const add = document.createElement("button");
    add.className = "set-btn";
    add.textContent = "+ Add template";
    add.addEventListener("click", () => {
      config.templates = [
        ...(config.templates ?? []),
        { name: `Template ${(config.templates?.length ?? 0) + 1}` },
      ];
      saveConfig();
      renderTemplates();
    });
    tplBlock.appendChild(add);
  };
  renderTemplates();
  settingRow(
    "Templates",
    "Named presets for new tabs — shell, start folder, and tab title. Right-click the + button to open one.",
    tplBlock
  );

  // Workspaces: launch a preset group of templates from one shortcut.
  const wsBlock = document.createElement("div");
  wsBlock.className = "tpl-list";
  const renderWorkspaces = () => {
    wsBlock.innerHTML = "";
    (config.workspaces ?? []).forEach((w, i) => {
      const row = document.createElement("div");
      row.className = "tpl-row ws-row";
      const name = mkTplInput("Workspace name", w.name, (v) => {
        w.name = v;
        saveConfig();
      });
      const tpls = mkTplInput(
        "Templates, comma-separated",
        w.templates.join(", "),
        (v) => {
          w.templates = v.split(",").map((s) => s.trim()).filter(Boolean);
          saveConfig();
        }
      );
      const copy = document.createElement("button");
      copy.className = "set-btn";
      copy.textContent = "Copy cmd";
      copy.title = "Copies a command line for a shortcut that opens this workspace";
      copy.addEventListener("click", () => {
        const exe = launchInfo?.exe || "gterminal.exe";
        void navigator.clipboard.writeText(`"${exe}" --workspace "${w.name}"`);
        copy.textContent = "Copied!";
        window.setTimeout(() => (copy.textContent = "Copy cmd"), 1200);
      });
      const saveBtn = document.createElement("button");
      saveBtn.className = "set-btn";
      saveBtn.textContent = "Save shortcut…";
      saveBtn.title = "Saves a ready-made shortcut (.lnk) that opens this workspace";
      saveBtn.addEventListener("click", async () => {
        const file = await saveDialog({
          defaultPath: `${w.name || "workspace"}.lnk`,
          filters: [{ name: "Shortcut", extensions: ["lnk"] }],
        }).catch(() => null);
        if (!file) return;
        try {
          await invoke("create_shortcut", { path: file, workspace: w.name });
          saveBtn.textContent = "Saved!";
        } catch {
          saveBtn.textContent = "Failed";
        }
        window.setTimeout(() => (saveBtn.textContent = "Save shortcut…"), 1500);
      });
      const del = document.createElement("button");
      del.className = "tpl-del";
      del.textContent = "✕";
      del.title = "Remove workspace";
      del.addEventListener("click", () => {
        config.workspaces!.splice(i, 1);
        if (!config.workspaces!.length) config.workspaces = undefined;
        saveConfig();
        renderWorkspaces();
      });
      row.append(name, tpls, copy, saveBtn, del);
      wsBlock.appendChild(row);
    });
    const add = document.createElement("button");
    add.className = "set-btn";
    add.textContent = "+ Add workspace";
    add.addEventListener("click", () => {
      config.workspaces = [
        ...(config.workspaces ?? []),
        { name: `Workspace ${(config.workspaces?.length ?? 0) + 1}`, templates: [] },
      ];
      saveConfig();
      renderWorkspaces();
    });
    wsBlock.appendChild(add);
  };
  renderWorkspaces();
  settingRow(
    "Workspaces",
    "A named set of templates opened together with `--workspace \"name\"` — Copy shortcut gives you the command line to paste into a desktop shortcut's Target.",
    wsBlock
  );
  settingRow(
    "Keep history (days)",
    "Every session's output is recorded and browsable from the ◷ button, even after the session dies. 0 disables recording.",
    mkNumber(config.history_days ?? 14, 0, 365, (v) => {
      config.history_days = v;
      saveConfig();
    })
  );
  settingRow(
    "Autocomplete suggestions",
    "Prediction for new PowerShell tabs. Smart modes add GTerminal's own suggestions — commands you've run in any session, ranked with a boost for the current folder — alongside PSReadLine's cross-app history. GTerminal-only modes suggest solely from what you've run here.",
    mkSelect(
      [
        ["shell", "Shell default"],
        ["inline", "Smart inline (history + GTerminal)"],
        ["list", "Smart dropdown (history + GTerminal)"],
        ["plugin-inline", "GTerminal only — inline"],
        ["plugin-list", "GTerminal only — dropdown"],
        ["off", "Off"],
      ],
      config.prediction ?? "shell",
      (v) => {
        config.prediction = v === "shell" ? undefined : v;
        saveConfig();
      }
    )
  );
  settingRow(
    "Undo window (minutes)",
    "Closed or exited sessions stay restorable this long before they actually die. 0 disables the grace period.",
    mkNumber(config.grace_minutes ?? 5, 0, 120, (v) => {
      config.grace_minutes = v;
      saveConfig();
    })
  );

  settingsSection("AI titles");
  const urlInput2 = document.createElement("input");
  urlInput2.className = "set-control set-wide";
  urlInput2.type = "text";
  urlInput2.placeholder = "blank = disabled";
  urlInput2.value = config.ai_base_url ?? "";
  urlInput2.addEventListener("change", () => {
    config.ai_base_url = urlInput2.value.trim() || undefined;
    saveConfig();
  });
  settingRow(
    "API endpoint",
    "Blank disables AI titles entirely — nothing is ever called. Set an Anthropic- or OpenAI-compatible base URL to enable.",
    urlInput2
  );
  settingRow(
    "API flavor",
    "Which request format the endpoint speaks.",
    mkSelect(
      [
        ["anthropic", "Anthropic-compatible"],
        ["openai", "OpenAI-compatible"],
      ],
      config.ai_flavor ?? "anthropic",
      (v) => {
        config.ai_flavor = v === "anthropic" ? undefined : v;
        saveConfig();
      }
    )
  );
  const keyInput = document.createElement("input");
  keyInput.className = "set-control set-wide";
  keyInput.type = "password";
  keyInput.placeholder = "optional";
  keyInput.value = config.ai_api_key ?? "";
  keyInput.addEventListener("change", () => {
    config.ai_api_key = keyInput.value.trim() || undefined;
    saveConfig();
  });
  settingRow(
    "API key",
    "Optional — local gateways often need none. Stored in config.json on this machine.",
    keyInput
  );
  const modelInput = document.createElement("input");
  modelInput.className = "set-control set-wide";
  modelInput.type = "text";
  modelInput.placeholder = "claude-opus-5";
  modelInput.value = config.ai_model ?? "";
  modelInput.addEventListener("change", () => {
    config.ai_model = modelInput.value.trim() || undefined;
    saveConfig();
  });
  settingRow(
    "Model",
    "Model ID your endpoint understands (e.g. claude-opus-5, or a local model name).",
    modelInput
  );
  settingRow(
    "Auto-titles",
    "Quietly names unnamed tabs from their activity, one tab every couple of minutes. Manual renames always win.",
    mkSelect(
      [["off", "Off"], ["on", "On"]],
      config.ai_auto_titles ? "on" : "off",
      (v) => {
        config.ai_auto_titles = v === "on";
        saveConfig();
      }
    )
  );

  settingsSection("About");
  const about = document.createElement("div");
  about.className = "about-block";
  const aboutApp = document.createElement("div");
  aboutApp.className = "about-app";
  aboutApp.textContent = "GTerminal";
  getVersion()
    .then((v) => (aboutApp.textContent = `GTerminal ${v}`))
    .catch(() => {});
  const aboutBy = document.createElement("div");
  aboutBy.textContent = "Made by Gus Catalano";
  const aboutLinks = document.createElement("div");
  aboutLinks.className = "about-links";
  // Links must open in the system browser — a plain anchor would
  // navigate the webview itself.
  const mkLink = (label: string, url: string) => {
    const a = document.createElement("a");
    a.textContent = label;
    a.href = url;
    a.addEventListener("click", (e) => {
      e.preventDefault();
      openUrl(url).catch(() => {});
    });
    aboutLinks.appendChild(a);
  };
  mkLink("guscatalano.dev", "https://guscatalano.dev");
  mkLink("Source on GitHub", "https://github.com/guscatalano/GTerminal");
  about.append(aboutApp, aboutBy, aboutLinks);
  settingsList.appendChild(about);
  filterSettings(); // rebuilds (e.g. theme change) keep the active query
  scroller.scrollTop = scrollAt;
}

// ── status bar ──────────────────────────────────────────────────────────
// A thin strip of glanceable counters. Three ways to extend it:
//   1. add an entry to STATUS_BUILTINS below (needs a rebuild),
//   2. point a Performance counter item at any PDH path (no rebuild),
//   3. run a shell command on a timer (no rebuild).
// Everything the items read arrives in one StatusCtx per tick.

interface SystemStats {
  cpu_pct: number;
  mem_used: number;
  mem_total: number;
  page_used: number;
  page_total: number;
  disk_read_bps: number;
  disk_write_bps: number;
  disk_free: number;
  disk_total: number;
  battery_pct: number | null;
  battery_charging: boolean;
  battery_minutes: number | null;
  uptime_s: number;
  processes: number;
  threads: number;
  input: InputDelay | null;
  gpu: GpuStats | null;
  net: NetStats | null;
  remote: RemoteStats | null;
}

interface InputDelay {
  session_max_ms: number;
  process_max_ms: number;
  worst_process: string;
  available: boolean;
}

interface GpuStats {
  busy_pct: number;
  engines: Array<{ kind: string; pct: number }>;
  vram_used: number;
  shared_used: number;
  adapters: Array<{ name: string; driver: string; memory: number }>;
}

interface NetStats {
  rx_bps: number;
  tx_bps: number;
  iface: string;
  iface_count: number;
}

interface RemoteStats {
  is_remote: boolean;
  active_sessions: number;
  total_sessions: number;
  rtt_ms: number;
  bandwidth_kbps: number;
  loss_pct: number;
  fps: number;
  encode_ms: number;
  frames_skipped: number;
}

/// Frame pacing of this window, measured off the real render loop —
/// there is no system counter for "how smooth is this app". rAF is
/// throttled while the window is hidden, so this reads 0 when minimised.
const frameTimes: number[] = [];
function startFpsMeter() {
  let last = performance.now();
  const tick = (now: number) => {
    const dt = now - last;
    last = now;
    if (dt > 0 && dt < 1000) {
      frameTimes.push(dt);
      if (frameTimes.length > 90) frameTimes.shift();
    }
    requestAnimationFrame(tick);
  };
  requestAnimationFrame(tick);
}
function fpsNow(): number {
  if (!frameTimes.length) return 0;
  const avg = frameTimes.reduce((a, b) => a + b, 0) / frameTimes.length;
  return avg > 0 ? Math.round(1000 / avg) : 0;
}

interface StatusCtx {
  stats: SystemStats;
  perf: Record<string, number>;
  custom: Record<string, string>;
}

interface StatusDetail {
  rows: Array<[string, string]>;
  /// Buttons that open a URL in the browser.
  links?: Array<{ label: string; url: string }>;
  /// Buttons that run a shell command (fire and forget).
  actions?: Array<{ label: string; cmd: string }>;
}

interface StatusItemDef {
  label: string;
  render: (c: StatusCtx) => string;
  detail?: (c: StatusCtx) => StatusDetail;
}

function fmtBytes(n: number): string {
  if (!isFinite(n) || n <= 0) return "0B";
  const u = ["B", "K", "M", "G", "T"];
  let i = 0;
  while (n >= 1024 && i < u.length - 1) {
    n /= 1024;
    i++;
  }
  return `${n >= 100 || i === 0 ? Math.round(n) : n.toFixed(1)}${u[i]}`;
}
function fmtRate(n: number): string {
  return `${fmtBytes(n)}/s`;
}
function fmtDuration(s: number): string {
  const d = Math.floor(s / 86400);
  const h = Math.floor((s % 86400) / 3600);
  const m = Math.floor((s % 3600) / 60);
  if (d) return `${d}d ${h}h`;
  if (h) return `${h}h ${m}m`;
  return `${m}m`;
}
function pct(n: number): string {
  return `${Math.round(n)}%`;
}

const STATUS_BUILTINS: Record<string, StatusItemDef> = {
  clock: {
    label: "Clock",
    render: () => new Date().toLocaleTimeString(),
    detail: () => {
      const d = new Date();
      return {
        rows: [
          ["Local", d.toLocaleString()],
          ["UTC", d.toUTCString()],
          ["ISO 8601", d.toISOString()],
          ["Epoch (s)", String(Math.floor(d.getTime() / 1000))],
          ["Time zone", Intl.DateTimeFormat().resolvedOptions().timeZone],
          ["Week day", d.toLocaleDateString(undefined, { weekday: "long" })],
        ],
      };
    },
  },
  cpu: {
    label: "CPU",
    render: (c) => `CPU ${pct(c.stats.cpu_pct)}`,
    detail: (c) => ({
      rows: [
        ["Usage", pct(c.stats.cpu_pct)],
        ["Logical cores", String(navigator.hardwareConcurrency || "?")],
        ["Uptime", fmtDuration(c.stats.uptime_s)],
      ],
      // Each external tool is offered by exactly one item: Task Manager
      // here, Resource Monitor on Disk I/O, Performance Monitor on
      // counter items.
      actions: [{ label: "Task Manager", cmd: "Start-Process taskmgr" }],
    }),
  },
  mem: {
    label: "Memory",
    render: (c) =>
      `MEM ${fmtBytes(c.stats.mem_used)}/${fmtBytes(c.stats.mem_total)}`,
    detail: (c) => {
      const s = c.stats;
      return {
        rows: [
          ["Used", fmtBytes(s.mem_used)],
          ["Free", fmtBytes(s.mem_total - s.mem_used)],
          ["Total", fmtBytes(s.mem_total)],
          ["In use", s.mem_total ? pct((s.mem_used / s.mem_total) * 100) : "—"],
          ["Commit", `${fmtBytes(s.page_used)} / ${fmtBytes(s.page_total)}`],
          ["Free commit", fmtBytes(s.page_total - s.page_used)],
        ],
      };
    },
  },
  diskio: {
    label: "Disk I/O",
    render: (c) =>
      `D ↓${fmtRate(c.stats.disk_read_bps)} ↑${fmtRate(c.stats.disk_write_bps)}`,
    detail: (c) => ({
      rows: [
        ["Read", fmtRate(c.stats.disk_read_bps)],
        ["Write", fmtRate(c.stats.disk_write_bps)],
        ["Total", fmtRate(c.stats.disk_read_bps + c.stats.disk_write_bps)],
        ["Source", "PDH \\PhysicalDisk(_Total)"],
      ],
      actions: [{ label: "Resource Monitor", cmd: "Start-Process resmon" }],
    }),
  },
  disk: {
    label: "Disk free",
    render: (c) => `C: ${fmtBytes(c.stats.disk_free)}`,
    detail: (c) => {
      const s = c.stats;
      const used = s.disk_total - s.disk_free;
      return {
        rows: [
          ["Free", fmtBytes(s.disk_free)],
          ["Used", fmtBytes(used)],
          ["Total", fmtBytes(s.disk_total)],
          ["In use", s.disk_total ? pct((used / s.disk_total) * 100) : "—"],
        ],
        actions: [
          { label: "Disk Cleanup", cmd: "Start-Process cleanmgr" },
          { label: "Open C:\\", cmd: "Start-Process explorer C:\\" },
        ],
      };
    },
  },
  battery: {
    label: "Battery",
    render: (c) => {
      const s = c.stats;
      if (s.battery_pct === null) return s.battery_charging ? "AC" : "BAT —";
      return `BAT ${s.battery_pct}%${s.battery_charging ? "⚡" : ""}`;
    },
    detail: (c) => {
      const s = c.stats;
      return {
        rows: [
          ["Charge", s.battery_pct === null ? "no battery" : `${s.battery_pct}%`],
          ["Power", s.battery_charging ? "AC connected" : "on battery"],
          [
            "Remaining",
            s.battery_minutes === null ? "—" : fmtDuration(s.battery_minutes * 60),
          ],
        ],
        actions: [
          { label: "Power settings", cmd: "Start-Process ms-settings:powersleep" },
        ],
      };
    },
  },
  uptime: {
    label: "Uptime",
    render: (c) => `UP ${fmtDuration(c.stats.uptime_s)}`,
    detail: (c) => ({
      rows: [
        ["Uptime", fmtDuration(c.stats.uptime_s)],
        ["Booted", new Date(Date.now() - c.stats.uptime_s * 1000).toLocaleString()],
      ],
    }),
  },
  fps: {
    label: "Frame rate",
    render: () => `${fpsNow()} fps`,
    detail: (c) => {
      const avg = frameTimes.length
        ? frameTimes.reduce((a, b) => a + b, 0) / frameTimes.length
        : 0;
      const worst = frameTimes.length ? Math.max(...frameTimes) : 0;
      const tab = activeId === null ? undefined : tabs.get(activeId);
      const rows: Array<[string, string]> = [
        ["Frame rate", `${fpsNow()} fps`],
        ["Frame time", `${avg.toFixed(1)} ms`],
        ["Worst frame", `${worst.toFixed(1)} ms`],
        ["Renderer", tab?.webgl ? "WebGL" : "DOM"],
      ];
      if (c.stats.gpu) {
        rows.push(["GPU busy", pct(c.stats.gpu.busy_pct)]);
        if (c.stats.gpu.adapters[0]) rows.push(["Adapter", c.stats.gpu.adapters[0].name]);
      }
      return { rows };
    },
  },
  gpu: {
    label: "GPU",
    render: (c) => (c.stats.gpu ? `GPU ${pct(c.stats.gpu.busy_pct)}` : "GPU …"),
    detail: (c) => {
      const g = c.stats.gpu;
      if (!g) return { rows: [["GPU", "sampling…"]] };
      const rows: Array<[string, string]> = [
        ["Busiest engine", pct(g.busy_pct)],
        ["Dedicated memory", fmtBytes(g.vram_used)],
        ["Shared memory", fmtBytes(g.shared_used)],
      ];
      for (const e of g.engines.slice(0, 6)) rows.push([`Engine ${e.kind}`, pct(e.pct)]);
      for (const a of g.adapters) {
        rows.push([a.name, a.memory ? fmtBytes(a.memory) : "—"]);
        if (a.driver) rows.push([`  driver`, a.driver]);
      }
      return {
        rows,
        actions: [{ label: "Display settings", cmd: "Start-Process ms-settings:display" }],
      };
    },
  },
  net: {
    label: "Network",
    render: (c) =>
      c.stats.net
        ? `NET ↓${fmtRate(c.stats.net.rx_bps)} ↑${fmtRate(c.stats.net.tx_bps)}`
        : "NET …",
    detail: (c) => {
      const n = c.stats.net;
      if (!n) return { rows: [["Network", "sampling…"]] };
      return {
        rows: [
          ["Received", fmtRate(n.rx_bps)],
          ["Sent", fmtRate(n.tx_bps)],
          ["Busiest adapter", n.iface || "—"],
          ["Adapters counted", String(n.iface_count)],
        ],
        actions: [{ label: "Network settings", cmd: "Start-Process ms-settings:network" }],
      };
    },
  },
  remote: {
    label: "Remote session",
    render: (c) => {
      const r = c.stats.remote;
      if (!r) return "RDP …";
      if (!r.is_remote) return "local";
      return r.rtt_ms > 0 ? `RDP ${r.rtt_ms.toFixed(0)}ms` : "RDP";
    },
    detail: (c) => {
      const r = c.stats.remote;
      if (!r) return { rows: [["Session", "sampling…"]] };
      const rows: Array<[string, string]> = [
        ["This session", r.is_remote ? "remote (RDP)" : "local console"],
        ["Active sessions", String(Math.round(r.active_sessions))],
        ["Total sessions", String(Math.round(r.total_sessions))],
      ];
      if (r.is_remote) {
        rows.push(
          ["Round trip", r.rtt_ms > 0 ? `${r.rtt_ms.toFixed(1)} ms` : "—"],
          ["Bandwidth", r.bandwidth_kbps > 0 ? `${Math.round(r.bandwidth_kbps)} kbps` : "—"],
          ["Packet loss", r.loss_pct > 0 ? pct(r.loss_pct) : "0%"],
          ["Output frames", r.fps > 0 ? `${r.fps.toFixed(0)} fps` : "—"],
          ["Encode time", r.encode_ms > 0 ? `${r.encode_ms.toFixed(1)} ms` : "—"],
          ["Frames skipped", r.frames_skipped.toFixed(1)]
        );
      } else {
        rows.push(["RemoteFX", "not applicable on a local session"]);
      }
      return { rows };
    },
  },
  input: {
    label: "Input delay",
    render: (c) => {
      const i = c.stats.input;
      if (!i) return "IN …";
      return i.available ? `IN ${Math.round(i.session_max_ms)}ms` : "IN —";
    },
    detail: (c) => {
      const i = c.stats.input;
      if (!i) return { rows: [["Input delay", "sampling…"]] };
      const ms = (v: number) => (i.available ? `${Math.round(v)} ms` : "—");
      return {
        rows: [
          ["Session worst", ms(i.session_max_ms)],
          ["Process worst", ms(i.process_max_ms)],
          ["Worst process", i.worst_process || "—"],
          ["Source", "User Input Delay per Session/Process"],
        ],
        actions: [{ label: "Services", cmd: "Start-Process services.msc" }],
      };
    },
  },
  procs: {
    label: "Processes",
    render: (c) => `P ${Math.round(c.stats.processes)}`,
    detail: (c) => ({
      rows: [
        ["Processes", String(Math.round(c.stats.processes))],
        ["Threads", String(Math.round(c.stats.threads))],
        [
          "Threads per process",
          c.stats.processes ? (c.stats.threads / c.stats.processes).toFixed(1) : "—",
        ],
      ],
    }),
  },
  sessions: {
    label: "Sessions",
    render: () => `S ${tabCount()}${tabs.size > tabCount() ? `/${tabs.size}` : ""}`,
    detail: () => {
      const cold = [...lastInfo.values()].filter((s) => !s.attached && !s.expires_ms);
      const doomed = [...lastInfo.values()].filter((s) => s.expires_ms);
      return {
        rows: [
          ["Open tabs", String(tabCount())], ["Panes", String(tabs.size)],
          ["Hidden", String(hidden.size)],
          ["Detached", String(cold.length)],
          ["Closing soon", String(doomed.length)],
          ["Known to daemon", String(lastInfo.size)],
        ],
        links: [
          { label: "GTerminal on GitHub", url: "https://github.com/guscatalano/GTerminal" },
        ],
      };
    },
  },
};

const statusbarEl = document.getElementById("statusbar")!;
const statusDetailEl = document.getElementById("status-detail")!;
let statusCtx: StatusCtx = {
  stats: {
    cpu_pct: 0, mem_used: 0, mem_total: 0, page_used: 0, page_total: 0,
    disk_read_bps: 0, disk_write_bps: 0, disk_free: 0, disk_total: 0,
    battery_pct: null, battery_charging: false, battery_minutes: null, uptime_s: 0,
    processes: 0, threads: 0, input: null, gpu: null, net: null, remote: null,
  },
  perf: {},
  custom: {},
};

/// Items whose data costs a wildcard PDH sweep; only those groups get
/// sampled, and only while an item that needs them is on the bar.
const STATUS_GROUPS: Record<string, string> = {
  gpu: "gfx",
  fps: "gfx",
  net: "net",
  remote: "remote",
  input: "input",
};
let statusOpenId: string | null = null;
let statusTimer: number | undefined;
const customLastRun = new Map<string, number>();

function statusItemIds(): string[] {
  return config.status_items ?? ["clock", "cpu", "mem", "diskio"];
}

/// Resolve an id to a renderable item: built-in, then user perf counter,
/// then user command. Unknown ids are dropped rather than rendered blank.
function statusItemDef(id: string): StatusItemDef | undefined {
  if (STATUS_BUILTINS[id]) return STATUS_BUILTINS[id];
  const p = (config.status_perf ?? []).find((x) => x.id === id);
  if (p) {
    return {
      label: p.label || p.path,
      render: (c) => {
        const v = c.perf[p.path];
        if (v === undefined) return `${p.label} …`;
        return `${p.label} ${formatPerf(v, p.format)}`;
      },
      detail: (c) => ({
        rows: [
          ["Value", c.perf[p.path] === undefined ? "sampling…" : formatPerf(c.perf[p.path], p.format)],
          ["Raw", c.perf[p.path] === undefined ? "—" : String(c.perf[p.path])],
          ["Counter", p.path],
        ],
        actions: [{ label: "Performance Monitor", cmd: "Start-Process perfmon" }],
      }),
    };
  }
  const cmd = (config.status_custom ?? []).find((x) => x.id === id);
  if (cmd) {
    return {
      label: cmd.label || cmd.command,
      render: (c) => {
        const v = c.custom[cmd.id];
        return v === undefined ? `${cmd.label} …` : `${cmd.label} ${v}`;
      },
      detail: (c) => ({
        rows: [
          ["Output", c.custom[cmd.id] ?? "—"],
          ["Command", cmd.command],
          ["Every", `${cmd.interval_s ?? 10}s`],
          ["Working folder", activeCwd() ?? "the active tab's folder"],
        ],
      }),
    };
  }
  return undefined;
}

function formatPerf(v: number, fmt?: string): string {
  switch (fmt) {
    case "bytes": return fmtBytes(v);
    case "rate": return fmtRate(v);
    case "pct": return pct(v);
    case "int": return String(Math.round(v));
    default: return v >= 100 ? String(Math.round(v)) : v.toFixed(2);
  }
}

/// The active tab's working directory, for command items that want it.
function activeCwd(): string | undefined {
  return activeId === null ? undefined : lastInfo.get(activeId)?.cwd;
}

async function sampleStatus() {
  if (!config.status_bar) return;
  const ids = statusItemIds();
  const needStats = ids.some((i) => STATUS_BUILTINS[i]);
  if (needStats) {
    const groups = [...new Set(ids.map((i) => STATUS_GROUPS[i]).filter(Boolean))];
    statusCtx.stats = await invoke<SystemStats>("system_stats", { groups }).catch(
      () => statusCtx.stats
    );
  }
  const paths = (config.status_perf ?? [])
    .filter((p) => ids.includes(p.id))
    .map((p) => p.path);
  if (paths.length) {
    const got = await invoke<Record<string, number>>("perf_counters", { paths }).catch(() => ({}));
    Object.assign(statusCtx.perf, got);
  }
  // Command items keep their own cadence — they cost a process each.
  const now = Date.now();
  for (const c of config.status_custom ?? []) {
    if (!ids.includes(c.id)) continue;
    const every = Math.max(2, c.interval_s ?? 10) * 1000;
    if (now - (customLastRun.get(c.id) ?? 0) < every) continue;
    customLastRun.set(c.id, now);
    // Always the active tab's folder: that is what makes `git branch`
    // and friends report on whatever the user is actually looking at.
    invoke<string>("status_command", { command: c.command, cwd: activeCwd() ?? null })
      .then((out) => {
        statusCtx.custom[c.id] = out;
        renderStatusBar();
      })
      .catch(() => {});
  }
  renderStatusBar();
  if (statusOpenId) renderStatusDetail(statusOpenId);
}

/// Widest pixel width each item has ever needed. Slots are held at this
/// width so a counter that swings between 1 and 5 digits stops shoving
/// everything beside it around; the mark resets when the bar is rebuilt.
const statusWidths = new Map<string, number>();
/// The same idea for the expanded panels, which re-render on every tick
/// while open: hold each at the largest size it has needed.
const statusDetailSizes = new Map<string, { w: number; h: number }>();

function renderStatusBar() {
  if (!config.status_bar) return;
  statusbarEl.innerHTML = "";
  const ids = statusItemIds();
  const rendered: Array<[string, HTMLElement]> = [];
  ids.forEach((id, i) => {
    const def = statusItemDef(id);
    if (!def) return;
    if (i === Math.floor(ids.length / 2)) {
      const spacer = document.createElement("div");
      spacer.className = "status-spacer";
      statusbarEl.appendChild(spacer);
    }
    const btn = document.createElement("button");
    btn.className = "status-item" + (statusOpenId === id ? " open" : "");
    btn.textContent = def.render(statusCtx);
    btn.title = `${def.label} — click for detail`;
    btn.dataset.item = id; // so the open detail panel can re-anchor to it
    const held = statusWidths.get(id);
    if (held) btn.style.minWidth = `${held}px`;
    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      toggleStatusDetail(id);
    });
    statusbarEl.appendChild(btn);
    rendered.push([id, btn]);
  });
  // Measure after everything is in the DOM: one layout pass per tick
  // rather than one per item.
  for (const [id, btn] of rendered) {
    const w = btn.offsetWidth;
    if (w > (statusWidths.get(id) ?? 0)) {
      statusWidths.set(id, w);
      btn.style.minWidth = `${w}px`;
    }
  }
}

function toggleStatusDetail(id: string) {
  if (statusOpenId === id) {
    closeStatusDetail();
    return;
  }
  statusOpenId = id;
  statusDetailEl.classList.add("open"); // must be laid out before measuring
  renderStatusDetail(id);
  renderStatusBar();
}

/// Centre the panel on its bar item and sit it just above the bar,
/// clamped inside the window. Re-run on every refresh so a panel that
/// grows stays anchored instead of drifting off its item.
function placeStatusDetail(id: string) {
  const anchor = statusbarEl.querySelector<HTMLElement>(`[data-item="${CSS.escape(id)}"]`);
  if (!anchor) return;
  const r = anchor.getBoundingClientRect();
  placeFloating(
    statusDetailEl,
    r.left + r.width / 2 - statusDetailEl.offsetWidth / 2,
    r.top - statusDetailEl.offsetHeight - 6
  );
}

function closeStatusDetail() {
  statusOpenId = null;
  statusDetailEl.classList.remove("open");
  renderStatusBar();
}

function renderStatusDetail(id: string) {
  const def = statusItemDef(id);
  if (!def) {
    closeStatusDetail();
    return;
  }
  const d = def.detail?.(statusCtx) ?? { rows: [["Value", def.render(statusCtx)]] };
  statusDetailEl.innerHTML = "";
  const title = document.createElement("div");
  title.className = "sd-title";
  title.textContent = def.label;
  statusDetailEl.appendChild(title);
  for (const [k, v] of d.rows) {
    const row = document.createElement("div");
    row.className = "sd-row";
    const kk = document.createElement("span");
    kk.className = "sd-label";
    kk.textContent = k;
    const vv = document.createElement("span");
    vv.className = "sd-value";
    vv.textContent = v;
    row.append(kk, vv);
    statusDetailEl.appendChild(row);
  }
  if (d.links?.length || d.actions?.length) {
    const bar = document.createElement("div");
    bar.className = "sd-links";
    for (const l of d.links ?? []) {
      const b = document.createElement("button");
      b.textContent = l.label;
      b.addEventListener("click", () => void openUrl(l.url).catch(() => {}));
      bar.appendChild(b);
    }
    for (const a of d.actions ?? []) {
      const b = document.createElement("button");
      b.textContent = a.label;
      b.addEventListener("click", () => {
        void invoke("status_command", { command: a.cmd, cwd: null }).catch(() => {});
      });
      bar.appendChild(b);
    }
    statusDetailEl.appendChild(bar);
  }
  // Same treatment as the bar itself: hold the panel at the largest size
  // it has needed so live values can't resize it under the pointer. The
  // marks are per item, so each panel settles after a tick or two.
  const held = statusDetailSizes.get(id);
  if (held) {
    statusDetailEl.style.minWidth = `${held.w}px`;
    statusDetailEl.style.minHeight = `${held.h}px`;
  } else {
    statusDetailEl.style.minWidth = "";
    statusDetailEl.style.minHeight = "";
  }
  const w = statusDetailEl.offsetWidth;
  const h = statusDetailEl.offsetHeight;
  if (w > (held?.w ?? 0) || h > (held?.h ?? 0)) {
    const next = { w: Math.max(w, held?.w ?? 0), h: Math.max(h, held?.h ?? 0) };
    statusDetailSizes.set(id, next);
    statusDetailEl.style.minWidth = `${next.w}px`;
    statusDetailEl.style.minHeight = `${next.h}px`;
  }
  placeStatusDetail(id);
}

/// Pick any PDH counter on this machine: object → instance → counter.
/// Enumeration comes straight from PDH, so whatever Performance Monitor
/// can show, this can too.
async function openPerfBrowser() {
  document.getElementById("perf-overlay")?.remove();
  const ov = document.createElement("div");
  ov.id = "perf-overlay";
  ov.className = "overlay";
  const box = document.createElement("div");
  box.className = "overlay-box";
  const title = document.createElement("div");
  title.className = "settings-h1";
  const h = document.createElement("span");
  h.textContent = "Performance counters";
  const close = document.createElement("button");
  close.id = "settings-close";
  close.textContent = "×";
  close.addEventListener("click", () => ov.remove());
  title.append(h, close);
  const note = document.createElement("div");
  note.className = "setting-desc";
  note.textContent = "Loading objects…";
  const grid = document.createElement("div");
  grid.className = "perf-grid";
  // size > 1 renders these as scrolling lists rather than dropdowns —
  // the lists are long and you browse them by eye.
  const objSel = document.createElement("select");
  objSel.className = "set-control";
  objSel.size = 12;
  const instSel = document.createElement("select");
  instSel.className = "set-control";
  instSel.size = 12;
  const cntSel = document.createElement("select");
  cntSel.className = "set-control";
  cntSel.size = 12;
  const pathOut = document.createElement("input");
  pathOut.className = "set-control set-wide";
  pathOut.readOnly = true;
  const add = document.createElement("button");
  add.className = "set-btn";
  add.textContent = "Add to status bar";
  grid.append(objSel, instSel, cntSel);
  box.append(title, note, grid, pathOut, add);
  ov.appendChild(box);
  ov.addEventListener("mousedown", (e) => {
    if (e.target === ov) ov.remove();
  });
  document.body.appendChild(ov);

  const composePath = () => {
    const obj = objSel.value;
    const inst = instSel.value;
    const cnt = cntSel.value;
    if (!obj || !cnt) return "";
    return inst ? `\\${obj}(${inst})\\${cnt}` : `\\${obj}\\${cnt}`;
  };
  const refreshPath = () => {
    pathOut.value = composePath();
  };
  const fill = (sel: HTMLSelectElement, values: string[], blankLabel?: string) => {
    sel.innerHTML = "";
    if (blankLabel) {
      const o = document.createElement("option");
      o.value = "";
      o.textContent = blankLabel;
      sel.appendChild(o);
    }
    for (const v of values) {
      const o = document.createElement("option");
      o.value = v;
      o.textContent = v;
      sel.appendChild(o);
    }
  };

  const objects = await invoke<string[]>("perf_objects").catch((e) => {
    note.textContent = `Could not enumerate counters: ${e}`;
    return [] as string[];
  });
  if (!objects.length) return;
  note.textContent = `${objects.length} objects. Pick an object, then an instance and counter.`;
  fill(objSel, objects);
  const loadItems = async () => {
    const empty: { counters: string[]; instances: string[] } = { counters: [], instances: [] };
    const items = await invoke<{ counters: string[]; instances: string[] }>("perf_items", {
      object: objSel.value,
    }).catch(() => empty);
    fill(cntSel, items.counters);
    fill(instSel, items.instances, items.instances.length ? "(pick instance)" : "(no instances)");
    if (items.instances.includes("_Total")) instSel.value = "_Total";
    refreshPath();
  };
  objSel.value = objects.includes("Processor") ? "Processor" : objects[0];
  await loadItems();
  objSel.addEventListener("change", () => void loadItems());
  instSel.addEventListener("change", refreshPath);
  cntSel.addEventListener("change", refreshPath);
  add.addEventListener("click", () => {
    const path = composePath();
    if (!path) return;
    const id = `perf-${Date.now().toString(36)}`;
    config.status_perf = [
      ...(config.status_perf ?? []),
      { id, label: cntSel.value.split("/")[0].trim().slice(0, 18), path, format: "raw" },
    ];
    config.status_items = [...statusItemIds(), id];
    saveConfig();
    applyStatusBar();
    ov.remove();
    buildSettingsPage();
  });
}

/// Shared by both key paths: the window-level handler ignores anything
/// typed inside a terminal, so the per-terminal handler has to offer the
/// same shortcut or it never fires while you're actually typing.
function toggleStatusBar() {
  config.status_bar = !(config.status_bar ?? true);
  saveConfig();
  applyStatusBar();
}

function applyStatusBar() {
  const on = config.status_bar ?? true;
  config.status_bar = on;
  // Item set or order may have changed; re-earn the size marks.
  statusWidths.clear();
  statusDetailSizes.clear();
  app.classList.toggle("status-on", on);
  if (!on) closeStatusDetail();
  window.clearInterval(statusTimer);
  if (on) {
    renderStatusBar();
    void sampleStatus();
    statusTimer = window.setInterval(
      () => void sampleStatus(),
      Math.max(250, config.status_interval_ms ?? 2000)
    );
    // A resized window can leave the detail panel hanging off the edge.
    if (statusOpenId) closeStatusDetail();
  }
}

async function main() {
  config = await invoke<AppConfig>("get_config").catch(() => ({}));
  registerCustomThemes();
  applyTheme(config.theme ?? localStorage.getItem("gterm-theme") ?? "one-dark");
  applyBackground();
  // The window starts hidden (tauri.conf visible:false) so users never
  // see the webview's white pre-paint flash; show once themed.
  void getCurrentWindow().show();
  launchInfo = await invoke<LaunchInfo>("launch_info").catch(() => null);
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
    aiTitleLastRun.delete(event.payload.id);
    removeTab(event.payload.id);
    // Let the daemon finish its exit/trash transition, then show the
    // session's "closes in Xm" row.
    window.setTimeout(() => refreshChrome(), 500);
  });

  // New-session picker: both click and right-click list every way to
  // start a session — default shell, templates, one-off shells.
  // (Ctrl+Shift+T stays the instant default-shell path.)
  const newShellMenu = (e: MouseEvent) => {
    e.preventDefault();
    e.stopPropagation();
    closeMenus();
    const items: CtxItem[] = [
      { label: "New tab — default shell", action: () => createTab() },
    ];
    const tpls = (config.templates ?? []).filter((t) => t.name.trim());
    if (tpls.length) {
      items.push("sep");
      for (const t of tpls) {
        items.push({ label: t.name, action: () => createTab(undefined, t.shell, t.cwd, t.title) });
      }
    }
    items.push("sep");
    items.push(
      ...SHELL_CHOICES.filter(([v]) => v !== "auto").map(([v, label]): CtxItem => ({
        label: `New ${label} tab`,
        action: () => createTab(undefined, v),
      }))
    );
    showContextMenu(e.clientX, e.clientY, items);
  };
  // Splitting needs a control you can see: it was keyboard-only plus a
  // context-menu entry, which is no way to discover a feature.
  const splitBtn = document.getElementById("splitbtn")!;
  splitBtn.addEventListener("click", (e) => {
    e.stopPropagation();
    void splitPane("row");
  });
  splitBtn.addEventListener("contextmenu", (e) => {
    e.preventDefault();
    e.stopPropagation();
    closeMenus();
    showContextMenu(e.clientX, e.clientY, [
      { label: "Split right (Ctrl+Shift+D)", action: () => void splitPane("row") },
      { label: "Split down (Ctrl+Shift+E)", action: () => void splitPane("col") },
      "sep",
      { label: "Arrange panes… (Ctrl+Shift+A)", action: () => openArrange() },
      { label: "Zoom pane (Ctrl+Shift+M)", action: () => toggleZoom() },
    ]);
  });

  const newTabBtn = document.getElementById("newtab")!;
  newTabBtn.addEventListener("click", newShellMenu);
  newTabBtn.addEventListener("contextmenu", newShellMenu);
  const sidebarNewBtn = document.getElementById("sidebar-new")!;
  sidebarNewBtn.addEventListener("click", newShellMenu);
  sidebarNewBtn.addEventListener("contextmenu", newShellMenu);
  document.getElementById("sidebtn")!.addEventListener("click", toggleSidebar);
  initSidebarResize();
  document.getElementById("zenbtn")!.addEventListener("click", () => void toggleZen());
  initZenPill();
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
  const settingsBtn = document.getElementById("settingsbtn")!;
  settingsBtn.addEventListener("click", (e) => {
    e.stopPropagation();
    closeMenus();
    closeHistory();
    if (settingsOpen()) closeSettings();
    else openSettings();
  });
  // Custom window controls (native title bar is off). Close detaches —
  // the daemon keeps every session running, same as before.
  const win = getCurrentWindow();
  document.getElementById("win-min")!.addEventListener("click", () => void win.minimize());
  document.getElementById("win-max")!.addEventListener("click", () => void win.toggleMaximize());
  document.getElementById("win-close")!.addEventListener("click", () => void win.close());
  const historyBtn = document.getElementById("historybtn")!;
  historyBtn.addEventListener("click", (e) => {
    e.stopPropagation();
    closeMenus();
    closeSettings();
    if (historyOpen()) closeHistory();
    else openHistory();
  });
  document.getElementById("history-close")!.addEventListener("click", closeHistory);
  document.getElementById("history-back")!.addEventListener("click", closeViewer);
  const histSearch = document.getElementById("history-search") as HTMLInputElement;
  histSearch.addEventListener("keydown", (e) => {
    if (e.key === "Enter") void buildHistoryPage(histSearch.value);
  });
  window.addEventListener("resize", () => viewerFit?.fit());
  document.addEventListener("mousedown", (e) => {
    const target = e.target as Node;
    for (const m of [restoreMenu, overflowMenu, hiddenMenu, ctxMenu]) {
      if (m.classList.contains("open") && !m.contains(target)) {
        m.classList.remove("open");
      }
    }
    if (statusOpenId && !statusDetailEl.contains(target) && !statusbarEl.contains(target)) {
      closeStatusDetail();
    }
  });
  // Suppress the WebView2 default context menu everywhere ("Send to
  // devices", "Web capture", etc.) — the app provides its own menus.
  window.addEventListener("contextmenu", (e) => e.preventDefault());
  document.getElementById("settings-close")!.addEventListener("click", closeSettings);
  window.addEventListener("keydown", (e) => {
    // Keystrokes inside a terminal are handled by that terminal's own
    // shortcut handler; letting them also reach this global handler
    // double-fires every shortcut (F11 would toggle zen on and off).
    if ((e.target as HTMLElement)?.closest?.(".xterm")) return;
    if (e.key === "F11") {
      e.preventDefault();
      void toggleZen();
      return;
    }
    if (e.key === "Escape" && arrangeKey !== undefined) {
      e.preventDefault();
      closeArrange();
      return;
    }
    if (e.key === "Escape" && app.classList.contains("zen-on")) {
      e.preventDefault();
      void toggleZen();
      return;
    }
    if (e.key === "Escape" && statusOpenId) {
      e.preventDefault();
      closeStatusDetail();
      return;
    }
    if (e.key === "Escape") {
      const badgeOv = document.getElementById("badge-overlay");
      if (badgeOv) {
        e.preventDefault();
        badgeOv.remove();
        return;
      }
      if (document.getElementById("clip-overlay")) {
        e.preventDefault();
        closeClipViewer();
        return;
      }
      if (document.getElementById("history-viewer")!.classList.contains("open")) {
        e.preventDefault();
        closeViewer();
        return;
      }
      if (historyOpen()) {
        e.preventDefault();
        closeHistory();
        return;
      }
      if (settingsOpen()) {
        e.preventDefault();
        closeSettings();
        return;
      }
    }
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
    if (e.ctrlKey && e.shiftKey && e.key.toUpperCase() === "S") {
      e.preventDefault();
      toggleStatusBar();
    }
    // Arrange mode blurs the terminal, so its own toggle has to work from
    // out here too — otherwise the key that opens it can't close it.
    if (e.ctrlKey && e.shiftKey && e.key.toUpperCase() === "A") {
      e.preventDefault();
      toggleArrange();
    }
  });
  // Ctrl+scroll over the tab bar resizes tabs live.
  document.getElementById("tabbar-row")!.addEventListener(
    "wheel",
    (e) => {
      if (!e.ctrlKey) return;
      e.preventDefault();
      const cur = config.tab_width ?? 220;
      config.tab_width = Math.min(400, Math.max(110, cur + (e.deltaY < 0 ? 12 : -12)));
      document.documentElement.style.setProperty("--tab-w", `${config.tab_width}px`);
      saveConfig();
    },
    { passive: false }
  );
  // Holding Alt labels the panes; releasing it (or losing the window)
  // clears them. Capture phase so it still fires with a terminal focused.
  window.addEventListener(
    "keydown",
    (e) => {
      if (e.key === "Alt" && !e.ctrlKey && !e.shiftKey) showPaneNumbers(true);
    },
    true
  );
  window.addEventListener(
    "keyup",
    (e) => {
      if (e.key === "Alt") showPaneNumbers(false);
    },
    true
  );
  window.addEventListener("blur", () => showPaneNumbers(false));

  new ResizeObserver(() => refreshChrome()).observe(tabbar);
  startFpsMeter();
  applyStatusBar();
  window.setInterval(updateLiveInfo, 5000);
  window.setInterval(aiAutoTitleTick, 120_000);

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
  for (const k of Object.keys(customBadges)) {
    if (!known.has(Number(k))) delete customBadges[k];
  }
  saveCustomBadges();
  // Restore last session's tab order; unknown sessions go to the end.
  const savedOrder: number[] = JSON.parse(localStorage.getItem("gterm-order") ?? "[]");
  const rank = (id: number) => {
    const i = savedOrder.indexOf(id);
    return i === -1 ? Number.MAX_SAFE_INTEGER : i;
  };
  sessions.sort((a, b) => rank(a.id) - rank(b.id) || a.created_ms - b.created_ms);
  // Never re-adopt a session the user closed: attaching cancels its
  // pending kill, so an app restart would resurrect every tab still in
  // its grace window. They stay under "Closing soon" instead.
  const adoptable = sessions.filter((s) => !s.expires_ms && !hidden.has(s.id));
  const alive = new Set(adoptable.map((s) => s.id));

  // Rebuild saved pane trees first, in the saved tab order. Any leaf whose
  // session is gone is pruned out, and a tab whose sessions have all gone
  // simply doesn't come back.
  const savedLayouts = loadLayouts();
  const placed = new Set<number>();
  for (const key of savedOrder) {
    const entry = savedLayouts[key];
    if (!entry) continue;
    const tree = pruneTree(entry.root, alive);
    if (!tree) continue;
    const leaves = leavesOf(tree).filter((l) => !placed.has(l));
    if (!leaves.length) continue;
    const owner = leaves[0];
    if ((await createTab(owner)) === undefined) continue;
    placed.add(owner);
    for (const leaf of leaves.slice(1)) {
      if ((await createTab(leaf, undefined, undefined, undefined, owner)) === undefined) continue;
      placed.add(leaf);
      paneTab.set(leaf, owner);
    }
    // Re-prune to whatever actually attached, so a session that failed to
    // come back can't leave a hole in the tree.
    const attached = pruneTree(tree, new Set(leaves.filter((l) => tabs.has(l))));
    if (attached) layouts.set(owner, attached);
    tabFocus.set(owner, tabs.has(entry.focus) ? entry.focus : owner);
    renderLayout(owner);
    fitPanes(owner);
  }
  // Anything the layouts didn't account for opens as its own tab.
  for (const s of adoptable) {
    if (!placed.has(s.id)) await createTab(s.id);
  }
  saveLayouts();
  // `--workspace <name>` (e.g. from a shortcut) opens every template the
  // named workspace lists, on top of whatever sessions were adopted.
  const wsArgs = launchInfo?.args ?? [];
  const wsAt = wsArgs.indexOf("--workspace");
  const wsName = wsAt >= 0 ? wsArgs[wsAt + 1]?.trim() : undefined;
  if (wsName) {
    const ws = (config.workspaces ?? []).find(
      (w) => w.name.trim().toLowerCase() === wsName.toLowerCase()
    );
    for (const tplName of ws?.templates ?? []) {
      const t = (config.templates ?? []).find(
        (x) => x.name.trim().toLowerCase() === tplName.trim().toLowerCase()
      );
      if (t) await createTab(undefined, t.shell, t.cwd, t.title);
    }
  }
  if (tabCount() === 0) await createTab();
  refreshChrome();
}

main();
