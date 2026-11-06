// jk-board — the right-hand sidebar, two tabs. Issues (default): the factory's work as a human reads it.
// Uptime: an Uptime Kuma overview from Argo's /uptime-kuma/monitors, read on the mini with secrets-run (the
// token never reaches argv), grouped by parent group. jk-status switches it to Uptime through
// shared("jk.board.tab"). Read-only.
// Issues: every 15 s one call on the mini reads software-factory's read API (`factory read overview|issues|sessions`,
// token through secrets-run) and hc's terminal list. Each part parses on its own and keeps its last good answer.
// Top to bottom: the summary line, ASKS (the owner's own first), HUMAN QUEUE (stale ones folded), HEALTH, then the
// Issues: RUNNING, QUEUED (folded), RECENT (folded), and the live sessions that belong to no Issue. An Issue card
// shows its human title, phase and summary; a click opens facts, its sessions, the hidden-child tree and the last
// timeline lines (`read issue <id>`, only while open). All text from the API is data.
// Header feed: after each good sessions answer the board publishes shared("jk.factory.terminals") (app terminal
// address -> what that agent is about) for the jk-pane header, and only when it changed.
// Hidden children: a session row lists the terminals that hang under it (hc's `parent`) as a tree: name,
// state, turn. Click a child for its last lines (`hc read`, on demand).
import { View, div, svg } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { exec, theme, machines, shared, setShared, run, terminals, focused } from "herdr";

// The token comes from the factory's own env template through secrets-run, never argv.
const SECRETS = `PATH="$HOME/.local/bin:$HOME/.bun/bin:/opt/homebrew/bin:$PATH"; cd ~/SourceRoot/software-factory && secrets-run run --env-file=.env.tpl --`;
// `--format json` goes before the subcommand. One secrets-run, three reads, split on a line holding only @@.
const READS = "factory --format json read overview; echo; echo @@; factory --format json read issues --state all --limit 40; echo; echo @@; factory --format json read sessions --live";
const HC_MARK = "@@HC@@";
const HC_SPLIT = `\n${HC_MARK}\n`;
// hc starts a stray core (no keychain) when none runs: ask lib/core-up.sh first (socket answers AND a launchd-born core), as rd's require_core does. Bounded when the host has a timeout.
const HC_GUARD = `PATH="$HOME/.local/bin:/opt/homebrew/bin:$PATH"; bash "$HOME/SourceRoot/dotfiles/scripts/lib/core-up.sh" >/dev/null 2>&1 || exit 1; t=$(command -v timeout || command -v gtimeout)`;
const HC_LS = `${HC_GUARD}; \${t:+"$t"} \${t:+8} hc ls --json`;
const CMD = `{ ${SECRETS} sh -c '${READS}'; } 2>/dev/null; echo; echo '${HC_MARK}'; ( ${HC_LS} ) 2>/dev/null`;
// A child's last lines: the screen, blank lines dropped. The address is checked (ADDR) before it reaches the shell.
const PEEK_LINES = 8;
const peekCmd = (addr) => `${HC_GUARD}; out=$(\${t:+"$t"} \${t:+8} hc read ${addr} 2>&1) || { echo "(hc read failed)"; exit 1; }; printf '%s\\n' "$out" | grep -v '^[[:space:]]*$' | tail -n ${PEEK_LINES}`;

// Argo's live Kuma snapshot. The token is read on the mini and piped to curl as a header file.
const UPTIME = `PATH="$HOME/.local/bin:/opt/homebrew/bin:$PATH"; t=$(secrets-run read op://common/api/SECRET) && printf 'Authorization: Bearer %s\\n' "$t" | curl -s -m 8 -H @- http://127.0.0.1:7737/api/uptime-kuma/monitors`;
const UPTIME_MS = 30000; // while the Uptime tab shows
const UPTIME_BG_MS = 60000; // otherwise, for the tab badge
const TABS = [["issues", "Issues"], ["uptime", "Uptime"]];

const POLL_MS = 15000;
const STALE_MS = 2 * 60000;
const RECENT_MAX = 8;
const TIMELINE_LINES = 5;
const base = (path) => path.replace(/\/+$/, "").split("/").pop();

// <tree> pure helpers (scripts/jk-board-tree.test.ts runs this block on its own: no imports, no gpui)
const ADDR = /^t[0-9a-z]+$/;

// `hc ls --json` -> the terminals, or null when it is not that.
function parseHc(text) {
  try {
    const d = JSON.parse(text);
    return Array.isArray(d?.terminals) ? d.terminals.filter((t) => t && ADDR.test(String(t.address))) : null;
  } catch {
    return null;
  }
}

// parent address -> its children, by name then address.
function childMap(terminals) {
  const kids = new Map();
  for (const t of terminals ?? []) {
    if (!t.parent) continue;
    if (!kids.has(t.parent)) kids.set(t.parent, []);
    kids.get(t.parent).push(t);
  }
  const key = (t) => String(t.name ?? t.address);
  for (const list of kids.values()) list.sort((a, b) => key(a).localeCompare(key(b)) || a.address.localeCompare(b.address));
  return kids;
}

// The descendants of `root`, depth first: [{ t, depth }] with depth 1 for a direct child. hc's parents form a tree; a cycle
// (never seen) stops at the first repeat.
function treeRows(kids, root) {
  const rows = [];
  const seen = new Set([root]);
  const walk = (addr, depth) => {
    for (const t of kids.get(addr) ?? []) {
      if (seen.has(t.address)) continue;
      seen.add(t.address);
      rows.push({ t, depth });
      walk(t.address, depth + 1);
    }
  };
  walk(root, 1);
  return rows;
}

// The panes of listed sessions that hang under another listed session: they show in its tree, not beside it. A pane in a
// cycle (never seen) stays beside the others, so it cannot vanish.
function nestedPanes(panes, terminals) {
  const listed = new Set(panes);
  const parentOf = new Map((terminals ?? []).map((t) => [t.address, t.parent]));
  const nested = new Set();
  for (const pane of listed) {
    const seen = new Set([pane]);
    let under = false;
    let up = parentOf.get(pane);
    for (; up && !seen.has(up); up = parentOf.get(up)) {
      under ||= listed.has(up);
      seen.add(up);
    }
    if (under && up !== pane) nested.add(pane);
  }
  return nested;
}
// </tree>


// <issues> pure helpers over the read API (scripts/jk-board-issues.test.ts runs this block after the tree block: no imports, no gpui)
// Most urgent first. wait=owner means the session needs a person.
const RANK = { needs: 0, working: 1, waiting: 2, idle: 3 };
function sessionKind(s) {
  if (s.state === "blocked" || s.state === "stuck" || s.wait === "owner") return "needs";
  if (s.state === "working" || s.state === "starting") return "working";
  if (s.state === "waiting" || s.state === "walled") return "waiting";
  return "idle";
}

