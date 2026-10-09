#!/usr/bin/env python3
"""Group the herdr sidebar into labelled sections.

herdr has no folders and no separator primitive. What it does have is spaces
and an ordering call, so a section header IS a space: one workspace per group
whose label is the header, ordered immediately above its members.

  workspace.create      makes the separator (a workspace is the only entry
                        herdr will render as its own row)
  workspace.move_block  atomically reorders spaces
  workspace.rename      keeps a separator's label in step with groups.json

config/herdr/groups.json is the declaration; this script is the applier.

WHY A FAKE SPACE AND NOT A METADATA TOKEN, because the token came first and
lost. `workspace.report_metadata` can put a `$group` value on a real space and
[ui.sidebar.spaces].rows renders it, but a token is always a ROW OF SOME ENTRY,
and herdr indents rows 2+ of an entry:

  header as row 1 of the group's first space  that repo sits indented while its
                                              siblings are flush — reads as
                                              "only this one is in the group"
  header as the last row of the previous      focusing that space paints the
  group's last space                          focus background over the next
                                              group's header

A separate space has neither problem: every entry is one flush row, and the
header can only ever be highlighted on its own. It also needs no re-applying —
a label is persisted in session.json, where reported metadata is not, which
retired the startup-hook plugin this used to need.

The costs, all measured rather than assumed: each separator holds an idle
shell, takes a slot in workspace numbering and the picker, and renders with the
state_icon herdr puts on every space (`· ── TOOLING`). It stays invisible to
agent-gateway's agent overview, which reads `herdr agent list` and uses
`workspace list` only as an id→label map.

Stdlib only, and 3.9-compatible: /usr/bin/python3 is the interpreter a
launchd-spawned caller resolves.
"""

import argparse
import json
import os
import socket
import sys


class NoServer(Exception):
    """No reachable herdr server — a missing socket path, or a stale one."""


HERE = os.path.dirname(os.path.abspath(__file__))
GROUPS_JSON = os.path.join(HERE, "..", "config", "herdr", "groups.json")
# HERDR_SOCKET_PATH is set in every pane and is the only correct answer under a
# NAMED session, whose socket lives at ~/.config/herdr/sessions/<name>/.
SOCKET_PATH = os.environ.get(
    "HERDR_SOCKET_PATH", os.path.expanduser("~/.config/herdr/herdr.sock")
)
# The marker that makes a separator recognisable on the next run. It has to be
# in the LABEL rather than anywhere else, because the label is the only per-
# workspace state herdr persists.
SEPARATOR_PREFIX = "── "
SEPARATOR_CWD = os.path.expanduser("~")
# A separator is a workspace, so herdr renders it with the same state_icon and
# the same colour as every other space — 0.8.2 has no way to style one label
# differently (`rules` on a token is 0.9.0). The rule characters are therefore
# the only thing making the line read as a separator, and the width is padded
# so they all end in the same column. 22 fits a 29-column sidebar behind the
# icon; a longer label simply goes unpadded.
#   ON A 0.9.0 UPGRADE: `rules = [{ starts_with = "── ", dim = true }]` on the
#   `workspace` token in [ui.sidebar.spaces] would let the padding shrink or go.
SEPARATOR_WIDTH = 22


class Herdr(object):
    """Newline-delimited JSON over the server socket.

    ONE CONNECTION PER REQUEST, and that is herdr's contract rather than a
    convenience here: only an `events.subscribe` connection stays open after
    its first response, so a second request written to the same socket dies
    with EPIPE. Measured, after exactly that traceback.
    """

    def __init__(self, path):
        self.path = path
        self.seq = 0

    def call(self, method, params):
        self.seq += 1
        req = {"id": "grp%d" % self.seq, "method": method, "params": params}
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(10)
        try:
            sock.connect(self.path)
            sock.sendall((json.dumps(req) + "\n").encode())
            line = sock.makefile("r").readline()
        except (OSError, socket.timeout) as err:
            # A STALE SOCKET FILE IS THE INTERESTING CASE, not a missing one: an
            # unclean herdr exit leaves the path behind, so only connect() finds
            # out. Same outcome either way.
            raise NoServer("%s: %s" % (self.path, err))
        finally:
            sock.close()
        if not line:
            raise RuntimeError("herdr closed the connection during %s" % method)
        resp = json.loads(line)
        if "error" in resp:
            raise RuntimeError("%s failed: %s" % (method, json.dumps(resp["error"])))
        return resp.get("result", {})

    def workspaces(self):
        return self.call("workspace.list", {})["workspaces"]


