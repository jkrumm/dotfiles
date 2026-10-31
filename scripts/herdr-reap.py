#!/usr/bin/env python3
"""herdr-reap — the janitor behind `rd reap` and com.jkrumm.herdr-reap.

Closes herdr tabs whose agents are finished, and nothing else:

  close    every agent in the tab is done/idle for longer than REAP_IDLE_H hours (default 12),
           the checkout is clean and pushed, and no `active` wave in the repo's plan could own it
  close    a fan tab (agent in a linked worktree under <repo>/.claude/worktrees, or one `rd fan` marked)
           whose branch is merged into origin's default branch (PR MERGED/CLOSED, or every commit
           patch-equal to the default, so a rebase merge counts) or was deleted on origin, with a clean
           tree and nothing unpushed. The agent must be done/idle; the idle age and an active wave
           in the repo's plan do not hold it back. Only inside ~/SourceRoot and ~/IuRoot
  message  the same tab, but dirty or unpushed — the agent is told (once per 24 h), the tab stays
  never    working/blocked/unknown agents, a checkout a working agent also uses, tabs holding a non-agent pane (a shell or server would
           die with it), tabs whose cwd is not inside a git repo (the ~/SourceRoot design tabs),
           any tab in a repo whose docs/waves/PLAN.md has an `active` wave (mother/lead/wave tabs) unless the
           merged-fan rule above applies, mother/lead/wave tabs (`wave <n>`, `*-mother`, `*-w<n>`) even then,
           a never-pushed branch (a fresh worker is not "merged"), the caller's own tab

Also stops `claude --bg` sessions older than 24 h whose state is blocked/idle/done (`claude stop` keeps the
conversation). --dry-run prints the plan and writes nothing. Every live action is one line in
~/Library/Logs/herdr-reap.log.

Idle age comes from the last timestamped record of the agent's Claude session transcript. An agent whose
transcript cannot be found has an unknown age and is never closed.
"""

# TODO(Wave 7): drop classic (scripts/hc-reap.py is the herdr-core port and carries on)
import argparse
import calendar
import fcntl
import glob
import json
import os
import re
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
LOG = os.path.join(HOME, "Library/Logs/herdr-reap.log")
STATE = os.path.join(HOME, ".local/state/herdr-reap/messaged.json")
MESSAGE_EVERY_S = 24 * 3600
BG_MAX_AGE_S = 24 * 3600
ACTIVE_RE = re.compile(r"<!--\s*status:\s*active\b")
FINISHED = {"done", "idle"}
FLEET_ROOTS = [os.path.join(HOME, "SourceRoot"), os.path.join(HOME, "IuRoot")]
# Tabs that own a wave or a fleet: never closed by the merged-fan rule, whatever their checkout says.
LEAD_LABEL_RE = re.compile(r"^(wave \d+|mother|lead|orchestrator)$", re.I)
LEAD_NAME_RE = re.compile(r"(-mother|-lead|-orchestrator|-w\d+)$", re.I)  # agent names and tab labels both
NET_TIMEOUT_S = 30
BG_STOPPABLE = {"blocked", "idle", "done"}


def sh(*cmd: str, cwd: str | None = None, env: dict | None = None, timeout: float | None = None) -> tuple[int, str]:
    """rc 124 and no output when `timeout` expires: callers treat that like any failure, i.e. keep."""
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, cwd=cwd, env=env, timeout=timeout)
    except subprocess.TimeoutExpired:
        return 124, ""
    return r.returncode, r.stdout


def herdr_json(*args: str) -> dict:
    rc, out = sh("herdr", *args)
    if rc != 0:
        sys.exit(f"herdr {' '.join(args)} failed")
    return json.loads(out)["result"]


def git(cwd: str, *args: str) -> tuple[int, str]:
    return sh("git", "-C", cwd, *args)


def repo_roots(cwd: str) -> tuple[str, str] | None:
    """(this checkout's toplevel, the main repo's root) or None outside a git repo."""
    if not os.path.isdir(cwd):
        return None
    rc, top = git(cwd, "rev-parse", "--show-toplevel")
    if rc != 0:
        return None
    rc, common = git(cwd, "rev-parse", "--path-format=absolute", "--git-common-dir")
    main = os.path.dirname(common.strip()) if rc == 0 and common.strip().endswith(".git") else top.strip()
    return top.strip(), main


