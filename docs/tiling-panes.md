# Tiling panes — design notes

**Status:** not started. This is a plan, not a description of anything that
exists. Written 2026-08-16 against `main` at v0.4.1.

Goal: split a tab into multiple terminals side by side, tmux/Windows
Terminal style.

## Why this is cheap

The daemon already owns sessions independently and the window is only a
client that attaches to them by id (`attach_session`, `resize_session`). A
split is just two attached sessions drawn next to each other.

- No Rust changes.
- No daemon protocol changes.
- Splits survive reboots for free, *provided the layout is persisted* —
  the sessions themselves already come back.

Everything below is frontend work in `src/main.ts` plus CSS.

## The refactor this needs

`Tab` currently conflates three things — a session, a pane element, and a
tab button — and `tabs` is keyed by session id. See `setActive`,
`fitTab`, `removeTab`. Tiling needs them separated:

```ts
interface PaneView { id: number; term; fit; el: HTMLElement; webgl?; icon; shellB }
interface TabEntry { key: string; button: HTMLElement; root: LayoutNode; focused: number }

type LayoutNode =
  | { kind: "leaf";  id: number }
  | { kind: "split"; dir: "row" | "col"; ratio: number; a: LayoutNode; b: LayoutNode };
```

A binary tree (the tmux/i3 model), not a flat grid: it nests arbitrarily
and makes "split the focused pane" a local operation.

### Tab identity is the decision that matters

Everything persisted keys off session id today: `tabOrder`,
`groupState.assign`, `customTitles`, `hidden`, `gterm-tab-widths`.

- **Cheap option** — tab identity is its first session's id. Small diff,
  but closing that pane forces a re-key. Subtle bug farm.
- **Right option** — tabs get their own id; migrate existing
  `gterm-order` as one-tab-per-session. Touches every persisted map and
  their pruning in `main()`, but only once.

Take the second.

## Rendering

Recursive flex containers. A split node is a flexbox with
`flex-direction: row | column`, children sized `flex: ratio` and
`flex: 1 - ratio`, with a ~4px divider between them.

Dividers can reuse `beginPointerDrag(e, el, "x" | "y", …)`, which already
drives tab and sidebar dragging. Drag updates `ratio` and re-fits.

## Functions that change

| Function | Change |
|---|---|
| `setActive` | becomes tab-level; add `focusPane(sessionId)` for the focus ring |
| `fitTab` | fit **every leaf** in the active tab, not one terminal |
| `createTab` | split into `openTab()` and `splitPane(dir)`; the latter inherits the focused pane's cwd, like tmux |
| `removeTab` | closing a pane collapses its parent split; only the last pane closes the tab; the `tabs.size === 0 → close window` check moves up a level |
| `closeTabViaKeyboard` | Ctrl+Shift+W targets the focused *pane* |
| `refreshChrome` | tab label and icon follow the focused pane |
| `activeCwd()` | focused pane, not active tab — status-bar command items depend on this |

## Persistence

Serialize the tree per tab into `localStorage` next to `gterm-order`, and
prune it on startup against the daemon's session list — the same pattern
`hidden` and `groupState` already use in `main()`. Sessions that vanished
collapse out of the tree.

## Layouts this model supports

Every one of these is plain recursive bisection, no extra machinery:

```
even columns        even rows          main + stack       quad
┌────┬────┬────┐   ┌───────────┐      ┌──────┬─────┐    ┌─────┬─────┐
│    │    │    │   ├───────────┤      │      ├─────┤    │     │     │
│    │    │    │   ├───────────┤      │      ├─────┤    ├─────┼─────┤
└────┴────┴────┘   └───────────┘      └──────┴─────┘    └─────┴─────┘

main + bottom      IDE three-column    spiral / golden
┌───────────┐      ┌───┬───────┬───┐  ┌──────┬──────┐
│           │      │   │       │   │  │      ├───┬──┤
├─────┬─────┤      │   │       │   │  │      ├───┴──┤
└─────┴─────┘      └───┴───────┴───┘  └──────┴──────┘
```

These line up with tmux's named layouts (`even-horizontal`,
`even-vertical`, `main-vertical`, `main-horizontal`, `tiled`), which is a
good sign — proven vocabulary.

### Dynamic behaviours

- **Auto-tile** — a new pane splits whichever pane is *largest*,
  alternating direction. Balanced layouts without ever picking a
  direction. Good default for the plain split key.
- **Zoom** (tmux `Ctrl-b z`) — blow one pane up to the whole tab
  temporarily, layout preserved underneath. Cheap, disproportionately
  useful.
- **Rebalance** — reset all ratios to even.
- **Rotate / swap** — cycle panes within a split, or swap two without
  touching sizes.
- **Promote** — move a pane out to its own tab, or pull a tab in as a
  pane.

### Sizing modes per pane

- **Ratio** (default) — keeps its share as the window resizes.
- **Fixed** — e.g. a 12-row log pane that stays 12 rows on resize. tmux
  can't really do this and people miss it.
- **Min size** — collapse guard so a drag can't make a pane unusable.

## The workspace angle

This is the payoff. Workspaces today launch N templates as N tabs. If a
workspace could describe a *layout* instead, one shortcut would open:

```
"XYZ project" → ┌──────────────┬────────────┐
                │ editor (repo)│ server     │
                │              ├────────────┤
                │              │ logs       │
                └──────────────┴────────────┘
```

Every pane with its own shell, folder, and startup command. Mostly
serialization work once the tree exists: the workspace JSON gains a
layout tree instead of a flat list of template names.

## What this model cannot express

A binary tree only produces **guillotine** layouts — arrangements you
could cut from a sheet with straight edge-to-edge cuts. The pinwheel is
the classic counterexample:

```
┌───────┬───┐
├───┬───┤   │   no single straight cut splits this
│   │   │   │   into two rectangles
│   ├───┴───┤
└───┴───────┘
```

Supporting it needs general rectangle packing — much more complexity in
resizing, focus navigation, and serialization. tmux, i3 and Windows
Terminal are all guillotine-only and nobody complains. Not worth it.

## Gotchas specific to this codebase

1. **Dividers need the veil.** Any pixel without terminal cells shows the
   background art unveiled — this bit us twice already (the left gutter,
   then the strip above the status bar). Dividers and split gutters must
   use `--cell-veil` or there will be bright seams between panes.
2. **WebGL is disposed whenever background art is active**
   (`applyAppearance`). Four DOM-rendered terminals is a real cost.
   Re-run `npm run test:typing` against a 4-pane layout — p50 echo
   latency is a tracked budget.
3. `ResizeObserver` is already per-pane, so that part scales cleanly.
4. **Grace-window restore needs a target.** Restoring a killed session
   should either return to its old slot or open a new tab. Undecided.
5. **Sidebar** lists sessions flat; with splits it should show which tab
   a session belongs to.

## Phasing

1. Tree model, split / close / focus, fit. No dragging, no persistence.
   This is the risky part; everything after is additive.
2. Draggable dividers with ratios.
3. Persistence and reboot restore.
4. Navigation keys (Alt+arrows), zoom, move-pane-to-tab, broadcast input.
5. Workspace layout templates.

Phase 1 is roughly 400–600 lines of TypeScript and no Rust.

## Open decisions

- Tab identity: own id (preferred) vs first session's id.
- What a multi-pane tab shows as its title and icon — focused pane, or
  something aggregated.
- Where a restored session from the grace window lands.
- Default split keybindings. Ctrl+Shift+D / Ctrl+Shift+E are free;
  Ctrl+Shift+W would move from "close tab" to "close pane".