def is_separator(workspace):
    return workspace["label"].startswith(SEPARATOR_PREFIX)


def separator_label(header):
    label = SEPARATOR_PREFIX + header + " "
    return label.ljust(SEPARATOR_WIDTH, "─") if len(label) < SEPARATOR_WIDTH else label


def is_variant(label, member):
    """A worktree-style variant of `member`, such as `dotfiles (feat-x)`.

    The separator test is what keeps `rollhook-action` and `dotfiles-private`
    from being swallowed as variants of `rollhook` and `dotfiles`: they are
    declared members in their own right, and plan() excludes every declared
    label here before asking.
    """
    return label.startswith(member) and not label[len(member):][:1].isalnum()


def plan(groups, fallback, workspaces):
    """Return [(header, [workspace, ...]), ...] covering every real space once."""
    declared = set()
    for group in groups:
        declared.update(group["members"])
    remaining = [w for w in workspaces if not is_separator(w)]
    out = []
    for group in groups:
        picked = []
        for member in group["members"]:
            claimed = [w for w in remaining if w["label"] == member] + [
                w
                for w in remaining
                if w["label"] not in declared and is_variant(w["label"], member)
            ]
            for w in claimed:
                picked.append(w)
                remaining.remove(w)
        if picked:
            out.append((group["label"], picked))
    if remaining:
        out.append((fallback, remaining))
    return out


def ensure_separators(herdr, sections, existing):
    """One separator space per section, reusing and renaming before creating.

    Reuse matters: creating spawns a shell and burns a workspace slot, so a
    renamed group should move its existing separator rather than leave an
    orphan behind. Leftovers are closed — they only ever hold an idle shell.
    """
    pool = list(existing)
    heads = []
    for header, _ in sections:
        label = separator_label(header)
        match = [w for w in pool if w["label"] == label]
        if match:
            pool.remove(match[0])
            heads.append(match[0])
            continue
        if pool:
            stale = pool.pop(0)
            herdr.call(
                "workspace.rename", {"workspace_id": stale["workspace_id"], "label": label}
            )
            heads.append(dict(stale, label=label))
            continue
        created = herdr.call(
            "workspace.create", {"label": label, "cwd": SEPARATOR_CWD, "focus": False}
        )["workspace"]
        heads.append(created)
    for orphan in pool:
        herdr.call("workspace.close", {"workspace_id": orphan["workspace_id"]})
    return heads


def apply_order(herdr, sections, heads):
    """Move each section, separator first, to the end in declared order."""
    for head, (_, members) in zip(heads, sections):
        ids = [head["workspace_id"]] + [w["workspace_id"] for w in members]
        herdr.call(
            "workspace.move_block", {"workspace_ids": ids, "before_workspace_id": None}
        )


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("mode", nargs="?", default="apply", choices=["apply", "check", "clear"])
    args = ap.parse_args()

    with open(GROUPS_JSON) as fh:
        config = json.load(fh)

    herdr = Herdr(SOCKET_PATH)
    try:
        current = herdr.workspaces()
    except NoServer as err:
        # Not an error: the MacBook is a thin client and usually runs no server,
        # and this also runs from `make setup`. Say so and exit clean.
        sys.stderr.write("no herdr server at %s — nothing to group\n" % err)
        return 0

    separators = [w for w in current if is_separator(w)]
    sections = plan(config["groups"], config["fallback"], current)

    if args.mode == "check":
        for header, members in sections:
            print(separator_label(header))
            for w in members:
                print("    %s" % w["label"])
        return 0

    if args.mode == "clear":
        for w in separators:
            herdr.call("workspace.close", {"workspace_id": w["workspace_id"]})
        # Also drop the metadata token this used to render headers with, so a
        # config that still names `$group` cannot resurrect a stale label.
        for w in current:
            if not is_separator(w):
                herdr.call(
                    "workspace.report_metadata",
                    {
                        "workspace_id": w["workspace_id"],
                        "source": config["source"],
                        "tokens": {config["token"]: None},
                    },
                )
        print("removed %d separator spaces" % len(separators))
        return 0

    heads = ensure_separators(herdr, sections, separators)
    apply_order(herdr, sections, heads)
    print(
        "%d spaces in %d groups (%d separators)"
        % (len(current) - len(separators), len(sections), len(heads))
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
