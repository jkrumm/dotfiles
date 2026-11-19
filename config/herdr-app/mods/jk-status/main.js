// The status bar: one compact chip (CPU %, RAM %) for this computer and for every connected machine
// (the mini's adds its load as a percent of the factory's admission ceiling), Claude Max usage per
// account, and the palette hint. It shares the
// status row with jk-glance's bar (the factory's items, left of this block, with the
// "needs you" count): what does not fit its width is dropped, least important first (`fit`).
// Click a machine or the usage for jk-details (history, top processes, quota resets).
import { View, div, svg } from "gpui-kit";
import { h_flex } from "gpui-base";
import { theme, run, window, exec, hc, shared, setShared, openOverlay } from "herdr";

// macOS: "<cpu %> <used GiB> <total GiB>", one decimal each. Used = active + wired +
// compressed, the figure Activity Monitor calls memory used; the file cache is left out.
const STATS = `export LC_ALL=C
cpu=$(ps -A -o %cpu= | awk -v n="$(sysctl -n hw.ncpu)" '{s+=$1} END{printf "%.1f", s/n}')
used=$(vm_stat | awk '/page size of/{ps=$8} /Pages active/{a=$3} /Pages wired/{w=$4} /occupied by compressor/{c=$5} END{printf "%.1f", (a+w+c)*ps/1073741824}')
echo "$cpu $used $(sysctl -n hw.memsize | awk '{printf "%.0f", $1/1073741824}')"`;

// claude-account reads only its local quota cache (the MacBook's includes the mini's
// samples, imported as source "peer"): no API call, ~20 ms. docs/claude-accounts.md.
const USAGE = 'PATH="$HOME/.local/bin:$HOME/.bun/bin:/opt/homebrew/bin:$PATH" claude-account usage --json';

// The same accounts' mode and forecast (`status --json` is the whole read model; only `mode` and `forecast` are used
// here, merged into the usage rows by id). A failed read leaves the rows without them: no marks, nothing else changes.
const STATUS = 'PATH="$HOME/.local/bin:$HOME/.bun/bin:/opt/homebrew/bin:$PATH" claude-account status --json';

// Login, quota and pending-ask health of this machine and its peer, each problem with its
// fix command: claude-account's own verdict (docs/claude-accounts.md), the one source the
// statusline-adjacent tools share. ~1 s (it asks the peer through its herdr-core).
const HEALTH = 'PATH="$HOME/.local/bin:$HOME/.bun/bin:/opt/homebrew/bin:$PATH" claude-account health --json';
const HEALTH_MS = 5 * 60000;
// A Re-login started from jk-details (shared "jk.relogin" = { at, key }): look again once a minute, from 60 s after
// it started until its row is gone or 15 min have passed, so the ⚠ chip clears when the login lands instead of up to
// 5 min later. Cheap to tick every 15 s: it only reads shared state until a poll is due.
const RELOGIN_TICK_MS = 15000;
const RELOGIN_POLL_MS = 60000;
const RELOGIN_WATCH_MS = 15 * 60000;
const healthKey = (x) => `${x.id}/${x.machine}/${x.check}`;

// Uptime Kuma through Argo's live snapshot, read on the mini (the token is piped to curl, never
// in argv). Groups and paused monitors don't count.
const KUMA = `PATH="$HOME/.local/bin:/opt/homebrew/bin:$PATH"; t=$(secrets-run read op://common/api/SECRET) && printf 'Authorization: Bearer %s\\n' "$t" | curl -s -m 8 -H @- http://127.0.0.1:7737/api/uptime-kuma/monitors`;
const KUMA_MS = 60000;

// The pool: plan-weighted 7-day use across accounts, the statusline's ∑ (scripts/statusline.sh):
// weight = the plan's multiple (ultra = 20, max = 5; legacy max20x / max5x read the same), all 1 when one is unknown; a window that has
// already reset counts as 0. Null below two accounts.
const planMult = (plan) => {
  const p = String(plan ?? "").toLowerCase();
  if (p === "ultra") return 20;
  if (p === "max") return 5;
  return Number(/(\d+)x/.exec(p)?.[1]) || null;
};

