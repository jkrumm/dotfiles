// jk-board — the right-hand sidebar, two tabs. Waves (default): ongoing wave work across the
// mini's repos. Uptime: an Uptime Kuma overview from Argo's /uptime-kuma/monitors, read on the
// mini with secrets-run (the token never reaches argv), grouped by parent group. jk-status
// switches it to Uptime through shared("jk.board.tab"). Read-only.
// Waves:  Every 30 s one call on the mini reads software-factory's `status` (sessions
// and spawn queue) and every repo's docs/waves/PLAN.md headings. A repo shows while a
// live session runs in it or a spawn is queued; an active plan nobody works on waits in a
// collapsed "Paused" section, one with only pending waves in "Planned", finished plans are hidden. Repos sit under
// the left sidebar's folders (config/herdr/groups.json). Click a card to open it.
import { View, div, svg } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { exec, theme, home, machines, shared, setShared } from "herdr";

const FACTORY = `PATH="$HOME/.local/bin:$HOME/.bun/bin:/opt/homebrew/bin:$PATH"; cd ~/SourceRoot/software-factory && secrets-run run --env-file=.env.tpl -- factory --format json status`;
const PLANS = `for f in ~/SourceRoot/*/docs/waves/PLAN.md ~/IuRoot/*/docs/waves/PLAN.md; do [ -f "$f" ] && { echo "== $f"; grep -E '^# |^## Wave'; } < "$f"; done`;
const MARK = "@@PLANS@@";
const CMD = `{ ${FACTORY}; } 2>/dev/null; echo; echo '${MARK}'; { ${PLANS}; } 2>/dev/null`;

// Argo's live Kuma snapshot. The token is read on the mini and piped to curl as a header file.
const UPTIME = `PATH="$HOME/.local/bin:/opt/homebrew/bin:$PATH"; t=$(secrets-run read op://common/api/SECRET) && printf 'Authorization: Bearer %s\\n' "$t" | curl -s -m 8 -H @- http://127.0.0.1:7737/api/uptime-kuma/monitors`;
const UPTIME_MS = 30000; // while the Uptime tab shows
const UPTIME_BG_MS = 60000; // otherwise, for the tab badge
const TABS = [["waves", "Waves"], ["uptime", "Uptime"]];

const POLL_MS = 30000;
const STALE_MS = 2 * 60000;
const GROUPS = ".config/herdr-app/groups.json";
const base = (path) => path.replace(/\/+$/, "").split("/").pop();

// The repo a path or a session id belongs to: the folder under SourceRoot/IuRoot, else the
// id's prefix before its wave suffix ("dotfiles-w1" -> "dotfiles").
function repoOf(cwd, id) {
  const m = /\/(?:SourceRoot|IuRoot)\/([^/]+)/.exec(cwd ?? "");
  if (m) return m[1];
  return String(id ?? "").replace(/-[wf]\d.*$/, "") || null;
}

function parsePlans(text) {
  const plans = {};
  let repo = null;
  for (const line of text.split("\n")) {
    const file = /^== .*\/(?:SourceRoot|IuRoot)\/([^/]+)\/docs\/waves\/PLAN\.md/.exec(line);
    if (file) { repo = file[1]; plans[repo] = { title: null, waves: [] }; continue; }
    if (!repo) continue;
    const plan = plans[repo];
    const wave = /^## Wave\s+(\d+)\s*[—–-]\s*(.*?)\s*(?:<!--\s*status:\s*(\w+)\s*-->)?\s*$/.exec(line);
    if (wave) plan.waves.push({ n: Number(wave[1]), name: wave[2], status: wave[3] ?? "pending" });
    else if (line.startsWith("# ") && plan.title === null) plan.title = line.slice(2).trim();
  }
  return plans;
}

function parse(stdout) {
  const [head, tail = ""] = stdout.split(MARK);
  let factory = null;
  try {
    const f = JSON.parse(head);
    if (f && Array.isArray(f.sessions)) factory = f;
  } catch {}
  return { factory, plans: parsePlans(tail) };
}

// Most urgent first. wait=owner means the session needs a person.
const RANK = { needs: 0, working: 1, waiting: 2, idle: 3 };
function sessionKind(s) {
  if (s.state === "blocked" || s.wait === "owner") return "needs";
  if (s.state === "working") return "working";
  if (s.state === "waiting") return "waiting";
  return "idle";
}