def active_wave(root: str) -> bool:
    try:
        with open(os.path.join(root, "docs/waves/PLAN.md")) as f:
            return any(ACTIVE_RE.search(line) for line in f)
    except OSError:
        return False


TS_RE = re.compile(rb'"timestamp":"(\d{4}-\d\d-\d\dT[\d:.]+Z)"')


def idle_hours(session_id: str | None) -> float | None:
    """Hours since the last timestamped record of the agent's transcript. Not the file mtime:
    Claude rewrites trailing metadata on resume, which makes a week-old session look fresh."""
    if not session_id:
        return None
    hits = glob.glob(os.path.join(HOME, ".claude/projects/*", f"{session_id}.jsonl"))
    if not hits:
        return None
    with open(hits[0], "rb") as f:
        f.seek(0, os.SEEK_END)
        f.seek(max(0, f.tell() - 262144))
        stamps = TS_RE.findall(f.read())
    if not stamps:
        return None
    last = calendar.timegm(time.strptime(stamps[-1].decode()[:19], "%Y-%m-%dT%H:%M:%S"))
    return (time.time() - last) / 3600


def checkout_problem(cwd: str) -> str | None:
    rc, out = git(cwd, "status", "--porcelain")
    if rc != 0:
        return "git status failed"
    if out.strip():
        return f"{len(out.strip().splitlines())} uncommitted path(s)"
    rc, out = git(cwd, "rev-list", "--count", "@{u}..HEAD")
    if rc != 0:
        return "no upstream branch"
    if out.strip() != "0":
        return f"{out.strip()} unpushed commit(s)"
    return None


def inside(path: str, root: str) -> bool:
    path, root = os.path.realpath(path), os.path.realpath(root)
    return path == root or path.startswith(root + os.sep)


def is_fan_checkout(top: str, main: str) -> bool:
    """A linked worktree `rd fan` made: it carries fan-list.sh's <git-dir>/rd-fan marker. The path alone
    proves nothing - native Claude and review worktrees live under .claude/worktrees too."""
    if os.path.realpath(top) == os.path.realpath(main):
        return False
    rc, gd = git(top, "rev-parse", "--absolute-git-dir")
    return rc == 0 and os.path.exists(os.path.join(gd.strip(), "rd-fan"))


def origin_default(cwd: str) -> str | None:
    rc, out = git(cwd, "symbolic-ref", "-q", "--short", "refs/remotes/origin/HEAD")
    if rc == 0 and out.strip():
        return out.strip()
    for b in ("origin/master", "origin/main"):
        if git(cwd, "rev-parse", "-q", "--verify", b)[0] == 0:
            return b
    return None


_fetched: dict[str, bool] = {}


def fetch_origin(main: str) -> bool:
    """One fetch attempt per repo per run, failures included (a dead remote costs one 90 s timeout, not one
    per tab). Explicitly --no-prune (fetch.prune config must not change this): a branch deleted on origin
    keeps its last-known remote-tracking tip, which 'nothing unpushed' is judged against."""
    if main not in _fetched:
        rc, _ = sh("git", "-C", main, "fetch", "-q", "--no-prune", "origin", timeout=90)
        _fetched[main] = rc == 0
    return _fetched[main]


def pr_heads(cwd: str, branch: str) -> list[tuple[str, str, str]] | None:
    """(state, head sha, base branch) of every PR ever opened from `branch` - MERGED/CLOSED/OPEN. [] when the remote is
    not GitHub or gh has no answer; None when gh timed out (the caller keeps the tab)."""
    rc, url = git(cwd, "config", "--get", "remote.origin.url")
    if rc != 0 or "github.com" not in url:
        return []
    rc, out = sh("gh", "pr", "list", "--head", branch, "--state", "all", "--json", "state,headRefOid,baseRefName",
                 cwd=cwd, timeout=NET_TIMEOUT_S)
    if rc == 124:
        return None
    try:
        return [(p["state"], p["headRefOid"], p["baseRefName"]) for p in json.loads(out)] if rc == 0 else []
    except (ValueError, KeyError, TypeError):
        return []


