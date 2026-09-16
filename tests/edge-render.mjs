// Render a fixture in headless Edge and print its final DOM to stdout.
//
// This is the CDP replacement for `--dump-dom`, a headless convenience
// flag current Edge/Chromium removed (Edge 153 emits nothing; the app's
// own WebView2 tracks that same engine). The render suites drove Edge
// with `--headless=new --virtual-time-budget=N --dump-dom <url>` and read
// the DOM string off stdout; this speaks the DevTools protocol instead -
// which Edge has NOT removed - and prints the same document, so a caller
// changes only how it launches, not how it parses.
//
// Virtual time is preserved faithfully via Emulation.setVirtualTimePolicy
// (the very mechanism `--virtual-time-budget` drove): grant the budget,
// let it drain, then read outerHTML. That keeps the deterministic timing
// the probes rely on, so a probe sees the same end state it always did.
//
// usage: node edge-render.mjs <edgePath> <url> [budgetMs=8000]
// Only the rendered DOM goes to stdout; every diagnostic goes to stderr,
// so the caller's stdout parse stays clean.
import { spawn } from "node:child_process";
import { mkdtempSync, readFileSync, existsSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const [edge, url, budgetArg] = process.argv.slice(2);
const budget = Number(budgetArg || "8000");
if (!edge || !url) {
  console.error("edge-render: usage: edge-render.mjs <edge> <url> [budgetMs]");
  process.exit(2);
}

// A fresh profile per launch, the reason the suites always passed a unique
// --user-data-dir: a second Edge sharing one can attach to the first, or
// find it locked, and exit having rendered nothing.
const userDataDir = mkdtempSync(join(tmpdir(), "gt-cdp-"));

const child = spawn(
  edge,
  [
    "--headless=new",
    "--no-sandbox",
    `--user-data-dir=${userDataDir}`,
    // ES modules over file:// are a cross-origin load to Chromium, and
    // without this the fixture never runs - it just reports "pending".
    "--allow-file-access-from-files",
    // Software WebGL, deterministically, on every machine. --disable-gpu
    // takes the missing-GPU negotiation off the table - on a GPU-less runner
    // some Chrome builds otherwise crash the launch outright rather than fall
    // back - and --enable-unsafe-swiftshader is what still grants a WebGL2
    // context once the hardware path is gone (without it the renderer gets
    // null: "WebGL2 not supported"). The pair is the standard headless recipe:
    // SwiftShader is a conformant GL, so the colours and glyphs the suites
    // read back are the same everywhere, and the same the app draws - it just
    // stops depending on whatever GPU the machine under the test happens to
    // have, which is where render tests go flaky.
    "--disable-gpu",
    "--enable-unsafe-swiftshader",
    "--remote-debugging-port=0",
    // Modern Chromium refuses a CDP websocket whose Origin it does not
    // recognise; the automation client sends none, but this is the
    // documented belt-and-braces against a 403 that renders nothing.
    "--remote-allow-origins=*",
    "--no-first-run",
    "--no-default-browser-check",
    "about:blank",
  ],
  { stdio: ["ignore", "ignore", "pipe"] }
);

let stderrTail = "";
child.stderr.on("data", (b) => {
  stderrTail = (stderrTail + b.toString()).slice(-2000);
});

let ws;
function finish(code, html) {
  try {
    ws && ws.close();
  } catch {}
  try {
    child.kill();
  } catch {}
  const done = () => {
    // Best-effort profile cleanup; Edge may still hold a handle on exit.
    try {
      rmSync(userDataDir, { recursive: true, force: true });
    } catch {}
    process.exit(code);
  };
  if (html != null) process.stdout.write(html, done);
  else done();
}

// Chromium writes the port it chose to DevToolsActivePort (first line).
function activePort(timeoutMs) {
  const f = join(userDataDir, "DevToolsActivePort");
  const deadline = Date.now() + timeoutMs;
  return new Promise((resolve, reject) => {
    (function tick() {
      if (existsSync(f)) {
        try {
          const p = readFileSync(f, "utf8").split("\n")[0].trim();
          if (p) return resolve(Number(p));
        } catch {}
      }
      if (Date.now() > deadline) return reject(new Error("Edge never opened a debugging port"));
      setTimeout(tick, 50);
    })();
  });
}

async function main() {
  const port = await activePort(20000);
  const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
  const page = list.find((t) => t.type === "page") || list[0];
  if (!page || !page.webSocketDebuggerUrl) throw new Error("Edge exposed no page target");

  ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => {
    ws.addEventListener("open", resolve, { once: true });
    ws.addEventListener("error", () => reject(new Error("could not open the CDP websocket")), {
      once: true,
    });
  });

  let id = 0;
  const pending = new Map();
  const eventWaiters = [];
  ws.addEventListener("message", (ev) => {
    const msg = JSON.parse(typeof ev.data === "string" ? ev.data : ev.data.toString());
    if (msg.id != null && pending.has(msg.id)) {
      const { resolve, reject } = pending.get(msg.id);
      pending.delete(msg.id);
      if (msg.error) reject(new Error(msg.error.message));
      else resolve(msg.result);
    } else if (msg.method) {
      for (let i = eventWaiters.length - 1; i >= 0; i--) {
        if (eventWaiters[i].method === msg.method) eventWaiters.splice(i, 1)[0].resolve(msg.params);
      }
    }
  });
  const send = (method, params = {}) =>
    new Promise((resolve, reject) => {
      const mid = ++id;
      pending.set(mid, { resolve, reject });
      ws.send(JSON.stringify({ id: mid, method, params }));
    });
  const waitFor = (method, timeoutMs) =>
    new Promise((resolve, reject) => {
      const t = setTimeout(() => reject(new Error("timed out waiting for " + method)), timeoutMs);
      eventWaiters.push({
        method,
        resolve: (p) => {
          clearTimeout(t);
          resolve(p);
        },
      });
    });

  await send("Page.enable");
  // Freeze the clock first, or the instant about:blank load spends the whole
  // budget before we have navigated and the expiry fires on an empty page.
  // Then arm the expiry, navigate, and grant the budget: with the clock
  // released as pauseIfNetworkFetchesPending, virtual time holds while the
  // page and its modules are still loading, then advances timers up to the
  // budget and fires the expiry - by which point the page has run to its end.
  // That is the contract --virtual-time-budget gave --dump-dom. The real-time
  // cap is only a backstop; virtual time drains as fast as the loop allows.
  await send("Emulation.setVirtualTimePolicy", { policy: "pause" });
  const expired = waitFor(
    "Emulation.virtualTimeBudgetExpired",
    Math.min(Math.max(budget * 2, 30000), 120000)
  ).catch(() => {});
  await send("Page.navigate", { url });
  await send("Emulation.setVirtualTimePolicy", {
    policy: "pauseIfNetworkFetchesPending",
    budget,
  });
  await expired;

  // Read the live DOM through the DOM domain, not Runtime.evaluate: after a
  // navigation the default JS execution context is torn down and replaced,
  // and evaluating against it races the teardown (document comes back null).
  // DOM.getOuterHTML serialises the current document regardless of any JS
  // context - the live tree, mutations and all, which is what --dump-dom gave.
  const doc = await send("DOM.getDocument", { depth: -1 });
  const html = await send("DOM.getOuterHTML", { nodeId: doc.root.nodeId });
  finish(0, (html && html.outerHTML) || "");
}

main().catch((e) => {
  console.error("edge-render: " + e.message + (stderrTail ? "\n[edge stderr] " + stderrTail : ""));
  finish(1, "");
});