export function pool(accounts, now = Date.now() / 1000) {
  if (accounts.length < 2) return null;
  const acc = accounts.map((a) => ({
    wk: a.seven_day == null ? null : (a.seven_day_resets_at ?? Infinity) < now ? 0 : a.seven_day,
    mult: planMult(a.plan),
  }));
  const weighted = acc.every((a) => a.mult);
  const known = acc.filter((a) => a.wk != null).map((a) => ({ ...a, w: weighted ? a.mult : 1 }));
  if (!known.length) return null;
  return Math.round(known.reduce((s, a) => s + a.w * a.wk, 0) / known.reduce((s, a) => s + a.w, 0));
}

// An account's mode as one mark beside its numbers, from `claude-account status --json` (docs/claude-accounts.md
// §Displays; the one definition of modes and forecasts is claude-account's, this only maps them to glyphs): drain ↓,
// reserve ◆, paused ‖; normal, an override past its end and any other kind show none. Same map as scripts/statusline.sh
// and the heartbeat's quota row.
const MODE_MARK = { drain: "↓", reserve: "◆", paused: "‖" };
export const modeMark = (a) => (a?.mode && !a.mode.expired ? (MODE_MARK[a.mode.kind] ?? "") : "");

// The forecast in words, only for an account that will not be full at its reset (status: no `full_at`, some of the week
// unused). Null otherwise, or when status gave no forecast.
export function forecastWords(a) {
  const f = a?.forecast;
  if (!f || f.full_at != null || !(f.waste_percent > 0) || f.weekly_at_reset == null) return null;
  return `ends the week at ${Math.round(f.weekly_at_reset)}%, ${Math.round(f.waste_percent)}% unused at reset`;
}

// usage rows + status rows -> usage rows carrying `mode` and `forecast` (unchanged where status has no row).
export function withStatus(rows, status) {
  const byId = new Map((status ?? []).map((s) => [s.id, s]));
  return rows.map((a) => (byId.has(a.id) ? { ...a, mode: byId.get(a.id).mode, forecast: byId.get(a.id).forecast } : a));
}

const STATS_MS = 5000;
const USAGE_MS = 60000;
const HISTORY = 180; // samples per machine: 15 min at STATS_MS
const STALE_S = 3 * 3600;

const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

// Room each item takes at the bar's 11.8 px text, gap included, rounded up. The machine chips are fixed-width cells
// (icon 13, 28 per figure, 5 between, 6 padding each side, 10 bar gap): 104 without the load figure, 144 with it. The
// quota is ~6 px a character: icon 12 + 8 gaps + "iu 46 me 2/75 me2 29/45 ∑56" is ~200 for three accounts, 220 kept.
// Before (measured 2026-11-16 on the MacBook): MacBook chip 144, mini chip 135, quota 236, branch 56, Kuma 60.
// A drop costs nothing, an overlap does.
const ROOM = { local: 104, usage: 220, kuma: 80, logins: 140, remote: 144, palette: 110 };
const BAR_PAD = 24;

// The items that fit `width`, in the order they matter (a missing width, before the first measurement, is everything).
// `want` is the set of items that exist now; `remotes` how many machines are connected.
export function fit(width, want, remotes = 0) {
  const order = ["local", "usage", "kuma", "logins", ...Array.from({ length: remotes }, (_, i) => `remote${i}`), "palette"];
  const shown = new Set();
  let left = (width ?? Infinity) - BAR_PAD;
  for (const key of order) {
    const kind = key.startsWith("remote") ? "remote" : key;
    if (kind !== "remote" && !want.has(key)) continue;
    if (ROOM[kind] > left) break;
    left -= ROOM[kind];
    shown.add(key);
  }
  return shown;
}

// One popup spec, duplicated in jk-details (mods can't import each other; keep in step): frameless (the card draws
// its own frame, so the measured card is the popup), bottom edge 10 px above the anchor.
function popupSpec(props, height) {
  const { anchor, width } = props;
  return { mod: "jk-details", kind: "popup", frame: "none", width, height,
    at: { x: Math.max(8, Math.round(anchor.x - width / 2)), y: Math.max(8, Math.round(anchor.y - height - 10)) },
    props: { ...props, height } };
}
// Whole numbers in fixed-width cells: the bar doesn't jump when a value crosses 10.
const pct = (v) => `${Math.round(v)}%`;

