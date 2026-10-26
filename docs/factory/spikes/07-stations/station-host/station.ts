#!/usr/bin/env node
// station — thin host that runs "station" packages as sessions on ONE private OpenCode 2.0.32 server.
// Runs on Node >= 24 (native type stripping: `node station.ts`) and on Bun (`bun station.ts`).
//   station up | down | status
//   station run <name> "<task>" [--json] [--profile yolo|focused]
//   station continue <sessionId> "<text>" [--json]
//   station show <sessionId> [--json]
//   station cancel <sessionId>        the only thing that interrupts a run (budgets/steps are report-only)
//   station inspect <name>            compiled agent + skills as the server sees them (evidence)
//   station api <METHOD> <path> [json] raw authenticated call (debug aid)
import { spawn, execFileSync } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import {
  statSync, appendFileSync, closeSync, existsSync, mkdirSync, openSync, readFileSync, readdirSync, rmSync,
  writeFileSync, chmodSync,
} from "node:fs";
import { createServer } from "node:net";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { Ajv2020 as Ajv } from "ajv/dist/2020.js";
import { parse as parseYaml, stringify as toYaml } from "yaml";

const ROOT = dirname(fileURLToPath(import.meta.url));
const RT = join(ROOT, ".runtime");
const HOME = homedir();
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

// ── types ──────────────────────────────────────────────────────────────────────────────────
type Profile = "yolo" | "focused";
type Rule = { action: string; resource: string; effect: "allow" | "deny" };
type Station = {
  name: string; description: string; route: string; steps?: number;
  budget: { usd: number; wall_s: number }; profile: Profile; shell: string[]; shellDeny: string[]; dir: string;
  schema: Record<string, unknown>; agents: string; skillsDir: string;
};
type Part = { type: string; text?: string; name?: string; state?: { status?: string } };
type Msg = {
  id: string; type: "user" | "assistant" | "idle";
  cost?: number; tokens?: { input: number; output: number; reasoning: number; cache: { read: number; write: number } };
  content?: Part[]; outcome?: string; agent?: string; model?: unknown; finish?: string; text?: string;
};
type Tokens = { input: number; output: number; reasoning: number; cacheRead: number; cacheWrite: number };
type Outcome = "ok" | "invalid_output" | "cancelled" | "failed";
type Result = {
  output: unknown; sessionId: string; cost: number; tokens: Tokens; wallMs: number; steps: number; outcome: Outcome;
  overBudget: boolean; error?: string;
};

// ── server lifecycle ───────────────────────────────────────────────────────────────────────
const readRt = (f: string) => (existsSync(join(RT, f)) ? readFileSync(join(RT, f), "utf8").trim() : "");
const serverPort = () => Number(readRt("port"));
const serverPid = () => Number(readRt("pid"));
const password = () => readRt("password");
const alive = (pid: number) => { try { process.kill(pid, 0); return pid > 0; } catch { return false; } };
const redact = (s: string) => {
  const pw = password();
  return pw ? s.split(pw).join("<pw>") : s;
};

async function freePort(): Promise<number> {
  return new Promise((res, rej) => {
    const s = createServer();
    s.once("error", rej);
    s.listen(0, "127.0.0.1", () => { const p = (s.address() as { port: number }).port; s.close(() => res(p)); });
  });
}

/** IU credentials via the owner's zsh helper. Only the first `export IU_KEY…` line is evaluated: the helper's
 *  later lines would touch the shared per-user OpenCode service, which this spike must never do. */
function iuEnv(): { IU_KEY: string; IU_OPENAI_BASE: string } {
  if (process.env.IU_KEY && process.env.IU_OPENAI_BASE) {
    return { IU_KEY: process.env.IU_KEY, IU_OPENAI_BASE: process.env.IU_OPENAI_BASE };
  }
  const out = execFileSync("zsh", ["-ic",
    `source ~/SourceRoot/dotfiles/config/zsh/claude.zsh >/dev/null 2>&1; _oc_env 2>/dev/null | grep '^export IU_KEY' > /tmp/.station-iu.$$; ` +
    `source /tmp/.station-iu.$$; rm -f /tmp/.station-iu.$$; printf '%s\\n%s' "$IU_KEY" "$IU_OPENAI_BASE"`,
  ], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });
  const [IU_KEY, IU_OPENAI_BASE] = out.trim().split("\n").slice(-2);
  if (!IU_KEY || !IU_OPENAI_BASE) throw new Error("IU credentials unresolvable");
  return { IU_KEY, IU_OPENAI_BASE };
}

