// The pane layout tree, and every operation on it that is pure.
//
// A binary tree, the tmux/i3 model: it nests arbitrarily and makes
// "split the focused pane" a local operation. See docs/tiling-panes.md.
//
// This lives apart from main.ts so it can be tested without a browser.
// Every function here takes a tree and returns a new one; nothing reads
// the DOM or the session maps. The DOM half — rendering, fitting,
// focusing — stays in main.ts and is not testable this way.

export type LayoutNode =
  | { kind: "leaf"; id: number }
  | { kind: "split"; dir: "row" | "col"; ratio: number; a: LayoutNode; b: LayoutNode };

export type DropSide = "left" | "right" | "top" | "bottom" | "swap";

export function leavesOf(n: LayoutNode): number[] {
  return n.kind === "leaf" ? [n.id] : [...leavesOf(n.a), ...leavesOf(n.b)];
}

export function replaceLeaf(n: LayoutNode, id: number, repl: LayoutNode): LayoutNode {
  if (n.kind === "leaf") return n.id === id ? repl : n;
  return { ...n, a: replaceLeaf(n.a, id, repl), b: replaceLeaf(n.b, id, repl) };
}

/// Remove a leaf and collapse the split that held it; null when the tree
/// was nothing but that leaf. Collapsing is the point: a split with one
/// arm left would render as a divider against nothing.
export function dropLeaf(n: LayoutNode, id: number): LayoutNode | null {
  if (n.kind === "leaf") return n.id === id ? null : n;
  const a = dropLeaf(n.a, id);
  const b = dropLeaf(n.b, id);
  if (!a) return b;
  if (!b) return a;
  return { ...n, a, b };
}

/// Drop every leaf whose session the daemon no longer has. Sessions can
/// die while their tab is not on screen, so a restored layout is checked
/// against reality rather than trusted.
export function pruneTree(n: LayoutNode, alive: Set<number>): LayoutNode | null {
  if (n.kind === "leaf") return alive.has(n.id) ? n : null;
  const a = pruneTree(n.a, alive);
  const b = pruneTree(n.b, alive);
  if (!a) return b;
  if (!b) return a;
  return { ...n, a, b };
}

/// Split one leaf in two. `first` puts the new pane before the old one,
/// which is what "split left" and "split up" mean.
export function splitLeaf(
  tree: LayoutNode,
  target: number,
  newId: number,
  dir: "row" | "col",
  first = false
): LayoutNode {
  return replaceLeaf(tree, target, {
    kind: "split",
    dir,
    ratio: 0.5,
    a: { kind: "leaf", id: first ? newId : target },
    b: { kind: "leaf", id: first ? target : newId },
  });
}

/// Even chain of leaves in one direction: ratios shrink down the chain so
/// every pane ends up the same size. Three panes are thirds, not a half
/// and two quarters.
export function evenChain(ids: number[], dir: "row" | "col"): LayoutNode {
  if (ids.length === 1) return { kind: "leaf", id: ids[0] };
  return {
    kind: "split",
    dir,
    ratio: 1 / ids.length,
    a: { kind: "leaf", id: ids[0] },
    b: evenChain(ids.slice(1), dir),
  };
}

/// Balanced split, alternating direction — roughly square cells.
export function tiled(ids: number[], dir: "row" | "col" = "row"): LayoutNode {
  if (ids.length === 1) return { kind: "leaf", id: ids[0] };
  const half = Math.ceil(ids.length / 2);
  const next = dir === "row" ? "col" : "row";
  return {
    kind: "split",
    dir,
    ratio: half / ids.length,
    a: tiled(ids.slice(0, half), next),
    b: tiled(ids.slice(half), next),
  };
}

/// Move a pane next to another, or exchange the two.
///
/// Removing the source can collapse the split that held it, which can
/// move the target — so the target is re-found in the pruned tree rather
/// than in the original. Returns null when the move cannot be made, so
/// callers do not render a half-applied layout.
export function moveWithin(
  tree: LayoutNode,
  src: number,
  target: number,
  side: DropSide
): LayoutNode | null {
  if (src === target) return null;
  // Both ends must be in this tree. Without the target check the source
  // is dropped first and then never placed — the pane survives as a live
  // terminal that no layout points at, which is worse than a visible
  // failure because nothing reports it.
  const here = leavesOf(tree);
  if (!here.includes(src) || !here.includes(target)) return null;
  if (side === "swap") {
    const swap = (n: LayoutNode): LayoutNode =>
      n.kind === "leaf"
        ? { kind: "leaf", id: n.id === src ? target : n.id === target ? src : n.id }
        : { ...n, a: swap(n.a), b: swap(n.b) };
    return swap(tree);
  }
  const without = dropLeaf(tree, src);
  if (!without) return null;
  const dir: "row" | "col" = side === "left" || side === "right" ? "row" : "col";
  const first = side === "left" || side === "top";
  return replaceLeaf(without, target, {
    kind: "split",
    dir,
    ratio: 0.5,
    a: { kind: "leaf", id: first ? src : target },
    b: { kind: "leaf", id: first ? target : src },
  });
}

/// Which part of a pane a point is over: the middle means "swap", the
/// outer bands mean "put it on that side". Fractions rather than pixels,
/// so a tall pane and a wide one behave the same.
export function dropSideAt(
  r: { left: number; top: number; width: number; height: number },
  x: number,
  y: number
): DropSide {
  const fx = (x - r.left) / r.width;
  const fy = (y - r.top) / r.height;
  if (fx > 0.3 && fx < 0.7 && fy > 0.3 && fy < 0.7) return "swap";
  const d: Array<[DropSide, number]> = [
    ["left", fx],
    ["right", 1 - fx],
    ["top", fy],
    ["bottom", 1 - fy],
  ];
  d.sort((a, b) => a[1] - b[1]);
  return d[0][0];
}