def is_ancestor(cwd: str, a: str, b: str) -> bool:
    """a is b or reachable from b (missing objects: False)."""
    return git(cwd, "merge-base", "--is-ancestor", a, b)[0] == 0


def patch_merged(cwd: str, default: str, ref: str) -> bool:
    """Every commit of `ref` has a patch-equal twin on `default` (rebase and cherry-pick merges), and `ref`
    adds no merge commit: cherry cannot see a merge commit's content."""
    rc, cherry = git(cwd, "cherry", default, ref)
    if rc != 0 or any(l.startswith("+") for l in cherry.splitlines()):
        return False
    rc, n = git(cwd, "rev-list", "--merges", "--count", f"{default}..{ref}")
    return rc == 0 and n.strip() == "0"


def commits_ahead(cwd: str, default: str) -> int:
    rc, n = git(cwd, "rev-list", "--count", f"{default}..HEAD")
    return int(n) if rc == 0 and n.strip().isdigit() else 0


def merged_fan(cwd: str) -> tuple[str | None, str, str]:
    """(reason this fan checkout's branch is finished on origin or None, why it is kept otherwise, the HEAD
    sha judged). Cheap local checks first; the network is touched only for a clean, published fan branch."""
    roots = repo_roots(cwd)
    if not roots or not is_fan_checkout(*roots):
        return None, "not a fan worktree", ""
    top, main = roots
    rc, br = git(top, "symbolic-ref", "-q", "--short", "HEAD")
    branch = br.strip()
    if rc != 0 or not branch:
        return None, "detached HEAD", ""
    rc, out = git(top, "status", "--porcelain")
    if rc != 0 or out.strip():
        return None, "uncommitted changes", ""
    # Published = this branch once reached origin. A fresh worker's branch is at the base and was never
    # pushed: it looks patch-merged and absent on origin, and is neither.
    tip = f"refs/remotes/origin/{branch}"
    has_tip = git(top, "rev-parse", "-q", "--verify", tip)[0] == 0
    if not (has_tip or git(top, "config", f"branch.{branch}.merge")[0] == 0):
        return None, "branch never pushed", ""
    default = origin_default(top)
    if not default:
        return None, "no origin default branch", ""
    if branch == default.split("/", 1)[1]:
        return None, "on the default branch", ""
    if not fetch_origin(main):
        return None, "fetch failed", ""
    has_tip = git(top, "rev-parse", "-q", "--verify", tip)[0] == 0  # the fetch may have created it
    head = git(top, "rev-parse", "HEAD")[1].strip()
    rc, ls = sh("git", "-C", top, "ls-remote", "--heads", "origin", f"refs/heads/{branch}", timeout=NET_TIMEOUT_S)
    if rc != 0:
        return None, "origin unreachable", ""
    on_origin = bool(ls.strip())
    prs = pr_heads(top, branch)
    if prs is None:
        return None, "gh timed out", ""

    # A PR found by branch name counts only if HEAD is inside its head: a stale PR from an earlier use of
    # the name never closes a fresh worker. A MERGED one must have landed on the default branch (a stacked
    # PR merged into another feature branch has not). Then the branch must hold nothing beyond that head,
    # and a PR closed unmerged does not retire a branch that is still live. A CLOSED PR whose branch is
    # gone is abandonment: closing that tab is intended. No fallback on this path.
    default_name = default.split("/", 1)[1]
    for state, pr_head, base in prs:
        if state not in ("MERGED", "CLOSED") or not is_ancestor(top, "HEAD", pr_head):
            continue
        if state == "MERGED" and base != default_name:
            continue
        if on_origin and (state != "MERGED" or not has_tip or not is_ancestor(top, tip, pr_head)):
            return None, "branch is live on origin", ""
        return f"PR {state.lower()}", "", head

    # The patch-equal paths need a commit of the branch's own, like fan-list.sh's `fresh`: a worker that
    # pushed at the base and sits idle is patch-equal to everything and merged into nothing.
    own = commits_ahead(top, default) > 0
    unpushed_zero = has_tip and git(top, "rev-list", "--count", f"{tip}..HEAD")[1].strip() == "0"
    if not on_origin:
        # Deleted on origin: nothing unpushed = HEAD within the last-known origin tip, else all patch-equal.
        if unpushed_zero or (own and patch_merged(top, default, "HEAD")):
            return "branch deleted on origin", "", head
        return None, "unpushed commits", ""
    if not own:
        return None, "fresh: no commit of its own", ""
    if unpushed_zero and patch_merged(top, default, "HEAD") and patch_merged(top, default, tip):
        return f"merged into {default}", "", head
    return None, "branch is live on origin", ""