// repo -> { plan, sessions, spawns }, then the shown ones and the planned ones.
function assemble(data) {
  const repos = {};
  const get = (name) => (repos[name] ??= { name, plan: null, sessions: [], spawns: [] });
  for (const [name, plan] of Object.entries(data.plans)) get(name).plan = plan;
  for (const s of data.factory?.sessions ?? []) {
    if (s.state === "dead") continue;
    const name = repoOf(s.cwd, s.id);
    if (name) get(name).sessions.push({ ...s, kind: sessionKind(s) });
  }
  const spawns = data.factory?.queue?.spawns ?? [];
  for (const q of Array.isArray(spawns) ? spawns : []) {
    const name = repoOf(q.cwd ?? q.repo, q.id ?? q.spawn ?? q.name);
    if (name) get(name).spawns.push(q);
  }
  const shown = [], paused = [], planned = [];
  for (const r of Object.values(repos)) {
    const waves = r.plan?.waves ?? [];
    r.active = waves.find((w) => w.status === "active") ?? null;
    r.done = waves.filter((w) => w.status === "done").length;
    r.sessions.sort((a, b) => RANK[a.kind] - RANK[b.kind] || a.id.localeCompare(b.id));
    r.kind = r.sessions[0]?.kind ?? null;
    if (r.sessions.length || r.spawns.length) shown.push(r);
    else if (r.active) paused.push(r);
    else if (waves.some((w) => w.status === "pending")) planned.push(r);
  }
  const order = (a, b) => (RANK[a.kind] ?? 4) - (RANK[b.kind] ?? 4) || a.name.localeCompare(b.name);
  const byName = (a, b) => a.name.localeCompare(b.name);
  return { shown: shown.sort(order), paused: paused.sort(byName), planned: planned.sort(byName) };
}

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
    this.data = null; // last good parse
    this.at = 0; // when it was read
    this.polling = false;
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
      const next = r?.stdout ? parse(r.stdout) : null;
      // Keep the last good data; a missing factory answer keeps the old sessions.
      if (next?.factory || (next && Object.keys(next.plans).length)) {
        this.data = { factory: next.factory ?? this.data?.factory ?? null, plans: next.plans };
        if (next.factory) this.at = Date.now();
      }
      cx.notify();
    });
  }

  toggle(set, key, store, cx) {
    set.has(key) ? set.delete(key) : set.add(key);
    localStorage.setItem(store, JSON.stringify([...set]));
    cx.notify();
  }

  tone(t, kind) {
    return { needs: t.blocked, working: t.working, waiting: t.working, idle: t.dim }[kind] ?? t.dim;
  }

  dot(t, kind, size = 7) {
    // Filled for needs you / working, a ring for waiting (amber: busy through its workers) and idle.
    const live = kind === "needs" || kind === "working";
    return div().size(size).flex_none().rounded(size / 2).when(Boolean(MEANING[kind]), (d) => d.tooltip(MEANING[kind]))
      .when(live, (d) => d.bg(this.tone(t, kind)))
      .when(!live, (d) => d.border_1().border_color(this.tone(t, kind)));
  }

  sessionRow(t, r, s) {
    const what = s.wait ? `${s.state} · ${s.wait}` : s.state;
    return h_flex().id(`wv-s-${s.id}`).h(18).flex_none().gap(6).items_center().pl(10).text_size(11)
      .child(this.dot(t, s.kind, 5))
      .child(div().flex_shrink(0).text_color(t.muted).child(s.role ?? "?"))
      .child(div().flex_1().min_w(0).truncate().text_color(t.foreground).child(shortId(s.id, r.name)))
      .child(div().flex_none().text_color(s.kind === "needs" ? this.tone(t, "needs") : t.dim).child(what))
      .when(Boolean(s.account), (el) => el.child(div().flex_none().text_color(t.dim).child(s.account)));
  }

  spawnRow(t, q) {
    const id = q.id ?? q.spawn ?? q.name ?? "spawn";
    const why = q.hold ?? q.status ?? "queued";
    return h_flex().id(`wv-q-${id}`).h(18).flex_none().gap(6).items_center().pl(10).text_size(11)
      .child(div().flex_shrink(0).text_color(t.dim).child("queued"))
      .child(div().flex_1().min_w(0).truncate().text_color(t.muted).child(id))
      .child(div().flex_none().text_color(t.dim).child(String(why)));
  }

  card(t, r) {
    const open = this.open.has(r.name);
    const waves = r.plan?.waves ?? [];
    const total = waves.length;
    const current = r.active ? waves.indexOf(r.active) + 1 : r.done;
    const pending = waves.filter((w) => w.status === "pending");
    return v_flex().id(`wv-${r.name}`).flex_none().px(8).py(5).gap(2).rounded(8).cursor_pointer()
      .hover((s) => s.bg(t.hover))
      .on_click((_e, cx) => this.toggle(this.open, r.name, "waves.open", cx))
      .child(h_flex().gap(7).items_center()
        .child(this.dot(t, r.kind))
        .child(div().flex_1().min_w(0).truncate().text_color(t.foreground).font_semibold().child(r.name))
        .when(total > 0, (el) => el.child(div().flex_none().text_size(11).text_color(t.muted).child(`Wave ${current}/${total}`)))
        .when(total === 0 && r.sessions.length > 0, (el) => el.child(div().flex_none().text_size(11).text_color(t.dim).child(`${r.sessions.length} sessions`))))
      .when(Boolean(r.plan?.title), (el) => el.child(div().pl(14).truncate().text_size(11).text_color(t.dim).child(r.plan.title)))
      .when(total > 0, (el) => el.child(div().ml(14).h(3).rounded(2).bg(t.hover).overflow_hidden()
        .child(div().h(3).rounded(2).bg(t.accent).w(`${Math.round((r.done / total) * 100)}%`))))
      .when(Boolean(r.active), (el) => el.child(div().pl(14).truncate().text_size(11).text_color(t.muted).child(r.active.name)))
      .when(open, (el) => el.child(v_flex().mt(3).gap(1)
        .children(pending.slice(0, 4).map((w) => div().id(`wv-w-${r.name}-${w.n}`).pl(10).truncate().text_size(11).text_color(t.dim).child(`${w.n} · ${w.name}`)))
        .children(r.sessions.map((s) => this.sessionRow(t, r, s)))
        .children(r.spawns.map((q) => this.spawnRow(t, q)))));
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

  summary(sessions, queue) {
    const live = sessions.filter((s) => s.state !== "dead");
    const running = live.filter((s) => s.state === "working").length;
    const parts = [`${running} running`, `${live.length} live`];
    if (queue?.spawns?.length) parts.push(`${queue.spawns.length} queued`);
    if (queue?.effective) parts.push(`queue: ${queue.effective}`);
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
            .when(id === "uptime" && down > 0, (el) => el.child(div().text_color(t.blocked).child(String(down))));
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
    const stale = this.at && Date.now() - this.at > STALE_MS;
    const factory = this.data?.factory;
    const { shown, paused, planned } = this.data ? assemble(this.data) : { shown: [], paused: [], planned: [] };
    const attention = factory?.attention?.length ?? 0;
    return v_flex().flex_1().min_h(0).text_size(13)
      .child(v_flex().flex_none().px(16).pt(8).pb(4).gap(1)
        .child(h_flex().items_center().gap(8).text_size(11.5).text_color(t.dim)
          .child(div().flex_1().child("Waves"))
          .when(attention > 0, (el) => el.child(div().flex_none().text_color(t.ansi3).child(`${attention} need you`))))
        .when(Boolean(factory), (el) => el.child(div().truncate().text_size(11).text_color(t.dim).child(this.summary(factory.sessions, factory.queue)))))
      .child(v_flex().flex_1().min_h(0).px(8).pb(14).overflow_y_scrollbar().mode("always")
        .when(Boolean(stale), (el) => el.opacity(0.5))
        .when(!this.data, (el) => el.child(div().px(8).py(6).text_size(12).text_color(t.dim).child("Loading…")))
        .when(Boolean(this.data) && !shown.length, (el) => el.child(div().px(8).py(6).text_size(12).text_color(t.dim).child("No waves running")))
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
      ["done", t.done, "done", "Finished, not looked at yet (left sidebar)"],
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
