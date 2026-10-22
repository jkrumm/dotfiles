#!/usr/bin/env python3
"""Stream Claude Code transcripts and aggregate what agents repeat by hand (toil helper).

Question: which shell patterns do agents run, how often, in how many sessions, which of them
fail or get blocked and are re-run, and which multi-step recipes recur?

Inputs: ~/.claude/projects/**/*.jsonl on this host (append-only, read-only, streamed line by
line; files with mtime older than the window are never opened; entries are filtered by their
own timestamp to [AS_OF - 30 d, AS_OF)). Only `tool_use` entries named Bash or Skill, their
`tool_result` (failure kind, duration), edit-tool markers (for blind-vs-fix retries),
skill-expansion entries and `<command-name>` user entries are read. Raw commands live in worker
memory only: they are normalised by cmdnorm.normalize() immediately and never returned, stored
or printed (a blake2b digest of each command is used inside one file to detect exact re-runs).

Determinism: files are processed in path order and merged in order; durations are integer
milliseconds, so a re-run over the same frozen window reproduces every number.

How to run: imported by toil.py (`python3 -I toil.py`). Standalone smoke run:
  python3 -I scan_transcripts.py --max-files 300
"""

import collections
import datetime as dt
import hashlib
import json
import os
import re
import sys
import time
from multiprocessing import get_context

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cmdnorm  # noqa: E402

HOME = os.path.expanduser("~")
PROJECTS = os.path.join(HOME, ".claude", "projects")
IUROOT = os.path.join(HOME, "IuRoot")

EDIT_TOOLS = {b"Edit", b"Write", b"MultiEdit", b"NotebookEdit"}
# waiting and delegation tools counted for context (the proper alternatives to sleep polling)
WATCH_TOOLS = {b"Monitor", b"ScheduleWakeup", b"Agent", b"SendMessage"}
WATCH_NAMES = {"Monitor", "ScheduleWakeup", "Agent", "SendMessage"}
# the block keys differ between backends (Anthropic: type,id,name; IU-endpoint models add index,text,
# citations,thinking before id), so allow any brace-free run between the type and the name
TOOLUSE_NAME_RE = re.compile(rb'"type":"tool_use"[^{}]{0,400}?"name":"([^"]*)"')
RESULT_ID_RE = re.compile(rb'"tool_use_id":"([^"]+)"')
CMDNAME_RE = re.compile(r"<command-name>\s*/?([^<\s]+)\s*</command-name>")
SKILL_DIR_RE = re.compile(r"Base directory for this skill: \S*?/skills/([A-Za-z0-9._-]+)")
IU_MENTION_RE = re.compile(r"(?:~|" + re.escape(HOME) + r")/IuRoot/([A-Za-z0-9._-]+)")
SR_MENTION_RE = re.compile(r"(?:~|" + re.escape(HOME) + r")/SourceRoot/([A-Za-z0-9._-]+)")

MAX_WALL_MS = 3_600_000
LONG_CALL_MS = 120_000
RETRY_LOOKAHEAD = 8
RETRY_GAP_S = 900
RECIPE_GAP_S = 1200
MIN_SESSIONS = 5

try:
    IU_NAMES = set(os.listdir(IUROOT))
except OSError:
    IU_NAMES = set()


# --------------------------------------------------------------------------- call groups
# Call-level predicates that feed the candidate-automation table. A call joins a group when any
# of its segment patterns matches (or, for the failure groups, when its failure class matches).
_ORCH_POLL = {"rd agents", "rd read", "script wave-watch.sh", "herdr agent wait", "herdr agent list",
              "herdr agent get", "herdr pane read", "gh pr checks", "gh run watch", "gh run view"}
_PROC = {"pgrep", "ps", "kill", "pkill", "killall", "lsof"}
_DEPS = {"bun outdated", "bun update", "npm outdated", "npx npm-check-updates", "uv lock", "brew outdated",
         "brew upgrade", "bun audit", "npm audit", "bun upgrade", "brew update"}
_VERIFY = {"bun test", "bunx oxfmt", "bun run typecheck", "bun run lint", "bun run format", "bun run format:check",
           "make check", "bun run build", "bunx tsc", "bunx oxlint", "bun run test", "make test", "make lint"}


def _any_in(pats, names):
    return any(p in names or (p.startswith("ssh ") and ": " in p and p.split(": ", 1)[1] in names) for p in pats)


