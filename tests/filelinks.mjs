// Finding `src/main.ts:4821` in a line of output.
// Run: node tests/filelinks.mjs
//
// Two ways to be wrong and they pull opposite ways: match too little and
// the feature is a lottery, match too much and prose turns blue and the
// terminal starts to look like a badly rendered web page. Most of what
// follows is the second kind, because that is the one a user cannot turn
// off by not clicking.
import {
  DEFAULT_EDITOR_COMMAND,
  editorArgv,
  findFileLinks,
  resolveLink,
} from "../src/filelinks.ts";

let failed = 0;
function check(name, got, want) {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${ok ? "" : `: got ${JSON.stringify(got)}, wanted ${JSON.stringify(want)}`}`);
  if (!ok) failed++;
}
const one = (s) => findFileLinks(s).map((f) => [f.path, f.line, f.col]);

// ── the shapes tools actually print ───────────────────────────────────
check("tsc", one("src/main.ts(4821,13): error TS2554: wrong"), [["src/main.ts", 4821, 13]]);
check("eslint and rust", one("  --> src/mux.rs:1402:9"), [["src/mux.rs", 1402, 9]]);
check("a line with no column", one("at src/main.ts:120"), [["src/main.ts", 120, undefined]]);
check(
  "a Windows absolute path",
  one("C:\\Users\\crimson\\source\\repos\\GTerminal\\src\\main.ts:4821"),
  [["C:\\Users\\crimson\\source\\repos\\GTerminal\\src\\main.ts", 4821, undefined]]
);
check("a dot-relative path", one(".\\tests\\visual.ps1:268"), [[".\\tests\\visual.ps1", 268, undefined]]);
check(
  "a stack trace line",
  one("    at Object.<anonymous> (C:\\src\\app\\index.js:42:15)"),
  [["C:\\src\\app\\index.js", 42, 15]]
);
check(
  "several on one line",
  one("src/a.ts:1 and src/b.ts:2"),
  [["src/a.ts", 1, undefined], ["src/b.ts", 2, undefined]]
);

// ── and the things that are not files ─────────────────────────────────
// The one that bites: a timestamp is digits and colons, and this
// terminal prints one in its own status bar.
check("a clock time is not a file", one("11:04:31 PM  CPU 19%"), []);
check("a duration is not a file", one("finished in 1:23"), []);
check("a bare word and a number is not a file", one("warning: 42"), []);
check("a ratio is not a file", one("scale 16:9"), []);
// Line zero does not exist in any editor's numbering, so `:0` is a
// duration or a ratio every time.
check("line zero is not a line", one("build.log:0"), []);
// URLs belong to the web-links addon, and treating one as a path offers
// to open something like //host:8080/x.js.
check("a URL is left alone", one("see https://example.com/x.js:3 for more"), []);
check(
  "even when it has a port and a line",
  one("http://localhost:1420/src/main.ts:12"),
  []
);
// A word with a dot in it is not a file unless something says where in
// it to go. Otherwise every version number is a link.
check("a version number is not a file", one("node v24.14.1"), []);
check("a sentence is left alone", one("the file was updated at 4 pm"), []);

// ── overlap ───────────────────────────────────────────────────────────
// The two patterns both match a path with a line, and a link inside a
// link would leave half the text clickable and half not.
check(
  "a path with line and column is one link, not two",
  findFileLinks("src/main.ts:4821:13").length,
  1
);
check(
  "and it spans the whole of it",
  findFileLinks("src/main.ts:4821:13")[0].end,
  "src/main.ts:4821:13".length
);

// ── resolving ─────────────────────────────────────────────────────────
// A relative path means nothing without the shell's working directory,
// which is the one thing the terminal knows and the text does not.
check("relative is joined to the cwd", resolveLink("C:\\repo", "src\\main.ts"), "C:\\repo\\src\\main.ts");
check("forward slashes become the platform's", resolveLink("C:\\repo", "src/main.ts"), "C:\\repo\\src\\main.ts");
check("a leading .\\ is not doubled", resolveLink("C:\\repo", ".\\src\\a.ts"), "C:\\repo\\src\\a.ts");
check("a trailing separator on the cwd is not doubled", resolveLink("C:\\repo\\", "a.ts"), "C:\\repo\\a.ts");
check("an absolute path is left alone", resolveLink("C:\\repo", "D:\\other\\a.ts"), "D:\\other\\a.ts");
// A UNC path starts with two separators and is mangled by naive joining.
check("a UNC path is left alone", resolveLink("C:\\repo", "\\\\server\\share\\a.ts"), "\\\\server\\share\\a.ts");
check("with no cwd, the path is all there is", resolveLink("", "src\\a.ts"), "src\\a.ts");

// ── the command ───────────────────────────────────────────────────────
check(
  "the default opens the file at the line",
  editorArgv(DEFAULT_EDITOR_COMMAND, "C:\\repo\\a.ts", 12, 3),
  { program: "code", args: ["-g", "C:\\repo\\a.ts:12:3"] }
);
check(
  "a missing column becomes the first one",
  editorArgv(DEFAULT_EDITOR_COMMAND, "C:\\repo\\a.ts", 12, undefined),
  { program: "code", args: ["-g", "C:\\repo\\a.ts:12:1"] }
);
// Paths with spaces are the common case on Windows, and handing this to
// a shell would make quoting the user's problem at the exact moment
// they click something under "Program Files".
check(
  "a quoted program with a space survives",
  editorArgv('"C:\\Program Files\\Editor\\ed.exe" --line {line} {file}', "C:\\a b\\x.ts", 7),
  { program: "C:\\Program Files\\Editor\\ed.exe", args: ["--line", "7", "C:\\a b\\x.ts"] }
);
check("an empty template falls back to the default", editorArgv("", "a.ts", 1)?.program, "code");
check("and nothing but spaces is no command at all", editorArgv("   ", "a.ts", 1)?.program, "code");


// ── what activates one ────────────────────────────────────────────────
// Not tested here, and worth saying why rather than leaving a gap that
// looks like an oversight. A synthetic click does reach the terminal -
// tests/mouse.mjs proves that - but activating a link needs xterm's
// hover to have registered it first, and driving that from a headless
// page turned into a test of the harness rather than of the feature.
//
// The question it was there to answer is answered from the engine's own
// code instead: the activation path compares the link under the pointer
// and calls `activate(...)` with no modifier check anywhere in it. So a
// plain click opens a file, Ctrl is not required, and the settings text
// says click rather than telling somebody to hold a key that does
// nothing. If that ever changes, this is the paragraph that was wrong.

if (failed) {
  console.log(`${failed} file-link test(s) failed`);
  process.exit(1);
}
console.log("all file-link tests passed");
