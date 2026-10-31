#!/usr/bin/env python3
"""hc-reap — the janitor behind `rd reap` and com.jkrumm.hc-reap, on herdr-core.

Closes terminals whose agents are finished, and nothing else. A terminal is an agent's when it reports a
status (`terminal.list` `status`); shells, servers and finished terminals are not its business.

  close    the agent is done/idle for longer than REAP_IDLE_H hours (default 12), the checkout is clean and
           pushed, and no `active` wave in the repo's plan could own it
  close    a fan terminal (agent in a linked worktree that `rd fan` marked) whose branch is merged into
           origin's default branch (PR MERGED/CLOSED, or every commit patch-equal to the default, so a
           rebase merge counts) or was deleted on origin, with a clean tree and nothing unpushed. The agent
           must be done/idle; the idle age and an active wave in the repo's plan do not hold it back. Only
           inside ~/SourceRoot and ~/IuRoot
  message  the same terminal, but dirty or unpushed — the agent is told (once per 24 h), the terminal stays
  never    working/blocked/unknown agents, a checkout a working agent also uses, a terminal with live
           children, terminals whose cwd is not inside a git repo (the ~/SourceRoot design terminals), any
           terminal in a repo whose docs/waves/PLAN.md has an `active` wave (mother/lead/wave terminals)
           unless the merged-fan rule above applies, mother/lead/wave terminals (`wave <n>`, `*-mother`,
           `*-w<n>`) even then, a never-pushed branch (a fresh worker is not "merged"), the caller's own
           terminal (HC_TERMINAL_ID), terminals of a linked machine

Also stops `claude --bg` sessions older than 24 h whose state is blocked/idle/done (`claude stop` keeps the
conversation). --dry-run prints the plan and writes nothing. Every live action is one line in
~/Library/Logs/hc-reap.log. "Close" is `terminal.kill` then `terminal.rm`.

Idle age comes from the last timestamped record of the agent's Claude session transcript, found through the
`jk.claude.session` label hooks/hc-session-label.ts sets. An agent without the label or whose transcript
cannot be found has an unknown age and is never closed.

Never starts a core: `hc connect` STARTS one when none runs, so unless HC_SESSION is set (a scratch core)
com.jkrumm.herdr-core must be `state = running` in launchd, otherwise the terminal pass is skipped.
"""

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
LOG = os.path.join(HOME, "Library/Logs/hc-reap.log")
STATE = os.path.join(HOME, ".local/state/hc-reap/messaged.json")
MESSAGE_EVERY_S = 24 * 3600
BG_MAX_AGE_S = 24 * 3600
ACTIVE_RE = re.compile(r"<!--\s*status:\s*active\b")
FINISHED = {"done", "idle"}
FLEET_ROOTS = [os.path.join(HOME, "SourceRoot"), os.path.join(HOME, "IuRoot")]
# Terminals that own a wave or a fleet: never closed by the merged-fan rule, whatever their checkout says.
LEAD_LABEL_RE = re.compile(r"^(wave \d+|mother|lead|orchestrator)$", re.I)
LEAD_NAME_RE = re.compile(r"(-mother|-lead|-orchestrator|-w\d+)$", re.I)  # terminal names and tab names both
NET_TIMEOUT_S = 30
BG_STOPPABLE = {"blocked", "idle", "done"}
SESSION_LABEL = "jk.claude.session"
CORE_LABEL = "com.jkrumm.herdr-core"
HC = os.environ.get("HC_BIN") or "hc"


class HcError(Exception):
    pass


def sh(*cmd: str, cwd: str | None = None, env: dict | None = None, timeout: float | None = None) -> tuple[int, str]:
    """rc 124 and no output when `timeout` expires: callers treat that like any failure, i.e. keep."""
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, cwd=cwd, env=env, timeout=timeout)
    except subprocess.TimeoutExpired:
        return 124, ""
    return r.returncode, r.stdout


def core_running() -> bool:
    """True when it is safe to `hc connect`: a scratch HC_SESSION, or the launchd core is running."""
    if os.environ.get("HC_SESSION"):
        return True
    rc, out = sh("launchctl", "print", f"gui/{os.getuid()}/{CORE_LABEL}", timeout=10)
    return rc == 0 and re.search(r"^\s*state = running$", out, re.M) is not None