const ISSUE_STATES = new Set(["settling", "queued", "working", "waiting", "watching", "closed"]);
const ISSUE_REASONS = new Set(["wait", "blocked", "decision", "wall", "dependency", "parked", "unreported", "lead_gone"]);
const SESSION_STATES = new Set(["starting", "working", "idle", "waiting", "walled", "blocked", "stuck", "dead"]);
const SESSION_WAITS = new Set(["workers", "deploy", "owner"]);
// The API is additive within /v1: a value this file does not know reads as "other", never as a crash.
const known = (value, set) => (set.has(value) ? value : value == null ? null : "other");

const asArray = (v) => (Array.isArray(v) ? v : []);
const parseJson = (text) => {
  try {
    const d = JSON.parse(String(text ?? ""));
    return d && typeof d === "object" ? d : null;
  } catch {
    return null;
  }
};

// `read overview` -> the overview, or null when it is not that (an error body, a cut line).
function parseOverview(text) {
  const d = parseJson(text);
  if (!d || !Array.isArray(d.asks) || !d.counts || typeof d.counts !== "object") return null;
  return { ...d, humanQueue: asArray(d.humanQueue), health: asArray(d.health), accounts: asArray(d.accounts),
    queue: { effective: d.queue?.effective ?? null, spawns: asArray(d.queue?.spawns) } };
}

const parseIssues = (text) => { const d = parseJson(text); return Array.isArray(d?.issues) ? d.issues.filter((c) => c && Number.isInteger(c.id)) : null; };
const parseSessions = (text) => { const d = parseJson(text); return Array.isArray(d?.sessions) ? d.sessions.filter((s) => s && typeof s.id === "string") : null; };

// The poll's stdout: three reads split on a line holding only @@, then hc's list behind a marker line. A JSON string cannot hold a
// raw newline, so no text from the API can equal either marker line.
function parse(stdout) {
  const cut = stdout.indexOf(HC_SPLIT);
  const [overview, issues, sessions] = (cut < 0 ? stdout : stdout.slice(0, cut)).split(/^@@$/m);
  return { overview: parseOverview(overview), issues: parseIssues(issues), sessions: parseSessions(sessions),
    hc: cut < 0 ? null : parseHc(stdout.slice(cut + HC_SPLIT.length)) };
}

// The Issue's id reaches the shell: an integer or no command at all.
const issueCmd = (id) => (Number.isInteger(id) && id > 0 ? `${SECRETS} factory --format json read issue ${id}` : null);

const isYours = (a) => (a.tier ?? "yours") === "yours";
const time = (iso) => Date.parse(iso) || 0;

// The owner's own asks first, then the rest; each group by time, oldest first.
function sortAsks(asks) {
  return [...asks].sort((a, b) => Number(!isYours(a)) - Number(!isYours(b)) || time(a.at) - time(b.at) || String(a.id).localeCompare(String(b.id)));
}

// The Issue an ask or a health line is about: its `issue` field, else the id of a decision ask (`decision:<issue>:…`).
function askIssue(a) {
  if (Number.isInteger(a?.issue)) return a.issue;
  const m = /^decision:(\d+):/.exec(String(a?.id ?? ""));
  return m ? Number(m[1]) : null;
}

// The human queue: the open ones, then the stale (listed, counted nowhere); each oldest first.
function splitQueue(items) {
  const byTime = (a, b) => time(a.at) - time(b.at) || String(a.id).localeCompare(String(b.id));
  const list = asArray(items);
  return { fresh: list.filter((q) => !q.stale).sort(byTime), stale: list.filter((q) => q.stale).sort(byTime) };
}

// The Issues tab badge: asks plus the open human queue. A health line never asks for the owner, so it is never counted here.
function askBadge(overview) {
  if (!overview) return { count: 0, urgent: false };
  const asks = asArray(overview.asks);
  const queue = Number.isInteger(overview.counts?.humanQueue) ? overview.counts.humanQueue : splitQueue(overview.humanQueue).fresh.length;
  return { count: asks.length + queue, urgent: asks.some(isYours) };
}

// Health lines (parks, a silent lead, regressions, machine failures) never ask the owner: oldest first, below the asks.
function sortHealth(lines) {
  return [...lines].sort((a, b) => time(a.since) - time(b.since) || String(a.id).localeCompare(String(b.id)));
}

// `3 working · 1 waiting · 6 queued · queue: run`
function summaryLine(overview) {
  const n = overview?.counts ?? {};
  const parts = [`${n.working ?? 0} working`, `${n.waiting ?? 0} waiting`];
  if (n.watching) parts.push(`${n.watching} watching`);
  parts.push(`${n.queued ?? 0} queued`);
  if (overview?.queue?.effective) parts.push(`queue: ${overview.queue.effective}`);
  return parts.join(" · ");
}

// An ask's text on one line.
function oneLine(text, max = 140) {
  const flat = String(text ?? "").replace(/\s+/g, " ").trim();
  return flat.length > max ? `${flat.slice(0, max - 1)}…` : flat;
}

function age(iso, now = Date.now()) {
  const ms = now - Date.parse(iso);
  if (!(ms >= 0)) return "";
  const m = Math.floor(ms / 60000);
  if (m < 1) return "now";
  if (m < 60) return `${m}m`;
  const h = Math.floor(m / 60);
  return h < 48 ? `${h}h` : `${Math.floor(h / 24)}d`;
}

// Working time: 38m, 2h 5m, 26h.
function duration(ms) {
  if (!(ms > 0)) return "";
  const m = Math.floor(ms / 60000);
  if (m < 1) return "<1m";
  if (m < 60) return `${m}m`;
  const h = Math.floor(m / 60);
  return h >= 10 || m % 60 === 0 ? `${h}h` : `${h}h ${m % 60}m`;
}

// 940, 1.2k, 61k, 3.4M
function compact(n) {
  if (!(n >= 0)) return "0";
  if (n < 1000) return String(Math.round(n));
  if (n < 10000) return `${(n / 1000).toFixed(1)}k`;
  if (n < 1e6) return `${Math.round(n / 1000)}k`;
  return `${(n / 1e6).toFixed(1)}M`;
}

// claude-sonnet-5-5 -> sonnet
function modelShort(name) {
  const m = /(opus|sonnet|haiku|fable)/i.exec(String(name ?? ""));
  return m ? m[1].toLowerCase() : String(name ?? "").replace(/^claude-/, "");
}

