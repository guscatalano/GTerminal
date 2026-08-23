// What a tab gets called. Run: node tests/titles.mjs
//
// Tab titles are on screen constantly, so every judgement in here is one
// people notice: a shell announcing its own name, a home directory whose
// leaf is your username, a program that starts and finishes, a template
// with an empty field in the middle of it.
import { autoTitle, BORING_TITLE, cwdParts, isHomeDir, runningProgram } from "../src/titles.ts";

let failed = 0;
function check(name, got, want) {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${ok ? "" : `: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`}`);
  if (!ok) failed++;
}
const t = (over = {}) =>
  autoTitle({
    cwd: "C:\\repos\\app",
    running: [],
    shellTitle: "",
    shellName: "PowerShell",
    mode: "smart",
    ...over,
  });

// ── paths ──────────────────────────────────────────────────────────────
check("path splits", cwdParts("C:\\repos\\app"), ["C:", "repos", "app"]);
check("a trailing slash is not a segment", cwdParts("C:\\repos\\app\\"), ["C:", "repos", "app"]);
check("forward slashes too", cwdParts("C:/repos/app"), ["C:", "repos", "app"]);
check("doubled separators collapse", cwdParts("C:\\\\repos\\\\app"), ["C:", "repos", "app"]);
check("no path, no parts", cwdParts(""), []);
check("a home directory is recognised", isHomeDir(["C:", "Users", "gus"]), true);
check("case does not matter", isHomeDir(["C:", "users", "gus"]), true);
check("a folder under home is not home", isHomeDir(["C:", "Users", "gus", "repos"]), false);
check("a two-part path is not home", isHomeDir(["C:", "Users"]), false);

// ── which process counts as "running" ──────────────────────────────────
check("the shell itself does not count", runningProgram(["pwsh"]), undefined);
check("nor does conhost", runningProgram(["conhost", "powershell"]), undefined);
check("a real program does", runningProgram(["pwsh", "node"]), "node");
check("the first one wins", runningProgram(["pwsh", "node", "git"]), "node");
check("nothing running", runningProgram([]), undefined);

// ── titles a shell sets for itself ─────────────────────────────────────
// Shells announce their own name or their path; neither is worth a tab.
check("its own name is boring", BORING_TITLE.test("Windows PowerShell"), true);
check("cmd's name is boring", BORING_TITLE.test("Command Prompt"), true);
check("an exe path is boring", BORING_TITLE.test("C:\\Windows\\System32\\cmd.exe"), true);
check("an elevated shell is still boring", BORING_TITLE.test("Administrator: cmd.exe"), true);
check("a bare path is boring", BORING_TITLE.test("C:\\repos\\app"), true);
check("a real title is not", BORING_TITLE.test("npm run dev"), false);
check("nor is a task name", BORING_TITLE.test("deploy — staging"), false);

// ── smart mode, the default ────────────────────────────────────────────
check("the folder, when nothing else is happening", t(), { text: "app", fromCwd: true });
check(
  "what is running, and where",
  t({ running: ["pwsh", "npm"] }),
  { text: "npm · app", fromCwd: false }
);
check(
  "a title the shell set beats everything",
  t({ shellTitle: "deploying", running: ["pwsh", "npm"] }),
  { text: "deploying", fromCwd: false }
);
check(
  "a boring shell title is ignored",
  t({ shellTitle: "Windows PowerShell" }),
  { text: "app", fromCwd: true }
);
// The home directory's leaf is the username, which would be every tab's
// name at once.
check(
  "home falls back to the shell name",
  t({ cwd: "C:\\Users\\gus" }),
  { text: "PowerShell", fromCwd: false }
);
check(
  "a program in home is named without the folder",
  t({ cwd: "C:\\Users\\gus", running: ["pwsh", "vim"] }),
  { text: "vim", fromCwd: false }
);
check("no cwd at all falls back too", t({ cwd: "" }), { text: "PowerShell", fromCwd: false });
check(
  "the shell name follows the shell",
  t({ cwd: "", shellName: "Command Prompt" }),
  { text: "Command Prompt", fromCwd: false }
);

// This is the restlessness: the same tab reads two different ways
// depending only on whether a command happens to be running. Deliberate,
// and worth pinning so a change to it is a decision rather than a drift.
{
  const idle = t();
  const busy = t({ running: ["pwsh", "npm"] });
  check("idle and busy differ by design", idle.text !== busy.text, true);
  check("and the idle one is the folder", idle.text, "app");
}

// ── the other modes ────────────────────────────────────────────────────
check("dir mode ignores the program", t({ mode: "dir", running: ["pwsh", "npm"] }), {
  text: "app",
  fromCwd: true,
});
check("dir mode ignores the shell title", t({ mode: "dir", shellTitle: "deploying" }), {
  text: "app",
  fromCwd: true,
});
check("program mode names the program", t({ mode: "program", running: ["pwsh", "npm"] }), {
  text: "npm",
  fromCwd: false,
});
check("program mode with nothing running", t({ mode: "program" }), {
  text: "PowerShell",
  fromCwd: false,
});
check("shelltitle mode prefers the title", t({ mode: "shelltitle", shellTitle: "build" }), {
  text: "build",
  fromCwd: false,
});
check("shelltitle mode falls back to the folder", t({ mode: "shelltitle" }), {
  text: "app",
  fromCwd: true,
});

// ── custom templates ───────────────────────────────────────────────────
check(
  "the default template",
  t({ mode: "custom", running: ["pwsh", "npm"] }),
  { text: "npm · app", fromCwd: false }
);
// An empty field must not leave a dangling separator — "· app" reads as
// a mistake, and templates have empty fields most of the time.
check(
  "an empty field drops its separator",
  t({ mode: "custom" }),
  { text: "app", fromCwd: false }
);
check(
  "all fields empty falls back to the shell",
  t({ mode: "custom", cwd: "C:\\Users\\gus" }),
  { text: "PowerShell", fromCwd: false }
);
check(
  "the parent folder is available",
  t({ mode: "custom", template: "{parent}/{folder}" }),
  { text: "repos/app", fromCwd: false }
);
check(
  "the whole path is available",
  t({ mode: "custom", template: "{path}" }),
  { text: "C:\\repos\\app", fromCwd: false }
);
check(
  "an unknown field renders as nothing rather than literally",
  t({ mode: "custom", template: "{nope}{folder}" }),
  { text: "app", fromCwd: false }
);
check(
  "literal text survives",
  t({ mode: "custom", template: "dev: {folder}" }),
  { text: "dev: app", fromCwd: false }
);
// Long titles would push every other tab off the strip.
{
  const long = t({ mode: "custom", template: "{path}", cwd: "C:\\" + "x".repeat(200) });
  check("a runaway template is truncated", long.text.length <= 60, true);
}

if (failed) {
  console.log(`${failed} title test(s) failed`);
  process.exit(1);
}
console.log("all title tests passed");