async function up() {
  if (alive(serverPid())) return console.log(`already up: pid ${serverPid()} port ${serverPort()}`);
  mkdirSync(RT, { recursive: true });
  const xdg = ["config", "data", "state", "cache"].map((d) => { const p = join(RT, "xdg", d); mkdirSync(p, { recursive: true }); return p; });
  const pw = randomBytes(16).toString("hex");
  const port = await freePort();
  writeFileSync(join(RT, "password"), pw, { mode: 0o600 });
  chmodSync(join(RT, "password"), 0o600);
  const cfg = JSON.parse(readFileSync(join(HOME, "SourceRoot/dotfiles/config/opencode/opencode.json"), "utf8"));
  const iu = iuEnv();
  const log = openSync(join(RT, "server.log"), "w");
  // Equivalent of `env -i`: only what is listed reaches the server (and never a shell it spawns).
  const child = spawn("opencode", ["serve", "--hostname", "127.0.0.1", "--port", String(port)], {
    detached: true, stdio: ["ignore", log, log],
    env: {
      PATH: process.env.PATH ?? "", HOME, TMPDIR: process.env.TMPDIR ?? "/tmp",
      XDG_CONFIG_HOME: xdg[0], XDG_DATA_HOME: xdg[1], XDG_STATE_HOME: xdg[2], XDG_CACHE_HOME: xdg[3],
      OPENCODE_SERVER_PASSWORD: pw, OPENCODE_DISABLE_CLAUDE_CODE_SKILLS: "true",
      IU_KEY: iu.IU_KEY, IU_OPENAI_BASE: iu.IU_OPENAI_BASE,
      OPENCODE_CONFIG_CONTENT: JSON.stringify({ providers: cfg.providers ?? cfg.provider }),
    },
  });
  child.unref();
  closeSync(log);
  writeFileSync(join(RT, "pid"), String(child.pid));
  writeFileSync(join(RT, "port"), String(port));
  for (let i = 0; i < 50; i++) {
    await sleep(200);
    const r = await fetch(`http://127.0.0.1:${port}/api/session/active`, { headers: auth() }).catch(() => null);
    if (r?.ok) {
      const info = (await (await fetch(`http://127.0.0.1:${port}/api/info`, { headers: auth() })).json()) as { data?: { version: string }; version?: string };
      return console.log(`up: opencode ${info.data?.version ?? info.version} pid ${child.pid} port ${port}`);
    }
  }
  throw new Error("server did not come up; see .runtime/server.log");
}

async function down() {
  const pid = serverPid();
  if (!alive(pid)) console.log("not running");
  else {
    // 2.0.32 can ignore SIGTERM while it has live sessions/children (measured: still up 5 s later) -> escalate.
    process.kill(pid, "SIGTERM");
    for (let i = 0; i < 25 && alive(pid); i++) await sleep(200);
    if (alive(pid)) { process.kill(pid, "SIGKILL"); console.log(`stopped pid ${pid} (SIGKILL after 5 s)`); }
    else console.log(`stopped pid ${pid}`);
  }
  for (const f of ["pid", "port"]) rmSync(join(RT, f), { force: true });
}

// ── HTTP client ────────────────────────────────────────────────────────────────────────────
const auth = () => ({ authorization: `Basic ${Buffer.from(`opencode:${password()}`).toString("base64")}` });
const locQ = (dir: string) => `location[directory]=${encodeURIComponent(dir)}`;

