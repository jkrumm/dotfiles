// jk-board — the right-hand sidebar, two tabs. Waves (default): the fleet view of the mini's agent work.
// Uptime: an Uptime Kuma overview from Argo's /uptime-kuma/monitors, read on the mini with secrets-run (the
// token never reaches argv), grouped by parent group. jk-status switches it to Uptime through
// shared("jk.board.tab"). Read-only.
// Waves:  Every 30 s one call on the mini reads software-factory's fleet model (`factory fleet`, token only:
// the socket never serves it) and hc's turn counts. The model holds the repos with their plan and sessions
// and everything waiting on the owner; this file collects nothing of its own. Asks sit on top (count in the
// tab badge; the owner's own first, then by time), then the repos that have a live session or a queued spawn
// under the left sidebar's folders (config/herdr-app/groups.json). A plan nobody works with an active wave waits in a collapsed
// "Paused" section, one with only waves ahead in "Planned"; finished plans are hidden. Click a card to
// open it, an ask or a session to jump to its agent.
// Hidden children: a tab row lists the terminals that hang under it (the model's `parent`) as a tree: name,
// state, turn (hc's, one `hc ls` per poll). Click a child for its last lines (`hc read`, on demand).
import { View, div, svg } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { exec, theme, home, machines, shared, setShared, run, terminals } from "herdr";

// The token comes from the factory's own env template through secrets-run, never argv; `factory fleet` exits 3 without one.
const FLEET = `PATH="$HOME/.local/bin:$HOME/.bun/bin:/opt/homebrew/bin:$PATH"; cd ~/SourceRoot/software-factory && secrets-run run --env-file=.env.tpl -- factory fleet --format json`;
const HC_MARK = "@@HC@@";
const HC_SPLIT = `\n${HC_MARK}\n`;
// hc starts a stray core (no keychain) when none runs: ask launchd first, as rd's require_core does. Bounded when the host has a timeout.
const HC_GUARD = `PATH="$HOME/.local/bin:/opt/homebrew/bin:$PATH"; launchctl print "gui/$(id -u)/com.jkrumm.herdr-core" 2>/dev/null | grep -q 'state = running' || exit 1; t=$(command -v timeout || command -v gtimeout)`;
const HC_LS = `${HC_GUARD}; \${t:+"$t"} \${t:+8} hc ls --json`;
const CMD = `{ ${FLEET}; } 2>/dev/null; echo; echo '${HC_MARK}'; ( ${HC_LS} ) 2>/dev/null`;
// A child's last lines: the screen, blank lines dropped. The address is checked (ADDR) before it reaches the shell.
const PEEK_LINES = 8;
const peekCmd = (addr) => `${HC_GUARD}; out=$(\${t:+"$t"} \${t:+8} hc read ${addr} 2>&1) || { echo "(hc read failed)"; exit 1; }; printf '%s\\n' "$out" | grep -v '^[[:space:]]*$' | tail -n ${PEEK_LINES}`;

// Argo's live Kuma snapshot. The token is read on the mini and piped to curl as a header file.
const UPTIME = `PATH="$HOME/.local/bin:/opt/homebrew/bin:$PATH"; t=$(secrets-run read op://common/api/SECRET) && printf 'Authorization: Bearer %s\\n' "$t" | curl -s -m 8 -H @- http://127.0.0.1:7737/api/uptime-kuma/monitors`;
const UPTIME_MS = 30000; // while the Uptime tab shows
const UPTIME_BG_MS = 60000; // otherwise, for the tab badge
const TABS = [["waves", "Waves"], ["uptime", "Uptime"]];

const POLL_MS = 30000;
const STALE_MS = 2 * 60000;
const GROUPS = ".config/herdr-app/groups.json";
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

// <fleet> pure helpers over the fleet model (scripts/jk-board-fleet.test.ts runs this block after the tree block: no imports, no gpui)
const PENDING_SPAWN = new Set(["queued", "waiting", "starting"]);

// Most urgent first. wait=owner means the session needs a person.
const RANK = { needs: 0, working: 1, waiting: 2, idle: 3 };
function sessionKind(s) {
  if (s.state === "blocked" || s.state === "stuck" || s.wait === "owner") return "needs";
  if (s.state === "working" || s.state === "starting") return "working";
  if (s.state === "waiting" || s.state === "walled") return "waiting";
  return "idle";
}