# Evaluated in this order; a call joins only the first group that matches, so the groups are disjoint
# and their hours can be added.
CALL_GROUPS = [
    ("blocked:sleep-then-command", lambda pats, st, blk, pr: st == "blocked" and bool(blk) and "sleep" in blk),
    ("blocked:worktree-isolation-guard", lambda pats, st, blk, pr: st == "blocked" and bool(blk) and "worktree isolation" in blk),
    ("blocked:git-and-docker-hooks", lambda pats, st, blk, pr: st == "blocked" and bool(blk) and blk.startswith("hook:")),
    ("fail:bsd-vs-gnu-and-glob", lambda pats, st, blk, pr: st == "exit" and bool(blk) and (blk.startswith("sed:") or blk.startswith("zsh: no matches") or blk.startswith("BSD "))),
    ("kill-sleep-kill-rm", lambda pats, st, blk, pr: sum(1 for p in pats if p in ("kill", "sleep <n>", "rm <path>", "pkill")) >= 3),
    ("poll:shell-loop", lambda pats, st, blk, pr: "<poll-loop>" in pats),
    ("poll:sleep", lambda pats, st, blk, pr: any(p == "sleep <n>" or p.endswith(": sleep <n>") for p in pats)),
    ("poll:orchestrator-status", lambda pats, st, blk, pr: _any_in(pats, _ORCH_POLL)),
    ("dependency-updates", lambda pats, st, blk, pr: _any_in(pats, _DEPS)),
    ("launchd-by-hand", lambda pats, st, blk, pr: any(p.startswith("launchctl") or p.startswith("sudo launchctl") for p in pats)),
    ("vps-homelab-container-inspect", lambda pats, st, blk, pr: any(p.startswith(("ssh vps: docker", "ssh homelab: docker")) for p in pats)),
    ("local-health-curl", lambda pats, st, blk, pr: "curl <local>" in pats),
    ("process-by-hand", lambda pats, st, blk, pr: _any_in(pats, _PROC)),
    ("verify-loop", lambda pats, st, blk, pr: _any_in(pats, _VERIFY)),
]

_COMMIT_FLOW = {"git add", "git commit", "git push", "gh pr create", "git push --force-with-lease"}


def collapse_cycles(stream):
    """Collapse a block of 2-4 steps repeated back to back (a b a b -> a b) so cycles do not yield rotations."""
    out, run = [], []

    def flush():
        i = 0
        while i < len(run):
            for period in (4, 3, 2):
                blk = [x[0] for x in run[i:i + period]]
                if len(blk) == period and [x[0] for x in run[i + period:i + 2 * period]] == blk:
                    j = i + period
                    while [x[0] for x in run[j:j + period]] == blk:
                        j += period
                    out.extend(run[i:i + period])
                    i = j
                    break
            else:
                out.append(run[i])
                i += 1
        run.clear()

    for item in stream:
        if item is None:
            flush()
            out.append(None)
        else:
            run.append(item)
    flush()
    return out


def chain_extra(stream, in_cat):
    """Extra calls spent on consecutive steps of one category (distinct calls in a run, minus one)."""
    extra, calls = 0, set()
    for item in list(stream) + [None]:
        if item is not None and in_cat(item[0]):
            calls.add(item[1])
        else:
            if calls:
                extra += len(calls) - 1
            calls = set()
    return extra


# --------------------------------------------------------------------------- attribution


def classify_cwd(cwd):
    """-> (lane, repo, is_iu). Repo names only; IuRoot content never read."""
    p = cwd or ""
    if p.startswith(HOME):
        p = "~" + p[len(HOME):]
    if p.startswith("~/.local/state/agent-gateway/worktrees/"):
        return "agw-job", "<agw-job>", False
    if p.startswith("~/.local/state/sideclaw/worktrees/"):
        return "sideclaw-job", "<sideclaw-job>", False
    if "/agent-gateway/bench" in p or "sideclaw-ab" in p or "bench-check" in p:
        return "bench", "<bench>", False
    m = re.match(r"~/\.herdr/worktrees/([^/]+)", p)
    if m:
        return "interactive", m.group(1), m.group(1) in IU_NAMES
    if re.match(r"~/IuRoot/worktrees(?:/|$)", p):
        return "interactive", "<iu-worktree>", True
    m = re.match(r"~/(SourceRoot|IuRoot)/([^/]+)", p)
    if m:
        return "interactive", m.group(2), m.group(1) == "IuRoot"
    if p in ("~/SourceRoot", "~/IuRoot"):
        return "interactive", "(root)", p == "~/IuRoot"
    if p in ("~", "", "~/"):
        return "interactive", "~", False
    if p.startswith(("/private/tmp", "/tmp", "/private/var", "/var/folders")):
        return "scratch", "<tmp>", False
    return "interactive", "<other>", False


def repo_for_call(repo, iu, cmd):
    """Root-level sessions work in many repos: take the first repo named in the command."""
    if repo not in ("(root)", "~", "<other>"):
        return repo, iu
    m = IU_MENTION_RE.search(cmd)
    if m and m.group(1) != "worktrees":
        return m.group(1), True
    m = SR_MENTION_RE.search(cmd)
    if m:
        return m.group(1), False
    return repo, iu


