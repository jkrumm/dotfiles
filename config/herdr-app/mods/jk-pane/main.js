// jk-pane: the shipped pane header (mods/pane), plus one thing. In a terminal that belongs to a factory session,
// the header says what that agent is about: the Issue's title, its state, its summary, and a link to its place in the Console, from
// shared("jk.factory.terminals"): app terminal address (`mini/<id>`) -> { title, summary, state, repo, link }.
// jk-glance publishes that feed (two extra reads in its poll); without an
// entry the header is the shipped one.
// A pane's header, for layouts that frame their panes:
//   { "tab": "active", "pane": { "header": { "content": { "mod": "jk-pane" } } } }
// Shows the program's icon (the app's program table), the agent's name or
// the terminal's title, the folder, and the agent's status; buttons split, zoom and close
// this pane. Props from the app: { pane, terminal }. Click: focus the pane.

import { View, div, svg, image } from "gpui-kit";
import { h_flex } from "gpui-base";
import { panes, props, run, theme, home, shared, exec } from "herdr";

function icon(p, size, color) {
  if (!p?.icon) return null;
  return p.tint ? svg(p.icon).size(size).flex_none().text_color(color) : image(p.icon).w(size).h(size).flex_none();
}

function folder(cwd) {
  if (!cwd) return "";
  const h = home();
  return cwd === h ? "~" : cwd.startsWith(h + "/") ? "~" + cwd.slice(h.length) : cwd;
}

// The Issue's state in the language's words ("working" -> "Working").
function state(f) {
  return f.state ? f.state[0].toUpperCase() + f.state.slice(1) : "";
}

function tip(f, cwd) {
  return [f.title, f.summary, f.repo ? `Repo: ${f.repo}` : null, cwd ? `Folder: ${folder(cwd)}` : null]
    .filter(Boolean).join("\n");
}

export default class Pane extends View {
  init() { this.hovered = false; }

  me() {
    return panes().find((p) => p.pane === props()?.pane);
  }

  button(t, id, icon, command, args) {
    return div()
      .id(id)
      .p(3)
      .rounded(4)
      .text_color(t.dim)
      .hover((s) => s.bg(t.hover).text_color(t.foreground))
      .on_click((_e, cx) => {
        cx.stop_propagation();
        run(command, args);
      })
      .child(svg(`mods/jk-pane/${icon}.svg`).size(14));
  }

  render(cx) {
    const t = theme();
    const p = this.me();
    if (!p) return div();
    const name = ((p.program?.agent || p.program?.shell) && p.program.name) || p.title || p.program?.name || "shell";
    const pic = icon(p.program, 14, t.dim);
    const st = p.status;
    const pane = p.pane;
    const f = shared("jk.factory.terminals")?.[p.terminal] ?? null;
    return h_flex()
      .id(`pane-head-${pane}`)
      .size_full()
      .px(10)
      .gap(8)
      .items_center()
      .bg(t.background)
      .border_b(1)
      .border_color(t.border)
      .text_size(12)
      .on_hover((hovered, cx) => { this.hovered = hovered; cx.notify(); })
      .on_click(() => run("pane.focus", { pane }))
      .when(Boolean(f), el => el.tooltip(tip(f, p.cwd)))
      .when(Boolean(pic), (el) => el.child(pic))
      .when(Boolean(f), el => el.child(div().flex_shrink(1).min_w(0).truncate().font_medium().text_color(t.foreground).child(f.title ?? "")))
      .when(Boolean(f) && Boolean(f.state), el => el.child(div().flex_none().max_w(120).truncate().text_color(t.dim).child(state(f))))
      .when(Boolean(f), el => el.child(div().flex_1().min_w(0).truncate().text_color(t.dim).child(f.summary ?? "")))
      .when(Boolean(f?.link), el => el.child(div().id(`ph-c-${pane}`).p(3).rounded(4).flex_none().text_color(t.dim).tooltip("Open in the Console")
        .hover((s) => s.bg(t.hover).text_color(t.foreground))
        .on_click((_e, cx) => { cx.stop_propagation(); exec("open", [f.link]).catch(() => {}); })
        .child(svg("mods/jk-pane/link.svg").size(14))))
      .when(!f, el => el
        .child(div().flex_none().truncate().max_w(260).font_medium().text_color(t.foreground).child(name))
        .child(div().flex_1().truncate().text_color(t.dim).child(folder(p.cwd))))
      .when(st === "working", el => el.child(svg("mods/workspace-chrome/spinner.svg").size(12).flex_none().text_color(t.working).spin(900)))
      .when(st === "blocked", el => el.child(div().flex_none().px(6).h(18).flex().items_center().rounded(5).bg(t.blocked + "26").text_size(10.5).font_semibold().text_color(t.blocked).child("Needs you")))
      .when(st === "done", el => el.child(div().size(7).flex_none().rounded(4).bg(t.done)))
      .when(this.hovered, el => el
        .child(this.button(t, `ph-r-${pane}`, "split-right", "pane.split", { direction: "right", pane }))
        .child(this.button(t, `ph-d-${pane}`, "split-down", "pane.split", { direction: "down", pane }))
        .child(this.button(t, `ph-z-${pane}`, p.zoomed ? "unzoom" : "zoom", "pane.zoom", { pane }))
        .child(this.button(t, `ph-x-${pane}`, "close", "pane.close", { pane })));
  }
}