export default class JkStatus extends View {
  init(_props, cx) {
    this.stats = {}; // machine ("" = this computer) -> { cpu, used, total } | null
    this.history = {}; // machine -> [{ t, cpu, mem }] (mem in %), newest last
    this.remotes = [];
    this.pending = new Set(); // machines whose stats call is still out
    this.usage = [];
    this.issues = []; // health rows that are not ok
    this.kuma = null; // { up, down: [names] } | null
    cx.timer.every(KUMA_MS, (cx) => this.refreshKuma(cx));
    this.refreshKuma(cx);
    cx.timer.every(HEALTH_MS, (cx) => this.refreshHealth(cx));
    cx.timer.every(RELOGIN_TICK_MS, (cx) => this.reloginTick(cx));
    cx.timer.every(STATS_MS, (cx) => this.refreshStats(cx));
    cx.timer.every(USAGE_MS, (cx) => this.refreshUsage(cx));
    this.refreshStats(cx);
    this.refreshUsage(cx);
    this.refreshHealth(cx);
  }

  reloginTick(cx) {
    const w = shared("jk.relogin");
    if (!w?.at) return;
    const age = Date.now() - w.at;
    if (age > RELOGIN_WATCH_MS) { setShared("jk.relogin", null); cx.notify(); return; }
    if (age < RELOGIN_POLL_MS || Date.now() - (this.reloginPolled ?? 0) < RELOGIN_POLL_MS) return;
    this.reloginPolled = Date.now();
    this.refreshHealth(cx);
  }

  refreshHealth(cx) {
    cx.spawn(async (cx) => {
      const r = await exec("sh", ["-c", HEALTH]).catch(() => null);
      let rows;
      try { rows = JSON.parse(r?.stdout ?? "").rows ?? []; } catch { return; }
      const next = rows.filter((x) => x.state !== "ok");
      setShared("jk.health", next);
      const w = shared("jk.relogin");
      if (w?.key && !next.some((x) => healthKey(x) === w.key)) setShared("jk.relogin", null); // fixed: stop watching
      if (same(next, this.issues)) return;
      this.issues = next;
      cx.notify();
    });
  }

  refreshStats(cx) {
    cx.spawn(async (cx) => {
      let changed = false;
      try {
        const r = await hc(["machine", "ls", "--json"]);
        const remotes = (JSON.parse(r.stdout).machines ?? []).filter((m) => !m.temporary && m.state === "connected").map((m) => m.name).sort();
        if (!same(remotes, this.remotes)) { this.remotes = remotes; changed = true; }
      } catch {}
      // In parallel, and a machine still answering the last poll is skipped: a
      // remote that hangs (exec's 30 s limit) must not stall the others.
      await Promise.all([null, ...this.remotes].filter((m) => !this.pending.has(m ?? "")).map(async (machine) => {
        const key = machine ?? "";
        this.pending.add(key);
        const r = await exec("sh", ["-c", STATS], { on: machine }).catch(() => null);
        this.pending.delete(key);
        const [cpu, used, total] = (r?.stdout ?? "").trim().split(" ").map(Number);
        const next = Number.isFinite(total) && total > 0 ? { cpu, used, total } : null;
        if (next) this.history[key] = [...(this.history[key] ?? []), { t: Date.now(), cpu, mem: (used / total) * 100, used, total }].slice(-HISTORY);
        if (!same(this.stats[key], next)) { this.stats[key] = next; changed = true; }
      }));
      setShared("jk.history", this.history);
      if (changed) cx.notify();
    });
  }

  refreshKuma(cx) {
    cx.spawn(async (cx) => {
      const r = await exec("sh", ["-c", KUMA], { on: "mini" }).catch(() => null);
      let ms = null;
      try { ms = JSON.parse(r?.stdout ?? "").monitors; } catch {}
      if (!Array.isArray(ms)) return; // keep the last good counter
      const live = ms.filter((m) => m.type !== "group" && m.active);
      const next = { up: live.filter((m) => m.status === 1).length, down: live.filter((m) => m.status === 0).map((m) => m.name).sort() };
      if (same(next, this.kuma)) return;
      this.kuma = next;
      cx.notify();
    });
  }

