#!/usr/bin/env python3
"""factory-spaces — render ~/.config/factory/spaces.json from config/herdr-app/groups.json.

software-factory keeps one space per listed repo and never reorders them; the sidebar order is groups.json
(the jk-spaces mod), which stays the one list. Every group's `members`, in order, resolves to ~/SourceRoot/<name>,
else ~/IuRoot/<name>, else is skipped; the member `IuRoot` is the work root itself, for a cross-repo planner
(software-factory decisions RS14). A name in groups.json's `noFactorySpace` gets none (a repo kept only for the
sidebar's order on another machine). A name listed twice appears once. The file is written atomically (temp + rename), mode 0644; a run that would write the same
bytes leaves it untouched.

    factory-spaces.py [--groups PATH] [--out PATH]
"""

import argparse
import json
import os
import sys

HOME = os.path.expanduser("~")
ROOTS = (os.path.join(HOME, "SourceRoot"), os.path.join(HOME, "IuRoot"))
WORK_ROOT_NAME = "IuRoot"
DEFAULT_GROUPS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "config", "herdr-app", "groups.json")
DEFAULT_OUT = os.path.join(HOME, ".config", "factory", "spaces.json")


def resolve(name: str) -> str | None:
    if name == WORK_ROOT_NAME:
        return ROOTS[1] if os.path.isdir(ROOTS[1]) else None
    return next((p for p in (os.path.join(r, name) for r in ROOTS) if os.path.isdir(p)), None)


def render(groups_path: str) -> str:
    with open(groups_path) as f:
        doc = json.load(f)
    spaces, seen = [], set(doc.get("noFactorySpace", []))
    for group in doc["groups"]:
        for name in group["members"]:
            if name in seen:
                continue
            seen.add(name)
            path = resolve(name)
            if path:
                spaces.append({"name": name, "path": path})
    return json.dumps({"spaces": spaces}, indent=2) + "\n"


def write_if_changed(out: str, text: str) -> bool:
    try:
        with open(out) as f:
            if f.read() == text and os.stat(out).st_mode & 0o777 == 0o644:
                return False
    except FileNotFoundError:
        pass
    os.makedirs(os.path.dirname(out), exist_ok=True)
    tmp = f"{out}.{os.getpid()}.tmp"
    try:
        with open(tmp, "w") as f:
            f.write(text)
        os.chmod(tmp, 0o644)
        os.replace(tmp, out)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
    return True


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--groups", default=DEFAULT_GROUPS)
    ap.add_argument("--out", default=DEFAULT_OUT)
    a = ap.parse_args()
    try:
        text = render(a.groups)
    except (OSError, ValueError, KeyError) as e:
        print(f"factory-spaces: cannot read {a.groups}: {e}", file=sys.stderr)
        return 1
    changed = write_if_changed(a.out, text)
    n = len(json.loads(text)["spaces"])
    print(f"{'wrote' if changed else 'unchanged'} {a.out} ({n} spaces)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
