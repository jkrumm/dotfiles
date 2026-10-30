#!/usr/bin/env bun
// rv: review-service prototype (Option B). `rv serve | submit | wait | comment | resolve | close | inbox`.
// Bun + bun:sqlite. All state is in SQLite, so a restart loses nothing; waits are level-triggered long-polls.
import { Database } from "bun:sqlite";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const PORT = Number(process.env.RV_PORT ?? 39221), BASE = `http://localhost:${PORT}`;
const [cmd, ...args] = process.argv.slice(2);
const flag = (n: string, d = "") => (args.includes(`--${n}`) ? args[args.indexOf(`--${n}`) + 1] : d);

function serve() {
  const db = new Database(process.env.RV_DB ?? "rv.db", { create: true });
  db.run("PRAGMA journal_mode=WAL");
  db.run(`CREATE TABLE IF NOT EXISTS artifact(id INTEGER PRIMARY KEY, project TEXT, path TEXT, rev INTEGER, sha TEXT,
    status TEXT NOT NULL DEFAULT 'open' CHECK(status IN ('open','closed','superseded')), created_at INTEGER)`);
  db.run(`CREATE TABLE IF NOT EXISTS comment(id INTEGER PRIMARY KEY, artifact_id INTEGER, parent_id INTEGER, quote TEXT, prefix TEXT,
    suffix TEXT, body TEXT, author TEXT, created_at INTEGER, resolved_at INTEGER, acked INTEGER NOT NULL DEFAULT 0)`);
  const waiters = new Map<number, Set<() => void>>();
  const wake = (id: number) => waiters.get(id)?.forEach((f) => f());
  // Feedback first (a Send must never be lost behind a close); then terminal status; null = keep waiting.
  const verdict = (id: number) => {
    const a = db.query("SELECT status FROM artifact WHERE id=?").get(id) as { status: string } | null;
    if (!a) return { status: "closed", reason: "unknown artifact" };
    const comments = db.query("SELECT id,parent_id,quote,prefix,suffix,body,author FROM comment WHERE artifact_id=? AND acked=0 ORDER BY id").all(id) as { id: number }[];
    if (comments.length) return { status: "feedback", comments, cursor: comments.at(-1)!.id };
    return a.status === "open" ? null : { status: a.status };
  };
  Bun.serve({ port: PORT, hostname: "localhost", idleTimeout: 255, async fetch(req) {
    const u = new URL(req.url), m = u.pathname.match(/^\/(artifacts|comments)\/(\d+)\/(wait|comments|close|resolve)$/);
    if (req.method === "POST" && u.pathname === "/artifacts") {
      const { project, path } = await req.json();
      const sha = createHash("sha256").update(readFileSync(path)).digest("hex");
      const prev = db.query("SELECT * FROM artifact WHERE project=? AND path=? ORDER BY rev DESC LIMIT 1").get(project, path) as any;
      if (prev?.status === "open" && prev.sha === sha) return Response.json({ id: prev.id, rev: prev.rev, unchanged: true });
      const rev = (prev?.rev ?? 0) + 1;
      const id = Number(db.query("INSERT INTO artifact(project,path,rev,sha,created_at) VALUES(?,?,?,?,?)").run(project, path, rev, sha, Date.now()).lastInsertRowid);
      if (prev?.status === "open") { db.query("UPDATE artifact SET status='superseded' WHERE id=?").run(prev.id); wake(prev.id); }
      return Response.json({ id, rev });
    }
    if (u.pathname === "/inbox") return Response.json(db.query(`SELECT project,id,path,rev,status,
      (SELECT count(*) FROM comment c WHERE c.artifact_id=a.id AND c.resolved_at IS NULL) AS open_comments,
      (SELECT count(*) FROM comment c WHERE c.artifact_id=a.id AND c.acked=0) AS undelivered
      FROM artifact a ORDER BY project, id DESC`).all());
    if (!m) return new Response("not found", { status: 404 });
    const id = Number(m[2]);
    if (m[1] === "comments" && m[3] === "resolve") { db.query("UPDATE comment SET resolved_at=? WHERE id=?").run(Date.now(), id); return Response.json({ ok: true }); }
    if (m[3] === "comments") {
      const b = await req.json();
      db.query("INSERT INTO comment(artifact_id,parent_id,quote,prefix,suffix,body,author,created_at) VALUES(?,?,?,?,?,?,?,?)")
        .run(id, b.parent_id ?? null, b.quote ?? "", b.prefix ?? "", b.suffix ?? "", b.body, b.author ?? "human", Date.now());
      wake(id); return Response.json({ ok: true });
    }
    if (m[3] === "close") { db.query("UPDATE artifact SET status='closed' WHERE id=?").run(id); wake(id); return Response.json({ ok: true }); }
    if (m[3] === "wait") {
      const ack = Number(u.searchParams.get("ack") ?? 0);
      if (ack) db.query("UPDATE comment SET acked=1 WHERE artifact_id=? AND id<=?").run(id, ack);
      let v = verdict(id);
      if (!v) {
        const ms = Math.min(Number(u.searchParams.get("timeout") ?? 25), 250) * 1000;
        await new Promise<void>((done) => {
          const set = waiters.get(id) ?? waiters.set(id, new Set()).get(id)!;
          const f = () => { set.delete(f); clearTimeout(t); done(); }, t = setTimeout(f, ms);
          set.add(f);
        });
        v = verdict(id);
      }
      return Response.json(v ?? { status: "timeout" });
    }
  } });
}

const call = async (path: string, init: RequestInit = {}) => (await fetch(BASE + path, init)).json();
const post = (path: string, body: object = {}) => call(path, { method: "POST", body: JSON.stringify(body) });
const out = (v: unknown) => console.log(JSON.stringify(v));

if (cmd === "serve") serve();
else if (cmd === "submit") out(await post("/artifacts", { project: args[0], path: resolve(args[1]) }));
else if (cmd === "comment") out(await post(`/artifacts/${args[0]}/comments`, { quote: flag("quote"), prefix: flag("prefix"), suffix: flag("suffix"), body: flag("body"), author: flag("author", "human") }));
else if (cmd === "resolve") out(await post(`/comments/${args[0]}/resolve`));
else if (cmd === "close") out(await post(`/artifacts/${args[0]}/close`));
else if (cmd === "inbox") for (const row of await call("/inbox")) out(row); // one JSON object per artifact, grouped by project
else if (cmd === "wait") {
  // Never a gate: bounded by --timeout, and on timeout prints the agent's --default so it can proceed.
  const id = args[0], deadline = Date.now() + Number(flag("timeout", "300")) * 1000;
  let ack = flag("ack", "0");
  while (Date.now() < deadline) {
    try {
      const chunk = Math.min(25, Math.max(1, Math.ceil((deadline - Date.now()) / 1000)));
      const r = await call(`/artifacts/${id}/wait?timeout=${chunk}&ack=${ack}`, { signal: AbortSignal.timeout(40_000) });
      ack = "0";
      if (r.status !== "timeout") { out(r); process.exit(0); }
    } catch { await Bun.sleep(1000); } // server restarting: state is in SQLite, ask again
  }
  out({ status: "timeout", default: flag("default", "proceed") });
}