def session_of(path):
    rel = os.path.relpath(path, PROJECTS).split(os.sep)
    if "subagents" in rel and len(rel) >= 3:
        return rel[1]
    return os.path.splitext(rel[-1])[0]


# --------------------------------------------------------------------------- results


def _result_text(block):
    c = block.get("content")
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        return " ".join(x.get("text", "") for x in c if isinstance(x, dict))
    return ""


def failure_class(line):
    """Coarse message class of a failing command's last output line (no names, paths or numbers)."""
    t = re.sub(r"(?:/Users|~|\.{0,2})/[^\s:'\"]*", "<path>", line)
    t = re.sub(r"'[^']*'|\"[^\"]*\"|`[^`]*`", "<q>", t)
    t = re.sub(r"\b[0-9a-f]{7,40}\b", "<sha>", t)
    t = re.sub(r"\d+", "N", t)
    t = re.sub(r"\s+", " ", t).strip().lower()
    if not t:
        return "(no output)"
    if t.startswith("sed:") or re.match(r'^(?:<q>|"): (?:undefined label|bad flag|command expected|extra characters)', t):
        return "sed: BSD-vs-GNU syntax error"
    if re.match(r"^node\.js v", t):
        return "node.js uncaught exception"
    if re.match(r"^bun v", t):
        return "bun runtime error"
    if re.match(r"^n total", t) or re.fullmatch(r"n", t):
        return "(no error text)"
    for needle, label in (
        ("no matches found", "zsh: no matches found (unquoted glob)"),
        ("illegal line count", "BSD head/tail: illegal line count (GNU negative count)"),
        ("illegal option", "BSD userland: illegal option (GNU flag)"),
        ("unrecognized option", "BSD userland: illegal option (GNU flag)"),
        ("invalid command code", "sed: BSD-vs-GNU syntax error"),
        ("command not found", "command not found"),
        ("no such file or directory", "no such file or directory"),
        ("permission denied", "permission denied"),
        ("not a git repository", "not a git repository"),
        ("could not resolve host", "network: could not resolve host"),
        ("connection refused", "network: connection refused"),
        ("operation timed out", "network: timed out"),
        ("syntax error", "shell syntax error"),
        ("unexpected token", "shell syntax error"),
        ("is a directory", "is a directory"),
        ("not found", "not found"),
        ("failed", "reported failure"),
        ("error", "reported error"),
    ):
        if needle in t:
            return label
    return "other (unclassified)"


def classify_result(block):
    """-> (status, exit_code, block_key)."""
    if not block.get("is_error"):
        return "ok", 0, None
    txt = _result_text(block)
    first = txt.split("\n", 1)[0].strip()
    m = re.match(r"Exit code (\d+)", first)
    if m:
        body = [ln.strip() for ln in txt.split("\n")[1:] if ln.strip()]
        return "exit", int(m.group(1)), failure_class(body[-1] if body else "")
    if first.startswith("<tool_use_error>Blocked:"):
        if "sleep" in first[:60]:
            return "blocked", -1, "harness: sleep-then-command polling blocked"
        return "blocked", -1, "harness: " + re.sub(r"\d+", "N", first[24:80]).strip()
    if first.startswith("PreToolUse") or "hook error" in first[:60]:
        msg = first.split("hook error:", 1)[-1].strip()
        msg = re.split(r"\s+[\u2014-]+\s+", msg)[0]
        return "blocked", -1, "hook: " + re.sub(r"(?:/Users|~)/\S*", "<path>", re.sub(r"\s+", " ", msg))[:90]
    if re.match(r"This (session|agent) is isolated in the worktree", first):
        low1 = first.lower()
        for needle, label in (("too complex", "too complex to verify it stays inside"), ("redirect", "redirects outside the worktree"),
                              ("chang", "changes directory out of the worktree"), ("names git", "names git in a form too complex to verify"),
                              ("hands", "hands work to another tool"), ("points", "points outside the worktree"),
                              ("runs a command whose name", "runs a computed command name"), ("names", "names a path outside the worktree"),
                              ("runs", "runs an unverifiable command")):
            if needle in low1:
                return "blocked", -1, "harness: worktree isolation guard -- command " + label
        return "blocked", -1, "harness: worktree isolation guard -- other"
    low = first.lower()
    if "permission" in low and ("denied" in low or "not allowed" in low):
        return "denied", -1, "permission denied by harness"
    if "timed out" in low:
        return "timeout", -1, None
    if "interrupted" in low:
        return "interrupted", -1, None
    return "error", -1, re.sub(r"\d+", "N", re.sub(r"(?:/Users|~)/\S*", "<path>", first))[:70]


