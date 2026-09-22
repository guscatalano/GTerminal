// What the × does with your terminals.
// Run: node tests/close.mjs
//
// The flow is a window dialog, but the parts that decide behaviour are
// pure: how the stored value normalises, and which modes end a shell. The
// wording is pinned too — "remember" must not read as if the shell keeps
// running. The rest is shape checks that the flow stays wired the safe way.
import { normalizeCloseMode, CLOSE_CHOICES, endsShells } from "../src/closebehavior.ts";
import { readFileSync } from "fs";

let failed = 0;
function check(name, got, want) {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${ok ? "" : `: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`}`);
  if (!ok) failed++;
}

// ── the stored value normalises ────────────────────────────────────────
check("hide stays hide", normalizeCloseMode("hide"), "hide");
check("keep stays keep", normalizeCloseMode("keep"), "keep");
check("remember stays remember", normalizeCloseMode("remember"), "remember");
check("close stays close", normalizeCloseMode("close"), "close");
// The legacy value: old installs and old configs said "quit".
check("legacy quit reads as close", normalizeCloseMode("quit"), "close");
// The default is deliberate: unset must not mean "run forever unseen".
check("unset defaults to remember", normalizeCloseMode(undefined), "remember");
check("garbage defaults to remember", normalizeCloseMode("banana"), "remember");

// ── which modes end a shell ────────────────────────────────────────────
check("keep does not end shells", endsShells("keep"), false);
check("remember ends shells", endsShells("remember"), true);
check("close ends shells", endsShells("close"), true);
check("hide does not end shells", endsShells("hide"), false);

// ── the wording is honest ──────────────────────────────────────────────
check("three choices, in order", CLOSE_CHOICES.map((c) => c.mode).join(","), "keep,remember,close");
const byMode = Object.fromEntries(CLOSE_CHOICES.map((c) => [c.mode, c]));
check("every choice has a label and a description", CLOSE_CHOICES.every((c) => c.label && c.desc.length > 20), true);
// "keep" must promise they come back and do not stop.
check("keep says they come back", /back|running|stay/i.test(byMode.keep.desc), true);
// "remember" must say it ENDS them, and that folders return — not that the
// shell survives, which is the whole thing the reviewer wanted made clear.
check("remember says it ends them", /\bends?\b/i.test(byMode.remember.desc), true);
check("remember says the folders come back", /folder/i.test(byMode.remember.desc), true);
// "close" must read as final.
check("close says it forgets", /forget/i.test(byMode.close.desc), true);

// ── the flow stays wired the safe way ──────────────────────────────────
const main = readFileSync(new URL("../src/main.ts", import.meta.url), "utf8");
// Hide-to-tray must stay the Rust handler's job — the frontend takes over
// only the quit modes, or it overrides the hide and breaks the tray.
check(
  "the close handler leaves hide to the Rust arm",
  /closeMode\(\) === "hide"\)\s*return;/.test(main),
  true
);
check("only the quit modes are confirmed and carried out here", /e\.preventDefault\(\);\s*void runCloseFlow\(\)/.test(main), true);
// Only the last window prompts; a non-last one just closes (detaches).
check("only the last window prompts", /windows\.length > 1 \|\| live\.length === 0/.test(main), true);
// Remember saves the folders; both remember and close end the shells.
check("remember saves the workspace", /config\.workspace_restore = openWorkspace\(\)/.test(main), true);
check("remember and close end the live shells", /kill_session"[\s\S]{0,80}tabs\.keys\(\)|tabs\.keys\(\)[\s\S]{0,80}kill_session"/.test(main), true);
// The remembered workspace is reopened once at startup, then cleared.
check(
  "the workspace is reopened and cleared at startup",
  /config\.workspace_restore\?\.length[\s\S]{0,200}config\.workspace_restore = undefined/.test(main),
  true
);
// The settings control and the confirm toggle exist.
check("settings offer the confirm toggle", /config\.close_confirm = v === "on"/.test(main), true);

if (failed) {
  console.log(`${failed} close test(s) failed`);
  process.exit(1);
}
console.log("all close tests passed");