// `factory fleet --format json` -> the model, or null when it is not that (an error body, a cut line, a 503).
function parseFleet(text) {
  try {
    const d = JSON.parse(text);
    if (!d || !Array.isArray(d.repos) || !Array.isArray(d.asks)) return null;
    return { ...d, health: Array.isArray(d.health) ? d.health : [] }; // an older server sends no health: none
  } catch {
    return null;
  }
}

const isYours = (a) => (a.tier ?? "yours") === "yours";
const time = (iso) => Date.parse(iso) || 0;

// The owner's own asks first, then the rest; each group by time, oldest first.
function sortAsks(asks) {
  return [...asks].sort((a, b) => Number(!isYours(a)) - Number(!isYours(b)) || time(a.at) - time(b.at) || String(a.id).localeCompare(String(b.id)));
}

// The Waves tab badge: asks only. A health line never asks for the owner, so it is never counted here.
function askBadge(fleet) {
  const asks = fleet?.asks ?? [];
  return { count: asks.length, urgent: asks.some(isYours) };
}

// Health lines (parks, a silent lead, regressions, machine failures) never ask the owner: oldest first, below the asks.
function sortHealth(lines) {
  return [...lines].sort((a, b) => time(a.since) - time(b.since) || String(a.id).localeCompare(String(b.id)));
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

// The model's repos -> cards, in the shown ones (a live session, a queued spawn, a running plan), the paused ones (an active wave
// nobody works) and the planned ones. A finished plan nobody works is dropped. `hc` is hc's terminal list, for the turn counts only.
// kids / byTerminal feed the child tree: the model's `parent` names the parent session, hc's addresses link them.
function assemble(fleet, hc) {
  const everyone = [...fleet.repos.flatMap((r) => r.sessions ?? []), ...(fleet.unplaced ?? [])];
  const byId = new Map(everyone.map((s) => [s.id, s]));
  const turns = new Map((hc ?? []).map((t) => [t.address, t.turn]));
  const terms = everyone.filter((s) => ADDR.test(String(s.terminal)))
    .map((s) => ({ address: s.terminal, parent: byId.get(s.parent)?.terminal ?? null, name: s.id, turn: turns.get(s.terminal) }));
  const byTerminal = new Map(everyone.filter((s) => s.terminal).map((s) => [s.terminal, { ...s, kind: sessionKind(s) }]));
  const spawns = new Map();
  for (const q of fleet.queue?.spawns ?? []) {
    if (PENDING_SPAWN.has(q.status)) spawns.set(q.space, [...(spawns.get(q.space) ?? []), q]);
  }
  const shown = [], paused = [], planned = [];
  for (const repo of fleet.repos) {
    // Nested only under a parent in the same repo's card; a child of another repo's session keeps its own card too.
    const all = (repo.sessions ?? []).map((s) => ({ ...s, kind: sessionKind(s) }))
      .sort((a, b) => RANK[a.kind] - RANK[b.kind] || a.id.localeCompare(b.id));
    const nested = nestedPanes(all.map((s) => s.terminal).filter(Boolean), terms);
    const waves = repo.plan?.waves ?? [];
    const active = waves.find((w) => w.status === "active") ?? null;
    const r = {
      name: repo.name, plan: repo.plan, waves, active, all,
      focus: active ?? waves.find((w) => w.status === "scheduled") ?? null,
      done: waves.filter((w) => w.status === "done").length,
      sessions: all.filter((s) => !s.terminal || !nested.has(s.terminal)),
      spawns: spawns.get(repo.space) ?? [],
      kind: all[0]?.kind ?? null,
    };
    const state = repo.plan?.state;
    if (all.length || r.spawns.length || state === "running") shown.push(r);
    else if (state === "stale" || (active && state !== "done")) paused.push(r);
    else if (state === "planned" || state === "scheduled") planned.push(r);
  }
  const order = (a, b) => (RANK[a.kind] ?? 4) - (RANK[b.kind] ?? 4) || a.name.localeCompare(b.name);
  const byName = (a, b) => a.name.localeCompare(b.name);
  return { shown: shown.sort(order), paused: paused.sort(byName), planned: planned.sort(byName), kids: childMap(terms), byTerminal, bySession: byId };
}

// The poll's stdout: the fleet JSON, then hc's list behind a marker line. A JSON string cannot hold a raw newline, so no line of the
// fleet part (an ask's text, a session title) can equal the marker line.
function parse(stdout) {
  const cut = stdout.indexOf(HC_SPLIT);
  return { fleet: parseFleet(cut < 0 ? stdout : stdout.slice(0, cut)), hc: cut < 0 ? null : parseHc(stdout.slice(cut + HC_SPLIT.length)) };
}
// </fleet>

// Hover text and the footer legend; the left sidebar's dots use the same colors.
const MEANING = {
  needs: "Needs you: blocked, or waiting on the owner",
  working: "Working",
  waiting: "Waiting on its workers or a deploy",
  idle: "Idle",
};

const shortId = (id, repo) => (id.startsWith(repo) ? id.slice(repo.length).replace(/^-/, "") : id) || id;

export default class Board extends View {
  init(_props, cx) {
    this.fleet = null; // last good fleet model
    this.at = 0; // when it was read
    this.tried = false; // a poll has ended, good or not
    this.polling = false;
    this.hc = null; // hc's terminals, for the turn counts
    this.hcAt = 0; // when hc last answered: turns of an old answer are not shown
    this.peeks = new Map(); // child address -> { lines, at } once opened; absent = closed
    this.byTerminal = new Map(); // terminal address -> fleet session, for the names and states in a tree
    this.bySession = new Map(); // session id -> fleet session, for an ask's jump
    this.kids = new Map(); // parent terminal -> its children
    this.tab = localStorage.getItem("board.tab") === "uptime" ? "uptime" : "waves";
    this.seenTab = null; // last shared("jk.board.tab") adopted
    this.uptime = null; // last good Argo answer
    this.uptimeAt = 0;
    this.uptimeBusy = false;
    this.upOpen = JSON.parse(localStorage.getItem("board.uptime.open") ?? "{}"); // group -> shown?
    this.open = new Set(JSON.parse(localStorage.getItem("waves.open") ?? "[]"));
    this.folded = new Set(JSON.parse(localStorage.getItem("waves.folded") ?? "[]"));
    this.groups = { list: [], fallback: "OTHER" };
    this.loadGroups(cx);
    cx.timer.every(60000, (cx) => this.loadGroups(cx));
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

  loadGroups(cx) {
    cx.spawn(async (cx) => {
      try {
        const r = await exec("cat", [`${home()}/${GROUPS}`]);
        if (r.code !== 0) throw new Error(r.stderr);
        const d = JSON.parse(r.stdout);
        this.groups = { list: (d.groups ?? []).map((g) => ({ label: g.label, members: new Set(g.members ?? []) })), fallback: d.fallback ?? "OTHER" };
      } catch (e) {
        console.log(`jk-board: no folders from ~/${GROUPS}: ${e?.message ?? e}`);
        return;
      }
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
      // hc and the fleet model are separate answers: each keeps its last good one.
      if (next?.fleet) {
        this.fleet = next.fleet;
        this.at = Date.now();
      }
      if (next?.hc) {
        this.hc = next.hc;
        this.hcAt = Date.now();
      }
      for (const addr of this.peeks.keys()) this.readPeek(addr, cx);
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
    const address = s?.terminal ? `mini/${s.terminal}` : null;
    return address && terminals().some((x) => x.address === address) ? address : null;
  }

  // The digest's one line of where a session stands; nothing while the model has none (IuRoot's never do).
  headline(t, s, indent) {
    if (!s.headline) return [];
    return [div().id(`wv-h-${s.id}`).pl(indent).pr(4).truncate().text_size(10.5).text_color(t.dim).tooltip(s.headline).child(s.headline)];
  }

  stateOf(s) {
    return s.wait ? `${s.state} · ${s.wait}` : s.state;
  }

  sessionRow(t, r, s) {
    const address = this.jumpTo(s);
    return h_flex().id(`wv-s-${s.id}`).h(18).flex_none().gap(6).items_center().pl(10).text_size(11).rounded(5)
      .when(Boolean(address), (el) => el.cursor_pointer().hover((st) => st.bg(t.selected)).tooltip("Jump to this agent")
        .on_click((_e, cx) => { cx.stop_propagation(); run("agent.focus", { terminal: address }); }))
      .child(this.dot(t, s.kind, 5))
      .child(div().flex_shrink(0).text_color(t.muted).child(s.role ?? "?"))
      .child(div().flex_1().min_w(0).truncate().text_color(t.foreground).child(shortId(s.id, r.name)))
      .child(div().flex_none().text_color(s.kind === "needs" ? this.tone(t, "needs") : t.dim).child(this.stateOf(s)))
      .when(Boolean(s.account), (el) => el.child(div().flex_none().text_color(t.dim).child(s.account)));
  }

  // A hidden child under its tab row: name, state, turn. The model knows every one of them (its `parent` built the tree).
  childRow(t, { t: c, depth }) {
    const s = this.byTerminal.get(c.address);
    const kind = s ? s.kind : "idle";
    const what = `${s ? this.stateOf(s) : "?"}${c.turn ? ` · t${c.turn}` : ""}`;
    const peek = this.peeks.get(c.address);
    const row = h_flex().id(`wv-c-${c.address}`).h(18).flex_none().gap(6).items_center().pl(10 + 12 * depth).text_size(11).cursor_pointer()
      .hover((e) => e.bg(t.hover))
      .on_mouse_down("left", (_e, cx) => cx.stop_propagation())
      .on_click((_e, cx) => { cx.stop_propagation(); this.togglePeek(c.address, cx); })
      .tooltip("Click for its last lines")
      .child(this.dot(t, kind, 5))
      .when(Boolean(s?.role), (el) => el.child(div().flex_shrink(0).text_color(t.muted).child(s.role)))
      .child(div().flex_1().min_w(0).truncate().text_color(t.muted).child(c.name))
      .child(div().flex_none().text_color(kind === "needs" ? this.tone(t, "needs") : t.dim).child(what));
    const head = s ? this.headline(t, s, 10 + 12 * depth + 11) : [];
    if (!peek) return [row, ...head];
    const lines = peek.lines ?? ["…"];
    return [row, ...head, v_flex().id(`wv-cp-${c.address}`).flex_none().pl(10 + 12 * depth + 11).pr(4).py(2)
      .children(lines.map((l, i) => div().id(`wv-cp-${c.address}-${i}`).truncate().text_size(10.5).text_color(t.dim).child(l)))];
  }

  spawnRow(t, q) {
    return h_flex().id(`wv-q-${q.key}`).h(18).flex_none().gap(6).items_center().pl(10).text_size(11)
      .child(div().flex_shrink(0).text_color(t.dim).child("queued"))
      .child(div().flex_1().min_w(0).truncate().text_color(t.muted).child(q.key))
      .child(div().flex_none().text_color(t.dim).child(String(q.hold ?? q.status)));
  }

  card(t, r) {
    const open = this.open.has(r.name);
    const total = r.waves.length;
    const current = r.active ? r.waves.indexOf(r.active) + 1 : r.done;
    const pending = r.waves.filter((w) => w.status === "pending");
    const title = r.plan ? r.plan.short ?? r.plan.title : null;
    return v_flex().id(`wv-${r.name}`).flex_none().px(8).py(5).gap(2).rounded(8).cursor_pointer()
      .hover((s) => s.bg(t.hover))
      .on_click((_e, cx) => this.toggle(this.open, r.name, "waves.open", cx))
      .child(h_flex().gap(7).items_center()
        .child(this.dot(t, r.kind))
        .child(div().flex_1().min_w(0).truncate().text_color(t.foreground).font_semibold().child(r.name))
        .when(Boolean(r.plan), (el) => el.child(div().flex_none().text_size(11).text_color(t.dim).child(r.plan.state)))
        .when(total > 0, (el) => el.child(div().flex_none().text_size(11).text_color(t.muted).child(`Wave ${current}/${total}`)))
        .when(total === 0 && r.all.length > 0, (el) => el.child(div().flex_none().text_size(11).text_color(t.dim).child(`${r.all.length} sessions`))))
      .when(Boolean(title), (el) => el.child(div().pl(14).truncate().text_size(11).text_color(t.dim).child(title)))
      .when(total > 0, (el) => el.child(div().ml(14).h(3).rounded(2).bg(t.hover).overflow_hidden()
        .child(div().h(3).rounded(2).bg(t.muted).w(`${Math.round((r.done / total) * 100)}%`))))
      .when(Boolean(r.focus), (el) => el.child(h_flex().pl(14).gap(6).text_size(11)
        .child(div().flex_1().min_w(0).truncate().text_color(t.muted).child(`${r.focus.n} · ${r.focus.short ?? r.focus.title}`))
        .child(div().flex_none().text_color(t.dim).child(r.focus.statusDate ? `${r.focus.status} ${r.focus.statusDate}` : r.focus.status))))
      .when(open, (el) => el.child(v_flex().mt(3).gap(1)
        .children(pending.slice(0, 4).map((w) => div().id(`wv-w-${r.name}-${w.n}`).pl(10).truncate().text_size(11).text_color(t.dim).child(`${w.n} · ${w.short ?? w.title}`)))
        .children(r.sessions.flatMap((s) => [this.sessionRow(t, r, s), ...this.headline(t, s, 21),
          ...treeRows(this.kids, s.terminal).flatMap((row) => this.childRow(t, row))]))
        .children(r.spawns.map((q) => this.spawnRow(t, q)))));
  }

  // One ask: the owner's own in the blocked tone, the rest muted. Text, repo (or where it came from), age; the tooltip has the rest.
  askRow(t, a) {
    const yours = isYours(a);
    const address = this.jumpTo(this.bySession.get(a.session));
    const tip = [oneLine(a.text, 600), a.suggestion ? `Suggested: ${a.suggestion.verb} — ${a.suggestion.why} (${a.suggestion.evidence})` : null]
      .filter(Boolean).join("\n\n");
    return h_flex().id(`wv-a-${a.id}`).h(18).flex_none().gap(6).items_center().pl(10).text_size(11).rounded(5).tooltip(tip)
      .when(Boolean(address), (el) => el.cursor_pointer().hover((st) => st.bg(t.selected))
        .on_click((_e, cx) => run("agent.focus", { terminal: address })))
      .child(this.dot(t, yours ? "needs" : "idle", 5, false))
      .child(div().flex_1().min_w(0).truncate().text_color(yours ? t.foreground : t.muted).child(oneLine(a.short ?? a.text)))
      .child(div().flex_shrink(0).max_w(76).truncate().text_color(t.dim).child(a.repo ? base(a.repo) : a.source))
      .child(div().w(26).flex_none().text_right().text_color(t.dim).child(age(a.at)));
  }

  asks(t, asks) {
    if (!asks.length) return [];
    const folded = this.folded.has("asks");
    const urgent = asks.some(isYours) ? "needs" : null;
    return [this.header(t, "asks", "ASKS", asks.length, folded, urgent), ...(folded ? [] : asks.map((a) => this.askRow(t, a)))];
  }

  // One health line, dimmer than an ask and with no urgency dot: text, repo (else its kind), age; a click jumps to its session when it has one.
  healthRow(t, h) {
    const address = this.jumpTo(this.bySession.get(h.session));
    return h_flex().id(`wv-hl-${h.id}`).h(18).flex_none().gap(6).items_center().pl(10).text_size(11).rounded(5).tooltip(oneLine(h.text, 600))
      .when(Boolean(address), (el) => el.cursor_pointer().hover((st) => st.bg(t.selected))
        .on_click((_e, cx) => run("agent.focus", { terminal: address })))
      .child(this.dot(t, "idle", 5, false))
      .child(div().flex_1().min_w(0).truncate().text_color(t.dim).child(oneLine(h.text)))
      .child(div().flex_shrink(0).max_w(76).truncate().text_color(t.dim).child(h.repo ? base(h.repo) : h.kind))
      .child(div().w(26).flex_none().text_right().text_color(t.dim).child(age(h.since)));
  }

  health(t, lines) {
    if (!lines.length) return [];
    const folded = this.folded.has("health");
    return [this.header(t, "health", "HEALTH", lines.length, folded, null), ...(folded ? [] : lines.map((h) => this.healthRow(t, h)))];
  }

  header(t, id, label, count, folded, urgent) {
    return h_flex().id(id).h(20).mt(4).flex_none().px(8).gap(7).items_center().rounded(6)
      .text_size(10.5).font_bold().text_color(t.dim).cursor_pointer().hover((s) => s.bg(t.hover))
      .on_click((_e, cx) => this.toggle(this.folded, id, "waves.folded", cx))
      .child(div().flex_1().truncate().child(label))
      .when(folded && urgent, (el) => el.child(div().flex_none().text_color(this.tone(t, urgent)).child("●")))
      .child(div().flex_none().child(String(count)))
      .child(svg(`mods/workspace-chrome/chevron-${folded ? "right" : "down"}.svg`).size(11).flex_none());
  }

  folders(t, repos) {
    const buckets = new Map();
    for (const r of repos) {
      const g = this.groups.list.find((x) => x.members.has(r.name));
      const label = g?.label ?? this.groups.fallback;
      if (!buckets.has(label)) buckets.set(label, []);
      buckets.get(label).push(r);
    }
    const order = [...this.groups.list.map((g) => g.label), this.groups.fallback];
    return order.filter((l) => buckets.has(l)).flatMap((label) => {
      const rows = buckets.get(label);
      const id = `f/${label}`;
      const folded = this.folded.has(id);
      const urgent = rows.map((r) => r.kind).filter(Boolean).sort((a, b) => RANK[a] - RANK[b])[0];
      return [this.header(t, id, label, rows.length, folded, urgent === "needs" || urgent === "working" ? urgent : null),
        ...(folded ? [] : rows.map((r) => this.card(t, r)))];
    });
  }

  summary(fleet) {
    const n = fleet.summary;
    const queued = (fleet.queue?.spawns ?? []).filter((q) => PENDING_SPAWN.has(q.status)).length;
    const parts = n ? [`${n.working ?? 0} working`, `${(n.working ?? 0) + (n.idle ?? 0) + (n.done ?? 0)} live`] : ["no summary"];
    if (queued) parts.push(`${queued} queued`);
    if (fleet.queue?.effective) parts.push(`queue: ${fleet.queue.effective}`);
    return parts.join(" · ");
  }

  // Honor a switch another mod asked for (jk-status' Kuma counter) once per change.
  adoptTab() {
    const want = shared("jk.board.tab");
    if (want === this.seenTab) return;
    this.seenTab = want;
    if (want === "waves" || want === "uptime") this.setTab(want, null);
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
    const { count, urgent } = askBadge(this.fleet);
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
            .when(id === "waves" && count > 0, (el) => el.child(div().text_color(urgent ? t.blocked : t.dim).child(String(count))));
        })));
  }

  render() {
    this.adoptTab();
    const t = theme();
    return v_flex().size_full().min_h(0).bg(t.chrome)
      .child(this.tabs(t))
      .child(this.tab === "uptime" ? this.uptimeView(t) : this.wavesView(t));
  }

  wavesView(t) {
    const fleet = this.fleet;
    // Stale after STALE_MS without a good poll, or when the factory's own snapshot is that old.
    const since = fleet ? Math.max(Date.now() - this.at, Date.now() - (Date.parse(fleet.builtAt) || this.at)) : 0;
    const stale = fleet && since > STALE_MS;
    const fresh = this.hcAt && Date.now() - this.hcAt <= STALE_MS;
    const { shown, paused, planned, kids, byTerminal, bySession } = fleet
      ? assemble(fleet, fresh ? this.hc : [])
      : { shown: [], paused: [], planned: [], kids: new Map(), byTerminal: new Map(), bySession: new Map() };
    this.kids = kids;
    this.byTerminal = byTerminal;
    this.bySession = bySession;
    const asks = fleet ? sortAsks(fleet.asks) : [];
    const health = fleet ? sortHealth(fleet.health ?? []) : [];
    const errors = fleet?.errors ?? [];
    const note = errors.length ? `fleet: ${oneLine(errors[0], 90)}${errors.length > 1 ? ` (+${errors.length - 1})` : ""}` : null;
    return v_flex().flex_1().min_h(0).text_size(13)
      .child(v_flex().flex_none().px(16).pt(8).pb(4).gap(1)
        .child(div().text_size(11.5).text_color(t.dim).child("Waves"))
        .when(Boolean(fleet), (el) => el.child(div().truncate().text_size(11).text_color(t.dim).child(this.summary(fleet))))
        .when(Boolean(note), (el) => el.child(div().truncate().text_size(11).text_color(t.dim).tooltip(errors.map((e) => oneLine(e, 300)).join("\n")).child(note))))
      .child(v_flex().flex_1().min_h(0).px(8).pb(14).overflow_y_scrollbar().mode("always")
        .when(Boolean(stale), (el) => el.opacity(0.5))
        .when(!fleet, (el) => el.child(div().px(8).py(6).text_size(12).text_color(t.dim).child(this.tried ? "No answer from the factory" : "Loading…")))
        .when(Boolean(fleet) && !shown.length, (el) => el.child(div().px(8).py(6).text_size(12).text_color(t.dim).child("No waves running")))
        .children(this.asks(t, asks))
        .children(this.health(t, health))
        .children(this.folders(t, shown))
        .children(this.parked(t, "PAUSED", paused))
        .children(this.parked(t, "PLANNED", planned)))
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

  // A section folded by default: open only once clicked.
  parked(t, label, repos) {
    if (!repos.length) return [];
    const id = `open:f/${label}`;
    const folded = !this.folded.has(id);
    return [this.header(t, id, label, repos.length, folded, null), ...(folded ? [] : repos.map((r) => this.card(t, r)))];
  }
}