def _ts_epoch(ts):
    try:
        return dt.datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


# --------------------------------------------------------------------------- per-file worker


def _init_worker():
    try:
        os.nice(8)
    except OSError:
        pass


def _block_text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return " ".join(x.get("text", "") for x in content if isinstance(x, dict))
    return ""


def scan_file(args):
    path, lo_ts, as_of_ts = args
    session = session_of(path)
    calls = []
    ids = {}
    slash = []
    skills = []
    typed = []
    tool_counts = collections.Counter()
    edits = 0
    cwd_first = None
    entrypoint = None
    try:
        fh = open(path, "rb")
    except OSError:
        return None
    with fh:
        for line in fh:
            try:
                if b'"promptSource":"typed"' in line and b'"type":"user"' in line and b'"tool_result"' not in line:
                    o = json.loads(line)
                    ts = o.get("timestamp", "")
                    if lo_ts <= ts < as_of_ts:
                        text = re.sub(r"\s+", " ", _block_text(o.get("message", {}).get("content")).strip().lower()).strip(" .!?")
                        n_words = len(text.split())
                        typed.append((o.get("uuid"), n_words, text if (n_words <= 6 and len(text) <= 50) else None))
                if b'"type":"assistant"' in line and b'"tool_use"' in line:
                    names = TOOLUSE_NAME_RE.findall(line)
                    watch = [n for n in names if n in WATCH_TOOLS or n.endswith(b"job_wait")]
                    if b"Bash" in names or b"bash" in names or b"Skill" in names or watch:
                        o = json.loads(line)
                        ts = o.get("timestamp", "")
                        if not (lo_ts <= ts < as_of_ts):
                            continue
                        cwd = o.get("cwd")
                        if cwd_first is None:
                            cwd_first = cwd
                            entrypoint = o.get("entrypoint")
                        for b in o.get("message", {}).get("content", []):
                            if not (isinstance(b, dict) and b.get("type") == "tool_use"):
                                continue
                            inp = b.get("input") or {}
                            nm = b.get("name") or ""
                            if nm in WATCH_NAMES or nm.endswith("job_wait"):
                                tool_counts["job_wait (mcp)" if nm.endswith("job_wait") else nm] += 1
                                continue
                            if b.get("name") == "Skill":
                                sk = inp.get("skill")
                                if isinstance(sk, str):
                                    skills.append((b.get("id"), ts, sk.lower().lstrip("/"), "model", cwd, o.get("entrypoint")))
                                continue
                            if nm not in ("Bash", "bash"):
                                continue
                            cmd = inp.get("command")
                            if not isinstance(cmd, str) or not cmd.strip():
                                continue
                            ids[b["id"]] = len(calls)
                            calls.append({
                                "id": b["id"], "ts": ts, "cwd": cwd, "cmd": cmd,
                                "bg": bool(inp.get("run_in_background")),
                                "edits": edits, "res": None, "res_ts": None,
                                "entry": o.get("entrypoint"),
                            })
                    else:
                        edits += sum(1 for n in names if n in EDIT_TOOLS)
                elif ids and b'"tool_result"' in line:
                    m = RESULT_ID_RE.search(line)
                    if not m:
                        continue
                    tid = m.group(1).decode("ascii", "replace")
                    idx = ids.get(tid)
                    if idx is None or calls[idx]["res"] is not None:
                        continue
                    o = json.loads(line)
                    for b in o.get("message", {}).get("content", []):
                        if isinstance(b, dict) and b.get("type") == "tool_result" and b.get("tool_use_id") == tid:
                            calls[idx]["res"] = classify_result(b)
                            calls[idx]["res_ts"] = o.get("timestamp")
                            break
                elif b'"type":"user"' in line and (b"<command-name>" in line or b"Base directory for this skill" in line):
                    o = json.loads(line)
                    ts = o.get("timestamp", "")
                    if not (lo_ts <= ts < as_of_ts):
                        continue
                    text = _block_text(o.get("message", {}).get("content"))
                    mm = CMDNAME_RE.search(text)
                    if mm:
                        slash.append((o.get("uuid"), ts, mm.group(1).lower(), o.get("turnOrigin"),
                                      o.get("promptSource"), o.get("entrypoint"), o.get("cwd")))
                    elif o.get("isMeta") and not o.get("sourceToolUseID"):
                        sm = SKILL_DIR_RE.search(text[:400])
                        if sm:
                            skills.append((o.get("uuid"), ts, sm.group(1).lower(), "typed", o.get("cwd"), o.get("entrypoint")))
            except (ValueError, KeyError, TypeError):
                continue
    if not calls and not slash and not skills and not tool_counts:
        return {"session": session, "calls": [], "slash": [], "skills": [], "stream": [], "retries": [], "chains": [], "epochs": [],
                "extras": {"verify": 0, "commit": 0}, "typed": typed, "tools": dict(tool_counts)}

    out = []
    for c in calls:
        lane, repo, iu = classify_cwd(c["cwd"])
        if lane == "interactive" and (c["entry"] or "").startswith("sdk"):
            lane = "headless"
        repo, iu = repo_for_call(repo, iu, c["cmd"])
        mask = iu or "IuRoot" in c["cmd"] or "glab " in c["cmd"]
        pats = tuple(p for p, _ in cmdnorm.normalize(c["cmd"], mask=mask))
        work = tuple(p for p in pats if not cmdnorm.is_glue(p))
        primary = work[-1] if work else (pats[-1] if pats else "<empty>")
        res = c["res"] or ("noresult", -1, None)
        wall = None
        if c["res_ts"]:
            t0, t1 = _ts_epoch(c["ts"]), _ts_epoch(c["res_ts"])
            if t0 is not None and t1 is not None and t1 >= t0:
                wall = min(int(round((t1 - t0) * 1000)), MAX_WALL_MS)
        out.append({
            "id": c["id"], "ts": c["ts"], "epoch": _ts_epoch(c["ts"]) or 0.0, "lane": lane, "repo": repo, "iu": iu,
            "pats": pats, "primary": primary, "status": res[0], "code": res[1], "block": res[2], "wall": wall,
            "bg": c["bg"], "edits": c["edits"],
            "benign": cmdnorm.is_benign_nonzero(list(pats)) if res[0] == "exit" else False,
            "exact": hashlib.blake2b(c["cmd"].encode("utf-8", "replace"), digest_size=8).hexdigest(),
        })

    # recipe stream: non-noise patterns in order, consecutive duplicates collapsed, gap barriers
    stream = []
    last_ep = None
    for i, c in enumerate(out):
        if last_ep is not None and c["epoch"] - last_ep > RECIPE_GAP_S:
            stream.append(None)
        last_ep = c["epoch"]
        for p in c["pats"]:
            if cmdnorm.is_noise(p) or p == "<poll-loop>":
                continue
            if stream and stream[-1] is not None and stream[-1][0] == p:
                continue
            stream.append((p, i))

    # failure-retry links: a failing call re-run (exact command, or the same action-level pattern)
    n = len(out)
    for i, c in enumerate(out):
        nxt = out[i + 1]["epoch"] if i + 1 < n else None
        c["gap_ms"] = int(min(max(nxt - c["epoch"], 0.0), 600.0) * 1000) if nxt is not None else 0
    link = {}
    for i, c in enumerate(out):
        if c["status"] != "exit" or c["benign"]:
            continue
        for j in range(i + 1, min(n, i + 1 + RETRY_LOOKAHEAD)):
            d = out[j]
            if d["epoch"] - c["epoch"] > RETRY_GAP_S:
                break
            exact = d["exact"] == c["exact"]
            same = exact or (cmdnorm.is_specific(c["primary"]) and d["primary"] == c["primary"])
            if same:
                link[i] = (j, exact)
                break
    retries = []
    linked_to = set(j for j, _ in link.values())
    chains = []
    for i, (j, exact) in sorted(link.items()):
        c, d = out[i], out[j]
        retries.append((c["primary"], exact, d["edits"] - c["edits"] > 0, d["status"] == "ok",
                        int(min(max(d["epoch"] - c["epoch"], 0.0), RETRY_GAP_S) * 1000)))
        if i in linked_to:
            continue
        # chain start
        length, k, ended_ok = 1, i, False
        while k in link:
            k = link[k][0]
            length += 1
        ended_ok = out[k]["status"] == "ok"
        chains.append((c["primary"], length, ended_ok))
    extras = {"verify": chain_extra(stream, lambda p: p in _VERIFY),
              "commit": chain_extra(stream, lambda p: p in _COMMIT_FLOW)}
    stream = collapse_cycles(stream)
    slim = [(c["id"], c["ts"], c["lane"], c["repo"], c["iu"], c["pats"], c["primary"], c["status"], c["code"],
             c["block"], c["wall"], c["bg"], c["benign"], c["gap_ms"]) for c in out]
    return {"session": session, "calls": slim, "slash": slash, "skills": skills, "stream": stream,
            "retries": retries, "chains": chains, "epochs": [c["epoch"] for c in out], "extras": extras, "typed": typed, "tools": dict(tool_counts)}


