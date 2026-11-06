// jk-keys — headless: key commands that run a script. No UI; a layout block of zero size hosts it
// because `<mod>.<command>` reaches shown copies only.
//   keys.json "cmd-e": "jk-keys.brain-note"   the focused terminal's repo page from the brain vault,
//                                             in $EDITOR, as a peek over the tab
//   keys.json "cmd-alt-b": "jk-keys.board"    the full-screen Issues board in, and out again
// Bound by scripts/herdr-app-keys.sh, never by hand. The key list is the file's job; this mod
// only answers the commands.
import { View, div } from "gpui-kit";
import { exec, hc, focused, notify, run, nextCommand, terminals, layout, shared, setShared } from "herdr";

// Run through bash -c so $HOME is the target machine's own (a terminal on `mini` edits the mini's vault checkout).
const BRAIN_NOTE = 'exec bash "$HOME/SourceRoot/dotfiles/scripts/brain-note.sh"';

function fail(title, body) {
  notify({ title, body: String(body ?? "").slice(0, 300), level: "error" });
}

// The script reads its repo from its cwd, so the terminal's cwd is all it needs. A terminal on another
// machine (`mini/t7`) gets the note started there, in that machine's vault.
async function brainNote() {
  const f = focused();
  const address = f?.terminal ?? null;
  const machine = address && address.includes("/") ? address.split("/")[0] : null;
  const args = ["run", "--bg", "--json", "--no-parent", "--rm", "--label", "jk.role=brain-note"];
  if (machine) args.push("--on", machine);
  if (f?.cwd) args.push("--cwd", f.cwd);
  args.push("--", "bash", "-c", BRAIN_NOTE);
  const r = await hc(args);
  if (r.code !== 0) return fail("Project note", r.stderr || r.stdout);
  let started;
  try {
    started = JSON.parse(r.stdout.split("\n")[0]).address;
  } catch {
    return fail("Project note", `unexpected hc output: ${r.stdout}`);
  }
  // The window learns of a terminal from the core's events: peeking at once says "no running terminal".
  for (let i = 0; i < 30 && !terminals().some((t) => t.address === started); i++) await exec("sleep", ["0.1"]);
  run("terminal.peek", { terminal: started });
}

// The full-screen board (layout block `boardfull`, jk-board with view=board) replaces the whole window content: the
// sidebar, the work column and the right board column hide, it shows; the same key leaves it again and brings back
// the board column only if it was open. Duplicated in jk-board's button (mods can't import each other; keep in step).
const hidden = (id) => Boolean(findBlock(layout(), id)?.hidden);
function findBlock(node, id) {
  if (node?.id === id) return node;
  for (const child of node?.children ?? []) {
    const found = findBlock(child, id);
    if (found) return found;
  }
  return null;
}
function toggleBoard() {
  if (hidden("boardfull")) {
    setShared("jk.board.wasOpen", !hidden("board"));
    for (const id of ["sidebar", "work", "board"]) run("layout.hide", { id });
    run("layout.show", { id: "boardfull" });
    return;
  }
  run("layout.hide", { id: "boardfull" });
  run("layout.show", { id: "sidebar" });
  run("layout.show", { id: "work" });
  if (shared("jk.board.wasOpen") !== false) run("layout.show", { id: "board" });
}

const COMMANDS = { "brain-note": brainNote, board: async () => toggleBoard() };

export default class JkKeys extends View {
  init(_props, cx) {
    cx.spawn(async () => {
      for (;;) {
        const name = await nextCommand();
        const handler = COMMANDS[name];
        if (!handler) continue;
        handler().catch((e) => fail(`Key ${name}`, e?.message ?? e));
      }
    });
  }

  render() {
    return div().size(0);
  }
}