// `feature · l · sonnet · 20 turns · 112 tools · 10 subagents · 61k out`, "partial" when the insights are incomplete.
function factsLine(c) {
  const i = c.insights ?? {};
  const parts = [c.kind, c.size, asArray(i.models).map(modelShort).join("+") || null,
    Number.isFinite(i.turns) ? `${i.turns} turns` : null, Number.isFinite(i.toolCalls) ? `${i.toolCalls} tools` : null,
    Number.isFinite(i.subagents) ? `${i.subagents} subagents` : null, Number.isFinite(i.tokens?.output) ? `${compact(i.tokens.output)} out` : null,
    i.partial ? "partial" : null];
  return parts.filter(Boolean).join(" · ");
}

// `me2 5h 1% · 7d 83%`; nothing without a quota.
function quotaLine(q) {
  if (!q?.account) return "";
  const parts = [Number.isFinite(q.fiveHourUsed) ? `5h ${Math.round(q.fiveHourUsed)}%` : null, Number.isFinite(q.weeklyUsed) ? `7d ${Math.round(q.weeklyUsed)}%` : null];
  return [q.account, parts.filter(Boolean).join(" · ")].filter(Boolean).join(" ");
}

// Line 2 of a card: repo · phase (else state, with its reason or outcome: "waiting: decision") · account.
function metaLine(c) {
  const state = known(c.state, ISSUE_STATES) ?? "other";
  const why = known(c.reason, ISSUE_REASONS) ?? (c.state === "closed" ? oneLine(c.outcome, 24) || null : null);
  const stage = c.phase ? oneLine(c.phase, 40) : why ? `${state}: ${why}` : state;
  return [c.repoName, stage, c.account].filter(Boolean).join(" · ");
}

// The dot of an Issue: needs when it waits on the owner (or its lead does), else its lead's state; queued and closed ones are idle.
function issueKind(c, lead) {
  if (c.waitingOnOwner || c.reason === "decision" || c.reason === "blocked" || c.reason === "wall") return "needs";
  if (lead && sessionKind(lead) === "needs") return "needs";
  if (c.state === "queued" || c.state === "closed") return "idle";
  if (lead) return sessionKind(lead);
  return c.state === "working" ? "working" : c.state === "waiting" || c.state === "watching" || c.state === "settling" ? "waiting" : "idle";
}

// The Issues in their three sections. Running: open with a live lead or an active state, needs first, then the most recent
// activity. Queued: oldest first (the queue's order). Recent: closed, newest first, RECENT_MAX of them.
function sections(cards, sessionsById) {
  const byId = sessionsById ?? new Map();
  const live = (c) => (c.lead ? byId.get(c.lead) ?? null : null);
  const recency = (a, b) => time(b.updatedAt) - time(a.updatedAt) || b.id - a.id;
  const running = [], queued = [], recent = [];
  for (const c of asArray(cards)) {
    if (c.state === "closed") recent.push(c);
    else if (c.state === "queued" && !live(c)) queued.push(c);
    else running.push(c);
  }
  const rank = (c) => RANK[issueKind(c, live(c))];
  return {
    running: running.sort((a, b) => rank(a) - rank(b) || recency(a, b)),
    queued: queued.sort((a, b) => time(a.createdAt) - time(b.createdAt) || a.id - b.id),
    recent: recent.sort((a, b) => time(b.closedAt) - time(a.closedAt) || b.id - a.id).slice(0, RECENT_MAX),
  };
}

// The queue's hold reason for an Issue's spawn (its key is `lead-<issue>-<n>`), or null.
function holdFor(spawns, c) {
  const q = asArray(spawns).find((s) => String(s.key).startsWith(`lead-${c.id}-`) && s.hold);
  return q ? String(q.hold) : null;
}

// A repo's name from a session's working folder (a factory worktree resolves to its repo).
function repoOf(path) {
  const p = String(path ?? "").replace(/\/\.claude\/worktrees\/.*$/, "").replace(/\/+$/, "");
  return p.split("/").pop() || null;
}

// What the pane header shows per terminal: app terminal address (`mini/<id>`) -> the Issue's words plus the session's own role.
// Only these fields are shared (shared is persisted and every mod re-renders on a change): no insights, no elapsed time.
function terminalsMap(issues, sessions) {
  const byId = new Map(asArray(issues).map((c) => [c.id, c]));
  const out = {};
  const rows = asArray(sessions).filter((s) => s.terminal && ADDR.test(String(s.terminal.id)))
    .sort((a, b) => String(a.terminal.id).localeCompare(String(b.terminal.id)));
  for (const s of rows) {
    const c = Number.isInteger(s.issue) ? byId.get(s.issue) : null;
    out[`mini/${s.terminal.id}`] = {
      issue: Number.isInteger(s.issue) ? s.issue : null,
      title: c?.filedTitle ?? s.title ?? null,
      short: c?.title ?? s.title ?? null,
      summary: c?.summary ?? s.summary ?? null,
      phase: c?.phase ?? null,
      role: s.role ?? null,
      state: s.state ?? null,
      repo: c?.repoName ?? repoOf(s.repo),
    };
  }
  return out;
}

// `read issue <id>` -> its last n timeline lines [{ at, text }], or null when it is not that.
function timelineTail(text, n = TIMELINE_LINES) {
  const d = parseJson(text);
  if (!Array.isArray(d?.timeline)) return null;
  return d.timeline.slice(-n).map((e) => ({ at: e.at, text: oneLine(e.text, 200) }));
}

const clock = (iso) => (Date.parse(iso) ? new Date(iso).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }) : "");

// A stored or shared tab name: "waves" (the old tab) reads as "issues".
const normTab = (v) => (v === "uptime" ? "uptime" : "issues");
// </issues>

// Hover text and the footer legend; the left sidebar's dots use the same colors.
const MEANING = {
  needs: "Needs you: blocked, or waiting on the owner",
  working: "Working",
  waiting: "Waiting on its workers or a deploy",
  idle: "Idle",
};

// hc's own status word for a terminal the factory does not list.
const hcKind = (status) => ({ working: "working", blocked: "needs" }[status] ?? "idle");

