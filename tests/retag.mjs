// Handing a tab's identity to a surviving pane.
// Run: node tests/retag.mjs
//
// None of these fail loudly in the app. They show up as a tab that jumped
// to the end of the strip, or lost the name you gave it, or a width that
// belongs to a session with no tab any more.
import { retagKeyed, retagOrder } from "../src/retag.ts";

let failed = 0;
function check(name, got, want) {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${ok ? "" : `: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`}`);
  if (!ok) failed++;
}

// ── the tab keeps its place ────────────────────────────────────────────
// The bug this exists to prevent: delete-and-append moves the tab to the
// end of the strip, which reads as "my tab jumped" after closing a pane.
check("the tab holds its position", retagOrder([7, 3, 9], 3, 4), [7, 4, 9]);
check("first stays first", retagOrder([3, 7, 9], 3, 4), [4, 7, 9]);
check("last stays last", retagOrder([7, 9, 3], 3, 4), [7, 9, 4]);
check("an id that is not there changes nothing", retagOrder([7, 9], 3, 4), [7, 9]);
check("an empty strip stays empty", retagOrder([], 3, 4), []);
// A duplicate in the strip is a tab that cannot be closed: two buttons,
// one session, and closing either leaves the other pointing at nothing.
check("no duplicate when the new id is already there", retagOrder([7, 3, 4], 3, 4), [7, 4]);
check("and the earlier position wins", retagOrder([4, 7, 3], 3, 4), [4, 7]);

// ── everything keyed by the tab moves with it ──────────────────────────
check("a name moves", retagKeyed({ 3: "deploy" }, 3, 4), { 4: "deploy" });
check("a width moves", retagKeyed({ 3: 158 }, 3, 4), { 4: 158 });
check("other tabs are untouched", retagKeyed({ 3: "a", 8: "b" }, 3, 4), { 4: "a", 8: "b" });
check("nothing to move is not an error", retagKeyed({ 8: "b" }, 3, 4), { 8: "b" });
// Overwriting is correct here: the survivor's own entry is from when it
// was a pane, and the tab's identity now belongs to it.
check("the tab's value wins over the pane's own", retagKeyed({ 3: "tab", 4: "pane" }, 3, 4), { 4: "tab" });
// A falsy value is still a value - 0 width, empty name - and dropping it
// silently would restore a default nobody asked for.
check("a zero survives the move", retagKeyed({ 3: 0 }, 3, 4), { 4: 0 });
check("an empty string survives too", retagKeyed({ 3: "" }, 3, 4), { 4: "" });
{
  // The caller's object must not change underneath it.
  const before = { 3: "deploy" };
  retagKeyed(before, 3, 4);
  check("the original is left alone", before, { 3: "deploy" });
}

if (failed) {
  console.log(`${failed} retag test(s) failed`);
  process.exit(1);
}
console.log("all retag tests passed");
