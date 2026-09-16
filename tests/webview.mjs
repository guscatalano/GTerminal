// Whether the window warns about the engine it is drawn in. Run: node tests/webview.mjs
//
// The warning has to fire for a genuinely old engine and stay silent for a
// current one, a dismissed one, or one it cannot read - each of which,
// gotten wrong, is either a false alarm on most machines or no warning on
// the one machine that needed it.
import { chromiumMajor, shouldWarnOldWebview, MIN_WEBVIEW } from "../src/webview.ts";

let failed = 0;
function check(name, got, want) {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${ok ? "" : `: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`}`);
  if (!ok) failed++;
}

// A real WebView2 user agent, Edge and Chrome tokens both present.
const UA = (n) =>
  `Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/${n}.0.0.0 Safari/537.36 Edg/${n}.0.0.0`;

check("reads the Chromium major", chromiumMajor(UA(118)), 118);
check("reads a three-digit major", chromiumMajor(UA(153)), 153);
check("no Chrome token is null", chromiumMajor("Mozilla/5.0 (X11; Linux) Gecko"), null);

const warn = (over = {}) => shouldWarnOldWebview({ major: 100, enabled: true, ...over });

// The floor.
check("an old engine warns", warn({ major: MIN_WEBVIEW - 1 }), true);
check("the floor itself is fine", warn({ major: MIN_WEBVIEW }), false);
check("a newer engine is fine", warn({ major: MIN_WEBVIEW + 20 }), false);

// The guards.
check("off means never", warn({ major: 90, enabled: false }), false);
check("unknown says nothing", warn({ major: null }), false);
check("the dismissed version stays quiet", warn({ major: 90, dismissed: 90 }), false);
check("a different old version still warns", warn({ major: 88, dismissed: 90 }), true);

if (failed) {
  console.log("");
  console.log(`${failed} webview test(s) failed`);
  process.exit(1);
}
console.log("");
console.log("all webview tests passed");
