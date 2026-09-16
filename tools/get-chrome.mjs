// Download a pinned Chrome for Testing build and print the path to its
// chrome.exe on stdout (everything else goes to stderr, so a caller can do
//   GT_BROWSER=$(node tools/get-chrome.mjs Stable)   ).
//
// Why Chrome for Testing and not Edge: the app renders in WebView2, which
// is Chromium, and Edge tracks that same upstream. Edge has no pinned,
// downloadable-by-version distribution the way Chrome for Testing does, so
// this is how the suites get an exact, reproducible engine to test against
// - a stable one, a beta one, whatever the matrix asks for. For the WebGL /
// canvas / layout the terminal exercises, a channel here is a faithful
// proxy for the Edge/WebView2 a user will get on that same Chromium.
//
// usage: node tools/get-chrome.mjs [Stable|Beta|Dev|Canary]   (default Stable)
import { execFileSync } from "node:child_process";
import { mkdirSync, existsSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const INDEX =
  "https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json";
const PLATFORM = "win64"; // the app is Windows-only; so is its engine.

const want = (process.argv[2] || "Stable").toLowerCase();

function log(...a) {
  console.error("[get-chrome]", ...a);
}

async function main() {
  const index = await (await fetch(INDEX)).json();
  const channelKey = Object.keys(index.channels).find((k) => k.toLowerCase() === want);
  if (!channelKey) {
    throw new Error(
      `unknown channel ${JSON.stringify(process.argv[2])}; have ${Object.keys(index.channels).join(", ")}`
    );
  }
  const channel = index.channels[channelKey];
  const dl = channel.downloads.chrome.find((d) => d.platform === PLATFORM);
  if (!dl) throw new Error(`no chrome ${PLATFORM} build in channel ${channelKey}`);

  // Cache by version so a second run on the same machine reuses the build.
  const home = join(tmpdir(), "gt-chrome-for-testing", `${channelKey}-${channel.version}`);
  const exe = join(home, "chrome-win64", "chrome.exe");
  if (existsSync(exe)) {
    log(`cached ${channelKey} ${channel.version}`);
    process.stdout.write(exe);
    return;
  }

  log(`downloading ${channelKey} ${channel.version} (${PLATFORM})`);
  mkdirSync(home, { recursive: true });
  const zip = join(home, "chrome.zip");
  const buf = Buffer.from(await (await fetch(dl.url)).arrayBuffer());
  writeFileSync(zip, buf);
  log(`extracting ${(buf.length / 1e6).toFixed(0)} MB`);
  // Windows' own tar (System32) is bsdtar and extracts zip; a shell's PATH
  // may resolve `tar` to git's GNU tar first, which cannot. Name the system
  // one so this behaves the same in a dev shell and on the CI runner. Run it
  // from `home` with a relative name, or bsdtar reads the drive colon in an
  // absolute C:\... path as a remote host:path and refuses.
  const tarExe = join(process.env.SystemRoot || "C:\\Windows", "System32", "tar.exe");
  execFileSync(existsSync(tarExe) ? tarExe : "tar", ["-xf", "chrome.zip"], {
    cwd: home,
    stdio: "inherit",
  });
  rmSync(zip, { force: true });

  if (!existsSync(exe)) throw new Error(`extracted, but no chrome.exe at ${exe}`);
  log(`ready: ${exe}`);
  process.stdout.write(exe);
}

main().catch((e) => {
  log("failed:", e.message);
  process.exit(1);
});
