// The popup behind jk-status. props().kind:
//   "machine" — CPU and memory history (jk-status's samples, last 15 min) and the
//               top processes on that machine, refreshed every 3 s;
//   "usage"   — every Claude account: 5-hour and 7-day %, when each window resets.
import { View, div } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { props as rawProps, theme, exec, shared, closeOverlay } from "herdr";

// pcpu, rss (KiB), full command; sorted by CPU, header dropped.
const TOP_ROWS = 10;
const TOP = `ps -Ao pcpu=,rss=,comm= -r | head -${TOP_ROWS}`;
const TOP_MS = 3000;
const BARS = 90;
const props = () => rawProps() ?? {};
// Anthropic renamed the tiers on 2026-10-30: Max 5x is "Max", Max 20x is "Ultra".
const PLAN = { max5x: "Max", max20x: "Ultra" };
const STALE_S = 3 * 3600;

const mem = (kib) => (kib >= 1048576 ? `${(kib / 1048576).toFixed(1)}G` : `${Math.round(kib / 1024)}M`);
const name = (cmd) => cmd.replace(/\.app\/.*$/, ".app").split("/").pop();

function until(epoch) {
  if (!epoch) return "—";
  const s = epoch - Date.now() / 1000;
  if (s <= 0) return "now";
  const d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60);
  // Formatted by hand: this runtime's toLocaleString ignores its options.
  const at = new Date(epoch * 1000);
  const hm = `${String(at.getHours()).padStart(2, "0")}:${String(at.getMinutes()).padStart(2, "0")}`;
  const clock = d >= 1 ? `${["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][at.getDay()]} ${hm}` : hm;
  return `${d ? `${d}d ` : ""}${h}h ${m}m · ${clock}`;
}

export default class JkDetails extends View {
  init(_props, cx) {
    this.top = null;
    if (props().kind === "usage") return;
    cx.timer.every(TOP_MS, (cx) => this.refresh(cx));
    this.refresh(cx);
  }

  refresh(cx) {
    cx.spawn(async (cx) => {
      const r = await exec("sh", ["-c", TOP], { on: props().machine ?? null }).catch(() => null);
      this.top = (r?.stdout ?? "").split("\n").map((l) => l.trim().match(/^([\d.]+)\s+(\d+)\s+(.+)$/)).filter(Boolean)
        .map(([, cpu, rss, cmd]) => ({ cpu: Number(cpu), rss: Number(rss), name: name(cmd) }));
      cx.notify();
    });
  }

  spark(t, label, values, unit, color) {
    const last = values.at(-1) ?? 0;
    const avg = values.length ? values.reduce((a, b) => a + b, 0) / values.length : 0;
    const max = values.length ? Math.max(...values) : 0;
    const bars = values.slice(-BARS);
    return v_flex().gap(4)
      .child(h_flex().gap(10).text_size(11.5).text_color(t.muted)
        .child(div().w(36).text_color(t.foreground).child(label))
        .child(div().child(`now ${last.toFixed(1)}${unit}`))
        .child(div().child(`avg ${avg.toFixed(1)}${unit}`))
        .child(div().child(`max ${max.toFixed(1)}${unit}`)))
      .child(h_flex().h(40).items_end().gap(1).p(2).rounded(4).bg(t.canvas)
        .children(bars.map((v, i) => div().id(`${label}-${i}`).w(3).flex_none().h(Math.max(1, (Math.min(v, 100) / 100) * 36)).bg(v >= 85 ? t.blocked : color))));
  }

  machine(t) {
    const m = props().machine ?? null;
    const hist = (shared("jk.history") ?? {})[m ?? ""] ?? [];
    return v_flex().gap(12)
      .child(div().text_size(13).font_bold().text_color(t.foreground).child(m ?? "MacBook"))
      .child(this.spark(t, "CPU", hist.map((s) => s.cpu), "%", t.accent))
      .child(this.spark(t, "MEM", hist.map((s) => s.mem), "%", t.ansi5))
      .child(div().text_size(10.5).text_color(t.dim).child(`${hist.length} samples · 5 s apart · newest right`))
      .child(v_flex().gap(2).text_size(11.5)
        .child(h_flex().gap(8).text_color(t.dim).child(div().w(48).text_right().child("CPU")).child(div().w(52).text_right().child("MEM")).child(div().child("process")))
        .children(Array.from({ length: TOP_ROWS }, (_, i) => this.top?.[i] ?? null).map((p, i) => !p ? h_flex().id(`p-${i}`).h(18).child(div().w(48).text_right().text_color(t.dim).child(i === 0 && this.top === null ? "…" : "")) : h_flex().id(`p-${i}`).h(18).gap(8)
          .child(div().w(48).text_right().text_color(p.cpu >= 50 ? t.blocked : t.foreground).child(`${p.cpu.toFixed(1)}%`))
          .child(div().w(52).text_right().text_color(t.muted).child(mem(p.rss)))
          .child(div().flex_1().truncate().text_color(t.muted).child(p.name)))));
  }

  usage(t) {
    const { accounts = [] } = shared("jk.usage") ?? {};
    const row = (label, value, resets) => h_flex().gap(8).text_size(11.5)
      .child(div().w(24).text_color(t.dim).child(label))
      .child(div().w(40).text_right().text_color(value >= 90 ? t.blocked : t.foreground).child(value == null ? "?" : `${value}%`))
      .child(div().flex_1().text_color(t.muted).child(until(resets)));
    // Only what changes a decision: the plan, and a warning when the numbers can't be trusted.
    const note = (a) => !a.auth_ok ? "login expired" : (a.age_s ?? 0) > STALE_S ? `data ${Math.round(a.age_s / 3600)} h old` : "";
    return v_flex().gap(14)
      .child(div().text_size(13).font_bold().text_color(t.foreground).child("Claude usage · resets"))
      .children(accounts.map((a) => v_flex().id(`acct-${a.id}`).gap(4)
        .child(h_flex().gap(8).items_center()
          .child(div().text_size(12.5).font_bold().text_color(a.auth_ok ? t.foreground : t.blocked).child(a.id))
          .child(div().text_size(11).text_color(t.dim).child(PLAN[a.plan] ?? a.plan ?? ""))
          .child(div().text_size(11).text_color(a.auth_ok ? t.dim : t.blocked).child(note(a))))
        .child(row("5h", a.five_hour, a.five_hour_resets_at))
        .child(row("7d", a.seven_day, a.seven_day_resets_at))))
      .when(!accounts.length, (el) => el.child(div().text_color(t.dim).child("no usage data yet")));
  }

  render() {
    const t = theme();
    return v_flex().id("jk-details").size_full().p(16).gap(8).bg(t.popover).text_color(t.foreground).overflow_y_scrollbar()
      .on_mouse_down("left", () => {})
      .child(props().kind === "usage" ? this.usage(t) : this.machine(t))
      .child(div().id("close").mt(6).text_size(11).text_color(t.dim).cursor_pointer().hover((s) => s.text_color(t.foreground))
        .on_click(() => closeOverlay(props().overlay)).child("Close · Esc"));
  }
}