  refreshUsage(cx) {
    cx.spawn(async (cx) => {
      const [r, s] = await Promise.all([exec("sh", ["-c", USAGE]).catch(() => null), exec("sh", ["-c", STATUS]).catch(() => null)]);
      let next = [];
      try { next = (JSON.parse(r?.stdout ?? "").accounts ?? []).filter((a) => a.enabled); } catch {}
      try { next = withStatus(next, JSON.parse(s?.stdout ?? "").accounts); } catch {}
      setShared("jk.usage", { at: Date.now(), accounts: next, pool: pool(next) });
      if (same(next, this.usage)) return;
      this.usage = next;
      cx.notify();
    });
  }

  track(key, e) {
    if (e?.bounds) (this.bounds ??= {})[key] = e.bounds;
  }

  // The popup ends 10 px above the clicked field (anchor = its top center). Its height is
  // jk-details' own last measurement for this kind (shared "jk.h.<kind>"); a first open
  // guesses high and jk-details re-places itself once with the measured height.
  details(props, event, key) {
    // The field's bounds (from the click, else the hover record); only trusted when they
    // are bar-sized, since a press can report a child's or an outer element's bounds.
    const b = [event?.bounds, this.bounds?.[key]].find((x) => x && x.height <= 40);
    const p = event?.position;
    const anchor = b ? { x: b.x + b.width / 2, y: b.y } : p ? { x: p.x, y: p.y - 14 } : null;
    if (!anchor) return openOverlay({ mod: "jk-details", kind: "popup", props });
    const width = props.kind === "usage" ? 460 : 400;
    const height = shared(`jk.h.${props.kind}`) ?? 640;
    openOverlay(popupSpec({ ...props, anchor, width }, height));
  }

  // The mini's load as a percent of the factory's admission ceiling, from jk-glance's shared model (null when the
  // factory has no answer, no ceiling is known, or the figure is stale). The tone is the factory's (it folds in swap);
  // the thresholds are the ones it used: amber from 75 % of the ceiling, red at it.
  loadFigure() {
    const g = shared("jk.factory.glance");
    const item = g && !g.empty && !g.stale ? (g.items ?? []).find((i) => i.key === "load") : null;
    const v = /^(\d+)%$/.exec(String(item?.value ?? ""));
    if (!v) return null;
    const n = Number(v[1]);
    return { n, level: item.tone === "bad" || n >= 100 ? 2 : item.tone === "warn" || n >= 75 ? 1 : 0 };
  }

  // One compact chip per machine: icon (the name is the tooltip), CPU %, RAM %, and on the mini the load % of its
  // ceiling. Fixed-width cells, so the bar doesn't jump. Detail (history, GiB, processes) is the click popup.
  machine(t, name, stats) {
    const hot = (v) => (v >= 85 ? t.blocked : t.muted);
    const num = (text, color) => div().w(28).flex_none().text_right().text_color(color).child(text);
    const load = name === "mini" ? this.loadFigure() : null;
    const tip = stats
      ? `${name ?? "MacBook"}: CPU ${pct(stats.cpu)}, RAM ${pct((stats.used / stats.total) * 100)} (${stats.used.toFixed(1)} of ${stats.total} GiB)${load ? `, load ${load.n}% of the admission ceiling` : ""}`
      : `${name ?? "MacBook"}: no reading yet`;
    return h_flex().id(`stats-${name ?? "local"}`).gap(5).items_center().px(6).rounded(5).cursor_pointer().hover((s) => s.bg(t.hover))
      .tooltip(tip)
      .on_mouse_move((e) => this.track(`m-${name ?? ""}`, e))
      .on_mouse_up("left", (e) => this.details({ kind: "machine", machine: name }, e, `m-${name ?? ""}`))
      .child(svg(`mods/workspace-chrome/${name ? "server" : "monitor"}.svg`).size(13))
      .when(Boolean(stats), (el) => el
        .child(num(pct(stats.cpu), hot(stats.cpu)))
        .child(num(pct((stats.used / stats.total) * 100), hot((stats.used / stats.total) * 100)))
        .when(Boolean(load), (el) => el.child(num(`${load.n}%`, [t.muted, t.ansi3, t.blocked][load.level]))))
      .when(!stats, (el) => el.child(div().text_color(t.dim).child("…")));
  }