export default class Board extends View {
  init(_props, cx) {
    this.overview = null; // last good answers, one per read
    this.issues = null;
    this.sessions = null;
    this.at = 0; // when the overview was read
    this.tried = false; // a poll has ended, good or not
    this.polling = false;
    this.hc = null; // hc's terminals, for the child tree
    this.hcAt = 0; // when hc last answered: an old answer is not shown
    this.peeks = new Map(); // child address -> { lines, at } once opened; absent = closed
    this.details = new Map(); // Issue id -> { lines } its last timeline lines, read while the card is open
    this.detailBusy = new Set();
    this.byTerminal = new Map(); // terminal id -> live session, for the names and states in a tree
    this.bySession = new Map(); // session id -> live session, for a jump
    this.cards = new Map(); // Issue id -> card
    this.kids = new Map(); // parent terminal -> its children
    this.published = JSON.stringify(shared("jk.factory.terminals") ?? null);
    this.tab = normTab(localStorage.getItem("board.tab"));
    this.seenTab = null; // last shared("jk.board.tab") adopted
    this.uptime = null; // last good Argo answer
    this.uptimeAt = 0;
    this.uptimeBusy = false;
    this.upOpen = JSON.parse(localStorage.getItem("board.uptime.open") ?? "{}"); // group -> shown?
    this.open = new Set(JSON.parse(localStorage.getItem("issues.open") ?? "[]")); // expanded Issue cards
    this.folded = new Set(JSON.parse(localStorage.getItem("issues.folded") ?? "[]"));
    this.refresh(cx);
    cx.timer.every(POLL_MS, (cx) => this.refresh(cx));
    this.refreshUptime(cx);
    cx.timer.every(UPTIME_MS, (cx) => {
      if (this.tab === "uptime" || Date.now() - this.uptimeAt >= UPTIME_BG_MS - 1000) this.refreshUptime(cx);
      else cx.notify();
    });
  }

  refreshUptime(cx) {
    if (this.uptimeBusy || machines().find((m) => m.name === "mini")?.layout !== "ready") return;
    this.uptimeBusy = true;
    cx.spawn(async (cx) => {
      const r = await exec("sh", ["-c", UPTIME], { on: "mini" }).catch(() => null);
      this.uptimeBusy = false;
      let d = null;
      try { d = JSON.parse(r?.stdout ?? ""); } catch {}
      if (Array.isArray(d?.monitors)) { this.uptime = d; this.uptimeAt = Date.now(); }
      cx.notify();
    });
  }

  refresh(cx) {
    if (this.polling || machines().find((m) => m.name === "mini")?.layout !== "ready") {
      cx.notify(); // the stale dimming follows the clock
      return;
    }
    this.polling = true;
    cx.spawn(async (cx) => {
      const r = await exec("sh", ["-c", CMD], { on: "mini" }).catch(() => null);
      this.polling = false;
      this.tried = true;
      const next = r?.stdout ? parse(r.stdout) : null;
      // The reads and hc are separate answers: each keeps its last good one.
      if (next?.overview) {
        this.overview = next.overview;
        this.at = Date.now();
      }
      if (next?.issues) {
        this.issues = next.issues;
        this.cards = new Map(next.issues.map((c) => [c.id, c]));
      }
      if (next?.sessions) this.sessions = next.sessions;
      // Both from this poll, or a new Issue's header would flicker through its session's words.
      if (next?.issues && next?.sessions) this.publish();
      if (next?.hc) {
        this.hc = next.hc;
        this.hcAt = Date.now();
      }
      for (const addr of this.peeks.keys()) this.readPeek(addr, cx);
      for (const id of this.open) if (this.cards.has(id)) this.readDetail(id, cx); // an aged-out Issue stays remembered, unread
      cx.notify();
    });
  }

  // The header feed, only when it changed.
  publish() {
    const json = JSON.stringify(terminalsMap(this.issues, this.sessions));
    if (json === this.published) return;
    this.published = json;
    setShared("jk.factory.terminals", JSON.parse(json));
  }

  // An open Issue's last timeline lines, with every poll. One read after it closed is final.
  readDetail(id, cx) {
    const cmd = issueCmd(id);
    if (!cmd || this.detailBusy.has(id)) return;
    if (this.details.get(id)?.final) return;
    const final = this.cards.get(id)?.state === "closed";
    this.detailBusy.add(id);
    cx.spawn(async (cx) => {
      const r = await exec("sh", ["-c", cmd], { on: "mini" }).catch(() => null);
      this.detailBusy.delete(id);
      const lines = timelineTail(r?.stdout);
      if (lines) this.details.set(id, { lines, final });
      cx.notify();
    });
  }

  // The last lines of a child, read on the mini. Kept while the row stays open, refreshed with every poll.
  readPeek(addr, cx) {
    if (!ADDR.test(addr)) return;
    const ticket = (this.peekTicket = (this.peekTicket ?? 0) + 1);
    this.peeks.set(addr, { ...(this.peeks.get(addr) ?? { lines: null }), ticket });
    cx.spawn(async (cx) => {
      const r = await exec("sh", ["-c", peekCmd(addr)], { on: "mini" }).catch(() => null);
      if (this.peeks.get(addr)?.ticket !== ticket) return; // closed, or a newer read is on its way
      const lines = r?.stdout?.trim() ? r.stdout.trimEnd().split("\n") : ["(could not read it)"];
      this.peeks.set(addr, { lines, ticket });
      cx.notify();
    });
  }

  togglePeek(addr, cx) {
    if (this.peeks.has(addr)) this.peeks.delete(addr);
    else this.readPeek(addr, cx);
    cx.notify();
  }

  toggle(set, key, store, cx) {
    set.has(key) ? set.delete(key) : set.add(key);
    localStorage.setItem(store, JSON.stringify([...set]));
    cx.notify();
  }

  toggleIssue(id, cx) {
    this.toggle(this.open, id, "issues.open", cx);
    if (this.open.has(id)) this.readDetail(id, cx);
  }

  tone(t, kind) {
    return { needs: t.blocked, working: t.working, waiting: t.working, idle: t.dim }[kind] ?? t.dim;
  }

  dot(t, kind, size = 7, hint = true) {
    // Filled for needs you / working, a ring for waiting (amber: busy through its workers) and idle.
    const live = kind === "needs" || kind === "working";
    return div().size(size).flex_none().rounded(size / 2).when(hint && Boolean(MEANING[kind]), (d) => d.tooltip(MEANING[kind]))
      .when(live, (d) => d.bg(this.tone(t, kind)))
      .when(!live, (d) => d.border_1().border_color(this.tone(t, kind)));
  }

  // Jump to a session's agent; null while the app does not list its terminal (a row without one is not clickable).
  jumpTo(s) {
    const address = s?.terminal?.id ? `mini/${s.terminal.id}` : null;
    return address && terminals().some((x) => x.address === address) ? address : null;
  }