class Journal:
    def __init__(self, dry: bool):
        self.dry = dry

    def line(self, action: str, **kv: str) -> None:
        text = " ".join([action] + [f"{k}={v}" for k, v in kv.items()])
        if self.dry:
            print(f"  would {text}")
            return
        print(f"  {text}")
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        with open(LOG, "a") as f:
            f.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S%z')} {text}\n")


def load_messaged() -> dict:
    try:
        with open(STATE) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_messaged(m: dict) -> None:
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    tmp = f"{STATE}.{os.getpid()}"
    with open(tmp, "w") as f:
        json.dump(m, f)
    os.replace(tmp, STATE)


def recheck(tab: str, panes: list[str], tops: set[str], judged: dict[str, str] | None) -> str | None:
    """Why the tab must NOT close after all, from one fresh roster read right before the close (the plan was
    made minutes ago), or None. The tab's pane set is unchanged and every pane is still done/idle; no other
    live agent has joined its checkout; for a merged-fan close (`judged`: checkout -> HEAD sha judged) the
    tree is still clean and HEAD has not moved. An unreadable roster or a timeout is a reason to keep."""
    rc, out = sh("herdr", "pane", "list", timeout=NET_TIMEOUT_S)
    rc2, out2 = sh("herdr", "agent", "list", timeout=NET_TIMEOUT_S)
    if rc != 0 or rc2 != 0:
        return "roster unreadable"
    try:
        now_panes = {p["pane_id"] for p in json.loads(out)["result"]["panes"] if p["tab_id"] == tab}
        agents = json.loads(out2)["result"]["agents"]
    except (ValueError, KeyError, TypeError):
        return "roster unreadable"
    if now_panes != set(panes):
        return "the tab's panes changed"
    status = {a["pane_id"]: a["agent_status"] for a in agents}
    if any(status.get(p) not in FINISHED for p in panes):
        return "agent status changed"
    for a in agents:
        r = repo_roots(a.get("cwd") or "")
        if a["pane_id"] not in panes and a["agent_status"] not in FINISHED and r and r[0] in tops:
            return "another agent is working in the checkout"
    for top, head in (judged or {}).items():
        if git(top, "status", "--porcelain")[1].strip():
            return "the checkout became dirty"
        if git(top, "rev-parse", "HEAD")[1].strip() != head:
            return "HEAD moved"
    return None


def close_tab(j: Journal, tab: str, panes: list[str], tops: set[str], judged: dict[str, str] | None = None,
              **kv: str) -> None:
    if not j.dry and (why := recheck(tab, panes, tops, judged)):
        j.line("close-skipped", tab=tab, why=f'"{why} before the close"')
        return
    j.line("close", tab=tab, panes=",".join(panes), **kv)
    if j.dry:
        return
    rc, out = sh("herdr", "tab", "close", tab)
    if rc != 0 or '"error"' in out:
        j.line("close-failed", tab=tab, out=out.strip()[:200])


def merged_tab_reason(tab: str, label: str, members: list[dict], busy_checkouts: set[str]) -> tuple[str | None, str, str]:
    """(reason, kept-why, judged HEAD): why this tab (all its agents done/idle, no other pane) can close now
    because its fan branch is merged or gone. Independent of idle age and of any active wave. The kept-why is
    empty for a tab the rule never applied to (not a fan worktree, a lead tab, outside the fleets)."""
    if LEAD_LABEL_RE.match(label.strip()) or LEAD_NAME_RE.search(label.strip()) \
            or any(LEAD_NAME_RE.search(a.get("name") or "") for a in members):
        return None, "", ""
    cwds = {a.get("cwd") or "" for a in members}
    if len(cwds) != 1:
        return None, "", ""
    cwd = next(iter(cwds))
    roots = repo_roots(cwd)
    if not roots or not any(inside(roots[1], f) for f in FLEET_ROOTS):
        return None, "", ""
    if roots[0] in busy_checkouts:
        return None, "", ""
    reason, why, head = merged_fan(cwd)
    return reason, ("" if why == "not a fan worktree" else why), head