  // "iu 46" (no five-hour window: weekly only) or "me 2/75": 5-hour / 7-day %, as in the Claude statusline; a mode mark
  // follows the id ("me2↓ 4/0"). No quota
  // color (a full account is the picker's job, not an alarm); red only for a failed login, dim when stale.
  account(t, a) {
    const bad = !a.auth_ok;
    const stale = (a.age_s ?? 0) > STALE_S;
    const color = bad ? t.blocked : stale ? t.dim : t.muted;
    const week = a.seven_day ?? "?";
    const id = `${a.id}${modeMark(a)}`;
    const text = bad ? `${id} login` : a.five_hour == null ? `${id} ${week}` : `${id} ${a.five_hour}/${week}`;
    return div().text_color(color).child(text);
  }

  render() {
    const t = theme();
    const want = new Set(["local", "palette"]);
    if (this.usage.length > 0) want.add("usage");
    if (this.issues.length > 0) want.add("logins");
    if (this.kuma) want.add("kuma");
    const shown = fit(this.width, want, this.remotes.length);
    const sep = () => div().w(1).h(12).bg(t.border);
    return h_flex().size_full().px(8).gap(10).overflow_hidden().on_size_change((size, cx) => {
      const width = Math.floor(size.width);
      if (width === this.width) return;
      this.width = width;
      cx.notify();
    }).items_center().bg(t.chrome).border_t(1).border_color(t.border).text_size(11.8).text_color(t.muted)
      .child(this.machine(t, null, this.stats[""]))
      .children(this.remotes.filter((_, i) => shown.has(`remote${i}`)).map((m) => this.machine(t, m, this.stats[m])))
      .when(shown.has("usage"), (el) => el.child(sep())
        .child(h_flex().id("usage").gap(8).items_center().px(6).rounded(5).cursor_pointer().hover((s) => s.bg(t.hover))
          .on_mouse_move((e) => this.track("usage", e))
          .on_mouse_up("left", (e) => this.details({ kind: "usage" }, e, "usage"))
          .child(svg("mods/workspace-chrome/clock.svg").size(12)).children(this.usage.map((a) => this.account(t, a)))
          .when(pool(this.usage) != null, (el) => el.child(div().text_color(t.muted).child(`∑${pool(this.usage)}`)))))
      .when(shown.has("logins"), (el) => {
        const bad = this.issues.some((x) => x.state === "fail");
        const who = [...new Set(this.issues.map((x) => `${x.id}·${x.machine === "macbook" ? "MacBook" : x.machine}`))].join(" ");
        return el.child(h_flex().id("logins").gap(6).items_center().px(6).rounded(5).cursor_pointer().hover((s) => s.bg(t.hover))
          .text_color(bad ? t.blocked : t.ansi3)
          .on_mouse_move((e) => this.track("logins", e))
          .on_mouse_up("left", (e) => this.details({ kind: "usage" }, e, "logins"))
          .child(`⚠ ${who}`));
      })
      .child(div().flex_1())
      .when(shown.has("kuma"), (el) => el.child(h_flex().id("kuma").gap(6).items_center().px(6).text_color(t.dim)
        .tooltip(this.kuma.down.length ? `Uptime Kuma down: ${this.kuma.down.join(", ")}` : "Uptime Kuma: every active monitor up")
        .child(div().child(`▲${this.kuma.up}`))
        .child(div().text_color(this.kuma.down.length ? t.blocked : t.dim).child(`▼${this.kuma.down.length}`))))
      .when(shown.has("palette"), (el) => el.child(div().id("palette").px(6).text_color(t.dim).on_click(() => run("app.palette")).child(`${window()?.platform === "macos" ? "⌘" : "Ctrl"} Shift P`)));
  }
}
