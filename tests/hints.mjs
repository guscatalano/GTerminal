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
  MOUSE_SELECTION_NOTE,
  RIGHT_CLICK_MENU_NOTE,
  copiedNote,
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
check("the hint explains before it suggests", /using the mouse/.test(SHIFT_HINT_TEXT), true);
check("names the key that selects", /Shift/.test(SHIFT_HINT_TEXT), true);
check("and the key that copies", /Ctrl\+Shift\+C/.test(SHIFT_HINT_TEXT), true);
// Suggested, not ordered. How much Shift takes back is between the
// terminal and the program - one that does its own selection may not
// give the drag up at all - and an instruction that does nothing when
// followed is worse than no instruction.
check("and suggests rather than instructs", / Try /.test(SHIFT_HINT_TEXT), true);
check("so it does not read as a rule", /^Hold Shift/.test(SHIFT_HINT_TEXT), false);


// ── saying that a copy happened ────────────────────────────────────────
// Every one of these ends with the way back to the menu. The person
// reading it has just lost a highlight to a gesture they expected to
// open one, and the menu is a modifier away - a fact that otherwise
// lives only in the settings page, which is not where they are.
const withTail = (head) => `${head} · ${RIGHT_CLICK_MENU_NOTE}`;
// The console's right button copies the selection and clears the
// highlight. Reported as "I select, then right-click and it disappears"
// - by somebody whose text had in fact been copied. A highlight that
// vanishes with nothing said is indistinguishable from one that was
// lost, so the pane says what went to the clipboard.
check("one line is shown back, so it can be recognised", copiedNote("hello world"), withTail("Copied 11 characters: hello world"));
check("a single character is not 1 characters", copiedNote("x"), withTail("Copied 1 character: x"));
// Long output is counted, not reprinted: a confirmation that puts a
// page of text back on the screen is a second problem.
check(
  "a long line is cut short",
  copiedNote("y".repeat(80)),
  withTail("Copied 80 characters: " + "y".repeat(40) + "…")
);
check(
  "several lines are counted rather than shown",
  copiedNote("one\ntwo\nthree"),
  withTail("Copied 3 lines, 13 characters")
);
check(
  "and CRLF counts the same as LF — the shell writes one and the clipboard the other",
  copiedNote("one\r\ntwo"),
  withTail("Copied 2 lines, 8 characters")
);
// The count is of what was copied, not of what is shown: trimming is
// for reading, and a report that disagreed with the clipboard would be
// worse than no report.
check(
  "leading space is trimmed from the preview but not from the count",
  copiedNote("   indented"),
  withTail("Copied 11 characters: indented")
);


check("and the way to the menu is on the end of it", copiedNote("x").endsWith(RIGHT_CLICK_MENU_NOTE), true);
check("which names shift, since that is what reaches the menu under either setting", /Shift/.test(RIGHT_CLICK_MENU_NOTE), true);


// ── why Copy is not in this menu ───────────────────────────────────────
// The hint teaches and is rationed; this answers and is not. The log of
// the session that prompted it shows why both are needed: two hint
// showings spent on the first two drags, then six menus in thirty-five
// seconds with no Copy in them and nothing left to say why.
check("the note says what is missing first", /^Nothing selected/.test(MOUSE_SELECTION_NOTE), true);
check("then why", /using the mouse/.test(MOUSE_SELECTION_NOTE), true);
check("then what to do instead", /Shift\+drag/.test(MOUSE_SELECTION_NOTE), true);
// It is not the hint. The hint suggests, because how much shift takes
// back is between the terminal and the program; this one states a fact
// about why an item is absent, and hedging it would leave somebody
// wondering whether the menu was broken.
check("and it is not just the hint again", MOUSE_SELECTION_NOTE === SHIFT_HINT_TEXT, false);

if (failed) {
  console.log(`${failed} hint test(s) failed`);
  process.exit(1);
}
console.log("all hint tests passed");