def reap_tabs(idle_h: float, j: Journal) -> None:
    panes = herdr_json("pane", "list")["panes"]
    agents = {a["pane_id"]: a for a in herdr_json("agent", "list")["agents"]}
    labels = {t["tab_id"]: t.get("label", "") for t in herdr_json("tab", "list")["tabs"]}
    own = os.environ.get("HERDR_PANE_ID", "")
    # A checkout another live agent is working in is not this tab's to clean up: its dirty files are
    # that agent's, and nudging an idle sibling to commit them would be wrong.
    busy_checkouts = set()
    for a in agents.values():
        if a["agent_status"] not in FINISHED and (r := repo_roots(a.get("cwd") or "")):
            busy_checkouts.add(r[0])
    messaged = load_messaged()
    now = time.time()

    by_tab: dict[str, list[dict]] = {}
    for p in panes:
        by_tab.setdefault(p["tab_id"], []).append(p)

    kept: list[str] = []
    for tab, tpanes in by_tab.items():
        members = [agents[p["pane_id"]] for p in tpanes if p["pane_id"] in agents]
        if not members:
            continue  # shell-only tab: not an agent's
        name = f"{tab} '{labels.get(tab, '')}'"
        why = None
        if any(p["pane_id"] not in agents for p in tpanes):
            why = "also holds a non-agent pane"
        elif any(p["pane_id"] == own for p in tpanes):
            why = "caller's own tab"
        elif any(a["agent_status"] not in FINISHED for a in members):
            why = "agent " + "/".join(sorted({a["agent_status"] for a in members}))
        if why:
            kept.append(f"{name}: {why}")
            continue

        done_reason, fan_why, fan_head = merged_tab_reason(tab, labels.get(tab, ""), members, busy_checkouts)
        tops = {r[0] for a in members if (r := repo_roots(a.get("cwd") or ""))}
        if done_reason:
            repo = os.path.basename(next(iter({a.get("cwd") or "" for a in members})))
            close_tab(j, tab, [p["pane_id"] for p in tpanes], tops, {next(iter(tops)): fan_head},
                      repo=repo, why=f'"{done_reason}"', label=f'"{labels.get(tab, "")}"')
            continue
        fan_note = f" [merged-fan rule: {fan_why}]" if fan_why else ""

        ages = [idle_hours((a.get("agent_session") or {}).get("value")) for a in members]
        if any(a is None for a in ages):
            kept.append(f"{name}: idle age unknown (no session transcript){fan_note}")
            continue
        age = min(ages)  # type: ignore[type-var]
        if age <= idle_h:
            kept.append(f"{name}: {'/'.join(a['agent_status'] for a in members)} {age:.1f}h <= {idle_h:g}h{fan_note}")
            continue

        cwds = {a.get("cwd") or "" for a in members}
        if any((r := repo_roots(c)) and r[0] in busy_checkouts for c in cwds):
            kept.append(f"{name}: checkout shared with a working agent{fan_note}")
            continue
        roots = [repo_roots(c) for c in cwds]
        if any(r is None for r in roots):
            kept.append(f"{name}: cwd is not a git repo{fan_note}")
            continue
        if any(active_wave(r) for pair in roots for r in set(pair)):  # type: ignore[union-attr]
            kept.append(f"{name}: repo plan has an active wave{fan_note}")
            continue
        problems = [(c, checkout_problem(c)) for c in sorted(cwds)]
        problems = [(c, p) for c, p in problems if p]
        repo = os.path.basename(next(iter(cwds)))
        if problems:
            detail = "; ".join(f"{os.path.basename(c)}: {p}" for c, p in problems)
            kept.append(f"{name}: {detail}{fan_note}")
            for a in members:
                key = a["pane_id"]
                if now - messaged.get(key, 0) < MESSAGE_EVERY_S:
                    continue
                if j.dry:
                    j.line("message", tab=tab, pane=key, repo=repo, reason=f'"{detail}"')
                    continue
                rc, out = sh("herdr", "agent", "prompt", key,
                             f"herdr-reap: this tab has been {a['agent_status']} for {age:.0f}h but its checkout has "
                             f"{detail}. Commit and push, or leave a note why not; the tab stays open until it is clean and pushed.")
                if rc != 0 or '"error"' in out:  # herdr reports a rejected prompt in the body with exit 0
                    j.line("message-failed", tab=tab, pane=key, repo=repo, out=json.dumps(out.strip()[:160]))
                    continue
                j.line("message", tab=tab, pane=key, repo=repo, reason=f'"{detail}"')
                messaged[key] = now
                save_messaged(messaged)
            continue

        close_tab(j, tab, [p["pane_id"] for p in tpanes], tops, repo=repo,
                  idle=f"{age:.0f}h", label=f'"{labels.get(tab, "")}"')

    if not j.dry:
        save_messaged({k: v for k, v in messaged.items() if k.startswith('bg:') or now - v < 7 * 86400})
    print(f"kept {len(kept)} tab(s):")
    for k in kept:
        print(f"  keep {k}")


