// jk-waves — the right-hand sidebar: ongoing wave work across the mini's repos.
// Read-only. Every 30 s one call on the mini reads software-factory's `status` (sessions
// and spawn queue) and every repo's docs/waves/PLAN.md headings. A repo shows while a
// live session runs in it or a spawn is queued; an active plan nobody works on waits in a
// collapsed "Paused" section, one with only pending waves in "Planned", finished plans are hidden. Repos sit under
// the left sidebar's folders (config/herdr/groups.json). Click a card to open it.
import { View, div, svg } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { exec, theme, home, machines } from "herdr";

const FACTORY = `PATH="$HOME/.local/bin:$HOME/.bun/bin:/opt/homebrew/bin:$PATH"; cd ~/SourceRoot/software-factory && secrets-run run --env-file=.env.tpl -- factory --format json status`;
const PLANS = `for f in ~/SourceRoot/*/docs/waves/PLAN.md ~/IuRoot/*/docs/waves/PLAN.md; do [ -f "$f" ] && { echo "== $f"; grep -E '^# |^## Wave'; } < "$f"; done`;
const MARK = "@@PLANS@@";
const CMD = `{ ${FACTORY}; } 2>/dev/null; echo; echo '${MARK}'; { ${PLANS}; } 2>/dev/null`;

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

const shortId = (id, repo) => (id.startsWith(repo) ? id.slice(repo.length).replace(/^-/, "") : id) || id;

export default class Waves extends View {
  init(_props, cx) {
    this.data = null; // last good parse
    this.at = 0; // when it was read
    this.polling = false;
    this.open = new Set(JSON.parse(localStorage.getItem("waves.open") ?? "[]"));
    this.folded = new Set(JSON.parse(localStorage.getItem("waves.folded") ?? "[]"));
    this.groups = { list: [], fallback: "OTHER" };
    this.loadGroups(cx);
    cx.timer.every(60000, (cx) => this.loadGroups(cx));
    this.refresh(cx);
    cx.timer.every(POLL_MS, (cx) => this.refresh(cx));
  }

  loadGroups(cx) {
    cx.spawn(async (cx) => {
      try {
        const r = await exec("cat", [`${home()}/${GROUPS}`]);
        if (r.code !== 0) throw new Error(r.stderr);
        const d = JSON.parse(r.stdout);
        this.groups = { list: (d.groups ?? []).map((g) => ({ label: g.label, members: new Set(g.members ?? []) })), fallback: d.fallback ?? "OTHER" };
      } catch (e) {
        console.log(`jk-waves: no folders from ~/${GROUPS}: ${e?.message ?? e}`);
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
    return { needs: t.blocked, working: t.working, waiting: t.accent, idle: t.dim }[kind] ?? t.dim;
  }

  dot(t, kind, size = 7) {
    const live = kind && kind !== "idle";
    return div().size(size).flex_none().rounded(size / 2)
      .when(live, (d) => d.bg(this.tone(t, kind)))
      .when(!live, (d) => d.border_1().border_color(t.dim));
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

  render() {
    const t = theme();
    const stale = this.at && Date.now() - this.at > STALE_MS;
    const factory = this.data?.factory;
    const { shown, paused, planned } = this.data ? assemble(this.data) : { shown: [], paused: [], planned: [] };
    const attention = factory?.attention?.length ?? 0;
    return v_flex().size_full().min_h(0).bg(t.chrome).text_size(13)
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
        .children(this.parked(t, "PLANNED", planned)));
  }

  // A section folded by default: open only once clicked.
  parked(t, label, repos) {
    if (!repos.length) return [];
    const id = `open:f/${label}`;
    const folded = !this.folded.has(id);
    return [this.header(t, id, label, repos.length, folded, null), ...(folded ? [] : repos.map((r) => this.card(t, r)))];
  }
}
