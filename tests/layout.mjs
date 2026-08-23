// The pane layout tree. Run: node tests/layout.mjs
//
// This is the largest piece of pure logic in the app and the one that
// churned most while tiling was being built. Its failures are quiet:
// a split that keeps one arm renders as a divider against nothing, a
// preset with the wrong ratios gives you a half and two quarters where
// you asked for thirds, and a stale leaf points at a session that died
// while its tab was off screen. None of those throw.
import {
  leavesOf,
  replaceLeaf,
  dropLeaf,
  pruneTree,
  splitLeaf,
  evenChain,
  tiled,
  moveWithin,
  dropSideAt,
} from "../src/layout.ts";

let failed = 0;
function check(name, got, want) {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${ok ? "" : `: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`}`);
  if (!ok) failed++;
}

const leaf = (id) => ({ kind: "leaf", id });
const split = (dir, a, b, ratio = 0.5) => ({ kind: "split", dir, ratio, a, b });

// A three-pane tree:  1 | (2 / 3)
const three = () => split("row", leaf(1), split("col", leaf(2), leaf(3)));

// ── reading the tree ───────────────────────────────────────────────────
check("a lone leaf", leavesOf(leaf(7)), [7]);
check("leaves come out in visual order", leavesOf(three()), [1, 2, 3]);

// ── replacing ──────────────────────────────────────────────────────────
check(
  "replacing a leaf leaves the rest alone",
  leavesOf(replaceLeaf(three(), 2, leaf(9))),
  [1, 9, 3]
);
check(
  "replacing a leaf that is not there changes nothing",
  leavesOf(replaceLeaf(three(), 42, leaf(9))),
  [1, 2, 3]
);
check("the whole tree can be one leaf", replaceLeaf(leaf(1), 1, leaf(2)), leaf(2));

// ── dropping, and the collapse that must follow ────────────────────────
// A split with one arm removed has to collapse into its survivor. Left
// alone it renders as a divider against nothing.
check("dropping collapses the split that held it", dropLeaf(three(), 3), split("row", leaf(1), leaf(2)));
check("dropping the other side collapses too", dropLeaf(three(), 2), split("row", leaf(1), leaf(3)));
check("dropping the far side", leavesOf(dropLeaf(three(), 1)), [2, 3]);
check("dropping the only leaf empties the tree", dropLeaf(leaf(1), 1), null);
check("dropping something absent is a no-op", dropLeaf(three(), 99), three());
check(
  "nested collapse: a split whose whole side goes",
  dropLeaf(split("row", leaf(1), split("col", leaf(2), leaf(3))), 2),
  split("row", leaf(1), leaf(3))
);

// ── pruning against the sessions that still exist ──────────────────────
check("everything alive survives", pruneTree(three(), new Set([1, 2, 3])), three());
check(
  "a dead leaf is dropped and its split collapses",
  pruneTree(three(), new Set([1, 3])),
  split("row", leaf(1), leaf(3))
);
check("all dead leaves an empty tree", pruneTree(three(), new Set()), null);
check("one survivor is returned bare", pruneTree(three(), new Set([2])), leaf(2));

// ── splitting ──────────────────────────────────────────────────────────
check(
  "splitting adds the new pane after by default",
  leavesOf(splitLeaf(leaf(1), 1, 2, "row")),
  [1, 2]
);
check(
  "first puts it before, which is what split-left means",
  leavesOf(splitLeaf(leaf(1), 1, 2, "row", true)),
  [2, 1]
);
check("a fresh split is even", splitLeaf(leaf(1), 1, 2, "row").ratio, 0.5);
check(
  "splitting deep in a tree touches only that leaf",
  leavesOf(splitLeaf(three(), 3, 4, "col")),
  [1, 2, 3, 4]
);

// ── presets ────────────────────────────────────────────────────────────
// Ratios are the whole point: three panes must be thirds, not a half and
// two quarters, or "even columns" is a lie.
check("one pane needs no split", evenChain([1], "row"), leaf(1));
check("two panes are halves", evenChain([1, 2], "row").ratio, 0.5);
{
  const t = evenChain([1, 2, 3], "row");
  check("three panes: the first takes a third", t.ratio, 1 / 3);
  check("and the rest split the remainder evenly", t.b.ratio, 0.5);
  check("all three are present in order", leavesOf(t), [1, 2, 3]);
}
{
  const t = evenChain([1, 2, 3, 4], "col");
  check("four panes: the first takes a quarter", t.ratio, 0.25);
  check("direction is carried down the chain", t.b.dir, "col");
}
{
  const t = tiled([1, 2, 3, 4]);
  check("tiled keeps every pane", leavesOf(t), [1, 2, 3, 4]);
  check("tiled alternates direction", [t.dir, t.a.dir, t.b.dir], ["row", "col", "col"]);
  check("tiled splits evenly at the top", t.ratio, 0.5);
}
check("tiled with three is still all three", leavesOf(tiled([1, 2, 3])), [1, 2, 3]);
check("tiled with one is a leaf", tiled([5]), leaf(5));

// ── moving ─────────────────────────────────────────────────────────────
check("moving onto itself does nothing", moveWithin(three(), 2, 2, "left"), null);
{
  // Swap exchanges two panes without disturbing the shape or the ratios.
  const t = moveWithin(three(), 1, 3, "swap");
  check("swap exchanges the two", leavesOf(t), [3, 2, 1]);
  check("swap keeps the shape", t.dir, "row");
  check("swap keeps the inner split", t.b.dir, "col");
}
{
  // Removing the source can collapse the split holding the target, so the
  // target has to be found again in the pruned tree, not the original.
  const t = moveWithin(three(), 3, 1, "right");
  check("moved next to the target", leavesOf(t), [1, 3, 2]);
  check("the vacated split collapsed", t.b, leaf(2));
}
{
  const t = moveWithin(three(), 3, 1, "left");
  check("left puts the source first", leavesOf(t), [3, 1, 2]);
}
{
  const t = moveWithin(three(), 1, 2, "bottom");
  check("bottom splits by column", t.a.dir ?? t.dir, "col");
  check("and the source lands second", leavesOf(t), [2, 1, 3]);
}
// A target outside the tree used to drop the source first and then fail
// to place it, leaving a live terminal that no layout pointed at. Nothing
// reported that, which is exactly why it is worth refusing outright.
check(
  "a target not in the tree is refused, not half-applied",
  moveWithin(split("row", leaf(1), leaf(2)), 1, 5, "left"),
  null
);
check(
  "a source not in the tree is refused too",
  moveWithin(split("row", leaf(1), leaf(2)), 9, 2, "left"),
  null
);
check(
  "swap with an absent pane is refused",
  moveWithin(split("row", leaf(1), leaf(2)), 1, 9, "swap"),
  null
);

// ── where a drop lands ─────────────────────────────────────────────────
const rect = { left: 0, top: 0, width: 100, height: 100 };
check("dead centre swaps", dropSideAt(rect, 50, 50), "swap");
check("far left places left", dropSideAt(rect, 5, 50), "left");
check("far right places right", dropSideAt(rect, 95, 50), "right");
check("top places above", dropSideAt(rect, 50, 5), "top");
check("bottom places below", dropSideAt(rect, 50, 95), "bottom");
// The corners are the ambiguous ones: nearest edge wins, and ties resolve
// consistently rather than flickering between two answers.
check("a corner picks the nearer edge", dropSideAt(rect, 10, 40), "left");
check("the other corner likewise", dropSideAt(rect, 40, 10), "top");
check("just outside the swap zone is an edge", dropSideAt(rect, 50, 29), "top");
// Fractions, not pixels: a tall pane and a wide one must behave alike.
const wide = { left: 0, top: 0, width: 1000, height: 100 };
check("a wide pane still swaps in the middle", dropSideAt(wide, 500, 50), "swap");
check("a wide pane still places left near its edge", dropSideAt(wide, 50, 50), "left");
// Offset rects must not be measured from the origin.
const off = { left: 500, top: 300, width: 100, height: 100 };
check("an offset pane swaps at its own centre", dropSideAt(off, 550, 350), "swap");
check("an offset pane places left at its own edge", dropSideAt(off, 505, 350), "left");

if (failed) {
  console.log(`${failed} layout test(s) failed`);
  process.exit(1);
}
console.log("all layout tests passed");