# --------------------------------------------------------------------------- aggregation


def list_files(lo_epoch, max_files=None):
    out = []
    for root, _dirs, files in os.walk(PROJECTS):
        for f in files:
            if not f.endswith(".jsonl"):
                continue
            p = os.path.join(root, f)
            try:
                st = os.stat(p)
            except OSError:
                continue
            if st.st_mtime >= lo_epoch:
                out.append((st.st_mtime, st.st_size, p))
    if max_files:
        out.sort(reverse=True)
        out = out[:max_files]
    out.sort(key=lambda t: t[2])
    return out


def pct(vals, q):
    if not vals:
        return None
    v = sorted(vals)
    return v[min(len(v) - 1, int(q * (len(v) - 1) + 0.5))]


def _new_pat():
    return {"calls": 0, "sessions": set(), "repos": collections.Counter(), "lanes": collections.Counter(),
            "primary": 0, "fail": 0, "benign": 0, "blocked": 0, "walls": [], "codes": collections.Counter(),
            "fail_classes": collections.Counter()}


def scan(as_of_iso, days=30, workers=8, max_files=None, log=sys.stderr):
    as_of = dt.datetime.fromisoformat(as_of_iso.replace("Z", "+00:00"))
    lo = as_of - dt.timedelta(days=days)
    lo_ts = lo.strftime("%Y-%m-%dT%H:%M:%S.000Z")
    as_of_ts = as_of.strftime("%Y-%m-%dT%H:%M:%S.000Z")
    files = list_files(lo.timestamp(), max_files)
    total_bytes = sum(f[1] for f in files)
    print(f"[scan] {len(files)} files, {total_bytes / 1e9:.1f} GB, window {lo_ts} .. {as_of_ts}", file=log)

    agg = {
        "files": len(files), "bytes": total_bytes, "window": [lo_ts, as_of_ts], "files_with_entries": 0,
        "calls": 0, "dup_ids": 0, "sessions": set(), "lane_calls": collections.Counter(),
        "lane_sessions": collections.defaultdict(set), "status": collections.Counter(),
        "exit_codes": collections.Counter(), "blocks": collections.Counter(),
        "block_sessions": collections.defaultdict(set), "block_repos": collections.defaultdict(collections.Counter),
        "block_gap_ms": collections.Counter(),
        "error_kinds": collections.Counter(),
        "glue_segments": 0, "segments": 0, "bg_calls": 0, "wall_ms": 0, "iu_calls": 0, "benign_nonzero": 0,
        "other_cmd_calls": 0, "gaps": [], "groups": {}, "chain_extra": collections.Counter(),
        "typed_prompts": 0, "typed_words": collections.Counter(), "typed_short": collections.Counter(),
        "tool_counts": collections.Counter(), "fail_class_total": collections.Counter(),
        "fail_class_sessions": collections.defaultdict(set),
        "pat": {}, "repo": {}, "slash": {}, "skills": {}, "retry": {}, "chains": collections.Counter(),
        "chain_ok": collections.Counter(), "streams": [], "calls_per_session": collections.Counter(),
    }
    seen_ids = set()
    seen_slash = set()
    seen_skill = set()
    seen_typed = set()
    pat = agg["pat"]
    t0 = time.time()
    ctx = get_context("fork")
    done = 0
    with ctx.Pool(workers, initializer=_init_worker) as pool:
        for res in pool.imap(scan_file, [(f[2], lo_ts, as_of_ts) for f in files], chunksize=4):
            done += 1
            if done % 1000 == 0:
                print(f"[scan] {done}/{len(files)} files, {agg['calls']} calls, {time.time() - t0:.0f}s", file=log)
            if not res:
                continue
            if res["calls"] or res["slash"] or res["skills"] or res.get("typed") or res.get("tools"):
                agg["files_with_entries"] += 1
            session = res["session"]
            for (cid, ts, lane, repo, iu, pats, primary, status, code, block, wall, bg, benign, gap_ms) in res["calls"]:
                if cid in seen_ids:
                    agg["dup_ids"] += 1
                    continue
                seen_ids.add(cid)
                agg["calls"] += 1
                agg["sessions"].add(session)
                agg["lane_calls"][lane] += 1
                agg["lane_sessions"][lane].add(session)
                agg["calls_per_session"][session] += 1
                agg["status"][status] += 1
                agg["iu_calls"] += 1 if iu else 0
                agg["bg_calls"] += 1 if bg else 0
                agg["wall_ms"] += wall or 0
                if gap_ms:
                    agg["gaps"].append(gap_ms)
                if status == "exit":
                    agg["exit_codes"][code] += 1
                    agg["benign_nonzero"] += 1 if benign else 0
                if status == "error" and block:
                    agg["error_kinds"][block] += 1
                if status in ("blocked", "denied") and block:
                    agg["blocks"][block] += 1
                    agg["block_gap_ms"][block] += gap_ms
                    agg["block_sessions"][block].add(session)
                    agg["block_repos"][block]["<iu:" + repo + ">" if iu else repo] += 1
                for gkey, gfn in CALL_GROUPS:
                    if gfn(pats, status, block, primary):
                        g = agg["groups"].setdefault(gkey, {"calls": 0, "sessions": set(), "gap_ms": 0, "wall_ms": 0,
                                                            "repos": collections.Counter(), "lanes": collections.Counter(), "fail": 0})
                        g["calls"] += 1
                        g["sessions"].add(session)
                        g["gap_ms"] += gap_ms
                        g["wall_ms"] += wall or 0
                        g["repos"]["<iu:" + repo + ">" if iu else repo] += 1
                        g["lanes"][lane] += 1
                        g["fail"] += 1 if (status == "exit" and not benign) else 0
                        break
                seen_in_call = set()
                for p in pats:
                    agg["segments"] += 1
                    if p == "<other-cmd>":
                        agg["other_cmd_calls"] += 1
                    if cmdnorm.is_glue(p):
                        agg["glue_segments"] += 1
                        continue
                    if p in seen_in_call:
                        continue
                    seen_in_call.add(p)
                    e = pat.get(p)
                    if e is None:
                        e = pat[p] = _new_pat()
                    e["calls"] += 1
                    e["sessions"].add(session)
                    e["repos"]["<iu:" + repo + ">" if iu else repo] += 1
                    e["lanes"][lane] += 1
                    if wall is not None:
                        e["walls"].append(wall)
                e = pat.get(primary)
                if e is not None:
                    e["primary"] += 1
                    if status == "exit" and not benign:
                        e["fail"] += 1
                        e["codes"][code] += 1
                        if block:
                            e["fail_classes"][block] += 1
                    elif status == "exit":
                        e["benign"] += 1
                    elif status == "blocked":
                        e["blocked"] += 1
                if status == "exit" and not benign and block:
                    agg["fail_class_total"][block] += 1
                    agg["fail_class_sessions"][block].add(session)
                if lane in ("interactive", "headless"):
                    r = agg["repo"].setdefault(repo, {"calls": 0, "iu": iu, "sessions": set(), "pat": collections.Counter(), "heads": collections.Counter()})
                    r["calls"] += 1
                    r["sessions"].add(session)
                    for p in seen_in_call:
                        r["pat"][p] += 1
                        r["heads"][cmdnorm.head_of(p)] += 1
            for (uuid, ts, name, turn, psrc, entry, cwd) in res["slash"]:
                if uuid and uuid in seen_slash:
                    continue
                if uuid:
                    seen_slash.add(uuid)
                lane, _repo, _iu = classify_cwd(cwd)
                if lane == "interactive" and (entry or "").startswith("sdk"):
                    lane = "headless"
                owner = lane == "interactive" and turn in (None, "human") and psrc in (None, "typed")
                s = agg["slash"].setdefault(name, {"total": 0, "owner": 0, "scheduled": 0, "other": 0, "sessions": set()})
                s["total"] += 1
                s["sessions"].add(session)
                if owner:
                    s["owner"] += 1
                elif turn == "scheduled":
                    s["scheduled"] += 1
                else:
                    s["other"] += 1
            for (sid, ts, name, how, cwd, entry) in res["skills"]:
                if sid and sid in seen_skill:
                    continue
                if sid:
                    seen_skill.add(sid)
                lane, _repo, _iu = classify_cwd(cwd)
                s = agg["skills"].setdefault(name, {"model": 0, "typed": 0, "sessions": set(), "lanes": collections.Counter()})
                s[how] += 1
                s["sessions"].add(session)
                s["lanes"][lane] += 1
            for k2, v2 in res.get("tools", {}).items():
                agg["tool_counts"][k2] += v2
            for (uid, nw, phrase) in res.get("typed", []):
                if uid and uid in seen_typed:
                    continue
                if uid:
                    seen_typed.add(uid)
                agg["typed_prompts"] += 1
                agg["typed_words"][min(nw, 10)] += 1
                if phrase:
                    agg["typed_short"][phrase] += 1
            for k2, v2 in res["extras"].items():
                agg["chain_extra"][k2] += v2
            if res["stream"]:
                agg["streams"].append((session, res["stream"], res["epochs"]))
            for (key, exact, has_edit, ok_next, cycle_ms) in res["retries"]:
                r = agg["retry"].setdefault(key, {"retried": 0, "exact": 0, "blind": 0, "fix": 0, "ok_next": 0, "sessions": set(), "cycle_ms": 0, "blind_cycle_ms": 0})
                r["retried"] += 1
                r["exact"] += 1 if exact else 0
                r["blind"] += 0 if has_edit else 1
                r["fix"] += 1 if has_edit else 0
                r["ok_next"] += 1 if ok_next else 0
                r["sessions"].add(session)
                r["cycle_ms"] += cycle_ms
                if not has_edit:
                    r["blind_cycle_ms"] += cycle_ms
            for (key, length, ok) in res["chains"]:
                agg["chains"][length] += 1
                agg["chain_ok"][length] += 1 if ok else 0
    print(f"[scan] done: {agg['calls']} calls, {len(agg['sessions'])} sessions, {time.time() - t0:.0f}s", file=log)
    return agg