  // Where an ask or a health line leads: its session, else the lead of its Issue.
  jumpFor(item) {
    const s = this.bySession.get(item.session) ?? this.bySession.get(this.cards.get(askIssue(item))?.lead);
    return this.jumpTo(s);
  }

  stateOf(s) {
    const state = known(s.state, SESSION_STATES) ?? "other";
    const wait = known(s.wait, SESSION_WAITS);
    return wait ? `${state} · ${wait}` : state;
  }

  // A session of an Issue (or of none): role, title, state. `tip` replaces the jump hint.
  sessionRow(t, s, tip = "Jump to this agent") {
    const address = this.jumpTo(s);
    const kind = sessionKind(s);
    return h_flex().id(`is-s-${s.id}`).h(18).flex_none().gap(6).items_center().pl(10).text_size(11).rounded(5).tooltip(tip)
      .when(Boolean(address), (el) => el.cursor_pointer().hover((st) => st.bg(t.selected))
        .on_click((_e, cx) => { cx.stop_propagation(); run("agent.focus", { terminal: address }); }))
      .child(this.dot(t, kind, 5))
      .child(div().flex_shrink(0).text_color(t.muted).child(s.role ?? "?"))
      .child(div().flex_1().min_w(0).truncate().text_color(t.foreground).child(s.title || s.id))
      .child(div().flex_none().text_color(kind === "needs" ? this.tone(t, "needs") : t.dim).child(this.stateOf(s)));
  }

  // A hidden child under its session row: name, state, turn. The state is the factory's when it lists the terminal, else hc's.
  childRow(t, { t: c, depth }) {
    const s = this.byTerminal.get(c.address);
    const kind = s ? s.kind : hcKind(c.status);
    const what = `${s ? this.stateOf(s) : c.status ?? "?"}${c.turn ? ` · t${c.turn}` : ""}`;
    const peek = this.peeks.get(c.address);
    const row = h_flex().id(`wv-c-${c.address}`).h(18).flex_none().gap(6).items_center().pl(10 + 12 * depth).text_size(11).cursor_pointer()
      .hover((e) => e.bg(t.hover))
      .on_mouse_down("left", (_e, cx) => cx.stop_propagation())
      .on_click((_e, cx) => { cx.stop_propagation(); this.togglePeek(c.address, cx); })
      .tooltip("Click for its last lines")
      .child(this.dot(t, kind, 5))
      .when(Boolean(s?.role), (el) => el.child(div().flex_shrink(0).text_color(t.muted).child(s.role)))
      .child(div().flex_1().min_w(0).truncate().text_color(t.muted).child(c.name ?? c.address))
      .child(div().flex_none().text_color(kind === "needs" ? this.tone(t, "needs") : t.dim).child(what));
    if (!peek) return [row];
    const lines = peek.lines ?? ["…"];
    return [row, v_flex().id(`wv-cp-${c.address}`).flex_none().pl(10 + 12 * depth + 11).pr(4).py(2)
      .children(lines.map((l, i) => div().id(`wv-cp-${c.address}-${i}`).truncate().text_size(10.5).text_color(t.dim).child(l)))];
  }

  // A session row with the hidden children under its terminal.
  sessionWithTree(t, s, tip) {
    const tree = s.terminal?.id ? treeRows(this.kids, s.terminal.id).flatMap((row) => this.childRow(t, row)) : [];
    return [this.sessionRow(t, s, tip), ...tree];
  }

  // The expanded part of an Issue card.
  issueBody(t, c) {
    const lead = this.bySession.get(c.lead) ?? null;
    const mine = [...this.bySession.values()].filter((s) => s.issue === c.id)
      .sort((a, b) => RANK[sessionKind(a)] - RANK[sessionKind(b)] || a.id.localeCompare(b.id));
    const nested = nestedPanes(mine.map((s) => s.terminal?.id).filter(Boolean), this.hcList);
    const shown = mine.filter((s) => !s.terminal?.id || !nested.has(s.terminal.id));
    const facts = factsLine(c);
    const quota = quotaLine(c.quota);
    const lines = this.details.get(c.id)?.lines ?? [];
    const jump = this.jumpTo(lead);
    const note = (id, text, tip) => div().id(`is-${c.id}-${id}`).truncate().text_size(11).text_color(t.dim).tooltip(tip ?? text).child(text);
    return v_flex().mt(3).gap(2)
      .when(Boolean(c.filedTitle) && c.filedTitle !== c.title, (el) => el.child(div().pl(14).text_size(11).text_color(t.dim).child(c.filedTitle)))
      .when(Boolean(facts), (el) => el.child(div().pl(14).child(note("facts", facts))))
      .when(Boolean(quota), (el) => el.child(div().pl(14).child(note("quota", quota))))
      .children(shown.flatMap((s) => this.sessionWithTree(t, s)))
      .children(lines.map((l, i) => h_flex().id(`is-${c.id}-tl-${i}`).pl(14).gap(6).text_size(10.5).text_color(t.dim)
        .child(div().flex_none().child(clock(l.at))).child(div().flex_1().min_w(0).truncate().tooltip(l.text).child(l.text))))
      .when(Boolean(jump), (el) => el.child(h_flex().id(`is-${c.id}-jump`).h(18).pl(10).items_center().rounded(5).text_size(11).text_color(t.muted)
        .cursor_pointer().hover((st) => st.bg(t.selected).text_color(t.foreground))
        .on_click((_e, cx) => { cx.stop_propagation(); run("agent.focus", { terminal: jump }); })
        .child("Jump to agent")));
  }

  // A running or closed Issue: dot, human title, working time; repo · phase · account; the summary, all of it; the rest on click.
  issueCard(t, c) {
    const open = this.open.has(c.id);
    const lead = this.bySession.get(c.lead) ?? null;
    const kind = issueKind(c, lead);
    const meta = metaLine(c);
    const worked = duration(c.insights?.workingMs);
    return v_flex().id(`is-${c.id}`).flex_none().px(8).py(5).gap(2).rounded(8).cursor_pointer()
      .when(this.focusIssue === c.id, (el) => el.bg(t.selected))
      .hover((s) => s.bg(t.hover))
      .on_click((_e, cx) => this.toggleIssue(c.id, cx))
      .child(h_flex().gap(7).items_start()
        .child(div().h(18).flex_none().flex().items_center().child(this.dot(t, kind)))
        .child(div().flex_1().min_w(0).text_color(t.foreground).font_semibold().child(c.title))
        .when(Boolean(worked), (el) => el.child(div().flex_none().text_size(11).text_color(t.dim).tooltip("Working time").child(worked))))
      .when(Boolean(meta), (el) => el.child(div().pl(14).truncate().text_size(11).text_color(t.dim).child(meta)))
      .when(Boolean(c.summary), (el) => el.child(div().pl(14).text_size(11).text_color(t.muted).child(c.summary)))
      .when(open, (el) => el.child(this.issueBody(t, c)));
  }

