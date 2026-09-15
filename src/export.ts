// Getting a transcript out, as a file somebody else can open.
//
// Transcripts are kept and can be read back inside the app. The thing
// anybody actually does with a failure is show it to someone, and that
// means a file: plain text for a bug report or a chat, HTML when the
// colours are the point - a diff, a test runner's red and green, a
// stack trace with its frames dimmed.
//
// The HTML side is a small renderer on purpose. It understands the
// colour and weight sequences that make output readable and steps over
// everything else, which is the right trade for a document: nobody
// wants a cursor-movement-accurate replay of their build in a browser,
// they want to read it.

/// Text with every escape sequence removed. What goes in a bug report.
export function transcriptToText(raw: string): string {
  return (
    raw
      // OSC, ended by BEL or ST
      .replace(/\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)/g, "")
      // DCS / APC / PM / SOS, ended by ST
      .replace(/\x1b[P_^X][^\x1b]*\x1b\\/g, "")
      // CSI
      .replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, "")
      // two-byte escapes
      .replace(/\x1b[@-Z\\-_]/g, "")
      .replace(/\r\n|\r/g, "\n")
  );
}

/// The sixteen colours, in a palette that reads on a white page as well
/// as a dark one. These are not the terminal's theme on purpose: a file
/// is opened somewhere the theme does not follow it.
const PALETTE = [
  "#3b3b3b", "#c62828", "#2e7d32", "#a66d00", "#1565c0", "#7b1fa2", "#00838f", "#9e9e9e",
  "#6b6b6b", "#e53935", "#43a047", "#c9a100", "#1e88e5", "#8e24aa", "#00acc1", "#212121",
];

interface Style {
  fg?: string;
  bg?: string;
  bold: boolean;
  dim: boolean;
  italic: boolean;
  underline: boolean;
}

function escapeHtml(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

function styleAttr(st: Style): string {
  const parts: string[] = [];
  if (st.fg) parts.push(`color:${st.fg}`);
  if (st.bg) parts.push(`background:${st.bg}`);
  if (st.bold) parts.push("font-weight:600");
  if (st.dim) parts.push("opacity:.6");
  if (st.italic) parts.push("font-style:italic");
  if (st.underline) parts.push("text-decoration:underline");
  return parts.join(";");
}

/// One SGR parameter list applied to a style. Returns the new style;
/// the old one is not mutated, so a span boundary is a value change.
function applySgr(st: Style, params: string): Style {
  const out = { ...st };
  const nums = params.split(";").map((p) => (p === "" ? 0 : Number(p)));
  for (let i = 0; i < nums.length; i++) {
    const n = nums[i];
    if (n === 0) {
      out.fg = undefined;
      out.bg = undefined;
      out.bold = out.dim = out.italic = out.underline = false;
    } else if (n === 1) out.bold = true;
    else if (n === 2) out.dim = true;
    else if (n === 3) out.italic = true;
    else if (n === 4) out.underline = true;
    else if (n === 22) out.bold = out.dim = false;
    else if (n === 23) out.italic = false;
    else if (n === 24) out.underline = false;
    else if (n === 39) out.fg = undefined;
    else if (n === 49) out.bg = undefined;
    else if (n >= 30 && n <= 37) out.fg = PALETTE[n - 30];
    else if (n >= 90 && n <= 97) out.fg = PALETTE[n - 90 + 8];
    else if (n >= 40 && n <= 47) out.bg = PALETTE[n - 40];
    else if (n >= 100 && n <= 107) out.bg = PALETTE[n - 100 + 8];
    else if ((n === 38 || n === 48) && nums[i + 1] === 5) {
      const idx = nums[i + 2] ?? 0;
      const c = idx < 16 ? PALETTE[idx] : xterm256(idx);
      if (n === 38) out.fg = c;
      else out.bg = c;
      i += 2;
    } else if ((n === 38 || n === 48) && nums[i + 1] === 2) {
      const c = `rgb(${nums[i + 2] ?? 0},${nums[i + 3] ?? 0},${nums[i + 4] ?? 0})`;
      if (n === 38) out.fg = c;
      else out.bg = c;
      i += 4;
    }
  }
  return out;
}

/// The 256-colour cube and greyscale ramp, as xterm defines them.
function xterm256(i: number): string {
  if (i >= 232) {
    const v = 8 + (i - 232) * 10;
    return `rgb(${v},${v},${v})`;
  }
  const c = i - 16;
  const r = Math.floor(c / 36);
  const g = Math.floor((c % 36) / 6);
  const b = c % 6;
  const step = (n: number) => (n === 0 ? 0 : 55 + n * 40);
  return `rgb(${step(r)},${step(g)},${step(b)})`;
}

/// Colours and weight kept; everything else stepped over.
///
/// Carriage returns without a newline are treated as "replace the line
/// so far", which is what a progress bar or a prompt repaint means and
/// what makes the result readable rather than a record of every frame.
export function transcriptToHtml(raw: string, title: string): string {
  const cleaned = raw
    .replace(/\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)/g, "")
    .replace(/\x1b[P_^X][^\x1b]*\x1b\\/g, "")
    .replace(/\x1b[@-Z\\-_]/g, (m) => (m === "\x1b[" ? m : ""));

  let st: Style = { bold: false, dim: false, italic: false, underline: false };
  const lines: string[] = [];
  let line = "";
  let span = "";
  const flushSpan = () => {
    if (!span) return;
    const attr = styleAttr(st);
    line += attr ? `<span style="${attr}">${escapeHtml(span)}</span>` : escapeHtml(span);
    span = "";
  };
  const re = /\x1b\[([0-?]*)([ -/]*)([@-~])/g;
  let i = 0;
  let m: RegExpExecArray | null;
  const emitText = (t: string) => {
    for (const ch of t) {
      if (ch === "\n") {
        flushSpan();
        lines.push(line);
        line = "";
      } else if (ch === "\r") {
        // Replace the line so far. See the doc comment.
        flushSpan();
        line = "";
      } else if (ch >= " " || ch === "\t") {
        span += ch;
      }
    }
  };
  while ((m = re.exec(cleaned))) {
    emitText(cleaned.slice(i, m.index));
    if (m[3] === "m") {
      flushSpan();
      st = applySgr(st, m[1]);
    }
    // Every other CSI is stepped over.
    i = m.index + m[0].length;
  }
  emitText(cleaned.slice(i));
  flushSpan();
  if (line) lines.push(line);

  return `<!doctype html>
<meta charset="utf-8">
<title>${escapeHtml(title)}</title>
<style>
  body { margin: 0; background: #fbfbfa; color: #1a1a1a; }
  @media (prefers-color-scheme: dark) { body { background: #111; color: #e6e6e6; } }
  pre { margin: 0; padding: 20px 24px; font: 13px/1.45 ui-monospace, Consolas, "Cascadia Mono", monospace; white-space: pre-wrap; word-break: break-word; }
  h1 { font: 500 14px system-ui, sans-serif; margin: 0; padding: 14px 24px 0; opacity: .7; }
</style>
<h1>${escapeHtml(title)}</h1>
<pre>${lines.join("\n")}</pre>
`;
}

/// A filename that will not collide and says what it is.
export function exportFilename(createdMs: number, shell: string, ext: "txt" | "html"): string {
  const d = new Date(createdMs);
  const pad = (n: number) => String(n).padStart(2, "0");
  const stamp = `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}${pad(d.getMinutes())}`;
  const sh = (shell || "shell").replace(/[^a-z0-9]+/gi, "-").toLowerCase();
  return `gterminal ${stamp} ${sh}.${ext}`;
}
