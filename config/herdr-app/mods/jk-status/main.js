// The status bar: CPU and memory of this computer and of every connected machine (the
// mini), Claude Max usage per account, then branch, "needs you" and the palette hint.
import { View, div, svg } from "gpui-kit";
import { h_flex } from "gpui-base";
import { spaces, agents, theme, run, window, exec, hc } from "herdr";

// macOS: "<cpu %> <used GiB×10> <total GiB×10>". Used = active + wired + compressed,
// the figure Activity Monitor calls memory used; the file cache is left out.
const STATS = `cpu=$(ps -A -o %cpu= | awk -v n="$(sysctl -n hw.ncpu)" '{s+=$1} END{printf "%d", s/n}')
used=$(vm_stat | awk '/page size of/{ps=$8} /Pages active/{a=$3} /Pages wired/{w=$4} /occupied by compressor/{c=$5} END{printf "%d", (a+w+c)*ps/107374182.4}')
echo "$cpu $used $(($(sysctl -n hw.memsize) / 107374182))"`;

// claude-account reads only its local quota cache (the MacBook's includes the mini's
// samples, imported as source "peer"): no API call, ~20 ms. docs/claude-accounts.md.
const USAGE = 'PATH="$HOME/.local/bin:$HOME/.bun/bin:/opt/homebrew/bin:$PATH" claude-account usage --json';

const STATS_MS = 5000;
const USAGE_MS = 60000;
const STALE_S = 3 * 3600;

const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

export default class JkStatus extends View {
  init(_props, cx) {
    this.stats = {}; // machine ("" = this computer) -> { cpu, used, total } | null
    this.remotes = [];
    this.pending = new Set(); // machines whose stats call is still out
    this.usage = [];
    cx.timer.every(STATS_MS, (cx) => this.refreshStats(cx));
    cx.timer.every(USAGE_MS, (cx) => this.refreshUsage(cx));
    this.refreshStats(cx);
    this.refreshUsage(cx);
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
        const next = Number.isFinite(total) && total > 0 ? { cpu, used: used / 10, total: total / 10 } : null;
        if (!same(this.stats[key], next)) { this.stats[key] = next; changed = true; }
      }));
      if (changed) cx.notify();
    });
  }

  refreshUsage(cx) {
    cx.spawn(async (cx) => {
      const r = await exec("sh", ["-c", USAGE]).catch(() => null);
      let next = [];
      try { next = (JSON.parse(r?.stdout ?? "").accounts ?? []).filter((a) => a.enabled); } catch {}
      if (same(next, this.usage)) return;
      this.usage = next;
      cx.notify();
    });
  }

  machine(t, name, stats) {
    const hot = (pct) => (pct >= 85 ? t.blocked : t.muted);
    return h_flex().gap(8).items_center()
      .child(svg(`mods/workspace-chrome/${name ? "server" : "monitor"}.svg`).size(13))
      .child(div().child(name ?? "MacBook"))
      .when(Boolean(stats), (el) => el
        .child(div().text_color(hot(stats.cpu)).child(`${stats.cpu}%`))
        .child(div().text_color(hot((stats.used / stats.total) * 100)).child(`${stats.used.toFixed(1)}/${stats.total.toFixed(0)}G`)))
      .when(!stats, (el) => el.child(div().text_color(t.dim).child("…")));
  }

  // "iu 7/59": 5-hour / 7-day %, as in the Claude statusline. Red at ≥ 90, dim when stale or logged out.
  account(t, a) {
    const bad = !a.auth_ok;
    const stale = (a.age_s ?? 0) > STALE_S;
    const color = bad ? t.blocked : stale ? t.dim : Math.max(a.five_hour ?? 0, a.seven_day ?? 0) >= 90 ? t.blocked : t.muted;
    const text = bad ? `${a.id} login` : `${a.id} ${a.five_hour ?? "?"}/${a.seven_day ?? "?"}`;
    return div().id(`usage-${a.id}`).text_color(color).child(text);
  }

  render() {
    const t = theme();
    const space = spaces().find((s) => s.active);
    const needs = agents().filter((a) => a.status === "blocked").length;
    const sep = () => div().w(1).h(12).bg(t.border);
    return h_flex().size_full().px(14).gap(14).items_center().bg(t.chrome).border_t(1).border_color(t.border).text_size(11.8).text_color(t.muted)
      .child(this.machine(t, null, this.stats[""]))
      .children(this.remotes.map((m) => this.machine(t, m, this.stats[m])))
      .when(this.usage.length > 0, (el) => el.child(sep())
        .child(h_flex().gap(10).items_center().child(svg("mods/workspace-chrome/clock.svg").size(12)).children(this.usage.map((a) => this.account(t, a)))))
      .when(Boolean(space?.branch), (el) => el.child(sep()).child(h_flex().gap(6).items_center().child(svg("mods/workspace-chrome/branch.svg").size(13)).child(space.branch)))
      .when(needs > 0, (el) => el.child(div().text_color(t.blocked).child(`${needs} needs you`)))
      .child(div().flex_1())
      .child(div().id("palette").text_color(t.dim).on_click(() => run("app.palette")).child(`${window()?.platform === "macos" ? "⌘" : "Ctrl"} Shift P`));
  }
}