async function api<T = unknown>(method: string, path: string, body?: unknown, signal?: AbortSignal): Promise<T> {
  if (!alive(serverPid())) throw new Error("server is not running (station up)");
  const res = await fetch(`http://127.0.0.1:${serverPort()}${path}`, {
    method, signal,
    headers: { ...auth(), ...(body === undefined ? {} : { "content-type": "application/json" }) },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(redact(`${method} ${path.split("?")[0]} -> ${res.status} ${text.slice(0, 300)}`));
  return (text ? JSON.parse(text) : null) as T;
}

async function allMessages(sessionId: string): Promise<Msg[]> {
  const out: Msg[] = [];
  let cursor: string | undefined;
  for (let i = 0; i < 100; i++) {
    // 2.0.32: a cursor carries its own order; sending `order` with it is a 400 InvalidCursorError
    const q = cursor ? `limit=200&cursor=${encodeURIComponent(cursor)}` : "order=asc&limit=200";
    const page = await api<{ cursor?: { next?: string }; data: Msg[] }>("GET", `/api/session/${sessionId}/message?${q}`);
    if (page.data.length === 0) break; // cursor.next is present even on the last page: stop on an empty one
    out.push(...page.data);
    cursor = page.cursor?.next;
    if (!cursor) break;
  }
  return out;
}

// ── station package → location directory ───────────────────────────────────────────────────
function loadStation(name: string, profile?: Profile): Station {
  const dir = join(ROOT, "stations", name);
  if (!existsSync(join(dir, "station.yaml"))) throw new Error(`unknown station: ${name}`);
  const y = parseYaml(readFileSync(join(dir, "station.yaml"), "utf8"));
  const schema = JSON.parse(readFileSync(join(dir, y.output), "utf8"));
  const expand = (s: string) => s.replaceAll("~/", `${HOME}/`);
  return {
    name: y.name, description: y.description, route: y.route, steps: y.steps, budget: y.budget,
    profile: profile ?? (y.profile === "focused" ? "focused" : "yolo"),
    shell: ((y.shell ?? []) as string[]).map(expand),
    shellDeny: ((y.shell_deny ?? []) as string[]).map(expand), dir, schema,
    agents: readFileSync(join(dir, "AGENTS.md"), "utf8"), skillsDir: join(dir, "skills"),
  };
}

/** Host guards appended after every allow (last match wins). OpenCode already parses compound commands (measured:
 *  `;` `&&` `|` `>` `$(...)` each rejected even with a matching allow), so these cover only what a text allowlist
 *  cannot: path traversal and the server's own credentials and API. Cost-raising text patterns, NOT a sandbox. */
function guardRules(): Rule[] {
  if (process.env.STATION_GUARDS === "off") return []; // test hook: measure the allowlist without the host guards
  const text = ["*..*", "*OPENCODE_SERVER_PASSWORD*", "*IU_KEY*", "*IU_OPENAI_BASE*", "*/api/session*", `*:${serverPort()}*`];
  return text.map((resource) => ({ action: "shell", resource, effect: "deny" as const }));
}

function permissions(st: Station): Rule[] {
  // Default profile: allow everything, never `ask`. `question` stays denied: it would block an unattended session.
  if (st.profile === "yolo") return [{ action: "*", resource: "*", effect: "allow" }, { action: "question", resource: "*", effect: "deny" }];
  const deny = (action: string): Rule => ({ action, resource: "*", effect: "deny" });
  return [
    deny("*"), // catch-all first: anything unnamed (incl. execute, MCP, future actions) is refused
    ...["edit", "webfetch", "websearch", "subagent", "question", "external_directory"].map(deny),
    ...st.shell.map((resource) => ({ action: "shell", resource, effect: "allow" as const })),
    ...guardRules(),
    ...(process.env.STATION_GUARDS === "off" ? [] : st.shellDeny).map((resource) => ({ action: "shell", resource, effect: "deny" as const })),
    { action: "skill", resource: "*", effect: "allow" },
    // OpenCode's two built-in skills are documentation helpers a station never needs
    ...["opencode", "report"].map((resource) => ({ action: "skill", resource, effect: "deny" as const })),
  ];
}

let changedFiles = 0;
function writeIfChanged(path: string, content: string) {
  mkdirSync(dirname(path), { recursive: true });
  if (existsSync(path) && readFileSync(path, "utf8") === content) return;
  writeFileSync(path, content);
  changedFiles++;
}

/** 2.0.32 does NOT hot-reload an already loaded location when its agent file changes (measured), so a
 *  compile that rewrote anything evicts the location; its next use boots fresh from the new files. */
async function compileAndLoad(st: Station): Promise<string> {
  changedFiles = 0;
  const loc = compile(st);
  if (changedFiles > 0) await api("DELETE", `/api/debug/location?${locQ(loc)}`).catch(() => null);
  return loc;
}

const locationDir = (st: Station) => join(RT, "locations", st.profile === "yolo" ? st.name : `${st.name}.focused`);

function compile(st: Station): string {
  const loc = locationDir(st);
  writeIfChanged(join(loc, "AGENTS.md"), st.agents);
  const system =
    `You are the "${st.name}" station: ${st.description}\n` +
    (st.profile === "focused"
      ? `Work with the tools you have been given and nothing else. A refused command stays refused: report it, do not retry variations.\n`
      : `Work in the scratch directory named in the task. Run code when a computation or an artifact is needed.\n`);
  // No OpenCode steps cap: steps are report-only (a cap would summarise-and-stop the run).
  const frontmatter = toYaml({ description: st.description, mode: "primary", permissions: permissions(st) });
  writeIfChanged(join(loc, ".opencode/agents", `${st.name}.md`), `---\n${frontmatter}---\n${system}`);
  const skills = join(loc, ".opencode/skills");
  if (existsSync(st.skillsDir)) {
    for (const s of readdirSync(st.skillsDir)) {
      const body = readFileSync(join(st.skillsDir, s, "SKILL.md"), "utf8");
      writeIfChanged(join(skills, s, "SKILL.md"), body);
    }
  }
  return loc;
}

type AgentInfo = { id: string; steps?: number; permissions: Rule[]; system?: string; mode: string };
/** The first read after boot can be empty: poll until the agent (and its skills) appear. */
async function warm(st: Station, loc: string) {
  const expectSkills = existsSync(st.skillsDir) ? readdirSync(st.skillsDir).length : 0;
  for (let i = 0; i < 40; i++) {
    const agents = await api<{ data: AgentInfo[] }>("GET", `/api/agent?${locQ(loc)}`);
    const skills = await api<{ data: { name?: string; id?: string }[] }>("GET", `/api/skill?${locQ(loc)}`);
    const agent = agents.data.find((a) => a.id === st.name);
    if (agent && skills.data.length >= expectSkills) return { agent, skills: skills.data, agents: agents.data };
    await sleep(250);
  }
  throw new Error(`location ${st.name} did not load its agent/skills`);
}

// ── routing ────────────────────────────────────────────────────────────────────────────────
function resolveModel(route: string): { providerID: string; id: string; variant?: string } {
  const r = JSON.parse(execFileSync("agw", ["routing", "--json"], { encoding: "utf8" })) as {
    routes: Record<string, { model: string; variant?: string }>;
  };
  const hit = r.routes[route];
  if (!hit) throw new Error(`route ${route} not in agw routing`);
  return { providerID: "iu", id: hit.model, ...(hit.variant ? { variant: hit.variant } : {}) };
}

// ── output contract ────────────────────────────────────────────────────────────────────────
const ajv = new Ajv({ allErrors: true, strict: false });

const contractText = (st: Station) =>
  `\n\nWhen you are done, end your final message with exactly ONE JSON object matching this JSON Schema, ` +
  `and nothing after it:\n${JSON.stringify(st.schema)}`;

function lastAssistantText(msgs: Msg[]): string {
  for (let i = msgs.length - 1; i >= 0; i--) {
    const m = msgs[i];
    if (m.type === "user") break;
    if (m.type !== "assistant") continue;
    const t = (m.content ?? []).filter((p) => p.type === "text").map((p) => p.text ?? "").join("\n");
    if (t.trim()) return t;
  }
  return "";
}

/** The last top-level `{...}` in the text that parses as JSON (string-aware brace matching). Fenced or bare. */
function extractJson(text: string): { value?: unknown; error?: string } {
  let last: unknown, found = false;
  for (let i = 0; i < text.length; i++) {
    if (text[i] !== "{") continue;
    let depth = 0, inStr = false, esc = false, end = -1;
    for (let j = i; j < text.length; j++) {
      const c = text[j];
      if (inStr) { if (esc) esc = false; else if (c === "\\") esc = true; else if (c === '"') inStr = false; continue; }
      if (c === '"') inStr = true;
      else if (c === "{") depth++;
      else if (c === "}" && --depth === 0) { end = j; break; }
    }
    if (end < 0) break;
    try { last = JSON.parse(text.slice(i, end + 1)); found = true; i = end; } catch { /* not JSON: keep scanning */ }
  }
  return found ? { value: last } : { error: "no JSON object found in the final message" };
}

function validate(st: Station, text: string): { value?: unknown; error?: string } {
  const ex = extractJson(text);
  if (ex.error) return ex;
  const check = ajv.compile(st.schema);
  if (check(ex.value)) return { value: ex.value };
  return { error: ajv.errorsText(check.errors, { dataVar: "output" }) };
}

// ── driving a session ──────────────────────────────────────────────────────────────────────
const sum = (msgs: Msg[]) => {
  const t: Tokens = { input: 0, output: 0, reasoning: 0, cacheRead: 0, cacheWrite: 0 };
  let cost = 0, steps = 0, toolCalls = 0;
  for (const m of msgs) {
    if (m.type !== "assistant") continue;
    steps++;
    cost += m.cost ?? 0;
    t.input += m.tokens?.input ?? 0; t.output += m.tokens?.output ?? 0; t.reasoning += m.tokens?.reasoning ?? 0;
    t.cacheRead += m.tokens?.cache?.read ?? 0; t.cacheWrite += m.tokens?.cache?.write ?? 0;
    toolCalls += (m.content ?? []).filter((p) => p.type === "tool").length;
  }
  return { cost, tokens: t, steps, toolCalls };
};
const diffTokens = (a: Tokens, b: Tokens): Tokens => ({
  input: a.input - b.input, output: a.output - b.output, reasoning: a.reasoning - b.reasoning,
  cacheRead: a.cacheRead - b.cacheRead, cacheWrite: a.cacheWrite - b.cacheWrite,
});

/** Send one prompt and wait until the session is idle again. Never interrupts: budgets are report-only.
 *  `wait` can return before a fresh prompt has started, so idle is confirmed from the message list:
 *  the newest message is an `idle` after as many user messages as prompts sent. */
async function turn(sessionId: string, text: string, expectedUsers: number): Promise<Msg[]> {
  await api("POST", `/api/session/${sessionId}/prompt`, { text });
  for (;;) {
    await api("POST", `/api/experimental/session/${sessionId}/wait`).catch(() => null); // long-poll may time out: just poll again
    const msgs = await allMessages(sessionId);
    const users = msgs.filter((m) => m.type === "user").length;
    if (users >= expectedUsers && msgs.at(-1)?.type === "idle") return msgs;
    await sleep(300);
  }
}

const sessionsDir = () => join(RT, "sessions");
type Index = { station: string; profile: Profile; dir: string; workdir: string; model: string; route: string; created: number };
const loadIndex = (id: string): Index => JSON.parse(readFileSync(join(sessionsDir(), `${id}.json`), "utf8"));

function emit(a: {
  st: Station; sessionId: string; model: string; phase: string; t0: number; msgs: Msg[]; before: ReturnType<typeof sum>;
  outcome: Outcome; cost: number; overBudget: boolean;
}) {
  const s = sum(a.msgs);
  const traceId = createHash("sha256").update(a.sessionId).digest("hex").slice(0, 32);
  const span = {
    traceId, spanId: randomBytes(8).toString("hex"), name: "station.session", startMs: a.t0, durMs: Date.now() - a.t0,
    attrs: {
      station: a.st.name, route: a.st.route, model: a.model, sessionId: a.sessionId, phase: a.phase, cost: a.cost,
      tokens: diffTokens(s.tokens, a.before.tokens), steps: s.steps - a.before.steps,
      toolCalls: s.toolCalls - a.before.toolCalls, outcome: a.outcome, overBudget: a.overBudget,
      profile: a.st.profile,
    },
  };
  appendFileSync(join(RT, "spans.jsonl"), JSON.stringify(span) + "\n");
  appendFileSync(join(RT, "usage.jsonl"), JSON.stringify({
    ts: new Date().toISOString(), station: a.st.name, route: a.st.route, model: a.model, sessionId: a.sessionId,
    phase: a.phase, cost: a.cost, tokens: span.attrs.tokens, steps: span.attrs.steps, outcome: a.outcome,
    overBudget: a.overBudget,
  }) + "\n");
}

/** Artifacts the output claims (`artifacts: [{path, kind}]`) must exist, non-empty, under the workdir. */
function artifactError(output: unknown, workdir: string): string | undefined {
  const list = (output as { artifacts?: { path?: string }[] } | null)?.artifacts;
  if (!Array.isArray(list)) return undefined;
  for (const a of list) {
    const abs = a.path?.startsWith("/") ? a.path : join(workdir, a.path ?? "");
    if (!abs.startsWith(workdir + "/")) return `artifact ${a.path} is outside the scratch workdir ${workdir}`;
    if (!existsSync(abs) || statSync(abs).size === 0) return `artifact ${a.path} does not exist or is empty`;
  }
  return undefined;
}

/** One caller-visible call (run or continue): prompt, validate (one re-ask), account, emit. Never cut for budget. */
async function converse(st: Station, ix: Index, sessionId: string, phase: string, text: string): Promise<Result> {
  const t0 = Date.now();
  const before = sum(await allMessages(sessionId));
  let users = (await allMessages(sessionId)).filter((m) => m.type === "user").length + 1;
  let msgs = await turn(sessionId, text + contractText(st), users);
  let outcome: Outcome = "ok", output: unknown, error: string | undefined;
  const last = () => msgs.at(-1);
  const ended = () => last()?.type === "idle" && last()?.outcome !== "succeeded";
  const endedWith = () => { outcome = last()?.outcome === "interrupted" ? "cancelled" : "failed"; error = `session ended ${last()?.outcome}`; };
  const check = () => {
    const v = validate(st, lastAssistantText(msgs));
    if (v.error) return v;
    const ae = artifactError(v.value, ix.workdir);
    return ae ? { error: ae } : v;
  };
  if (ended()) endedWith();
  else {
    let v = check();
    if (v.error) {
      const ask = `Your last message did not satisfy the output contract: ${v.error}. ` +
        `Fix it and reply again with exactly ONE JSON object matching the schema.${contractText(st)}`;
      msgs = await turn(sessionId, ask, ++users);
      if (ended()) endedWith(); else v = check();
    }
    if (outcome === "ok") {
      if (v.error) { outcome = "invalid_output"; error = v.error; } else output = v.value;
    }
  }
  const s = sum(msgs);
  const cost = s.cost - before.cost, wallMs = Date.now() - t0, steps = s.steps - before.steps;
  // Report-only: flag, never interrupt.
  const overBudget = cost > st.budget.usd || wallMs > st.budget.wall_s * 1000 || (st.steps !== undefined && steps > st.steps);
  emit({ st, sessionId, model: ix.model, phase, t0, msgs, before, outcome, cost, overBudget });
  return { output, sessionId, cost, tokens: diffTokens(s.tokens, before.tokens), wallMs, steps, outcome, overBudget, ...(error ? { error } : {}) };
}

async function run(name: string, task: string, opts: { budgetUsd?: number; profile?: Profile } = {}): Promise<Result> {
  const st = loadStation(name, opts.profile);
  if (opts.budgetUsd !== undefined) st.budget.usd = opts.budgetUsd; // test hook: --budget-usd (report-only threshold)
  const loc = await compileAndLoad(st);
  await warm(st, loc);
  const m = resolveModel(st.route);
  // Per-run scratch workdir inside the location (the location is shared by concurrent sessions of a station).
  const workdir = join(loc, "work", `${new Date().toISOString().replace(/[:.]/g, "-")}-${randomBytes(3).toString("hex")}`);
  mkdirSync(workdir, { recursive: true });
  const created = await api<{ data: { id: string } }>("POST", "/api/session", {
    title: `station ${name}`, agent: st.name, model: m, location: { directory: loc },
    metadata: { station: { name, route: st.route, profile: st.profile } },
  });
  const sessionId = created.data.id;
  // Defense in depth, as agent-gateway does: the shell never sees the server's credentials.
  await api("PUT", `/api/session/${sessionId}/environment`, {
    variables: { OPENCODE_SERVER_PASSWORD: "", IU_KEY: "", IU_OPENAI_BASE: "" },
  });
  mkdirSync(sessionsDir(), { recursive: true });
  const ix: Index = { station: name, profile: st.profile, dir: loc, workdir, model: m.id, route: st.route, created: Date.now() };
  writeFileSync(join(sessionsDir(), `${sessionId}.json`), JSON.stringify(ix));
  const framed = st.profile === "yolo" ? `${task}\n\nScratch workdir for this run (create files and run code here): ${workdir}` : task;
  return converse(st, ix, sessionId, "run", framed);
}

async function cont(sessionId: string, text: string): Promise<Result> {
  const ix = loadIndex(sessionId);
  const st = loadStation(ix.station, ix.profile);
  await compileAndLoad(st);
  return converse(st, ix, sessionId, "continue", text);
}

async function cancel(sessionId: string) {
  console.log(JSON.stringify(await api("POST", `/api/session/${sessionId}/interrupt`)));
}

// ── show ───────────────────────────────────────────────────────────────────────────────────
async function show(sessionId: string, json: boolean) {
  const ix = loadIndex(sessionId);
  const msgs = await allMessages(sessionId);
  const s = sum(msgs);
  const turns = msgs.map((m) => {
    if (m.type === "user") return { role: "user", text: m.text ?? "" };
    if (m.type === "idle") return { role: "idle", outcome: m.outcome };
    return {
      role: "assistant", cost: m.cost, finish: m.finish,
      parts: (m.content ?? []).filter((p) => p.type !== "reasoning").map((p) => (p.type === "text" ? { text: p.text } : p)),
    };
  });
  if (json) return console.log(JSON.stringify({ sessionId, ...ix, cost: s.cost, tokens: s.tokens, steps: s.steps, toolCalls: s.toolCalls, turns }, null, 2));
  console.log(`session ${sessionId}  station=${ix.station} model=${ix.model}  cost=$${s.cost.toFixed(5)} steps=${s.steps} tools=${s.toolCalls}`);
  for (const t of turns as { role: string; text?: string; parts?: { text?: string; type?: string; name?: string }[]; outcome?: string }[]) {
    if (t.role === "user") console.log(`\n[user] ${t.text?.slice(0, 300)}`);
    else if (t.role === "idle") console.log(`[idle] ${t.outcome}`);
    else for (const p of t.parts ?? []) console.log(p.text ? `[assistant] ${p.text.slice(0, 500)}` : `[tool] ${JSON.stringify(p).slice(0, 300)}`);
  }
}

async function inspect(name: string, profile?: Profile) {
  const st = loadStation(name, profile);
  const loc = await compileAndLoad(st);
  const w = await warm(st, loc);
  const skills = await api<{ data: unknown[] }>("GET", `/api/skill?${locQ(loc)}`);
  console.log(JSON.stringify({ location: loc, agent: w.agent, skills: skills.data }, null, 2));
}

// ── cli ────────────────────────────────────────────────────────────────────────────────────
function flag(args: string[], name: string, withValue = false): string | boolean | undefined {
  const i = args.indexOf(name);
  if (i < 0) return undefined;
  const v = withValue ? args[i + 1] : true;
  args.splice(i, withValue ? 2 : 1);
  return v;
}

function printResult(r: Result, json: boolean) {
  if (json) return console.log(JSON.stringify(r, null, 2));
  console.log(JSON.stringify(r.output, null, 2));
  console.log(`\noutcome=${r.outcome}${r.overBudget ? " OVER-BUDGET" : ""} cost=$${r.cost.toFixed(5)} wall=${(r.wallMs / 1000).toFixed(1)}s session=${r.sessionId}${r.error ? `\nerror: ${r.error}` : ""}`);
}

async function main() {
  const args = process.argv.slice(2);
  const cmd = args.shift();
  const json = Boolean(flag(args, "--json"));
  const budget = flag(args, "--budget-usd", true);
  const profile = flag(args, "--profile", true) as Profile | undefined;
  switch (cmd) {
    case "up": return up();
    case "down": return down();
    case "status": return console.log(alive(serverPid()) ? `up pid ${serverPid()} port ${serverPort()}` : "down");
    case "run": {
      if (args.length < 2) throw new Error('usage: station run <name> "<task>" [--json]');
      const r = await run(args[0], args.slice(1).join(" "), { budgetUsd: budget ? Number(budget) : undefined, profile });
      printResult(r, json);
      process.exitCode = r.outcome === "ok" ? 0 : 1;
      return;
    }
    case "continue": {
      if (args.length < 2) throw new Error('usage: station continue <sessionId> "<text>" [--json]');
      const r = await cont(args[0], args.slice(1).join(" "));
      printResult(r, json);
      process.exitCode = r.outcome === "ok" ? 0 : 1;
      return;
    }
    case "cancel": return cancel(args[0]);
    case "show": return show(args[0], json);
    case "inspect": return inspect(args[0], profile);
    case "api": {
      const out = await api(args[0], args[1], args[2] ? JSON.parse(args[2]) : undefined);
      return console.log(JSON.stringify(out, null, 2));
    }
    default:
      console.error("usage: station up|down|status | run <name> \"<task>\" | continue <id> \"<text>\" | show <id> | inspect <name>");
      process.exitCode = 2;
  }
}

main().catch((e) => { console.error(redact(String(e?.message ?? e))); process.exitCode = 1; });