# --------------------------------------------------------------------------- recipes


def recipes(streams, min_sessions=MIN_SESSIONS, max_n=5):
    """Apriori-style: n-grams (3..max_n) of non-noise patterns present in >= min_sessions sessions."""
    runs = []
    for session, stream, epochs in streams:
        cur = []
        for item in stream:
            if item is None:
                if len(cur) >= 2:
                    runs.append((session, cur, epochs))
                cur = []
            else:
                cur.append(item)
        if len(cur) >= 2:
            runs.append((session, cur, epochs))
    uni = collections.defaultdict(set)
    for session, run, _ in runs:
        for p, _i in run:
            uni[p].add(session)
    prev_set = {(p,) for p, s in uni.items() if len(s) >= min_sessions}
    result = {}
    for n in range(2, max_n + 1):
        sess = collections.defaultdict(set)
        occ = collections.Counter()
        for session, run, _ in runs:
            pats = [p for p, _i in run]
            for k in range(len(pats) - n + 1):
                g = tuple(pats[k:k + n])
                if g[:-1] not in prev_set or g[1:] not in prev_set or len(set(g)) == 1:
                    continue
                sess[g].add(session)
                occ[g] += 1
        cur = {g: (len(s), occ[g]) for g, s in sess.items() if len(s) >= min_sessions}
        prev_set = set(cur)
        if n >= 3:
            result.update(cur)
        if not cur:
            break
    return result, runs


