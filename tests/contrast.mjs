// Contrast audit: every theme's fg + 16 ANSI colors vs its background.
// WCAG relative luminance; flags pairs below 3.0 (readable-text floor for
// terminal content). Run: node tests/contrast.mjs   (exit 1 on failures)
import { readFileSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";

const here = dirname(fileURLToPath(import.meta.url));
const src = readFileSync(join(here, "..", "src", "main.ts"), "utf8");

// Pull each mkTheme call's bg, fg, and ansi array out of the source.
const themes = [];
const re = /mkTheme\(\s*"([^"]+)",[\s\S]*?"(#[0-9a-fA-F]{6})",\s*"(#[0-9a-fA-F]{6})",\s*\[\s*([\s\S]*?)\]\s*\)/g;
let m;
while ((m = re.exec(src))) {
  const ansi = [...m[4].matchAll(/#[0-9a-fA-F]{6}/g)].map((x) => x[0]);
  if (ansi.length === 16) themes.push({ name: m[1], bg: m[2], fg: m[3], ansi });
}

function lum(hex) {
  const c = [1, 3, 5].map((i) => {
    let v = parseInt(hex.slice(i, i + 2), 16) / 255;
    return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
  });
  return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
}
function contrast(a, b) {
  const [l1, l2] = [lum(a), lum(b)].sort((x, y) => y - x);
  return (l1 + 0.05) / (l2 + 0.05);
}

const NAMES = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
  "brBlack", "brRed", "brGreen", "brYellow", "brBlue", "brMagenta", "brCyan", "brWhite"];
const FLOOR = 3.0;
let failures = 0;

for (const t of themes) {
  const bad = [];
  const lightBg = lum(t.bg) > 0.5;
  const fgRatio = contrast(t.fg, t.bg);
  if (fgRatio < 4.5) bad.push(`fg ${t.fg} = ${fgRatio.toFixed(2)}`);
  t.ansi.forEach((c, i) => {
    // Background-tier colors are legitimately near-bg: black on dark
    // themes, white/brWhite on light themes. brBlack is dim-text — give
    // it a lower floor rather than none.
    if (i === 0) return;
    if (lightBg && (i === 7 || i === 15)) return;
    const floor = i === 8 ? 2.5 : FLOOR;
    const r = contrast(c, t.bg);
    if (r < floor) bad.push(`${NAMES[i]} ${c} = ${r.toFixed(2)}`);
  });
  // PSReadLine prominence: commands render in brYellow (11), arguments in
  // white (7). The command must never look thinner than its arguments.
  const cmd = t.ansi[11], arg = t.ansi[7];
  if (lightBg) {
    // On light bg the renderer's minimumContrastRatio darkens a near-bg
    // white(7) to ~4.5; the command needs at least that much on its own.
    const r = contrast(cmd, t.bg);
    if (r < 4.5) bad.push(`brYellow(cmd) ${cmd} = ${r.toFixed(2)} < 4.5 (thinner than args)`);
  } else if (lum(arg) > lum(cmd) * 1.25) {
    bad.push(`white(arg) ${arg} brighter than brYellow(cmd) ${cmd}: commands look thin`);
  }
  if (bad.length) {
    failures += bad.length;
    console.log(`FAIL ${t.name} (bg ${t.bg}):`);
    for (const b of bad) console.log(`   ${b}`);
  } else {
    console.log(`PASS ${t.name}`);
  }
}
console.log(themes.length + " themes audited");
process.exit(failures ? 1 : 0);
