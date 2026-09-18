// "Copy this line" joins the rows a wrapped line spans. Run: node tests/copyline.mjs
//
// A long line wraps across several buffer rows; a click lands on one of
// them, and "copy this line" has to return the whole line, not the visual
// row it hit. This drives the joining over a fake buffer - rows with a
// wrapped flag and text - so the walk is checked without a terminal.
import { logicalLine } from "../src/copyline.ts";

let failed = 0;
function check(name, got, want) {
  const ok = got === want;
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${ok ? "" : `: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`}`);
  if (!ok) failed++;
}

// rows: [{ w: isWrapped, t: full text }]; text(trim) drops trailing spaces.
function buffer(rows) {
  return (y) => {
    if (y < 0 || y >= rows.length) return undefined;
    const r = rows[y];
    return { isWrapped: r.w, text: (trim) => (trim ? r.t.replace(/ +$/, "") : r.t) };
  };
}

// A plain, unwrapped line is itself, trimmed.
check("a plain line is itself, trimmed", logicalLine(buffer([{ w: false, t: "hello   " }]), 0), "hello");

// A line wrapped across three rows: any row on it returns the whole line.
{
  const b = buffer([{ w: false, t: "AAAA" }, { w: true, t: "BBBB" }, { w: true, t: "CC  " }]);
  check("clicking the first row joins the whole line", logicalLine(b, 0), "AAAABBBBCC");
  check("clicking a middle row joins the whole line", logicalLine(b, 1), "AAAABBBBCC");
  check("clicking the last row joins the whole line", logicalLine(b, 2), "AAAABBBBCC");
}

// Inner rows keep their trailing space (the gap between words); only the
// last row is trimmed.
{
  const b = buffer([{ w: false, t: "one two " }, { w: true, t: "three   " }]);
  check("only the last row is trimmed, the wrap-point space stays", logicalLine(b, 0), "one two three");
}

// A wrapped line between neighbours pulls neither of them in.
{
  const b = buffer([{ w: false, t: "before" }, { w: false, t: "wrapA" }, { w: true, t: "wrapB" }, { w: false, t: "after" }]);
  check("the line above is not joined", logicalLine(b, 1), "wrapAwrapB");
  check("the line below is not joined", logicalLine(b, 2), "wrapAwrapB");
  check("a neighbour stays itself", logicalLine(b, 3), "after");
}

if (failed) {
  console.log("");
  console.log(`${failed} copy-line test(s) failed`);
  process.exit(1);
}
console.log("");
console.log("all copy-line tests passed");