def maximal(result):
    """Drop an n-gram when a longer kept n-gram contains it with >= 80 % of its sessions."""
    kept = {}
    for g, (s, o) in sorted(result.items(), key=lambda kv: (-len(kv[0]), -kv[1][0], kv[0])):
        dominated = False
        for h, (s2, _o2) in kept.items():
            if len(h) > len(g) and s2 >= 0.8 * s and any(h[i:i + len(g)] == g for i in range(len(h) - len(g) + 1)):
                dominated = True
                break
        if not dominated:
            kept[g] = (s, o)
    return kept


def drop_rotations(kept):
    """Repeated cycles (a b c a b c) yield rotations of one motif; keep the best-supported rotation."""
    out, seen = {}, set()
    for g, (s, o) in sorted(kept.items(), key=lambda kv: (-kv[1][0], -kv[1][1], kv[0])):
        canon = min(g[i:] + g[:i] for i in range(len(g)))
        if canon in seen:
            continue
        seen.add(canon)
        out[g] = (s, o)
    return out


def recipe_spans(grams, runs):
    """Elapsed seconds first-to-last call per occurrence (capped 30 min), for the kept n-grams."""
    spans = collections.defaultdict(list)
    want = set(grams)
    maxn = max((len(g) for g in grams), default=0)
    for session, run, epochs in runs:
        pats = [p for p, _i in run]
        for n in range(3, maxn + 1):
            for k in range(len(pats) - n + 1):
                g = tuple(pats[k:k + n])
                if g in want:
                    a, b = run[k][1], run[k + n - 1][1]
                    if a < len(epochs) and b < len(epochs):
                        spans[g].append((min(epochs[b] - epochs[a], 1800.0), b - a + 1))
    return spans


if __name__ == "__main__":
    mf = None
    if "--max-files" in sys.argv:
        mf = int(sys.argv[sys.argv.index("--max-files") + 1])
    t = time.time()
    a = scan(os.environ.get("AS_OF", "2026-10-22T08:00:00Z"), max_files=mf)
    top = sorted(a["pat"].items(), key=lambda kv: (-kv[1]["calls"], kv[0]))[:15]
    print("calls", a["calls"], "sessions", len(a["sessions"]), "dups", a["dup_ids"], "secs", round(time.time() - t, 1))
    for p, e in top:
        print(e["calls"], len(e["sessions"]), p)
    rc, runs = recipes(a["streams"])
    mx = maximal(rc)
    for g, (s, o) in sorted(mx.items(), key=lambda kv: (-kv[1][0], kv[0]))[:10]:
        print(s, o, " -> ".join(g))
