#!/usr/bin/env python3
"""hc-reap — the janitor behind `rd reap` and com.jkrumm.hc-reap, on herdr-core.

Closes terminals whose agents are finished, and nothing else. A terminal is an agent's when it reports a
status (`terminal.list` `status`); shells, servers and finished terminals are not its business.

  close    the agent is done/idle for longer than REAP_IDLE_H hours (default 12), and the checkout is clean
           and pushed
  message  the same terminal, but dirty or unpushed — the agent is told (once per 24 h), the terminal stays
  close    an orphaned shell: a live terminal with no status, no name, no `factory.key` and no Claude session label,
           whose program and foreground program are a login shell, with no children, whose `turn` (it rises as
           commands run) hc-reap has seen unchanged for 7 days (remembered per terminal in its state file; a first
           sighting starts the clock, so nothing closes in the first 7 days).
           Never a `plan:` tab, a named terminal, one running a program, or the caller's own
  never    a terminal with no `factory.key` label (the owner's own sessions) and a `plan:<repo>` one (the factory's
           planning tab), before any other rule, whatever their age or state (the one exception: the
           orphaned-shell rule above, which needs a shell whose `turn` has not moved for 7 days)
  never    working/blocked/unknown agents, a checkout a working agent also uses, a terminal with live
           children, terminals whose cwd is not inside a git repo (the ~/SourceRoot design terminals), the
           caller's own terminal (HC_TERMINAL_ID), terminals of a linked machine

Also stops `claude --bg` sessions older than 24 h whose state is blocked/idle/done (`claude stop` keeps the
conversation). --dry-run prints the plan and writes nothing. Every live action is one line in
~/Library/Logs/hc-reap.log. "Close" is `terminal.kill` then `terminal.rm`.

Idle age comes from the last timestamped record of the agent's Claude session transcript, found through the
`jk.claude.session` label hooks/hc-session-label.ts sets. An agent without the label or whose transcript
cannot be found has an unknown age and is never closed.

Never starts a core: `hc connect` STARTS one when none runs, so unless HC_SESSION is set (a scratch core)
scripts/lib/core-up.sh must say a launchd-born core answers, otherwise the terminal pass is skipped.
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
FINISHED = {"done", "idle"}
SHELLS = {"zsh", "bash", "sh", "dash", "fish"}
SHELL_IDLE_S = 7 * 24 * 3600
NET_TIMEOUT_S = 30
BG_STOPPABLE = {"blocked", "idle", "done"}
SESSION_LABEL = "jk.claude.session"
FACTORY_KEY_LABEL = "factory.key"
PLAN_KEY_PREFIX = "plan:"
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
    """True when it is safe to `hc connect`: a scratch HC_SESSION, or lib/core-up.sh says a launchd-born core answers."""
    if os.environ.get("HC_SESSION"):
        return True
    core_up = os.environ.get("CORE_UP_SH") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib", "core-up.sh")
    rc, _ = sh("bash", core_up, timeout=10)
    return rc == 0


def hc_rpc(method: str, params: dict | None = None, timeout: float = NET_TIMEOUT_S) -> dict:
    """One JSON-RPC request on a short-lived `hc connect`. Raises HcError (also for 'no core running')."""
    if not core_running():
        raise HcError("no launchd-born core answers (scripts/lib/core-up.sh): not connecting (hc would start a core)")
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


def protected_by_label(t: dict) -> str | None:
    """Why the factory's labels put this terminal out of the janitor's reach, or None. Only terminals the factory
    spawned (a `factory.key` label) are reaped; `plan:<repo>` tabs are its planning tabs, never closed."""
    key = (t.get("labels") or {}).get(FACTORY_KEY_LABEL)
    if not key:
        return "no factory.key label (not factory-spawned)"
    if key.startswith(PLAN_KEY_PREFIX):
        return f"plan tab ({key})"
    return None


def recheck(t: dict, tops: set[str]) -> str | None:
    """Why the terminal must NOT close after all, from one fresh roster read right before the close (the plan
    was made minutes ago), or None. It is still the same live terminal and still done/idle; no other live
    agent has joined its checkout and nothing hangs under it. An unreadable roster is a reason to keep."""
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
    return None


def close_terminal(j: Journal, t: dict, tops: set[str], **kv: str) -> None:
    addr = t["address"]
    if not j.dry and (why := recheck(t, tops)):
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
        why = protected_by_label(t)  # first: before any other rule
        if why is None and addr == own:
            why = "caller's own terminal"
        elif why is None and addr in parents:
            why = "has live child terminals"
        elif why is None and tstate(t) not in FINISHED:
            why = "agent " + tstate(t)
        if why:
            kept.append(f"{name}: {why}")
            continue

        cwd = foreground_cwd(t)
        roots = repo_roots(cwd)
        tops = {roots[0]} if roots else set()

        age = idle_hours((t.get("labels") or {}).get(SESSION_LABEL))
        if age is None:
            kept.append(f"{name}: idle age unknown (no session label or transcript)")
            continue
        if age <= idle_h:
            kept.append(f"{name}: {tstate(t)} {age:.1f}h <= {idle_h:g}h")
            continue

        if roots and roots[0] in busy_checkouts:
            kept.append(f"{name}: checkout shared with a working agent")
            continue
        if not roots:
            kept.append(f"{name}: cwd is not a git repo")
            continue
        problem = checkout_problem(cwd)
        repo = os.path.basename(cwd)
        if problem:
            detail = f"{repo}: {problem}"
            kept.append(f"{name}: {detail}")
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
        save_messaged({k: v for k, v in messaged.items() if k.startswith('bg:') or k.startswith('shell:') or now - v < 7 * 86400})
    print(f"kept {len(kept)} terminal(s) of {len(agents)} agent(s):")
    for k in kept:
        print(f"  keep {k}")


def is_orphan_shell(t: dict) -> bool:
    """Whether a terminal is the shell rule's kind: live, no agent status, no name, no label that makes it the
    factory's or an agent's (`factory.key`, so `plan:` tabs too; the Claude session label), and its program and
    foreground program both a shell. Idleness is judged separately, from `turn` (see `reap_shells`)."""
    if t.get("state") != "live" or t.get("status") is not None or "/" in t["address"] or t.get("name"):
        return False
    labels = t.get("labels") or {}
    if labels.get(FACTORY_KEY_LABEL) or labels.get(SESSION_LABEL):
        return False
    argv = t.get("argv") or []
    if not argv or os.path.basename(argv[0]).lstrip("-") not in SHELLS:
        return False
    return ((t.get("foreground") or {}).get("name") or "") in SHELLS


def shell_key(t: dict) -> str:
    return f"shell:{t['address']}:{t.get('created_ms')}"


def reap_shells(j: Journal) -> None:
    """The orphaned-shell rule, a pass of its own: `is_agent` never sees a shell. hc reports no output time for a
    shell, but its `turn` rises as commands run. hc-reap remembers, per terminal, the last `turn` it saw and when
    that changed (in the state file, `shell:<address>:<created_ms>`); a shell closes only when the `turn` has been
    unchanged for SHELL_IDLE_S of observations. A first sighting starts the clock. A dry run reads that state and
    writes none. The close is re-judged from a fresh roster (same terminal, still an orphan shell, same turn)."""
    terminals = list_terminals()
    own = os.environ.get("HC_TERMINAL_ID", "")
    parents = {t["parent"] for t in terminals if t.get("parent") and t.get("state") == "live"}
    state = load_messaged()
    now = time.time()
    seen: dict = {}
    for t in terminals:
        if not is_orphan_shell(t):
            continue
        key, turn = shell_key(t), t.get("turn")
        if not isinstance(turn, int):
            continue  # no turn reported: idleness is unknown, never close it and never start a clock
        prev = state.get(key)
        if not isinstance(prev, dict) or prev.get("turn") != turn:
            seen[key] = {"turn": turn, "at": now}  # first sighting, or it moved: the clock starts over
            continue
        seen[key] = prev
        if now - prev.get("at", now) < SHELL_IDLE_S or t["address"] == own or t["address"] in parents:
            continue
        addr = t["address"]
        if not j.dry:
            try:
                fresh = next((x for x in list_terminals() if x["address"] == addr), None)
            except HcError:
                continue
            if not fresh or fresh.get("created_ms") != t.get("created_ms") or not is_orphan_shell(fresh) \
                    or fresh.get("turn") != turn:
                j.line("close-skipped", terminal=addr, why='"the terminal changed before the close"')
                continue
        j.line("close", terminal=addr, why='"orphaned shell"', idle=f"{(now - prev['at']) / 86400:.0f}d",
               cwd=json.dumps(t.get("cwd") or ""))
        if j.dry:
            continue
        try:
            hc_rpc("terminal.kill", {"terminal": addr, "caller": "hc-reap"})
            hc_rpc("terminal.rm", {"terminal": addr, "caller": "hc-reap"})
        except HcError as e:
            j.line("close-failed", terminal=addr, out=json.dumps(str(e)[:200]))
    if not j.dry:
        save_messaged({**{k: v for k, v in load_messaged().items() if not k.startswith("shell:")}, **seen})


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
    try:
        r = subprocess.run(["claude", "agents", "--json"], capture_output=True, text=True, env=env, timeout=NET_TIMEOUT_S)
    except subprocess.TimeoutExpired:
        print(f"claude agents --json timed out after {NET_TIMEOUT_S}s ({env.get('CLAUDE_CONFIG_DIR', 'default account')}); skipping its bg leftovers")
        return
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
        rc, _ = sh("claude", "stop", a["id"], env=env, timeout=NET_TIMEOUT_S)
        if rc == 0:
            j.line("bg-stop", **desc)
        elif rc == 124:
            j.line("bg-stop-timeout", **desc, why='"claude stop timed out; retried on the next run"')
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
    try:
        reap_shells(j)
    except HcError as e:
        print(f"shell pass skipped: {e}")
    reap_bg(j)
    if not args.dry_run:
        j.line("run-complete", idle_h=f"{idle_h:g}")


if __name__ == "__main__":
    main()
