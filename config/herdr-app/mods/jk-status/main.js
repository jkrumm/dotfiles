// The status bar: CPU and memory of this computer and of every connected machine (the
// mini), Claude Max usage per account, then branch, "needs you" and the palette hint.
// Click a machine or the usage for jk-details (history, top processes, quota resets).
import { View, div, svg } from "gpui-kit";
import { h_flex } from "gpui-base";
import { spaces, agents, theme, run, window, exec, hc, shared, setShared, openOverlay } from "herdr";

// macOS: "<cpu %> <used GiB> <total GiB>", one decimal each. Used = active + wired +
// compressed, the figure Activity Monitor calls memory used; the file cache is left out.
const STATS = `cpu=$(ps -A -o %cpu= | awk -v n="$(sysctl -n hw.ncpu)" '{s+=$1} END{printf "%.1f", s/n}')
used=$(vm_stat | awk '/page size of/{ps=$8} /Pages active/{a=$3} /Pages wired/{w=$4} /occupied by compressor/{c=$5} END{printf "%.1f", (a+w+c)*ps/1073741824}')
echo "$cpu $used $(sysctl -n hw.memsize | awk '{printf "%.0f", $1/1073741824}')"`;

// claude-account reads only its local quota cache (the MacBook's includes the mini's
// samples, imported as source "peer"): no API call, ~20 ms. docs/claude-accounts.md.
const USAGE = 'PATH="$HOME/.local/bin:$HOME/.bun/bin:/opt/homebrew/bin:$PATH" claude-account usage --json';

// Login, quota and pending-ask health of this machine and its peer, each problem with its
// fix command: claude-account's own verdict (docs/claude-accounts.md), the one source the
// statusline-adjacent tools share. ~1 s (it asks the peer over ssh).
const HEALTH = 'PATH="$HOME/.local/bin:$HOME/.bun/bin:/opt/homebrew/bin:$PATH" claude-account health --json';
const HEALTH_MS = 5 * 60000;

const STATS_MS = 5000;
const USAGE_MS = 60000;
const HISTORY = 180; // samples per machine: 15 min at STATS_MS
const STALE_S = 3 * 3600;

const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

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
    cx.timer.every(HEALTH_MS, (cx) => this.refreshHealth(cx));
    cx.timer.every(STATS_MS, (cx) => this.refreshStats(cx));
    cx.timer.every(USAGE_MS, (cx) => this.refreshUsage(cx));
    this.refreshStats(cx);
    this.refreshUsage(cx);
    this.refreshHealth(cx);
  }

  refreshHealth(cx) {
    cx.spawn(async (cx) => {
      const r = await exec("sh", ["-c", HEALTH]).catch(() => null);
      let rows;
      try { rows = JSON.parse(r?.stdout ?? "").rows ?? []; } catch { return; }
      const next = rows.filter((x) => x.state !== "ok");
      setShared("jk.health", next);
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
        if (next) this.history[key] = [...(this.history[key] ?? []), { t: Date.now(), cpu, mem: (used / total) * 100 }].slice(-HISTORY);
        if (!same(this.stats[key], next)) { this.stats[key] = next; changed = true; }
      }));
      setShared("jk.history", this.history);
      if (changed) cx.notify();
    });
  }

  refreshUsage(cx) {
    cx.spawn(async (cx) => {
      const r = await exec("sh", ["-c", USAGE]).catch(() => null);
      let next = [];
      try { next = (JSON.parse(r?.stdout ?? "").accounts ?? []).filter((a) => a.enabled); } catch {}
      setShared("jk.usage", { at: Date.now(), accounts: next });
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

  machine(t, name, stats) {
    const hot = (v) => (v >= 85 ? t.blocked : t.muted);
    const num = (w, text, color) => div().w(w).flex_none().text_right().text_color(color).child(text);
    return h_flex().id(`stats-${name ?? "local"}`).gap(6).items_center().px(6).rounded(5).cursor_pointer().hover((s) => s.bg(t.hover))
      .on_mouse_move((e) => this.track(`m-${name ?? ""}`, e))
      .on_mouse_up("left", (e) => this.details({ kind: "machine", machine: name }, e, `m-${name ?? ""}`))
      .child(svg(`mods/workspace-chrome/${name ? "server" : "monitor"}.svg`).size(13))
      .child(div().child(name ?? "MacBook"))
      .when(Boolean(stats), (el) => el
        .child(num(32, pct(stats.cpu), hot(stats.cpu)))
        .child(num(48, `${Math.round(stats.used)}/${stats.total}G`, hot((stats.used / stats.total) * 100))))
      .when(!stats, (el) => el.child(div().text_color(t.dim).child("…")));
  }

  // "iu 7/59": 5-hour / 7-day %, as in the Claude statusline. Red at ≥ 90, dim when stale or logged out.
  account(t, a) {
    const bad = !a.auth_ok;
    const stale = (a.age_s ?? 0) > STALE_S;
    const color = bad ? t.blocked : stale ? t.dim : Math.max(a.five_hour ?? 0, a.seven_day ?? 0) >= 90 ? t.blocked : t.muted;
    const text = bad ? `${a.id} login` : `${a.id} ${a.five_hour ?? "?"}/${a.seven_day ?? "?"}`;
    return div().text_color(color).child(text);
  }

  render() {
    const t = theme();
    const space = spaces().find((s) => s.active);
    const needs = agents().filter((a) => a.status === "blocked").length;
    const sep = () => div().w(1).h(12).bg(t.border);
    return h_flex().size_full().px(8).gap(10).items_center().bg(t.chrome).border_t(1).border_color(t.border).text_size(11.8).text_color(t.muted)
      .child(this.machine(t, null, this.stats[""]))
      .children(this.remotes.map((m) => this.machine(t, m, this.stats[m])))
      .when(this.usage.length > 0, (el) => el.child(sep())
        .child(h_flex().id("usage").gap(10).items_center().px(6).rounded(5).cursor_pointer().hover((s) => s.bg(t.hover))
          .on_mouse_move((e) => this.track("usage", e))
          .on_mouse_up("left", (e) => this.details({ kind: "usage" }, e, "usage"))
          .child(svg("mods/workspace-chrome/clock.svg").size(12)).children(this.usage.map((a) => this.account(t, a)))))
      .when(this.issues.length > 0, (el) => {
        const bad = this.issues.some((x) => x.state === "fail");
        const who = [...new Set(this.issues.map((x) => `${x.id}·${x.machine === "macbook" ? "MacBook" : x.machine}`))].join(" ");
        return el.child(h_flex().id("logins").gap(6).items_center().px(6).rounded(5).cursor_pointer().hover((s) => s.bg(t.hover))
          .text_color(bad ? t.blocked : t.ansi3)
          .on_mouse_move((e) => this.track("logins", e))
          .on_mouse_up("left", (e) => this.details({ kind: "usage" }, e, "logins"))
          .child(`⚠ ${who}`));
      })
      .when(Boolean(space?.branch), (el) => el.child(sep()).child(h_flex().gap(6).items_center().child(svg("mods/workspace-chrome/branch.svg").size(13)).child(space.branch)))
      .when(needs > 0, (el) => el.child(div().text_color(t.blocked).child(`${needs} needs you`)))
      .child(div().flex_1())
      .child(div().id("palette").px(6).text_color(t.dim).on_click(() => run("app.palette")).child(`${window()?.platform === "macos" ? "⌘" : "Ctrl"} Shift P`));
  }
}
