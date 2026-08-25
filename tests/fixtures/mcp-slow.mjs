// A minimal MCP server over stdio that is deliberately slow and noisy.
//
// It exists to reproduce what an agent CLI does before it can draw: spawn
// child processes, wait on them, and let them write to the same terminal.
// The waiting is the point - the host has a screen up while a child it
// does not control is still starting, and the redraw that follows is the
// thing under test.
//
// Two behaviours are on purpose. It waits before answering `initialize`,
// so the host is stuck mid-startup for a visible stretch. And it writes
// to stderr, which the host does not redirect, so those bytes land in the
// middle of an alternate screen someone else is drawing on. Both are
// ordinary for real MCP servers, and both are the interesting case.
import process from "node:process";

const wait = Number(process.env.MCP_SLOW_MS ?? 4000);
const noisy = process.env.MCP_QUIET !== "1";

if (noisy) process.stderr.write("mcp-slow: starting up\n");

let buf = "";
process.stdin.on("data", async (chunk) => {
  buf += chunk.toString("utf8");
  let i;
  while ((i = buf.indexOf("\n")) !== -1) {
    const line = buf.slice(0, i).trim();
    buf = buf.slice(i + 1);
    if (!line) continue;
    let msg;
    try { msg = JSON.parse(line); } catch { continue; }
    if (msg.method === "initialize") {
      if (noisy) process.stderr.write(`mcp-slow: initializing, back in ${wait}ms\n`);
      await new Promise((r) => setTimeout(r, wait));
      reply(msg.id, {
        protocolVersion: msg.params?.protocolVersion ?? "2025-06-18",
        capabilities: { tools: {} },
        serverInfo: { name: "mcp-slow", version: "1.0.0" },
      });
      if (noisy) process.stderr.write("mcp-slow: ready\n");
    } else if (msg.method === "tools/list") {
      reply(msg.id, { tools: [] });
    } else if (msg.method === "resources/list") {
      reply(msg.id, { resources: [] });
    } else if (msg.method === "prompts/list") {
      reply(msg.id, { prompts: [] });
    } else if (msg.id !== undefined) {
      reply(msg.id, {});
    }
  }
});

function reply(id, result) {
  process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, result }) + "\n");
}
