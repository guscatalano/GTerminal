// The settings page groups its sections into tabs; this pins that map.
// Run: node tests/settings.mjs
//
// Thirteen sections in one scroll was the "long overwhelming list". They
// are grouped into five tabs now, and the danger is quiet: add a section
// and forget to file it in a group and it drops into the catch-all "Other"
// tab, which is not where anyone will look for it. So every section a
// settingsSection() call creates must be named in exactly one group, and
// every name a group lists must be a real section — no typos that would
// silently never match. Pure shape checks against main.ts.
import { readFileSync } from "fs";

let failed = 0;
function check(name, ok, detail = "") {
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${ok ? "" : `: ${detail}`}`);
  if (!ok) failed++;
}

const main = readFileSync(new URL("../src/main.ts", import.meta.url), "utf8");

// Every section the page builds, from its settingsSection("…") calls.
const sections = [...main.matchAll(/settingsSection\("([^"]+)"\)/g)]
  .map((m) => m[1])
  .filter((t) => t !== "Other"); // the catch-all is not a built section
const uniqueSections = [...new Set(sections)];

// The group map: pull each `sections: [ … ]` list out of SETTINGS_GROUPS.
const groupBlock = main.match(/const SETTINGS_GROUPS[\s\S]*?\n\];/);
check("the SETTINGS_GROUPS map exists", !!groupBlock, "could not find the SETTINGS_GROUPS array");
const grouped = groupBlock
  ? [...groupBlock[0].matchAll(/sections:\s*\[([^\]]*)\]/g)].flatMap((m) =>
      [...m[1].matchAll(/"([^"]+)"/g)].map((s) => s[1])
    )
  : [];

// No section listed in two groups.
const dupes = grouped.filter((s, i) => grouped.indexOf(s) !== i);
check("no section is filed in two groups", dupes.length === 0, `duplicated: ${dupes.join(", ")}`);

// Every built section has a group.
const homeless = uniqueSections.filter((s) => !grouped.includes(s));
check(
  "every settings section is filed in a group",
  homeless.length === 0,
  `these would fall into "Other": ${homeless.join(", ")}`
);

// Every name a group lists is a real section (catches a typo that would
// never match and quietly drop the section into "Other").
const phantom = grouped.filter((s) => !uniqueSections.includes(s));
check(
  "every group entry names a real section",
  phantom.length === 0,
  `named in a group but never built: ${phantom.join(", ")}`
);

// Five groups, as designed.
const groupNames = groupBlock
  ? [...groupBlock[0].matchAll(/name:\s*"([^"]+)"/g)].map((m) => m[1])
  : [];
check("the five groups are the five groups", groupNames.join(",") === "Appearance,Terminal,Window,Remote control,System", groupNames.join(","));

// The page is regrouped and the tabs are drawn on every rebuild.
check("the flat list is regrouped after it is built", /groupSettingsList\(\);/.test(main), "buildSettingsPage must call groupSettingsList()");
check("and the tab bar is drawn over it", /buildSettingsTabs\(\);/.test(main), "buildSettingsPage must call buildSettingsTabs()");
// The filter still works across the new headings: a group heading hides
// when its whole group is filtered away.
check("the filter closes empty group headings", /settings-group-title/.test(main) && /closeGroup\(\)/.test(main), "filterSettings must hide a group with no matching rows");

if (failed) {
  console.log(`${failed} settings test(s) failed`);
  process.exit(1);
}
console.log("all settings tests passed");
