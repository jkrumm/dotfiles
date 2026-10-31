// jk-keys — headless: key commands that run a script. No UI; a layout block of zero size hosts it
// because `<mod>.<command>` reaches shown copies only.
//   keys.json "cmd-e": "jk-keys.brain-note"   the focused terminal's repo page from the brain vault,
//                                             in $EDITOR, as a peek over the tab
// Bound by scripts/herdr-app-keys.sh, never by hand. The key list is the file's job; this mod
// only answers the commands.
import { View, div } from "gpui-kit";
import { exec, hc, focused, notify, run, nextCommand, terminals } from "herdr";

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

const COMMANDS = { "brain-note": brainNote };

export default class JkKeys extends View {
  init(_props, cx) {
    cx.spawn(async () => {
      for (;;) {
        const name = await nextCommand();
        const handler = COMMANDS[name];
        if (!handler) continue;
        handler().catch((e) => fail("Project note", e?.message ?? e));
      }
    });
  }

  render() {
    return div().size(0);
  }
}