def hc_rpc(method: str, params: dict | None = None, timeout: float = NET_TIMEOUT_S) -> dict:
    """One JSON-RPC request on a short-lived `hc connect`. Raises HcError (also for 'no core running')."""
    if not core_running():
        raise HcError(f"{CORE_LABEL} is not running: not connecting (hc would start a core)")
    req = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}}) + "\n"
    try:
        r = subprocess.run([HC, "connect"], input=req, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise HcError(f"{method} timed out after {timeout:g}s")
    except OSError as e:
        raise HcError(f"hc not runnable: {e}")
    for line in r.stdout.splitlines():
        try:
            o = json.loads(line)
        except ValueError:
            continue
        if o.get("id") != 1:
            continue
        if "error" in o:
            err = o["error"] or {}
            kind = (err.get("data") or {}).get("kind") or err.get("message") or "error"
            raise HcError(f"{method}: {kind}")
        return o.get("result") or {}
    raise HcError(f"{method}: no answer from hc connect (rc={r.returncode})")


def list_terminals() -> list[dict]:
    return hc_rpc("terminal.list", {"all": True})["terminals"]


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
    except FileNotFoundError:
        return False
    except OSError:
        return True  # unreadable plan: unknown, so the terminal stays


TS_RE = re.compile(rb'"timestamp":"(\d{4}-\d\d-\d\dT[\d:.]+Z)"')


def idle_hours(session_id: str | None) -> float | None:
    """Hours since the last timestamped record of the agent's transcript. Not the file mtime:
    Claude rewrites trailing metadata on resume, which makes a week-old session look fresh."""
    if not session_id:
        return None
    hits = glob.glob(os.path.join(HOME, ".claude*/projects/*", f"{session_id}.jsonl"))
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


def foreground_cwd(t: dict) -> str:
    return ((t.get("foreground") or {}).get("cwd")) or t.get("cwd") or ""


def tstate(t: dict) -> str:
    return (t.get("status") or {}).get("state") or "unknown"


def is_agent(t: dict) -> bool:
    return t.get("state") == "live" and t.get("status") is not None and "/" not in t["address"]


def tab_name(t: dict) -> str:
    """The tab part of the app's `where` label (`proj / tab`), which is also what the app shows."""
    return (t.get("labels", {}).get("where") or "").split(" / ", 1)[-1]


def recheck(t: dict, tops: set[str], judged: dict[str, str] | None) -> str | None:
    """Why the terminal must NOT close after all, from one fresh roster read right before the close (the plan
    was made minutes ago), or None. It is still the same live terminal and still done/idle; no other live
    agent has joined its checkout and nothing hangs under it; for a merged-fan close (`judged`: checkout ->
    HEAD sha judged) the tree is still clean and HEAD has not moved. An unreadable roster is a reason to keep."""
    try:
        now = list_terminals()
    except HcError:
        return "roster unreadable"
    me = next((x for x in now if x["address"] == t["address"]), None)
    if not me or me.get("created_ms") != t.get("created_ms") or me.get("state") != "live":
        return "the terminal changed"
    if tstate(me) not in FINISHED:
        return "agent status changed"
    for x in now:
        if x.get("parent") == me["address"] and x.get("state") == "live":
            return "a child terminal appeared"
        r = repo_roots(foreground_cwd(x))
        if x["address"] != me["address"] and is_agent(x) and tstate(x) not in FINISHED and r and r[0] in tops:
            return "another agent is working in the checkout"
    for top, head in (judged or {}).items():
        if git(top, "status", "--porcelain")[1].strip():
            return "the checkout became dirty"
        if git(top, "rev-parse", "HEAD")[1].strip() != head:
            return "HEAD moved"
    return None


def close_terminal(j: Journal, t: dict, tops: set[str], judged: dict[str, str] | None = None, **kv: str) -> None:
    addr = t["address"]
    if not j.dry and (why := recheck(t, tops, judged)):
        j.line("close-skipped", terminal=addr, why=f'"{why} before the close"')
        return
    j.line("close", terminal=addr, **kv)
    if j.dry:
        return
    try:
        hc_rpc("terminal.kill", {"terminal": addr, "caller": "hc-reap"})
        hc_rpc("terminal.rm", {"terminal": addr, "caller": "hc-reap"})
    except HcError as e:
        j.line("close-failed", terminal=addr, out=json.dumps(str(e)[:200]))


def merged_terminal_reason(t: dict, busy_checkouts: set[str]) -> tuple[str | None, str, str]:
    """(reason, kept-why, judged HEAD): why this done/idle terminal can close now because its fan branch is merged
    or gone. Independent of idle age and of any active wave. The kept-why is empty for a terminal the rule never
    applied to (not a fan worktree, a lead terminal, outside the fleets)."""
    if LEAD_LABEL_RE.match(tab_name(t).strip()) or LEAD_NAME_RE.search(tab_name(t).strip()) \
            or LEAD_NAME_RE.search(t.get("name") or ""):
        return None, "", ""
    cwd = foreground_cwd(t)
    roots = repo_roots(cwd)
    if not roots or not any(inside(roots[1], f) for f in FLEET_ROOTS):
        return None, "", ""
    if roots[0] in busy_checkouts:
        return None, "", ""
    reason, why, head = merged_fan(cwd)
    return reason, ("" if why == "not a fan worktree" else why), head


def reap_terminals(idle_h: float, j: Journal) -> None:
    terminals = list_terminals()
    agents = [t for t in terminals if is_agent(t)]
    own = os.environ.get("HC_TERMINAL_ID", "")
    # A checkout another live agent is working in is not this terminal's to clean up: its dirty files are
    # that agent's, and nudging an idle sibling to commit them would be wrong.
    busy_checkouts = set()
    for a in agents:
        if tstate(a) not in FINISHED and (r := repo_roots(foreground_cwd(a))):
            busy_checkouts.add(r[0])
    parents = {t["parent"] for t in terminals if t.get("parent") and t.get("state") == "live"}
    messaged = load_messaged()
    now = time.time()

    kept: list[str] = []
    for t in agents:
        addr = t["address"]
        name = f"{addr} '{t.get('name') or tab_name(t)}'"
        why = None
        if addr == own:
            why = "caller's own terminal"
        elif addr in parents:
            why = "has live child terminals"
        elif tstate(t) not in FINISHED:
            why = "agent " + tstate(t)
        if why:
            kept.append(f"{name}: {why}")
            continue

        done_reason, fan_why, fan_head = merged_terminal_reason(t, busy_checkouts)
        cwd = foreground_cwd(t)
        roots = repo_roots(cwd)
        tops = {roots[0]} if roots else set()
        if done_reason:
            close_terminal(j, t, tops, {roots[0]: fan_head}, repo=os.path.basename(cwd), why=f'"{done_reason}"',
                           label=f'"{tab_name(t)}"')
            continue
        fan_note = f" [merged-fan rule: {fan_why}]" if fan_why else ""

        age = idle_hours((t.get("labels") or {}).get(SESSION_LABEL))
        if age is None:
            kept.append(f"{name}: idle age unknown (no session label or transcript){fan_note}")
            continue
        if age <= idle_h:
            kept.append(f"{name}: {tstate(t)} {age:.1f}h <= {idle_h:g}h{fan_note}")
            continue

        if roots and roots[0] in busy_checkouts:
            kept.append(f"{name}: checkout shared with a working agent{fan_note}")
            continue
        if not roots:
            kept.append(f"{name}: cwd is not a git repo{fan_note}")
            continue
        if any(active_wave(r) for r in set(roots)):
            kept.append(f"{name}: repo plan has an active wave{fan_note}")
            continue
        problem = checkout_problem(cwd)
        repo = os.path.basename(cwd)
        if problem:
            detail = f"{repo}: {problem}"
            kept.append(f"{name}: {detail}{fan_note}")
            key = f"{addr}:{t.get('created_ms')}"
            if now - messaged.get(key, 0) < MESSAGE_EVERY_S:
                continue
            if j.dry:
                j.line("message", terminal=addr, repo=repo, reason=f'"{detail}"')
                continue
            text = (f"hc-reap: this terminal has been {tstate(t)} for {age:.0f}h but its checkout has "
                    f"{detail}. Commit and push, or leave a note why not; the terminal stays open until it is clean and pushed.")
            try:  # `if` makes the send a no-op unless the agent is still in the state it was judged in
                hc_rpc("terminal.send", {"terminal": addr, "text": text, "if": tstate(t), "caller": "hc-reap"})
            except HcError as e:
                j.line("message-failed", terminal=addr, repo=repo, out=json.dumps(str(e)[:160]))
                continue
            j.line("message", terminal=addr, repo=repo, reason=f'"{detail}"')
            messaged[key] = now
            save_messaged(messaged)
            continue

        close_terminal(j, t, tops, repo=repo, idle=f"{age:.0f}h", label=f'"{tab_name(t)}"')

    if not j.dry:
        save_messaged({k: v for k, v in messaged.items() if k.startswith('bg:') or now - v < 7 * 86400})
    print(f"kept {len(kept)} terminal(s) of {len(agents)} agent(s):")
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
            print("another hc-reap run holds the lock; exiting")
            return
    j = Journal(args.dry_run)
    print(f"hc-reap {'DRY RUN ' if args.dry_run else ''}idle>{idle_h:g}h")
    try:
        reap_terminals(idle_h, j)
    except HcError as e:  # a stopped core is the health check's to report, not a reason to fail this job
        print(f"terminal pass skipped: {e}")
    reap_bg(j)
    if not args.dry_run:
        j.line("run-complete", idle_h=f"{idle_h:g}")


if __name__ == "__main__":
    main()
