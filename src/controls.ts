// Is a control actually on screen?
//
// "Does the – button even show up?" is not a question CSS answers: a
// button can be present, styled, and still invisible because the tab it
// lives in is too narrow and has clipped it. Those are different faults
// with different fixes — one is a setting, the other is tab width — so
// the answer has to tell them apart rather than say "no".

export interface ControlRect {
  /// The control's own width, 0 when it is not laid out at all.
  width: number;
  /// Its right edge, and the right edge of whatever contains it.
  right: number;
  ownerRight: number;
  /// display:none, or no offsetParent — laid out nowhere.
  hidden: boolean;
}

export type ControlState = "visible" | "clipped" | "hidden";

export function controlState(r: ControlRect): ControlState {
  if (r.hidden || r.width <= 0) return "hidden";
  // Half a pixel of slack: a control flush with the edge is visible, and
  // sub-pixel layout should not report it as cut off.
  return r.right <= r.ownerRight + 0.5 ? "visible" : "clipped";
}

/// A sentence for the settings page. It names the count, because "some of
/// your tabs" is the sort of answer that sends someone counting tabs.
export function visibilityReport(rects: ControlRect[]): string {
  if (!rects.length) return "No tabs are open to check.";
  const states = rects.map(controlState);
  const visible = states.filter((s) => s === "visible").length;
  const clipped = states.filter((s) => s === "clipped").length;
  const total = states.length;
  if (visible === total) return total === 1 ? "Visible on the open tab." : `Visible on all ${total} tabs.`;
  if (clipped > 0 && visible === 0) {
    return `Cut off on ${clipped === total ? "every tab" : `${clipped} of ${total} tabs`} — the tabs are too narrow.`;
  }
  if (clipped > 0) return `Visible on ${visible} of ${total} tabs, cut off on ${clipped} — those tabs are too narrow.`;
  return `Not shown on ${total - visible} of ${total} tabs.`;
}