  // A queued Issue: title and repo, plus the queue's hold reason when it has one.
  queuedCard(t, c, spawns) {
    const hold = holdFor(spawns, c);
    return v_flex().id(`is-${c.id}`).flex_none().px(8).py(3).gap(1).rounded(8).hover((s) => s.bg(t.hover))
      .tooltip(c.summary || c.filedTitle || c.title)
      .child(h_flex().gap(7).items_center()
        .child(this.dot(t, "idle"))
        .child(div().flex_1().min_w(0).truncate().text_color(t.foreground).child(c.title)))
      .child(div().pl(14).truncate().text_size(11).text_color(t.dim).child([c.repoName, hold ? `held: ${hold}` : null].filter(Boolean).join(" · ")));
  }

  // One ask: the owner's own in the blocked tone, the rest muted. Short, repo (or where it came from), age; the tooltip has the rest.
  askRow(t, a) {
    const yours = isYours(a);
    const address = this.jumpFor(a);
    const hint = a.suggestion ? `Suggested: ${a.suggestion.verb} — ${a.suggestion.why} (${a.suggestion.evidence})` : null;
    const tip = [a.summary, oneLine(a.text, 600), hint].filter(Boolean).join("\n\n");
    return h_flex().id(`is-a-${a.id}`).h(18).flex_none().gap(6).items_center().pl(10).text_size(11).rounded(5).tooltip(tip)
      .when(Boolean(address), (el) => el.cursor_pointer().hover((st) => st.bg(t.selected))
        .on_click((_e, cx) => run("agent.focus", { terminal: address })))
      .child(this.dot(t, yours ? "needs" : "idle", 5, false))
      .child(div().flex_1().min_w(0).truncate().text_color(yours ? t.foreground : t.muted).child(oneLine(a.short ?? a.text)))
      .child(div().flex_shrink(0).max_w(76).truncate().text_color(t.dim).child(a.repo ? base(a.repo) : a.source))
      .child(div().w(26).flex_none().text_right().text_color(t.dim).child(age(a.at)));
  }

  // A human-queue item: nothing to jump to. Stale ones are dim.
  queueRow(t, q, stale) {
    const tip = [q.summary, oneLine(q.text, 600)].filter(Boolean).join("\n\n");
    return h_flex().id(`is-q-${q.id}`).h(18).flex_none().gap(6).items_center().pl(10).text_size(11).rounded(5).tooltip(tip)
      .when(stale, (el) => el.opacity(0.55))
      .child(this.dot(t, "idle", 5, false))
      .child(div().flex_1().min_w(0).truncate().text_color(stale ? t.dim : t.foreground).child(oneLine(q.short ?? q.text)))
      .child(div().flex_shrink(0).max_w(76).truncate().text_color(t.dim).child(q.repo ? base(q.repo) : q.source))
      .child(div().w(26).flex_none().text_right().text_color(t.dim).child(age(q.at)));
  }

  // One health line, dimmer than an ask and with no urgency dot: short, repo (else its kind), age; a click jumps to its session or Issue's lead.
  healthRow(t, h) {
    const address = this.jumpFor(h);
    const tip = [h.summary, oneLine(h.text, 600)].filter(Boolean).join("\n\n");
    return h_flex().id(`is-hl-${h.id}`).h(18).flex_none().gap(6).items_center().pl(10).text_size(11).rounded(5).tooltip(tip)
      .when(Boolean(address), (el) => el.cursor_pointer().hover((st) => st.bg(t.selected))
        .on_click((_e, cx) => run("agent.focus", { terminal: address })))
      .child(this.dot(t, "idle", 5, false))
      .child(div().flex_1().min_w(0).truncate().text_color(t.dim).child(oneLine(h.short ?? h.text)))
      .child(div().flex_shrink(0).max_w(76).truncate().text_color(t.dim).child(h.repo ? base(h.repo) : h.kind))
      .child(div().w(26).flex_none().text_right().text_color(t.dim).child(age(h.since)));
  }

  // A section: its header, then the rows (a thunk) unless folded. `fold` sections start folded and open on a click.
  section(t, id, label, count, rows, { fold = false, urgent = null } = {}) {
    const key = fold ? `open:${id}` : id;
    const folded = fold ? !this.folded.has(key) : this.folded.has(key);
    return [this.header(t, key, label, count, folded, urgent), ...(folded ? [] : rows())];
  }

  header(t, id, label, count, folded, urgent) {
    return h_flex().id(id).h(20).mt(4).flex_none().px(8).gap(7).items_center().rounded(6)
      .text_size(10.5).font_bold().text_color(t.dim).cursor_pointer().hover((s) => s.bg(t.hover))
      .on_click((_e, cx) => this.toggle(this.folded, id, "issues.folded", cx))
      .child(div().flex_1().truncate().child(label))
      .when(folded && urgent, (el) => el.child(div().flex_none().text_color(this.tone(t, urgent)).child("●")))
      .child(div().flex_none().child(String(count)))
      .child(svg(`mods/workspace-chrome/chevron-${folded ? "right" : "down"}.svg`).size(11).flex_none());
  }

  // Honor a switch another mod asked for (jk-status' Kuma counter) once per change.
  adoptTab() {
    const want = shared("jk.board.tab");
    if (want === this.seenTab) return;
    this.seenTab = want;
    if (want === "issues" || want === "waves" || want === "uptime") this.setTab(normTab(want), null);
  }

  setTab(tab, cx) {
    this.tab = tab;
    localStorage.setItem("board.tab", tab);
    if (!cx) return;
    this.seenTab = tab;
    setShared("jk.board.tab", tab);
    cx.notify();
  }

  // Monitors that count: not groups, not paused (as Argo's /uptime-kuma/status).
  upStats() {
    const ms = (this.uptime?.monitors ?? []).filter((m) => m.type !== "group" && m.active);
    const by = (s) => ms.filter((m) => m.status === s);
    return { ms, up: by(1), down: by(0), pending: by(2), maint: by(3) };
  }

