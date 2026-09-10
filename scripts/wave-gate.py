#!/usr/bin/env python3
"""The /wave green gate, the mechanical half of it.

The skill's gate table (`skills/wave/SKILL.md` § The green gate) has four
rows. Two are unprovable here without re-running work the finishing wave
already did — "/check passed" and "review findings resolved" stay that wave's
own judgment call, since re-running check/review from this script would just
duplicate a job an agent already ran and cannot be proven from the plan file
alone. Two ARE mechanically checkable from `docs/waves/PLAN.md` and the git
tree, and Round 2 of the estate audit (finding 13) found nothing checked them:
"plan committed" (a dirty tree means the close-out including the plan update
never landed) and "a next wave exists" (no `active` section, or the wave
handing off didn't actually finish). The fifth row — the next step being
outward-facing — is the skill's one explicit judgment call ("Stop and hand
back to the human. `/ship` is a human's call, not a wave's."); this script
turns it into a keyword heuristic on the exact verbs the skill already names
(merge, publish, release, deploy) rather than leaving it unchecked, but it
is a heuristic, not a proof — a wave that must stop for a subtler
outward-facing reason still has to notice that itself.

Usage: wave-gate.py <repo-path> <plan-path-or-relative-plan-ref>

Exit 0 and silent on pass. Exit 1 with a reason on stderr on any gate failure
— `cmd_wave` in remote-dev.sh treats that as a hard stop, matching the skill's
own "Stop. Do not spawn."
"""

import os
import re
import subprocess
import sys

WAVE_RE = re.compile(r"(Wave \d+) — .*?<!--\s*status:\s*(\w+)[^>]*-->")
BULLET_RE = re.compile(r"^- \[( |x)\] (.+)$")
LEFT_BEHIND_MARKER = "**Left behind:**"
LEFT_BEHIND_RE = re.compile(r"\*\*Left behind:\*\*\s*(.*)")
OUTWARD_RE = re.compile(r"\b(merge|publish|release|deploy|ship)\b", re.I)


def fail(reason: str) -> None:
    print(reason, file=sys.stderr)
    sys.exit(1)


def resolve_plan_path(repo_path: str, plan_ref: str) -> str:
    expanded = os.path.expanduser(plan_ref)
    if os.path.isabs(expanded):
        return expanded
    return os.path.join(repo_path, expanded)


def git_root_for(path: str) -> str | None:
    """The repo that actually owns `path` — may differ from the repo a wave
    is spawning INTO, since a cross-repo chain's plan lives in one repo
    (dotfiles) while `rd wave` targets another (e.g. brain). None if `path`
    isn't inside a git worktree at all.
    """
    result = subprocess.run(
        ["git", "-C", os.path.dirname(path) or ".", "rev-parse", "--show-toplevel"],
        capture_output=True,
        text=True,
    )
    return result.stdout.strip() if result.returncode == 0 else None


def check_clean(repo: str) -> None:
    status = subprocess.run(
        ["git", "-C", repo, "status", "--porcelain"],
        capture_output=True,
        text=True,
    )
    if status.returncode != 0:
        fail(f"git status failed in {repo}: {status.stderr.strip()}")
    if status.stdout.strip():
        fail(
            f"uncommitted changes in {repo} — commit the wave close-out "
            "(plan update included) before spawning the next wave"
        )


def parse_steps(body: str) -> list[tuple[str, str]]:
    """A step is its bullet line plus every indented continuation line that
    follows, joined into one string — the plan's own bullets wrap (see any
    step in `docs/waves/PLAN.md`), and a naive one-line-per-step capture
    truncates the outward-facing keyword scan to whatever fit on the first
    line.
    """
    lines = body.split("\n")
    steps: list[tuple[str, str]] = []
    i = 0
    while i < len(lines):
        m = BULLET_RE.match(lines[i])
        if not m:
            i += 1
            continue
        checked, parts = m.group(1), [m.group(2)]
        i += 1
        while (
            i < len(lines)
            and lines[i].strip()
            and not BULLET_RE.match(lines[i])
            and not lines[i].lstrip().startswith(LEFT_BEHIND_MARKER)
        ):
            parts.append(lines[i].strip())
            i += 1
        steps.append((checked, " ".join(parts)))
    return steps


def parse_waves(text: str) -> list[dict]:
    sections = re.split(r"(?m)^## ", text)[1:]
    waves = []
    for sec in sections:
        header, _, body = sec.partition("\n")
        m = WAVE_RE.match(header)
        if not m:
            continue
        name, status = m.group(1), m.group(2)
        steps = parse_steps(body)
        left = LEFT_BEHIND_RE.search(body)
        waves.append(
            {
                "name": name,
                "status": status,
                "unchecked": [s for c, s in steps if c == " "],
                # A wave with zero checklist items is NOT vacuously complete —
                # "done" with nothing to verify against is exactly the signal
                # this check exists to catch, not a pass.
                "all_checked": bool(steps) and all(c == "x" for c, _ in steps),
                "left_behind": left.group(1).strip() if left else "",
            }
        )
    return waves


def main() -> None:
    if len(sys.argv) != 3:
        fail(f"usage: {sys.argv[0]} <repo-path> <plan-path-or-relative-plan-ref>")
    repo_path, plan_ref = sys.argv[1], sys.argv[2]

    if not os.path.isdir(repo_path):
        fail(f"repo path does not exist: {repo_path}")

    plan_path = resolve_plan_path(repo_path, plan_ref)
    if not os.path.isfile(plan_path):
        fail(f"no plan file at {plan_path} — nothing to gate against, see the wave skill")

    # The repo being spawned INTO and the repo that owns the plan file are the
    # same thing in the common case, but not in a cross-repo chain (this
    # estate's own wave plan lives in dotfiles while a wave can target
    # `brain`) — "plan committed" means the PLAN'S repo is clean, which is not
    # necessarily `repo_path`. Check both, deduplicated.
    plan_repo = git_root_for(plan_path) or repo_path
    for repo in {repo_path, plan_repo}:
        check_clean(repo)

    with open(plan_path, encoding="utf-8") as f:
        waves = parse_waves(f.read())
    active = [w for w in waves if w["status"] == "active"]
    if not active:
        fail(f"no `active` wave in {plan_path} — chain is complete, or the plan is malformed")
    if len(active) > 1:
        fail(
            f"more than one `active` wave in {plan_path}: "
            + ", ".join(w["name"] for w in active)
        )
    active_wave = active[0]

    idx = waves.index(active_wave)
    if idx > 0:
        prev = waves[idx - 1]
        if prev["status"] != "done":
            fail(f"{prev['name']} precedes the active wave but is status:{prev['status']}, not done")
        if not prev["all_checked"]:
            # An empty `unchecked` list here (rather than "all_checked is
            # True") means zero checklist items existed at all, not that they
            # were all ticked — see parse_waves' comment.
            reason = "has no checklist items to verify completeness against" if not prev["unchecked"] else "has unchecked steps"
            fail(f"{prev['name']} is marked done but {reason}")
        if not prev["left_behind"]:
            fail(f"{prev['name']} has no Left behind — a finished wave must say what the next one inherits")

    hit = next((s for s in active_wave["unchecked"] if OUTWARD_RE.search(s)), None)
    if hit:
        fail(
            f"{active_wave['name']}'s next step looks outward-facing, stop and hand back "
            f"to the human: {hit!r}"
        )


if __name__ == "__main__":
    main()
