#!/usr/bin/env bun
// rv-pn: the `rv submit | wait` contract implemented on top of the Plannotator Inbox (Option A behind Option B's interface).
// Talks Streamable-HTTP MCP to the loopback Inbox (port from inbox.json), starts it if stopped, and keeps every tool
// definition out of the agent's context. Env: PLANNOTATOR_BIN, PLANNOTATOR_DATA_DIR, RV_SESSION.
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { basename, resolve } from "node:path";

const BIN = process.env.PLANNOTATOR_BIN ?? "plannotator", DATA = process.env.PLANNOTATOR_DATA_DIR ?? `${process.env.HOME}/.plannotator`;
const session = process.env.RV_SESSION ?? "rv-agent";
const [cmd, ...args] = process.argv.slice(2);
const flag = (n: string, d = "") => (args.includes(`--${n}`) ? args[args.indexOf(`--${n}`) + 1] : d);
const out = (v: unknown) => console.log(JSON.stringify(v));

async function tool(name: string, a: object, projectPath: string): Promise<any> {
  for (let attempt = 0; ; attempt++) {
    try {
      const port = JSON.parse(readFileSync(`${DATA}/inbox/inbox.json`, "utf8")).port;
      const r = await fetch(`http://localhost:${port}/mcp`, { method: "POST", signal: AbortSignal.timeout(70_000),
        headers: { "Content-Type": "application/json", Accept: "application/json, text/event-stream" },
        body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name, arguments: { project_path: projectPath, agent_session: session, ...a } } }) });
      const res = JSON.parse((await r.text()).split("\n").find((l) => l.startsWith("data:"))!.slice(5)).result;
      if (res.isError) throw new Error(res.content[0].text);
      return res.structuredContent ?? res;
    } catch (e) {
      if (attempt > 3 || String(e).includes("isError") || !/fetch|ECONN|ENOENT|Unable|timed out/i.test(String(e))) throw e;
      Bun.spawnSync([BIN, "inbox", "--background"]); await Bun.sleep(1500); // Inbox stopped or restarting: start it, retry
    }
  }
}

if (cmd === "submit") { // submit <project_dir> <file> [--default "<what the agent does if nobody answers>"]
  const [project, file] = [resolve(args[0]), resolve(args[1])];
  const sha = createHash("sha256").update(readFileSync(file)).digest("hex").slice(0, 12);
  const body = `Review requested: ${basename(file)} (rev ${sha}). Comments are a signal, not a gate. Default if nobody answers: ${flag("default", "proceed unchanged")}.`;
  const key = `rv:${file}:${createHash("sha256").update(body).digest("hex").slice(0, 12)}`; // same content + same default => replay
  const r = await tool("send_message", { thread: file, subject: `Review: ${basename(file)}`, body, attachments: [file], idempotency_key: key }, project);
  out({ id: r.thread_id, message: r.message_id, project: r.project.name, replayed: r.replayed });
} else if (cmd === "wait") { // wait <thread_id> <project_dir> [--timeout s] [--default text]  -> feedback | approved | closed | timeout
  const [id, project] = [args[0], resolve(args[1])], deadline = Date.now() + Number(flag("timeout", "300")) * 1000;
  let cursor: number | undefined;
  while (Date.now() < deadline) {
    const left = Math.max(1, Math.min(50, Math.ceil((deadline - Date.now()) / 1000)));
    const r = await tool("wait_for_reply", { thread_id: id, timeout_seconds: left, ...(cursor ? { cursor } : {}) }, project);
    if (r.status === "waiting") { cursor = r.cursor; continue; }
    const map: Record<string, string> = { replied: "feedback", acknowledged: "approved", resolved: "closed" };
    out({ status: map[r.status] ?? r.status, body: r.reply?.body, cursor: r.cursor });
    process.exit(0);
  }
  out({ status: "timeout", default: flag("default", "proceed unchanged") });
}
