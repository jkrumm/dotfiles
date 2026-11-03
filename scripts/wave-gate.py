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

The sixth check is review coverage of the finished wave: `agw review covered
--cwd <plan repo> --range <wave start>..HEAD --format json` must answer
`covered: true`. Wave start is the commit that flipped the finished wave to
`active` in `docs/waves/PLAN.md`: the plan's history is walked newest first,
the wave's status read in each version, and the oldest commit of the newest
unbroken run of `active` is the start (a wave that was `active` since the
plan's first commit starts there). The range is exclusive of that commit, so
the wave's own work is what gets checked. Not found, `agw` missing or failing,
or any uncovered commit stops the chain (fail closed). The first wave has no
predecessor and skips the check.

Usage: wave-gate.py <repo-path> <plan-path-or-relative-plan-ref>

Exit 0 and silent on pass. Exit 1 with a reason on stderr on any gate failure
— `cmd_wave` in remote-dev.sh treats that as a hard stop, matching the skill's
own "Stop. Do not spawn."
"""

import json
import os
import re
import shutil
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


def wave_start(plan_repo: str, plan_path: str, wave_name: str) -> str | None:
    """The commit that made `wave_name` `active` in the plan's git history, else None."""
    rel = os.path.relpath(os.path.realpath(plan_path), os.path.realpath(plan_repo))
    log = subprocess.run(
        ["git", "-C", plan_repo, "log", "--format=%H", "--", rel],
        capture_output=True,
        text=True,
    )
    if log.returncode != 0:
        return None
    start = None
    in_run = False
    for sha in log.stdout.split():  # newest first
        show = subprocess.run(
            ["git", "-C", plan_repo, "show", f"{sha}:{rel}"], capture_output=True, text=True
        )
        status = None
        if show.returncode == 0:
            status = next((w["status"] for w in parse_waves(show.stdout) if w["name"] == wave_name), None)
        if status == "active":
            in_run, start = True, sha
        elif in_run:
            break
    return start


def check_review_coverage(plan_repo: str, plan_path: str, wave_name: str) -> None:
    start = wave_start(plan_repo, plan_path, wave_name)
    if not start:
        fail(
            f"cannot find the commit where {wave_name} became `active` in the git history of {plan_path} — "
            "review coverage of the finished wave cannot be checked; stop and run "
            "`agw review covered --cwd <repo> --range <wave start>..HEAD` by hand"
        )
    # host_run gives no PATH prefix: fall back to the install location.
    agw = shutil.which("agw") or os.path.expanduser("~/.local/bin/agw")
    try:
        result = subprocess.run(
            [agw, "review", "covered", "--cwd", plan_repo, "--range", f"{start}..HEAD", "--format", "json"],
            capture_output=True,
            text=True,
        )
    except OSError as e:
        fail(f"agw is not runnable ({e}) — review coverage of {wave_name} cannot be checked")
    if result.returncode != 0:
        fail(f"agw review covered failed (exit {result.returncode}): {(result.stderr or result.stdout).strip()}")
    try:
        answer = json.loads(result.stdout)
        covered = answer["covered"]
        commits = answer.get("commits", [])
        uncovered = answer.get("uncovered", [])
    except (ValueError, KeyError, TypeError, AttributeError):
        fail(f"agw review covered answered something unreadable: {result.stdout.strip()[:300]}")
    if covered is True:
        return
    by_sha = {c.get("sha"): c for c in commits if isinstance(c, dict)}
    lines = []
    for sha in uncovered:
        c = by_sha.get(sha, {})
        why = f"; open important {', '.join(c.get('findings') or [])}" if c.get("reason") == "open-important" else ""
        lines.append(f"  {str(sha)[:9]} {c.get('subject', '?')} (needs {c.get('required', '?')}: {c.get('rule', '?')}{why})")
    fail(
        f"{wave_name} is not fully reviewed ({start[:9]}..HEAD): uncovered commits —\n"
        + "\n".join(lines or ["  (agw named none)"])
        + "\nrun `/review` over the range (and dispose open findings), then retry"
    )


def outward_next_step(unchecked: list[str]) -> str | None:
    """The NEXT unchecked step's text if it names an outward-facing verb, else
    None. Only the next step — that is the contract the skill and the module
    docstring state ("the next step being outward-facing"), and it is what
    makes a wave like the estate chain's Wave 5 spawnable at all: its first
    steps are pure code, its last is an owner-authorized canary landing that
    the wave agent itself must stop and judge when it gets there. Scanning the
    whole wave (what this did until 2026-09-10) refused the spawn on a step
    three steps away and reported it as "the next step".
    """
    if not unchecked:
        return None
    return unchecked[0] if OUTWARD_RE.search(unchecked[0]) else None


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
    args = sys.argv[1:]
    # Orchestrated mode: a visible orchestrator tab spawns each wave on purpose and
    # owns merges/deploys itself, so the outward-facing keyword stop (a chain-mode
    # guard against a wave continuing into a deploy unattended) does not apply.
    orchestrated = "--orchestrated" in args
    args = [a for a in args if a != "--orchestrated"]
    if len(args) != 2:
        fail(f"usage: {sys.argv[0]} [--orchestrated] <repo-path> <plan-path-or-relative-plan-ref>")
    repo_path, plan_ref = args

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
        check_review_coverage(plan_repo, plan_path, prev["name"])

    hit = None if orchestrated else outward_next_step(active_wave["unchecked"])
    if hit:
        fail(
            f"{active_wave['name']}'s next step looks outward-facing, stop and hand back "
            f"to the human: {hit!r}"
        )


if __name__ == "__main__":
    main()
