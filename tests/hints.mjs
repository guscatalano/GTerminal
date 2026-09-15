// When the window volunteers that Shift exists.
// Run: node tests/hints.mjs
//
// The case this is for: a full-screen program has asked for the mouse,
// so a drag belongs to the program and selects nothing. Every route to
// the answer is closed by the same fact - no selection, so the menu has
// no Copy to offer, and a shortcut list in settings is no use to someone
// who does not yet know there is a shortcut to look for.
//
// Which makes the hint worth showing, and makes when it is *not* shown
// the part worth testing. A hint that appears on every click into a TUI
// is noise, and noise is how a hint stops being read at all.
import {
  SHIFT_HINT_LIMIT,
  SHIFT_HINT_TEXT,
  shiftHintLearned,
  shouldOfferShiftHint,
} from "../src/hints.ts";

let failed = 0;
function check(name, got, want) {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${ok ? "" : `: got ${JSON.stringify(got)}, wanted ${JSON.stringify(want)}`}`);
  if (!ok) failed++;
}

const fresh = { shown: 0, learned: false };
// A drag that came back empty while a program held the mouse.
const eaten = { tracking: true, dragged: true, shift: false, selected: false };

check("a drag eaten by the program earns the hint", shouldOfferShiftHint(eaten, fresh), true);

// Every reason not to.
check(
  "not when no program is reading the mouse — an empty drag there is just an empty drag",
  shouldOfferShiftHint({ ...eaten, tracking: false }, fresh),
  false
);
check(
  "not for a click — clicking into a TUI is how you use it",
  shouldOfferShiftHint({ ...eaten, dragged: false }, fresh),
  false
);
check(
  "not when Shift was already held — they know",
  shouldOfferShiftHint({ ...eaten, shift: true }, fresh),
  false
);
check(
  "not when something did get selected — nothing went wrong",
  shouldOfferShiftHint({ ...eaten, selected: true }, fresh),
  false
);
check(
  "and never again once it has been learned",
  shouldOfferShiftHint(eaten, { shown: 0, learned: true }),
  false
);

// Twice, then it stops. The first lands while somebody is mid-task and
// reading something else; a third would be nagging.
check("still offered on the last allowed showing", shouldOfferShiftHint(eaten, { shown: SHIFT_HINT_LIMIT - 1, learned: false }), true);
check("and not after that", shouldOfferShiftHint(eaten, { shown: SHIFT_HINT_LIMIT, learned: false }), false);
check("nor long after that", shouldOfferShiftHint(eaten, { shown: 99, learned: false }), false);

// The other half: the gesture that proves the lesson landed.
check(
  "a shift-drag that selects something is the lesson landing",
  shiftHintLearned({ tracking: true, dragged: true, shift: true, selected: true }),
  true
);
check(
  "a shift-drag that selected nothing proves nothing",
  shiftHintLearned({ tracking: true, dragged: true, shift: true, selected: false }),
  false
);
check(
  "and neither does a shift-drag with no program reading the mouse — Shift was not what made it work",
  shiftHintLearned({ tracking: false, dragged: true, shift: true, selected: true }),
  false
);

// The wording is the feature. It has to answer the question actually
// being asked - "why did my drag do nothing" - before giving the
// instruction, and it has to name the key that copies, because
// selecting and copying are two different problems and the second one
// is the one they came for.
check("the hint explains before instructing", /using the mouse/.test(SHIFT_HINT_TEXT), true);
check("names the key that selects", /Shift/.test(SHIFT_HINT_TEXT), true);
check("and the key that copies", /Ctrl\+Shift\+C/.test(SHIFT_HINT_TEXT), true);

if (failed) {
  console.log(`${failed} hint test(s) failed`);
  process.exit(1);
}
console.log("all hint tests passed");
