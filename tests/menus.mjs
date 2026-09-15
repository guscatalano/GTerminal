// When a click on a menu row counts as choosing it.
// Run: node tests/menus.mjs
//
// Reported from real use: "if you hover over Paste it pastes, you need to
// actually click on it", and then again as "the right click does a paste
// without me clicking it". Nothing fires on hover — but a menu sits under
// the pointer that opened it, so any press that arrives at that spot
// without anyone reaching for it lands on a row and looks exactly like
// that. The last argument is what separates the two: how far the press
// had to travel from the point the menu opened at.
import { activates } from "../src/menus.ts";
import { readFileSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";

let failed = 0;
function check(name, got, want) {
  const ok = got === want;
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${ok ? "" : `: got ${got}, want ${want}`}`);
  if (!ok) failed++;
}

// The ordinary case: you press on the row, a moment after the menu opened,
// having moved the pointer onto it.
check("a deliberate press chooses the item", activates(true, 900, 60), true);

// The release of the gesture that opened the menu. No press ever landed
// on the row, so this is not a choice however long the menu has been up.
check("a release with no press on the row does not", activates(false, 900, 60), false);
check("and still does not, however late it arrives", activates(false, 60_000, 60), false);

// A press on the row, but within the arming window — it belongs to
// whatever opened the menu, not to the row that appeared under it.
check("a press too soon after opening does not", activates(true, 10, 60), false);
check("nor right at the edge below the threshold", activates(true, 249, 60), false);
check("at the threshold it counts", activates(true, 250, 60), true);
check("a custom window is respected", activates(true, 300, 60, 500), false);

// The one the clock cannot catch: a second press the input device emitted
// on its own — a two-finger tap whose fingers lift a moment apart, a
// click synthesized after a long-press. It is a real press on the row and
// it arrives late, but it happens exactly where the menu opened, and no
// row of a menu anchored at the pointer is there.
check("a press that never moved from the opening point does not", activates(true, 900, 0), false);
check("nor one that only jittered", activates(true, 900, 7), false);
check("at the travel threshold it counts", activates(true, 900, 8), true);
check("a custom travel threshold is respected", activates(true, 900, 10, 250, 24), false);

// A menu with no recorded opening time has been there since before anyone
// reached for it — treating that as "too soon" would make it unclickable.
// Same for one with no opening point: a menu dropped from a button never
// sat under the cursor, so there is nothing to measure against.
check("an unarmed menu still works", activates(true, Number.NaN, 60), true);
check("and an unarmed menu still needs a press", activates(false, Number.NaN, 60), false);
check("an unanchored menu is not judged on travel", activates(true, 900, Number.NaN), true);
check("and an unanchored menu still needs a press", activates(false, 900, Number.NaN), false);


// ── which menu an item belongs in ──────────────────────────────────────
// There are two menus and they are about different things. The one in
// the terminal is about the text: copy what is selected, paste, reach
// the clipboard history. The one on a tab is about the tab as a thing:
// what it is called, whether it exists, where it goes.
//
// "Reopen elevated…" was in the first, one row above Clipboard history,
// where a right-click aimed at a selection could reach it - and where
// adding it silently moved the row a visual scene was clicking, which
// cost a day of chasing a phantom. Opening a second window running as
// administrator is not an operation on the selected text.
const src = readFileSync(join(dirname(fileURLToPath(import.meta.url)), "..", "src", "main.ts"), "utf8");

/// The body of a top-level function, by name. Crude on purpose: a real
/// parser here would be a dependency and a brace at column zero is how
/// this file is written.
function bodyOf(name) {
  const start = src.indexOf(`function ${name}(`);
  if (start < 0) return "";
  const end = src.indexOf(String.fromCharCode(10) + "}", start);
  return src.slice(start, end < 0 ? undefined : end);
}

// Matched on the label a row is built with, not on the words: the
// story of how this went wrong is written in a comment a few hundred
// lines away, and a check that reads comments is a check that fails
// when somebody explains something.
const tabMenu = bodyOf("showTabContextMenu");
check("the tab menu exists to be checked", tabMenu.length > 0, true);
check("reopening elevated is a tab action", tabMenu.includes('label: "Reopen elevated'), true);
check("so is duplicating", tabMenu.includes('label: "Duplicate tab'), true);

// And the terminal's own menu, which is everything between the
// contextmenu listener and the end of the items it builds.
const paneMenu = src.slice(
  src.indexOf('pane.addEventListener("contextmenu"'),
  src.indexOf("function placeFloating")
);
check("the terminal menu exists to be checked", paneMenu.length > 0, true);
check("and it does not offer to open an elevated window", paneMenu.includes('label: "Reopen elevated'), false);
check("while it does offer the clipboard history", paneMenu.includes("Clipboard history"), true);
check("and Copy, with the key that does it", paneMenu.includes('keys: "Ctrl+Shift+C"'), true);

if (failed) {
  console.log(`${failed} menu test(s) failed`);
  process.exit(1);
}
console.log("all menu tests passed");