def account_envs() -> list[dict]:
    """One process env per enabled Claude account (config/claude-accounts.json): the background daemon
    is bound to one identity, so `claude agents` / `claude stop` run once per account."""
    registry = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "config", "claude-accounts.json")
    try:
        with open(registry) as f:
            dirs = [a.get("dir") for a in json.load(f)["accounts"].values() if a.get("enabled")]
    except Exception as e:
        print(f"claude-accounts registry unreadable ({e}); bg leftovers checked for the default account only")
        dirs = [None]
    envs = []
    for d in dirs:
        env = dict(os.environ)
        env.pop("CLAUDE_CONFIG_DIR", None)
        if d is not None:
            for k in ("CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY"):
                env.pop(k, None)  # credentials for the default account must not follow another account's dir
            env["CLAUDE_CONFIG_DIR"] = os.path.expanduser(d)
        envs.append(env)
    return envs


def reap_bg(j: Journal) -> None:
    for env in account_envs():
        reap_bg_account(j, env)


def reap_bg_account(j: Journal, env: dict) -> None:
    r = subprocess.run(["claude", "agents", "--json"], capture_output=True, text=True, env=env)
    if r.returncode != 0:
        print(f"claude agents --json failed ({env.get('CLAUDE_CONFIG_DIR', 'default account')}, rc={r.returncode}): "
              f"{(r.stderr or r.stdout).strip()[:160]!r}; skipping its bg leftovers")
        return
    out = r.stdout
    now = time.time() * 1000
    seen = load_messaged()
    for a in json.loads(out):
        # Only a state known to be finished is stopped; an unknown or missing one is left alone.
        if a.get("kind") != "background" or (a.get("state") or a.get("status")) not in BG_STOPPABLE:
            continue
        if now - a["startedAt"] < BG_MAX_AGE_S * 1000:
            continue
        key = f"bg:{a['id']}"
        if key in seen:
            continue  # stop already failed once (daemon gone): the record stays, logging it every run is noise
        desc = dict(id=a["id"], name=f'"{a.get("name", "")}"', state=str(a.get("state")),
                    cwd=a.get("cwd", ""), age=f"{(now - a['startedAt']) / 3.6e6:.0f}h")
        if j.dry:
            j.line("bg-stop", **desc)
            continue
        rc, _ = sh("claude", "stop", a["id"], env=env)
        if rc == 0:
            j.line("bg-stop", **desc)
        else:
            j.line("bg-stop-failed", **desc, why='"claude stop could not reach the background daemon; record left in place"')
            seen[key] = now
            save_messaged(seen)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dry-run", action="store_true", help="print the plan, change nothing")
    args = ap.parse_args()
    idle_h = float(os.environ.get("REAP_IDLE_H", "12"))
    lock = None
    if not args.dry_run:  # a dry run writes nothing, so it neither needs nor blocks on the lock
        os.makedirs(os.path.dirname(STATE), exist_ok=True)
        lock = open(STATE + ".lock", "w")
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            print("another herdr-reap run holds the lock; exiting")
            return
    j = Journal(args.dry_run)
    print(f"herdr-reap {'DRY RUN ' if args.dry_run else ''}idle>{idle_h:g}h")
    reap_tabs(idle_h, j)
    reap_bg(j)
    if not args.dry_run:
        j.line("run-complete", idle_h=f"{idle_h:g}")


if __name__ == "__main__":
    main()