  tabs(t) {
    const down = this.upStats().down.length;
    const { count, urgent } = askBadge(this.overview);
    return h_flex().flex_none().px(8).pt(8).pb(2)
      .child(h_flex().flex_1().gap(2).p(2).rounded(8).bg(t.hover)
        .children(TABS.map(([id, label]) => {
          const on = this.tab === id;
          return h_flex().id(`bd-tab-${id}`).flex_1().h(22).gap(5).items_center().justify_center().rounded(6).cursor_pointer().text_size(11.5)
            .text_color(on ? t.foreground : t.dim)
            .when(on, (el) => el.bg(t.selected).font_semibold())
            .when(!on, (el) => el.hover((s) => s.bg(t.selected)))
            .on_click((_e, cx) => this.setTab(id, cx))
            .child(label)
            .when(id === "uptime" && down > 0, (el) => el.child(div().text_color(t.blocked).child(String(down))))
            .when(id === "issues" && count > 0, (el) => el.child(div().text_color(urgent ? t.blocked : t.dim).child(String(count))));
        })));
  }

  render() {
    this.adoptTab();
    const t = theme();
    return v_flex().size_full().min_h(0).bg(t.chrome)
      .child(this.tabs(t))
      .child(this.tab === "uptime" ? this.uptimeView(t) : this.issuesView(t));
  }

  issuesView(t) {
    const ov = this.overview;
    // Stale after STALE_MS without a good poll, or when the factory's own snapshot is that old.
    const since = ov ? Math.max(Date.now() - this.at, Date.now() - (Date.parse(ov.builtAt) || this.at)) : 0;
    const stale = ov && since > STALE_MS;
    const hcFresh = this.hcAt && Date.now() - this.hcAt <= STALE_MS;
    const live = this.sessions ?? [];
    this.bySession = new Map(live.map((s) => [s.id, s]));
    this.byTerminal = new Map(live.filter((s) => s.terminal?.id).map((s) => [s.terminal.id, { ...s, kind: sessionKind(s) }]));
    this.hcList = hcFresh ? this.hc ?? [] : [];
    this.kids = childMap(this.hcList);
    const at = focused();
    const here = at?.terminal ?? at?.agent ?? null;
    this.focusIssue = here ? live.find((s) => s.terminal?.id && `mini/${s.terminal.id}` === here)?.issue ?? null : null;

    const asks = ov ? sortAsks(ov.asks) : [];
    const { fresh, stale: older } = splitQueue(ov?.humanQueue);
    const health = ov ? sortHealth(ov.health) : [];
    const { running, queued, recent } = this.issues ? sections(this.issues, this.bySession) : { running: [], queued: [], recent: [] };
    const nestedLoose = nestedPanes(live.filter((s) => s.issue == null).map((s) => s.terminal?.id).filter(Boolean), this.hcList);
    const loose = live.filter((s) => s.issue == null && !nestedLoose.has(s.terminal?.id)).sort((a, b) => RANK[sessionKind(a)] - RANK[sessionKind(b)] || a.id.localeCompare(b.id));
    const spawns = ov?.queue?.spawns ?? [];
    const queueCount = Number.isInteger(ov?.counts?.humanQueue) ? ov.counts.humanQueue : fresh.length;
    const olderOpen = this.folded.has("open:hq-older");
    return v_flex().flex_1().min_h(0).text_size(13)
      .child(v_flex().flex_none().px(16).pt(8).pb(4).gap(1)
        .child(div().text_size(11.5).text_color(t.dim).child("Issues"))
        .when(Boolean(ov), (el) => el.child(div().truncate().text_size(11).text_color(t.dim).child(summaryLine(ov)))))
      .child(v_flex().flex_1().min_h(0).px(8).pb(14).overflow_y_scrollbar().mode("always")
        .when(Boolean(stale), (el) => el.opacity(0.5))
        .when(!ov, (el) => el.child(div().px(8).py(6).text_size(12).text_color(t.dim).child(this.tried ? "No answer from the factory" : "Loading…")))
        .when(Boolean(ov) && Boolean(this.issues) && !running.length, (el) => el.child(div().px(8).py(6).text_size(12).text_color(t.dim).child("No Issue running")))
        .children(asks.length ? this.section(t, "asks", "ASKS", asks.length, () => asks.map((a) => this.askRow(t, a)), { urgent: asks.some(isYours) ? "needs" : null }) : [])
        .children(fresh.length || older.length ? this.section(t, "hq", "HUMAN QUEUE", queueCount, () => [
          ...fresh.map((q) => this.queueRow(t, q, false)),
          ...(older.length ? [h_flex().id("is-hq-older").h(18).flex_none().gap(6).items_center().pl(10).text_size(11).rounded(5).cursor_pointer()
            .hover((s) => s.bg(t.hover)).text_color(t.dim)
            .on_click((_e, cx) => this.toggle(this.folded, "open:hq-older", "issues.folded", cx))
            .child(div().flex_1().child(`older (${older.length})`))
            .child(svg(`mods/workspace-chrome/chevron-${olderOpen ? "down" : "right"}.svg`).size(11).flex_none().mr(8))] : []),
          ...(older.length && olderOpen ? older.map((q) => this.queueRow(t, q, true)) : []),
        ]) : [])
        .children(health.length ? this.section(t, "health", "HEALTH", health.length, () => health.map((h) => this.healthRow(t, h))) : [])
        .children(running.length ? this.section(t, "running", "RUNNING", running.length, () => running.map((c) => this.issueCard(t, c))) : [])
        .children(queued.length ? this.section(t, "queued", "QUEUED", queued.length, () => queued.map((c) => this.queuedCard(t, c, spawns)), { fold: true }) : [])
        .children(recent.length ? this.section(t, "recent", "RECENT", recent.length, () => recent.map((c) => this.issueCard(t, c)), { fold: true }) : [])
        .children(loose.length ? this.section(t, "sessions", "SESSIONS", loose.length,
          () => loose.flatMap((s) => this.sessionWithTree(t, s, [s.title, s.summary].filter(Boolean).join("\n\n")))) : []))
      .child(this.legend(t));
  }

  // Every dot color in one line, with its meaning on hover.
  legend(t) {
    return this.legendRow(t, "wv", [
      ["working", t.working, "working", "Agent working"],
      ["blocked", t.blocked, "needs you", "Blocked, or waiting on the owner"],
      ["waiting", t.working, "waiting", "Waiting on its workers or a deploy", true],
      ["idle", t.dim, "idle", "Agent there, idle", true],
    ]);
  }

  legendRow(t, prefix, items) {
    const item = (id, color, label, hint, ring = false) => h_flex().id(`${prefix}-legend-${id}`).flex_none().gap(4).items_center().tooltip(hint)
      .child(div().size(6).rounded(3).when(!ring, (d) => d.bg(color)).when(ring, (d) => d.border_1().border_color(color)))
      .child(label);
    return h_flex().flex_none().flex_wrap().gap_x(10).gap_y(2).px(16).py(8).border_t_1().border_color(t.border).text_size(10.5).text_color(t.dim)
      .children(items.map((i) => item(...i)));
  }

