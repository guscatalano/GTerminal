import { invoke, convertFileSrc } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { getCurrentWindow } from "@tauri-apps/api/window";
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
  history_days?: number;
  prediction?: string;
  title_mode?: string;
  title_template?: string;
  bg_style?: string;
  bg_image?: string;
  bg_dim?: number;
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
  const image = resolvedBgCss();
  if (!image) {
    panes.style.background = "";
    return;
  }
  // Theme-built-in art is already palette-matched and subtle; presets and
  // images get the dim overlay for readability.
  const isThemeArt = (config.bg_style ?? "theme") === "theme";
  const dim = Math.min(0.95, Math.max(0, (config.bg_dim ?? 50) / 100));
  const overlay = hexToRgba(currentTheme().xterm.background ?? "#0f1115", dim);
  panes.style.background = isThemeArt
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

// ── drag-and-drop reordering ────────────────────────────────────────────
let dragId: number | null = null;

function clearDropMarkers() {
  for (const el of tabbar.querySelectorAll(".drop-before, .drop-after, .drop-into")) {
    el.classList.remove("drop-before", "drop-after", "drop-into");
  }
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
  xterm: ITheme;
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
  "one-dark": mkTheme("One Dark", "white", ['"Cascadia Mono", Consolas, monospace', 1.1, "bar"], "radial-gradient(ellipse 55% 40% at 78% 12%, rgba(97,175,239,0.3), transparent 65%), linear-gradient(115deg, transparent 42%, rgba(198,120,221,0.1) 50%, transparent 58%), linear-gradient(200deg, #131a2b, #0a0c12)", "#0f1115", "#d7dae0", [
    "#1c1f26", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#d7dae0",
    "#5c6370", "#ef7d85", "#a9d387", "#f0cd8a", "#74bdf7", "#d48ce8", "#67c5d0", "#f0f2f6",
  ]),
  dracula: mkTheme("Dracula", "white", ['"Cascadia Code", "Cascadia Mono", monospace', 1.15, "block"], "radial-gradient(circle at 80% 20%, rgba(248,248,242,0.12) 0 110px, rgba(189,147,249,0.3) 112px 128px, transparent 130px), radial-gradient(ellipse 90% 60% at 78% 18%, rgba(189,147,249,0.28), transparent 60%), radial-gradient(ellipse 70% 50% at 15% 100%, rgba(255,121,198,0.14), transparent 60%), linear-gradient(210deg, #2c2745, #16171f)", "#282a36", "#f8f8f2", [
    "#21222c", "#ff5555", "#50fa7b", "#f1fa8c", "#bd93f9", "#ff79c6", "#8be9fd", "#f8f8f2",
    "#6272a4", "#ff6e6e", "#69ff94", "#ffffa5", "#d6acff", "#ff92df", "#a4ffff", "#ffffff",
  ]),
  nord: mkTheme("Nord", "white", ['"Cascadia Mono", Consolas, monospace', 1.2, "bar"], "linear-gradient(100deg, transparent 18%, rgba(136,192,208,0.26) 30%, transparent 42%), linear-gradient(95deg, transparent 42%, rgba(163,190,140,0.18) 53%, transparent 64%), linear-gradient(107deg, transparent 62%, rgba(180,142,173,0.16) 72%, transparent 84%), linear-gradient(180deg, #1e222b 0%, #2e3440 60%, #272c37 100%)", "#2e3440", "#d8dee9", [
    "#3b4252", "#bf616a", "#a3be8c", "#ebcb8b", "#81a1c1", "#b48ead", "#88c0d0", "#e5e9f0",
    "#7b88a1", "#bf616a", "#a3be8c", "#f4dda1", "#81a1c1", "#b48ead", "#8fbcbb", "#eceff4",
  ]),
  gruvbox: mkTheme("Gruvbox Dark", "white", ["Consolas, monospace", 1.1, "block"], "radial-gradient(ellipse 75% 40% at 50% 112%, rgba(251,73,52,0.32), transparent 65%), linear-gradient(0deg, rgba(215,153,33,0.22) 0%, transparent 32%), linear-gradient(0deg, rgba(254,128,25,0.12) 8%, transparent 45%), linear-gradient(180deg, #171512, #322d26)", "#282828", "#ebdbb2", [
    "#282828", "#fb4934", "#98971a", "#d79921", "#458588", "#b16286", "#689d6a", "#a89984",
    "#928374", "#fb4934", "#b8bb26", "#fabd2f", "#83a598", "#d3869b", "#8ec07c", "#ebdbb2",
  ]),
  "tokyo-night": mkTheme("Tokyo Night", "white", ['"Cascadia Code", "Cascadia Mono", monospace', 1.15, "bar"], "repeating-linear-gradient(0deg, rgba(122,162,247,0.13) 0 1px, transparent 1px 38px), repeating-linear-gradient(90deg, rgba(122,162,247,0.13) 0 1px, transparent 1px 38px), radial-gradient(ellipse 85% 50% at 50% 0%, rgba(187,154,247,0.34), transparent 62%), linear-gradient(180deg, #171830, #0d0e1a)", "#1a1b26", "#c0caf5", [
    "#15161e", "#f7768e", "#9ece6a", "#e0af68", "#7aa2f7", "#bb9af7", "#7dcfff", "#a9b1d6",
    "#7982b4", "#f7768e", "#9ece6a", "#e0af68", "#7aa2f7", "#bb9af7", "#7dcfff", "#c0caf5",
  ]),
  catppuccin: mkTheme("Catppuccin Mocha", "white", ['"Cascadia Mono", Consolas, monospace', 1.2, "bar"], "radial-gradient(circle at 18% 25%, rgba(245,194,231,0.2) 0 70px, transparent 110px), radial-gradient(circle at 78% 18%, rgba(137,180,250,0.18) 0 90px, transparent 140px), radial-gradient(circle at 62% 78%, rgba(166,227,161,0.13) 0 80px, transparent 130px), radial-gradient(circle at 28% 85%, rgba(250,179,135,0.16) 0 60px, transparent 100px), linear-gradient(180deg, #1e1e30, #141420)", "#1e1e2e", "#cdd6f4", [
    "#45475a", "#f38ba8", "#a6e3a1", "#f9e2af", "#89b4fa", "#f5c2e7", "#94e2d5", "#bac2de",
    "#7f849c", "#f38ba8", "#a6e3a1", "#f9e2af", "#89b4fa", "#f5c2e7", "#94e2d5", "#a6adc8",
  ]),
  "solarized-dark": mkTheme("Solarized Dark", "white", ["Consolas, monospace", 1.1, "underline"], "linear-gradient(180deg, rgba(42,161,152,0.3) 0%, transparent 32%), linear-gradient(180deg, transparent 55%, rgba(0,8,12,0.5) 100%), radial-gradient(ellipse 90% 45% at 50% -5%, rgba(147,161,161,0.16), transparent 60%), linear-gradient(180deg, #00323f, #001217)", "#002b36", "#839496", [
    "#073642", "#dc322f", "#859900", "#b58900", "#268bd2", "#d33682", "#2aa198", "#eee8d5",
    "#657b83", "#cb4b16", "#78909a", "#eed968", "#839496", "#6c71c4", "#93a1a1", "#fdf6e3",
  ]),
  "solarized-light": mkTheme("Solarized Light", "black", ["Consolas, monospace", 1.1, "underline"], "radial-gradient(circle at 80% 10%, rgba(181,137,0,0.38) 0 70px, rgba(203,75,22,0.16) 72px 130px, transparent 200px), radial-gradient(ellipse 100% 55% at 50% 0%, rgba(203,75,22,0.08), transparent 55%), linear-gradient(180deg, #fdf6e3, #eadfc0)", "#fdf6e3", "#586e75", [
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
  `url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='180' height='180'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.85' numOctaves='2'/%3E%3CfeColorMatrix values='0 0 0 0 1 0 0 0 0 1 0 0 0 0 1 0 0 0 0.05 0'/%3E%3C/filter%3E%3Crect width='180' height='180' filter='url(%23n)'/%3E%3C/svg%3E") repeat, radial-gradient(90% 70% at 50% 35%, rgba(237,255,69,0.07), transparent 55%), radial-gradient(140% 110% at 50% 50%, transparent 45%, rgba(0,0,110,0.6) 100%), linear-gradient(0deg, #0000f2, #0000f2)`,
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
  `url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='160' height='160'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.9' numOctaves='2'/%3E%3CfeColorMatrix values='0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0.06 0'/%3E%3C/filter%3E%3Crect width='160' height='160' filter='url(%23n)'/%3E%3C/svg%3E") repeat, radial-gradient(100% 80% at 50% 0%, rgba(4,113,169,0.09), transparent 55%), radial-gradient(130% 100% at 50% 55%, transparent 55%, rgba(4,42,64,0.14) 100%), linear-gradient(180deg, #fbfaf7, #f1efe9)`,
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
  "linear-gradient(100deg, transparent 68%, rgba(249,38,114,0.14) 68.5% 72%, transparent 72.5%), linear-gradient(100deg, transparent 74%, rgba(166,226,46,0.12) 74.5% 77%, transparent 77.5%), linear-gradient(100deg, transparent 79%, rgba(102,217,239,0.12) 79.5% 81.5%, transparent 82%), radial-gradient(ellipse 70% 50% at 20% 0%, rgba(230,219,116,0.1), transparent 60%), linear-gradient(180deg, #2b2c24, #21221c)",
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
  "repeating-linear-gradient(180deg, rgba(0,0,0,0.35) 0 1px, transparent 1px 3px), radial-gradient(ellipse 90% 80% at 50% 45%, rgba(255,176,0,0.13), transparent 70%), radial-gradient(ellipse 140% 110% at 50% 50%, transparent 55%, rgba(0,0,0,0.55) 100%), linear-gradient(180deg, #140d02, #0a0600)",
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
  "radial-gradient(ellipse 90% 55% at 25% 118%, rgba(88,118,98,0.5), transparent 65%), radial-gradient(ellipse 90% 55% at 80% 122%, rgba(64,92,76,0.55), transparent 68%), radial-gradient(ellipse 100% 40% at 50% -5%, rgba(219,188,127,0.11), transparent 55%), linear-gradient(180deg, #333c43, #262d33)",
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
  "linear-gradient(90deg, transparent 0 14%, rgba(0,229,255,0.4) 14.05% 14.3%, transparent 14.6%), linear-gradient(0deg, transparent 0 22%, rgba(0,229,255,0.3) 22.05% 22.3%, transparent 22.6%), linear-gradient(90deg, transparent 0 88%, rgba(255,136,54,0.35) 88.05% 88.3%, transparent 88.6%), radial-gradient(ellipse 70% 45% at 50% 110%, rgba(0,140,180,0.2), transparent 65%), linear-gradient(180deg, #060a10, #04060a)",
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
  "linear-gradient(180deg, #ff9933 0 18%, #000 18% 19.5%, #9999ff 19.5% 34%, #000 34% 35.5%, #cc99cc 35.5% 46%, #000 46% 47.5%, #ffcc66 47.5% 70%, #000 70% 71.5%, #e07a66 71.5% 100%) left/7px 100% no-repeat, radial-gradient(circle at 0% 0%, transparent 56px, rgba(255,153,51,0.55) 58px 64px, transparent 66px) no-repeat, linear-gradient(#000, #000)",
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
  "repeating-linear-gradient(0deg, rgba(8,32,8,0.4) 0 1px, transparent 1px 3px), repeating-linear-gradient(90deg, rgba(8,32,8,0.4) 0 1px, transparent 1px 3px), radial-gradient(ellipse 80% 50% at 50% 0%, rgba(155,188,15,0.12), transparent 60%), linear-gradient(180deg, #123f12, #0c2e0c)",
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

let themeKey = "one-dark";
function currentTheme(): ThemeDef {
  return THEMES[themeKey] ?? THEMES["one-dark"];
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
  // Hex8 form: xterm's color parser handles it reliably everywhere.
  return bgActive() ? { ...t, background: "#00000000" } : t;
}

/// Push current appearance settings into every open terminal, switching
/// renderers live: WebGL can't composite transparency, so tabs move to the
/// DOM renderer while a background is active and back to WebGL without one.
function applyAppearance() {
  applyBackground();
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
  applyAppearance();
  config.theme = themeKey;
  saveConfig();
}

function orderedIds(): number[] {
  return [...tabbar.querySelectorAll<HTMLElement>(".tab")].map((el) => Number(el.dataset.id));
}

function setActive(id: number) {
  const tab = tabs.get(id);
  if (!tab) return;
  closeSettings();
  activeId = id;
  for (const [tid, t] of tabs) {
    t.pane.classList.toggle("active", tid === id);
    t.button.classList.toggle("active", tid === id);
  }
  fitTab(tab);
  tab.term.focus();
  refreshChrome();
  // Re-assert focus after the chrome rebuild settles so a click in the
  // sidebar (or anywhere in the bar) always ends with the terminal ready
  // to type into.
  requestAnimationFrame(() => {
    if (activeId === id && !renameActive) tab.term.focus();
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

async function createTab(attachId?: number, shell?: string, cwd?: string, title?: string) {
  const pane = document.createElement("div");
  pane.className = "pane active";
  panes.appendChild(pane);

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
  button.append(icon, label, hide, close);
  tabbar.appendChild(button);
  tabOrder.push(id);
  saveOrder();

  const tab: Tab = { id, term, fit, pane, button, label, icon, webgl };
  tabs.set(id, tab);

  button.addEventListener("mousedown", (e) => {
    if (e.target !== close && e.target !== hide) setActive(id);
  });
  button.addEventListener("dblclick", (e) => {
    if (e.target === label) renameTab(id);
  });
  button.draggable = true;
  button.addEventListener("dragstart", (e) => {
    dragId = id;
    e.dataTransfer!.effectAllowed = "move";
    button.classList.add("dragging");
  });
  button.addEventListener("dragend", () => {
    dragId = null;
    button.classList.remove("dragging");
    clearDropMarkers();
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
    const sel = term.getSelection();
    const items: CtxItem[] = [];
    if (sel) {
      items.push({
        label: "Copy",
        action: () => {
          navigator.clipboard.writeText(sel).catch(() => {});
          term.clearSelection();
        },
      });
    }
    items.push({ label: "Paste", action: paste });
    items.push("sep", {
      label: "Select all",
      action: () => term.selectAll(),
    });
    showContextMenu(e.clientX, e.clientY, items);
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
  saveOrder();
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

function settingsOpen(): boolean {
  return app.classList.contains("settings-on");
}

function openSettings() {
  buildSettingsPage();
  app.classList.add("settings-on");
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
  ctxMenu.style.left = `${Math.min(x, window.innerWidth - ctxMenu.offsetWidth - 8)}px`;
  ctxMenu.style.top = `${Math.min(y, window.innerHeight - ctxMenu.offsetHeight - 8)}px`;
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
  aiTitles[id] = title;
  saveAiTitles();
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
    addHeader(g.name, g.color);
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
  settingsList.innerHTML = "";
  const changed = () => {
    applyAppearance();
    saveConfig();
  };

  settingsSection("Appearance");
  settingRow(
    "Theme",
    "Colors, plus each theme's default font, spacing, and cursor personality.",
    mkSelect(
      Object.entries(THEMES).map(([k, t]) => [k, t.label] as [string, string]),
      themeKey,
      (v) => {
        applyTheme(v);
        buildSettingsPage();
      }
    )
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
    "",
    mkSelect([["on", "On"], ["off", "Off"]], effCursorBlink() ? "on" : "off", (v) => {
      config.cursor_blink = v === "on";
      changed();
    })
  );
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
      config.bg_style ?? "theme",
      (v) => {
        config.bg_style = v === "theme" ? undefined : v;
        changed();
      }
    )
  );
  const bgInput = document.createElement("input");
  bgInput.className = "set-control set-wide";
  bgInput.type = "text";
  bgInput.placeholder = "C:\\path\\to\\image.jpg or https://…";
  bgInput.value = config.bg_image ?? "";
  bgInput.addEventListener("change", () => {
    config.bg_image = bgInput.value.trim() || undefined;
    changed();
  });
  settingRow("Background image", "Used when Background is Custom image. Local file path or URL.", bgInput);
  settingRow(
    "Background dim (%)",
    "How strongly the theme color covers the background — higher keeps text more readable.",
    mkNumber(config.bg_dim ?? 50, 0, 95, (v) => {
      config.bg_dim = v;
      changed();
    })
  );

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
      }
    )
  );
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
    "Used when style is Custom. Placeholders: {program} {folder} {parent} {path} {shell} {title}. Join parts with ·",
    tplInput
  );

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
    cwdInput
  );
  // Session templates: named presets combining shell, folder, and title.
  const mkTplInput = (ph: string, value: string, onChange: (v: string) => void) => {
    const input = document.createElement("input");
    input.className = "set-control";
    input.type = "text";
    input.placeholder = ph;
    input.value = value;
    input.addEventListener("change", () => onChange(input.value.trim()));
    return input;
  };
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
      row.append(name, shellSel, cwd, title, del);
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
}

async function main() {
  config = await invoke<AppConfig>("get_config").catch(() => ({}));
  applyTheme(config.theme ?? localStorage.getItem("gterm-theme") ?? "one-dark");
  applyBackground();
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

  const newShellMenu = (e: MouseEvent) => {
    e.preventDefault();
    e.stopPropagation();
    const items: CtxItem[] = (config.templates ?? [])
      .filter((t) => t.name.trim())
      .map((t) => ({
        label: t.name,
        action: () => createTab(undefined, t.shell, t.cwd, t.title),
      }));
    if (items.length) items.push("sep");
    items.push(
      ...SHELL_CHOICES.filter(([v]) => v !== "auto").map(([v, label]): CtxItem => ({
        label: `New ${label} tab`,
        action: () => createTab(undefined, v),
      }))
    );
    showContextMenu(e.clientX, e.clientY, items);
  };
  const newTabBtn = document.getElementById("newtab")!;
  newTabBtn.addEventListener("click", () => createTab());
  newTabBtn.addEventListener("contextmenu", newShellMenu);
  const sidebarNewBtn = document.getElementById("sidebar-new")!;
  sidebarNewBtn.addEventListener("click", () => createTab());
  sidebarNewBtn.addEventListener("contextmenu", newShellMenu);
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
  const settingsBtn = document.getElementById("settingsbtn")!;
  settingsBtn.addEventListener("click", (e) => {
    e.stopPropagation();
    closeMenus();
    closeHistory();
    if (settingsOpen()) closeSettings();
    else openSettings();
  });
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
  });
  // Suppress the WebView2 default context menu everywhere ("Send to
  // devices", "Web capture", etc.) — the app provides its own menus.
  window.addEventListener("contextmenu", (e) => e.preventDefault());
  document.getElementById("settings-close")!.addEventListener("click", closeSettings);
  window.addEventListener("keydown", (e) => {
    if (e.key === "Escape") {
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
  });
  new ResizeObserver(() => refreshChrome()).observe(tabbar);
  window.setInterval(updateLiveInfo, 5000);
  window.setInterval(aiAutoTitleTick, 120_000);

  // Drag-and-drop reordering, with group awareness: dropping between a
  // group's members joins it, past its right edge leaves it, onto the
  // chip adds at the front.
  tabbar.addEventListener("dragover", (e) => {
    if (dragId === null) return;
    e.preventDefault();
    e.dataTransfer!.dropEffect = "move";
    clearDropMarkers();
    const target = (e.target as HTMLElement).closest(".tab, .group-chip") as HTMLElement | null;
    if (!target || Number(target.dataset.id) === dragId) return;
    if (target.classList.contains("group-chip")) {
      target.classList.add("drop-into");
      return;
    }
    const rect = target.getBoundingClientRect();
    const before = e.clientX < rect.left + rect.width / 2;
    target.classList.add(before ? "drop-before" : "drop-after");
  });
  tabbar.addEventListener("drop", (e) => {
    if (dragId === null) return;
    e.preventDefault();
    clearDropMarkers();
    const dragged = dragId;
    dragId = null;
    const target = (e.target as HTMLElement).closest(".tab, .group-chip") as HTMLElement | null;
    if (!target) {
      moveTab(dragged, undefined, false);
      return;
    }
    if (target.classList.contains("group-chip")) {
      const gid = target.dataset.gid!;
      const first = tabOrder.find((m) => groupState.assign[m] === gid);
      moveTab(dragged, first, true, gid);
      return;
    }
    const refId = Number(target.dataset.id);
    if (refId === dragged) return;
    const rect = target.getBoundingClientRect();
    const before = e.clientX < rect.left + rect.width / 2;
    const gid = groupState.assign[refId];
    let joinGroup: string | undefined = gid;
    if (gid) {
      const members = tabOrder.filter((m) => groupState.assign[m] === gid);
      if (!before && members[members.length - 1] === refId) joinGroup = undefined;
    }
    moveTab(dragged, refId, before, joinGroup);
  });

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
  // Restore last session's tab order; unknown sessions go to the end.
  const savedOrder: number[] = JSON.parse(localStorage.getItem("gterm-order") ?? "[]");
  const rank = (id: number) => {
    const i = savedOrder.indexOf(id);
    return i === -1 ? Number.MAX_SAFE_INTEGER : i;
  };
  sessions.sort((a, b) => rank(a.id) - rank(b.id) || a.created_ms - b.created_ms);
  for (const s of sessions) {
    if (!hidden.has(s.id)) await createTab(s.id);
  }
  if (tabs.size === 0) await createTab();
  refreshChrome();
}

main();
