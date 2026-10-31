// The shipped workspace-status bar plus CPU and memory of the machine the active
// space runs on — this computer, or a remote core's host via exec's `on`.
import { View, div, svg } from "gpui-kit";
import { h_flex } from "gpui-base";
import { spaces, agents, theme, run, window, exec } from "herdr";

// macOS: "<cpu %> <used GiB×10> <total GiB×10>". Used = active + wired + compressed,
// the figure Activity Monitor calls memory used; the file cache is left out.
const STATS = `cpu=$(ps -A -o %cpu= | awk -v n="$(sysctl -n hw.ncpu)" '{s+=$1} END{printf "%d", s/n}')
used=$(vm_stat | awk '/page size of/{ps=$8} /Pages active/{a=$3} /Pages wired/{w=$4} /occupied by compressor/{c=$5} END{printf "%d", (a+w+c)*ps/107374182.4}')
echo "$cpu $used $(($(sysctl -n hw.memsize) / 107374182))"`;

const POLL_MS = 5000;

export default class JkStatus extends View {
  init(_props, cx) {
    this.stats = {};
    cx.timer.every(POLL_MS, (cx) => this.refresh(cx));
    this.refresh(cx);
  }

  refresh(cx) {
    const machine = spaces().find((s) => s.active)?.machine ?? null;
    cx.spawn(async (cx) => {
      const r = await exec("sh", ["-c", STATS], { on: machine }).catch(() => null);
      const [cpu, used, total] = (r?.stdout ?? "").trim().split(" ").map(Number);
      const next = Number.isFinite(total) && total > 0 ? { cpu, used: used / 10, total: total / 10 } : null;
      const key = machine ?? "";
      if (JSON.stringify(this.stats[key]) === JSON.stringify(next)) return;
      this.stats[key] = next;
      cx.notify();
    });
  }

  render() {
    const t = theme();
    const space = spaces().find((s) => s.active);
    const list = agents();
    const needs = list.filter((a) => a.status === "blocked").length;
    const stats = this.stats[space?.machine ?? ""];
    const hot = (pct) => (pct >= 85 ? t.blocked : t.muted);
    const label = (icon, text) => h_flex().gap(6).items_center().child(svg(`mods/workspace-chrome/${icon}.svg`).size(13)).child(text);
    return h_flex().size_full().px(14).gap(16).items_center().bg(t.chrome).border_t(1).border_color(t.border).text_size(11.8).text_color(t.muted)
      .child(label(space?.machine ? "server" : "monitor", space?.machine ?? "This computer"))
      .when(Boolean(stats), (el) => el
        .child(div().text_color(hot(stats.cpu)).child(`CPU ${stats.cpu}%`))
        .child(div().text_color(hot((stats.used / stats.total) * 100)).child(`MEM ${stats.used.toFixed(1)} / ${stats.total.toFixed(0)} GB`)))
      .when(Boolean(space?.branch), (el) => el.child(label("branch", space.branch)))
      .when(needs > 0, (el) => el.child(div().text_color(t.blocked).child(`${needs} needs you`)))
      .child(div().flex_1())
      .child(div().id("palette").text_color(t.dim).on_click(() => run("app.palette")).child(`${window()?.platform === "macos" ? "⌘" : "Ctrl"} Shift P  commands`));
  }
}