  upTone(t, status) {
    return { 0: t.blocked, 2: t.ansi3, 3: t.accent }[status] ?? t.dim;
  }

  upDot(t, m) {
    return div().size(7).flex_none().rounded(3.5).bg(this.upTone(t, m.status));
  }

  // "Parent / Child" for a monitor's group chain; null when Argo sends no parents (a flat list).
  upGroup(m, byId) {
    if (!("parent" in m)) return null;
    const names = [];
    for (let p = byId.get(String(m.parent)), n = 0; p && n < 8; p = byId.get(String(p.parent)), n++) names.unshift(p.name);
    return names.length ? names.join(" / ") : "Other";
  }

  upTip(m) {
    const parts = [m.msg, m.lastBeatAt ? `last beat ${new Date(m.lastBeatAt).toLocaleString()}` : null,
      m.uptime30d != null ? `30 d: ${(m.uptime30d * 100).toFixed(2)}%` : null].filter(Boolean);
    return parts.join("\n");
  }

  upRow(t, m, scope, group) {
    const tip = this.upTip(m);
    const day = m.uptime1d;
    const alarm = m.status === 0 || m.status === 2;
    return h_flex().id(`ub-${scope}-${m.id}`).h(20).flex_none().gap(7).items_center().px(8).rounded(6).text_size(11.5)
      .hover((s) => s.bg(t.hover)).when(Boolean(tip), (el) => el.tooltip(tip))
      .child(this.upDot(t, m))
      .child(div().flex_1().min_w(0).truncate().text_color(t.foreground).child(m.name))
      .when(alarm && Boolean(group), (el) => el.child(div().flex_shrink(0).max_w(60).truncate().text_size(10.5).text_color(t.dim).child(group.split(" / ").pop())))
      .when(alarm && Boolean(m.msg), (el) => el.child(div().flex_shrink(1).max_w(80).truncate().text_size(10.5).text_color(t.dim).child(m.msg)))
      .when(!alarm, (el) => el
        .child(div().w(44).flex_none().text_right().text_size(10.5).text_color(t.dim).child(m.ping != null ? `${Math.round(m.ping)} ms` : ""))
        .child(div().w(42).flex_none().text_right().text_size(10.5).text_color(day != null && day < 0.95 ? t.blocked : t.dim)
          .child(day == null ? "" : day >= 0.9995 ? "100%" : `${(day * 100).toFixed(1)}%`)));
  }

  upHeader(t, label, count, shown, hasDown) {
    return h_flex().id(`ub-g-${label}`).h(20).mt(4).flex_none().px(8).gap(7).items_center().rounded(6)
      .text_size(10.5).font_bold().text_color(t.dim).cursor_pointer().hover((s) => s.bg(t.hover))
      .on_click((_e, cx) => {
        this.upOpen[label] = !shown;
        localStorage.setItem("board.uptime.open", JSON.stringify(this.upOpen));
        cx.notify();
      })
      .child(div().flex_1().truncate().child(label))
      .when(!shown && hasDown, (el) => el.child(div().flex_none().text_color(t.blocked).child("●")))
      .child(div().flex_none().child(String(count)))
      .child(svg(`mods/workspace-chrome/chevron-${shown ? "down" : "right"}.svg`).size(11).flex_none());
  }

  uptimeView(t) {
    const d = this.uptime;
    const { ms, up, down, pending, maint } = this.upStats();
    const age = Date.now() - this.uptimeAt;
    const stale = d && (age > STALE_MS || d.status !== "ready");
    const byId = new Map((d?.monitors ?? []).map((m) => [String(m.id), m]));
    const alarms = ms.filter((m) => m.status === 0 || m.status === 2).sort((a, b) => a.status - b.status || a.name.localeCompare(b.name));
    const buckets = new Map();
    for (const m of ms) {
      const label = this.upGroup(m, byId) ?? "";
      if (!buckets.has(label)) buckets.set(label, []);
      buckets.get(label).push(m);
    }
    const labels = [...buckets.keys()].sort((a, b) => a.localeCompare(b));
    const parts = [`${up.length} up`, `${down.length} down`];
    if (pending.length) parts.push(`${pending.length} pending`);
    if (maint.length) parts.push(`${maint.length} maintenance`);
    const note = !d ? null
      : d.status === "stale" ? `Argo: stale since ${d.staleSince ?? "?"}`
      : d.status !== "ready" ? `Argo: ${d.status}`
      : age > STALE_MS ? "Argo: no fresh answer" : null;
    return v_flex().flex_1().min_h(0).text_size(13)
      .child(v_flex().flex_none().px(16).pt(8).pb(4).gap(1)
        .child(div().truncate().text_size(11.5).text_color(down.length ? t.foreground : t.dim).child(d ? parts.join(" · ") : "Uptime"))
        .when(Boolean(note), (el) => el.child(div().truncate().text_size(11).text_color(t.dim).child(note))))
      .child(v_flex().flex_1().min_h(0).px(8).pb(14).overflow_y_scrollbar().mode("always")
        .when(Boolean(stale), (el) => el.opacity(0.5))
        .when(!d, (el) => el.child(div().px(8).py(6).text_size(12).text_color(t.dim).child(this.uptimeAt ? "No answer from Argo" : "Loading…")))
        .when(alarms.length > 0, (el) => el
          .child(h_flex().h(20).mt(4).flex_none().px(8).gap(7).items_center().text_size(10.5).font_bold().text_color(t.blocked)
            .child(div().flex_1().child("DOWN")).child(div().flex_none().child(String(alarms.length))))
          .children(alarms.map((m) => this.upRow(t, m, "d", this.upGroup(m, byId)))))
        .children(labels.flatMap((label) => {
          const rows = buckets.get(label).sort((a, b) => a.name.localeCompare(b.name));
          if (!label) return rows.map((m) => this.upRow(t, m, "g", null));
          const hasDown = rows.some((m) => m.status === 0 || m.status === 2);
          const shown = this.upOpen[label] ?? hasDown;
          return [this.upHeader(t, label, rows.length, shown, hasDown), ...(shown ? rows.map((m) => this.upRow(t, m, "g", null)) : [])];
        })))
      .child(this.legendRow(t, "ub", [
        ["up", t.dim, "up", "Up"],
        ["down", t.blocked, "down", "Down"],
        ["pending", t.ansi3, "pending", "Pending: failed, retrying"],
        ["maint", t.accent, "maintenance", "Under maintenance"],
      ]));
  }

}
