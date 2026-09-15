// Turning `src/main.ts:4821` in the output into something you can click.
//
// Every compiler, linter, test runner and stack trace prints a file and
// a line, and in this terminal all of it is dead text — `addon-web-links`
// matches URLs and nothing else. The gap is felt daily by anybody who
// reads build output, and closing it is one link provider and one
// command to run.
//
// The pattern is the whole risk, which is why it lives here on its own
// with tests rather than inline in main.ts. Two ways to get it wrong and
// they pull in opposite directions: match too little and the feature is
// a lottery, match too much and ordinary prose turns blue and the
// terminal starts looking like a badly rendered web page. Timestamps are
// the ones that bite — `11:04:31` is three numbers and two colons, and a
// careless pattern reads it as a file at line 4.

export interface FileLink {
  /// Index of the first character of the whole match, in the line.
  start: number;
  /// One past the last character.
  end: number;
  /// The path as written. Resolving it against a working directory is a
  /// separate job — see `resolveLink`.
  path: string;
  line: number;
  /// Column, when the tool bothered to say.
  col?: number;
}

/// Characters a Windows path cannot contain, which is what ends one.
const NOT_IN_PATH = '\\s:*?"<>|';

/// What counts as a file, followed by where in it.
///
/// Three shapes, because three families of tool print three things:
///
///   src/main.ts:4821:13   unix-ish, and what tsc, eslint and rust print
///   C:\src\main.ts:4821   a Windows absolute path
///   Program.cs(12,5)      MSBuild, csc, and most of the .NET world
///
/// A path has to carry an extension. Without that rule `foo:12` in a
/// sentence is a file, and so is every `name: 5` in a YAML dump.
const PATTERNS: RegExp[] = [
  // path:line[:col]
  new RegExp(
    `((?:[A-Za-z]:[\\\\/]|\\.{1,2}[\\\\/]|~[\\\\/])?(?:[^${NOT_IN_PATH}]+[\\\\/])*[^${NOT_IN_PATH}/\\\\]+\\.[A-Za-z][\\w]{0,9}):(\\d+)(?::(\\d+))?`,
    "g"
  ),
  // path(line,col)
  new RegExp(
    `((?:[A-Za-z]:[\\\\/]|\\.{1,2}[\\\\/]|~[\\\\/])?(?:[^${NOT_IN_PATH}]+[\\\\/])*[^${NOT_IN_PATH}/\\\\]+\\.[A-Za-z][\\w]{0,9})\\((\\d+),(\\d+)\\)`,
    "g"
  ),
];

/// Everything in one line of output that names a file and a place in it.
///
/// Overlaps are resolved by preferring the earlier match, then the
/// longer one: `C:\a\b.ts:12:3` should be one link, not a link inside a
/// link.
export function findFileLinks(text: string): FileLink[] {
  const found: FileLink[] = [];
  for (const re of PATTERNS) {
    re.lastIndex = 0;
    let m: RegExpExecArray | null;
    while ((m = re.exec(text))) {
      const whole = m[0];
      const start = m.index;
      // A URL is not a file path. Judged on the whole run of
      // non-space characters the match sits inside, rather than on what
      // comes immediately before it: the path pattern happily starts
      // *inside* "https" and matches "s://example.com/x.js", so looking
      // backwards one character finds nothing wrong.
      const runStart = text.lastIndexOf(" ", start) + 1;
      const runEndRaw = text.indexOf(" ", start);
      const run = text.slice(runStart, runEndRaw === -1 ? text.length : runEndRaw);
      if (run.includes("://")) continue;
      const line = Number(m[2]);
      const col = m[3] === undefined ? undefined : Number(m[3]);
      // Line 0 does not exist in any editor's numbering. A match of
      // `:0` is almost always a duration or a ratio.
      if (!Number.isFinite(line) || line < 1) continue;
      found.push({ start, end: start + whole.length, path: m[1], line, col });
    }
  }
  found.sort((a, b) => a.start - b.start || b.end - a.end);
  const out: FileLink[] = [];
  for (const f of found) {
    const last = out[out.length - 1];
    if (last && f.start < last.end) continue;
    out.push(f);
  }
  return out;
}

/// The path to actually open.
///
/// Relative paths are relative to the shell's working directory, which
/// is the one thing the terminal knows and the text does not. A path
/// that is already absolute is left alone — including a UNC path, which
/// starts with two separators and would otherwise be mangled by naive
/// joining.
export function resolveLink(cwd: string, path: string): string {
  const p = path.replace(/\//g, "\\");
  if (/^[A-Za-z]:\\/.test(p) || p.startsWith("\\\\")) return p;
  if (p.startsWith("~\\")) return p;
  if (!cwd) return p;
  return `${cwd.replace(/[\\/]+$/, "")}\\${p.replace(/^\.\\/, "")}`;
}

/// The default way to open one.
///
/// VS Code, because it is what is installed on the machine this is
/// written on and it takes a line number. `{file}`, `{line}` and `{col}`
/// are filled in; anything else in the template is passed through, so
/// somebody using another editor writes its own flags rather than
/// asking for support.
export const DEFAULT_EDITOR_COMMAND = "code -g {file}:{line}:{col}";

/// The command line to run, as a program and its arguments.
///
/// Split here rather than handed to a shell. A path with a space in it
/// is the common case on Windows, and passing this through cmd would
/// make quoting somebody's problem — usually at the moment they click a
/// path under "Program Files".
export function editorArgv(
  template: string,
  file: string,
  line: number,
  col?: number
): { program: string; args: string[] } | undefined {
  // Split first, substitute second. The other order tears a path with a
  // space in it into two arguments - which on Windows is not an edge
  // case, it is anything under "Program Files" - and no amount of
  // quoting in the template would help, because the quotes are not in
  // the template, they are in the value.
  const use = template.trim() ? template : DEFAULT_EDITOR_COMMAND;
  const parts = use.match(/"[^"]*"|\S+/g);
  if (!parts || !parts.length) return undefined;
  const unquote = (s: string) => (s.startsWith('"') && s.endsWith('"') ? s.slice(1, -1) : s);
  const fill = (s: string) =>
    s
      .replace(/\{file\}/g, file)
      .replace(/\{line\}/g, String(line))
      .replace(/\{col\}/g, String(col ?? 1));
  return { program: fill(unquote(parts[0])), args: parts.slice(1).map((p) => fill(unquote(p))) };
}
