// Which Tauri commands are allowed to run on the UI thread.
// Run: node tests/commands.mjs
//
// A plain `#[tauri::command]` is ExecutionContext::Blocking: the body runs
// inline in the IPC callback, which on Windows is the UI thread. So a
// command that blocks does not just make itself slow - it holds the thread
// that every other command arrives on, including write_session, which is a
// keystroke. Adding `(async)` to a synchronous command compiles it to
// sync_threadpool instead, and costs nothing else.
//
// This is what made the status bar felt rather than seen. status_command
// spawns a whole powershell.exe and waits for it; system_stats collects
// PDH counters. Both are on timers - every 10s and every 500ms in one
// real config - and both used to run on the UI thread, so typing stopped
// for as long as they took, on a schedule nobody could connect to what
// they were doing.
//
// Every command has to be listed here. A new one fails this test until
// somebody decides which side it belongs on, because the question ("can
// this block?") is not one to answer by default.
import { readFileSync, readdirSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";

const here = dirname(fileURLToPath(import.meta.url));
const srcDir = join(here, "..", "src-tauri", "src");

// Must not run on the UI thread: a process spawn, a PDH collection, a
// socket round trip to the daemon, the network, or a file read with no
// bound on its size.
const OFF_UI_THREAD = new Set([
  "system_stats",
  "perf_counters",
  "perf_objects",
  "perf_items",
  "status_command",
  "weather_report",
  "claude_usage",
  "update_status",
  "update_versions",
  "update_check",
  "update_install",
  "history_list",
  "history_read",
  "peek_session",
  "list_sessions",
  "kill_session",
  "daemon_info",
  "retire_daemon",
  "restart_daemon",
  "open_logs_folder",
  // Asks Windows for an elevated window: a shell call that does not
  // return until the user has answered a UAC prompt.
  "open_elevated_window",
  // Reads and deletes a file at startup.
  "take_handoff",
  "open_folder",
  "create_shortcut",
]);

// Allowed on the UI thread, each for one of two reasons: it is a memory
// or config access that finishes in microseconds, or it is ordered
// against other calls and a thread pool could reorder it. write_session
// is the second kind - keystrokes must arrive in the order they were
// typed, and inline execution on one thread is what guarantees that.
const ON_UI_THREAD = new Set([
  "write_session",
  "resize_session",
  "detach_session",
  "create_session",
  "attach_session",
  "move_session",
  "get_config",
  "set_config",
  "log_ui",
  "logs_path",
  "launch_info",
  "package_family_name",
  "window_labels",
  "summon_toggle",
  "refresh_tray",
]);

let failed = 0;
function check(name, ok, detail = "") {
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${ok ? "" : `: ${detail}`}`);
  if (!ok) failed++;
}

// Every #[tauri::command] in the crate, with whether it runs off the UI
// thread - either `(async)` on a sync fn, or an `async fn` body.
const found = new Map();
for (const file of readdirSync(srcDir).filter((f) => f.endsWith(".rs"))) {
  const text = readFileSync(join(srcDir, file), "utf8");
  const re = /#\[tauri::command(\([^)]*\))?\]\s*(?:pub\s+)?(async\s+)?fn\s+([a-z_0-9]+)/g;
  for (const m of text.matchAll(re)) {
    const [, attr, asyncFn, name] = m;
    found.set(name, {
      file,
      offThread: Boolean(asyncFn) || Boolean(attr && attr.includes("async")),
    });
  }
}

check("commands were found at all", found.size > 0, "the attribute pattern stopped matching");

for (const [name, { file, offThread }] of [...found].sort()) {
  if (OFF_UI_THREAD.has(name)) {
    check(
      `${name} runs off the UI thread`,
      offThread,
      `${file}: this one blocks — write \`#[tauri::command(async)]\`, or move it to ON_UI_THREAD here and say why it cannot block`
    );
  } else if (ON_UI_THREAD.has(name)) {
    check(
      `${name} stays on the UI thread`,
      !offThread,
      `${file}: it became async — either it now blocks (move it to OFF_UI_THREAD) or the change was accidental, and for the ordered ones a thread pool can reorder calls`
    );
  } else {
    check(
      `${name} is classified`,
      false,
      `${file}: a new command — add it to OFF_UI_THREAD (it can block: a process, a socket, the network, an unbounded read) or ON_UI_THREAD (microseconds, or ordered against other calls) in tests/commands.mjs`
    );
  }
}

// The other direction: a name that was removed or renamed leaves a stale
// entry behind, and a list nobody prunes stops meaning anything.
for (const name of [...OFF_UI_THREAD, ...ON_UI_THREAD]) {
  check(`${name} still exists`, found.has(name), "listed here but no longer a command — remove it");
}

if (failed) {
  console.log(`${failed} command test(s) failed`);
  process.exit(1);
}
console.log(`all ${found.size} commands classified`);
