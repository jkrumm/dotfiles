#!/usr/bin/env python3
"""What does the owner actually ask, day to day, about the state of his estate?

Question (Phase 5 input): the cockpit (Argo) is designed from the owner's own questions --
"list what I ask every day, derive the read model that answers each, then the views". This
script builds that inventory mechanically from his real messages; nothing is imagined.

Definition keys (this script's own; DEFINITIONS.md has no key for this question):
  owner message   a message the owner typed himself.
                  Claude Code: `type: user`, not a sidechain, not `isMeta`, `origin.kind ==
                  "human"`, `entrypoint == "cli"`, text content (no tool_result), not a wrapper
                  (`<command-*>`, `<local-command-*>`, `<system*>`, `<task-notification>`,
                  compaction summaries, interrupts), not an agent brief (see AGENT_FED /
                  THIRD_PERSON / STRUCTURED below), session cwd not a worktree or an automated
                  state dir, deduplicated by entry uuid (resumed sessions replay history).
                  Hermes: `role = user` in a slack session whose content starts with the
                  owner's Slack prefix (injected background-process notices removed), or in a
                  desktop / tui / cli session. `api_server` and `oneshot` user messages are
                  agent-authored probes ("reply with pong", "Validation r3: ...") and are
                  counted separately as `probe`, never as owner messages.
  unit            a sentence ("atom") of an owner message, or the whole message if <= 300
                  chars. Messages > 1500 chars (dictated specs, design prompts) are mined for
                  `?` sentences <= 250 chars only.
  question form   the unit has a `?`, starts with an interrogative or status stem, or carries
                  an uncertainty marker ("not sure if", "wondering whether").
  class           one canonical question (CATALOG). A message may fall in several classes; a
                  class counts a message once. Rules are regexes in CATALOG; every rule is
                  stated there, nothing is learned.
  estate gate     sessions in `brain/` or `~` carry a lot of private research; their messages
                  count only if they name an estate entity (herdr, agent, warden, ...).
  rank score      sum over the class's messages of 0.5 ** (age_days / 14), age from AS_OF
                  ("frequency x recency", 14-day half-life).
  repeat day      a UTC calendar day on which the class has >= 2 messages across all
                  sessions. fast repeat: the same class asked again in the same session within
                  2 h -- the answer was not enough or not at hand.
  answer_s        seconds from the owner message to the first assistant entry with
                  `stop_reason == end_turn` (Claude Code) / `finish_reason == stop` (Hermes)
                  before the next owner message; unanswered (interrupted, capped at 150
                  entries) turns are excluded from latency and counted.
  path token      what the agent ran to answer: first word (+ verb for git/gh/herdr/warden/
                  agw/rd/make/docker) of every shell segment, tool names, skills, MCP tools.

Inputs (read-only, append-only stores, filtered to < AS_OF):
  ~/.claude/projects/**/*.jsonl on this host (mini) -- last 45 days by file mtime and entry
  timestamp; the MacBook copy through `ssh iumac` (this file is piped to the remote python and
  returns only owner-message rows, never the transcripts); ~/.hermes/state.db opened with
  mode=ro, last 60 days, aggregated in SQL / streamed.

Outputs (next to this file; every number in questions.md comes from questions.out.json):
  candidates.out.json   funnel counts, per-message class assignments, <= 160-char redacted
                        excerpts (none for IuRoot sessions), turn metrics. No full text.
  questions.out.json    the canonical questions with counts, recency, repeats, entities,
                        answer paths, latency.
  questions.md          the human document rendered from questions.out.json.

Run:  python3 -I questions.py                 # full run (streams ~5.6k transcripts, ~1 min; fails loudly if ssh iumac is down)
      python3 -I questions.py --cache /tmp/q.json   # reuse collected rows (classification work)
      python3 -I questions.py --no-mac          # skip the ssh iumac leg
      python3 -I questions.py --allow-partial --mac-dump <raw.jsonl>   # MacBook down: rows from an earlier raw pull
      python3 -I questions.py --sample          # print the seeded hand-check sample; verdicts go in labels.json
      AS_OF=2026-10-22T08:00:00Z python3 -I questions.py
      (internal) python3 -I - collect-claude <since-iso> <until-iso> < questions.py
"""

import collections
import datetime as dt
import random
import hashlib
import json
import math
import os
import re
import sqlite3
import statistics
import subprocess
import sys

AS_OF = os.environ.get("AS_OF", "2026-10-22T08:00:00Z")
CLAUDE_DAYS = 45
HERMES_DAYS = 60
HALF_LIFE_D = 14.0
TURN_CAP = 150  # assistant entries inspected per owner message
MAX_UNIT = 300
LONG_MSG = 1500
EXCERPT = 160

SAMPLE_PER_CLASS = 8
SAMPLE_SEED = "20261022"

HERE = os.path.dirname(os.path.abspath(__file__)) if "__file__" in globals() else os.getcwd()


def iso(ts):
    return dt.datetime.fromtimestamp(ts, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# --------------------------------------------------------------------------- provenance
# Everything below this banner up to "LOCAL ONLY" also runs on the MacBook (piped through ssh).

WRAPPER_PREFIXES = (
    "<command-", "<local-command", "<system", "<task-notification", "<user-prompt-submit-hook",
    "<bash-", "<ide_", "[Request interrupted", "This session is being continued", "Caveat:",
    "<environment", "<scheduled", "<teammate",
)
# Typed into a pane by an orchestrator, lead, fleet tool or loop: a brief or a relay, not the owner.
AGENT_FED = re.compile(
    r"^\s*(?:<pasted_content[^>]*>\s*)?(?:"
    r"Read\s+\S*(?:PLAN\.md|/tmp/)|Read (?:your|and execute|the brief)|Base:\s*origin|Lead\b|Orchestrator\b|"
    r"Review (?:round|of)\b|Round[- ]\d|Hold:|Your repo is|New brief from|Post-live|PR #\d+|"
    r"You are (?:the|a|an|fleet|session)\b|Your previous turn|Wave \d+|Execute\b|Investigation \+|"
    r"Calendar \(PR|The merge train|Continue the wave|Rebase|Next:|Brief:|Task:|Wake \(|"
    r"From the (?:\w+ )?(?:orchestrator|\w+ agent)|From [\w-]+(?: \([\w:]+\)|-w\d+)|Heads-up from|"
    r"Owner-(?:approved|authorized|decided)|Anschlussauftrag|Johannes\b|\(Wave \d+\)|"
    r"[\w.-]+ \((?:lead|orchestrator|worker|mother)\)|[\w.-]+ (?:r\d+ )?(?:done|correction):|"
    r"\[from [^\]]+\]|(?:mother|lead|worker|reviewer|verifier|operator)[-\w]*\s*[,:(]|"
    r"mother-\d+ relaying|[\w-]+ lead:|\w+-w\d+ \(lead\)|w\d+ lead:|Quick (?:confirmation|check-in)|"
    r"URGENT from|Follow-up from|Kontext \(|Context[: ]|READ-ONLY AUDIT|Hermes update|/hermes-update|"
    r"Nachtrag aus|Run \d+[a-z]? \(|[A-Z]\d+[a-z]? has landed|Domain run|\w+ has landed|"
    r"Your (?:previous )?turn|Disk alarm|This app needs|FYI from|Update from the|From the [\w-]+ session|"
    r"[\w./-]+(?: [\w.-]+){0,3} done on\b|[\w.-]+(?: (?:round \d+|r\d+|final))+ done\b)",
    re.I,
)
THIRD_PERSON = re.compile(r"\b(Johannes|the owner['’]?s?|der Owner|Owner-(?:approved|authorized|decided|round))\b")
STRUCTURED = re.compile(r"^\s*(?:#{1,4} |\d+\. |[-*] |```|\|)")
WT_CWD = re.compile(r"/(?:\.claude/worktrees|worktrees|\.herdr/worktrees|[\w-]+-wt)/|^/private/tmp|/\.local/(?:share|state)/|/\.hermes/|/basalt-(?:expr|dx)-trial")


def unwrap(t):
    """Strip paste wrappers and cut at a spliced-in agent relay: `<owner text>[from lead-8] ...`."""
    t = re.sub(r"</?pasted_content[^>]*>", "", t).strip()
    m = re.search(r"\S\s*\[from [^\]]+\]", t)
    return t[: m.start() + 1].strip() if m else t


def cwd_split(cwd):
    """('SourceRoot'|'IuRoot'|'home'|'other', repo-or-None). Home dirs differ per machine."""
    p = re.sub(r"^/Users/[^/]+", "~", cwd or "")
    m = re.match(r"^~/(SourceRoot|IuRoot)(?:/([^/]+))?", p)
    if m:
        return m.group(1), m.group(2)
    if p == "~":
        return "home", None
    return "other", os.path.basename(p) or None


def owner_voice(text, cwd):
    """The provenance gate. True only for text the owner typed himself."""
    t = unwrap(text)
    if not t:
        return False
    if t.startswith(WRAPPER_PREFIXES):
        return False
    if WT_CWD.search(cwd or ""):
        return False
    if AGENT_FED.search(t) or THIRD_PERSON.search(t):
        return False
    if "Follow the /wave skill" in t or "do NOT spawn" in t:
        return False
    if STRUCTURED.search(t) and len(t) > 400:
        return False
    return True


GIT_READ = {"log", "status", "diff", "show", "branch", "fetch", "worktree", "ls-files", "rev-parse", "blame", "remote", "stash", "describe", "shortlog", "reflog", "tag", "rev-list", "ls-remote", "config", "cat-file", "grep"}
GIT_WRITE = {"add", "commit", "push", "pull", "merge", "rebase", "checkout", "switch", "reset", "cherry-pick", "restore", "clean", "apply", "am", "revert", "mv", "rm"}
FS_READ = {"cat", "ls", "head", "tail", "sed", "grep", "rg", "find", "wc", "awk", "jq", "stat", "file", "less", "tree", "diff", "readlink", "realpath", "sort", "uniq", "cut", "tr", "xargs", "column"}
HOST_PROBE = {"launchctl", "pgrep", "ps", "lsof", "df", "du", "top", "uptime", "pmset", "vm_stat", "sysctl", "netstat", "nc", "dig", "nslookup", "ping"}
SCRIPT = {"python3", "python", "uv", "node", "bunx", "npx", "tsx", "deno", "bun", "npm", "pnpm", "cargo", "go"}
GENERIC = {"fs read (cat/ls/grep)", "Read file", "search files (Grep/Glob)", "script run (python/node/bun)", "edit/write files", "git write (add/commit/push/pull)"}


def _strip_noise(cmd):
    """Drop heredoc bodies and quoted strings so inline scripts do not leak words as commands."""
    cmd = re.sub(r"<<-?\s*(['\"]?)(\w+)\1[^\n]*\n.*?\n\s*\2\s*(?:\n|$)", "\n", cmd or "", flags=re.S)
    cmd = re.sub(r"'[^']*'|\"[^\"]*\"", "''", cmd)
    return cmd


def bash_tokens(cmd):
    out = []
    for seg in re.split(r"&&|\|\||;|\||\n", _strip_noise(cmd)):
        words = seg.strip().split()
        while words and (re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", words[0]) or words[0] in ("sudo", "time", "nohup", "env", "command", "timeout", "cd", "then", "do", "if", "!", "(", "{")):
            words = words[1:] if words[0] != "cd" else []
        if not words:
            continue
        w = os.path.basename(words[0].strip("()`{}"))
        rest = words[1:]
        if w in ("git", "gh", "herdr", "warden", "agw", "rd", "make", "glab", "tailscale", "brew", "hermes", "docker", "colima", "bd", "hl", "caddy"):
            i = 0
            while i < len(rest) and rest[i].startswith("-"):
                i += 2 if rest[i] in ("-C", "-c") else 1
            verb = rest[i] if i < len(rest) and re.match(r"^[a-z][a-z0-9:_-]*$", rest[i]) else ""
            if w == "git":
                out.append("git read (log/status/diff/branch)" if verb in GIT_READ else "git write (add/commit/push/pull)" if verb in GIT_WRITE else "git")
            elif w in ("docker", "colima"):
                out.append("docker")
            else:
                out.append(f"{w} {verb}".strip())
        elif w in ("curl", "wget", "http"):
            out.append("curl (HTTP probe)")
        elif w in ("ssh", "scp", "rsync"):
            out.append("ssh")
        elif w == "sqlite3":
            out.append("sqlite3 (db read)")
        elif w in HOST_PROBE:
            out.append("host probe (ps/df/launchctl)")
        elif w in FS_READ:
            out.append("fs read (cat/ls/grep)")
        elif w in SCRIPT:
            out.append("script run (python/node/bun)")
        elif w in ("op", "secrets-run"):
            out.append("secrets")
    return out


def tool_tokens(name, inp):
    """Path tokens for one Claude Code tool_use block."""
    if name == "Bash":
        return bash_tokens((inp or {}).get("command", ""))
    if name in ("Read", "NotebookRead"):
        p = (inp or {}).get("file_path", "") or ""
        base = os.path.basename(p)
        if base in ("PLAN.md", "STATUS.md", "JOURNAL.md", "HANDOVER.md", "AGENTS.md") or re.search(r"(STATUS|HANDOVER|JOURNAL|REPORT)", base):
            return [f"Read {base if base in ('PLAN.md','STATUS.md','JOURNAL.md','AGENTS.md') else 'status/handover doc'}"]
        return ["Read file"]
    if name in ("Grep", "Glob"):
        return ["search files (Grep/Glob)"]
    if name in ("Agent", "Task"):
        return ["subagent (Explore/worker)"]
    if name == "Skill":
        return [f"Skill {(inp or {}).get('skill', '')}".strip()]
    if name.startswith("mcp__"):
        parts = name.split("__")
        return [f"MCP {parts[1]} {parts[2] if len(parts) > 2 else ''}".strip()]
    if name in ("WebFetch", "WebSearch"):
        return ["web"]
    if name in ("Edit", "Write", "NotebookEdit", "MultiEdit"):
        return ["edit/write files"]
    if name in ("TodoWrite", "ToolSearch", "TaskCreate", "TaskUpdate", "TaskList", "TaskGet", "ScheduleWakeup", "Monitor", "AskUserQuestion", "EnterPlanMode", "ExitPlanMode"):
        return []
    return [name]


def entry_text(d):
    c = (d.get("message") or {}).get("content")
    if isinstance(c, list):
        if any(isinstance(x, dict) and x.get("type") == "tool_result" for x in c):
            return None
        return "\n".join(x.get("text", "") for x in c if isinstance(x, dict) and x.get("type") == "text")
    return c if isinstance(c, str) else None


def collect_claude(root, since, until):
    """Owner-voice rows from one host's transcripts, each with the agent's turn metrics."""
    rows = []
    seen = set()
    now = dt.datetime.now(dt.timezone.utc).timestamp()
    cutoff_mtime = dt.datetime.strptime(since, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc).timestamp() - 86400
    stats = collections.Counter()
    for dp, _dn, fn in os.walk(root):
        if "/subagents" in dp:
            continue
        for f in fn:
            if not f.endswith(".jsonl"):
                continue
            fp = os.path.join(dp, f)
            try:
                if os.stat(fp).st_mtime < cutoff_mtime:
                    continue
            except OSError:
                continue
            stats["files"] += 1
            cur = None  # the open turn window
            try:
                fh = open(fp, "r", errors="replace")
            except OSError:
                continue
            with fh:
                for line in fh:
                    is_user = '"type":"user"' in line
                    if is_user and '"kind":"human"' in line and '"tool_result"' not in line:
                        try:
                            d = json.loads(line)
                        except ValueError:
                            continue
                        if d.get("type") != "user" or d.get("isSidechain") or d.get("isMeta"):
                            continue
                        o = d.get("origin")
                        if not (isinstance(o, dict) and o.get("kind") == "human") or d.get("entrypoint") != "cli":
                            continue
                        text = entry_text(d)
                        if not text or not text.strip():
                            continue
                        cur = None  # any human message closes the previous window
                        ts = d.get("timestamp") or ""
                        if not (since <= ts < until):
                            continue
                        stats["human"] += 1
                        uid = d.get("uuid")
                        if uid in seen:
                            stats["dup_uuid"] += 1
                            continue
                        seen.add(uid)
                        cwd = d.get("cwd") or ""
                        if not owner_voice(text, cwd):
                            stats["agent_fed_or_wrapper"] += 1
                            continue
                        stats["owner"] += 1
                        t = unwrap(text)
                        ws, repo = cwd_split(cwd)
                        row = {"ts": ts, "sid": (d.get("sessionId") or "")[:8], "ws": ws, "repo": repo,
                               "len": len(t), "text": t[:LONG_MSG + 200], "uuid": uid,
                               "turn": {"answered": False, "answer_s": None, "first_text_s": None, "asst": 0, "tools": 0, "path": [], "interrupted": False, "capped": False}}
                        rows.append(row)
                        if len(t) <= 900:
                            cur = row
                        continue
                    if cur is None:
                        continue
                    if is_user:
                        if "[Request interrupted by user" in line:
                            cur["turn"]["interrupted"] = True
                            cur = None
                        continue
                    if '"type":"assistant"' not in line:
                        continue
                    tr = cur["turn"]
                    if tr["asst"] >= TURN_CAP:
                        tr["capped"] = True
                        cur = None
                        continue
                    try:
                        d = json.loads(line)
                    except ValueError:
                        continue
                    if d.get("type") != "assistant" or d.get("isSidechain"):
                        continue
                    tr["asst"] += 1
                    m = d.get("message") or {}
                    ts2 = d.get("timestamp") or ""
                    try:
                        dsec = (dt.datetime.strptime(ts2, "%Y-%m-%dT%H:%M:%S.%fZ") - dt.datetime.strptime(cur["ts"], "%Y-%m-%dT%H:%M:%S.%fZ")).total_seconds()
                    except ValueError:
                        dsec = None
                    c = m.get("content")
                    for b in c if isinstance(c, list) else []:
                        if not isinstance(b, dict):
                            continue
                        if b.get("type") == "text" and (b.get("text") or "").strip() and tr["first_text_s"] is None and dsec is not None:
                            tr["first_text_s"] = round(dsec, 1)
                        if b.get("type") == "tool_use":
                            tr["tools"] += 1
                            tr["path"].extend(tool_tokens(b.get("name", ""), b.get("input")))
                    if m.get("stop_reason") == "end_turn" and not tr["answered"]:
                        tr["answered"] = True
                        tr["answer_s"] = round(dsec, 1) if dsec is not None else None
                        cur = None
    stats["rows"] = len(rows)
    return rows, dict(stats)


# --------------------------------------------------------------------------- LOCAL ONLY
# Hermes, the ssh leg, classification, aggregation and rendering run on the mini only.

PROBE = re.compile(
    r"(?:\bpong\b|reply (?:with )?(?:exactly|only|OK)|antworte (?:nur|mit|in)|^ping\b|smoke test|\(Testlauf|"
    r"^Validation\b|Wave\d+ probe|terminal tool|^Run '|^Using only the weatherorb tools|Quick check from|"
    r"Modelpick session test|Post-update|Fix the flaky|Der Test fuer|Use the terminal|Sag in einem Wort|"
    r"Liste kurz die Dateien|Zwei Dinge, in dieser Reihenfolge|Quick check-in from)",
    re.I,
)
HERMES_OWNER = re.compile(r"^\[jkrumm \| Slack user <@\w+>\]\s*")
HERMES_NOISE = re.compile(r"^(?:\[IMPORTANT: Background|\[System note|\[CONTEXT COMPACTION|\[Thread context|Gateway message origin|\[OUT-OF-BAND|\[STILL IN PROGRESS|@\w+ ist dem Channel|added an integration|removed an integration)", re.I)


def classify_hermes_cmd(args_json):
    try:
        a = json.loads(args_json or "{}")
    except ValueError:
        return []
    return bash_tokens(a.get("command", ""))


def collect_hermes(db_path, since_ts, until_ts):
    con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=60)
    cur = con.cursor()
    stats = collections.Counter()
    rows, probes = [], []
    q = """SELECT m.id, m.session_id, m.timestamp, m.content, s.source, coalesce(m.display_kind,''), s.title
           FROM messages m JOIN sessions s ON s.id = m.session_id
           WHERE m.role = 'user' AND m.timestamp >= ? AND m.timestamp < ?
             AND s.source IN ('slack','desktop','tui','cli','api_server','oneshot')
           ORDER BY m.timestamp, m.id"""
    seen = set()
    for mid, sid, ts, content, src, dkind, title in cur.execute(q, (since_ts, until_ts)).fetchall():
        content = content or ""
        stats["user_msgs_scanned"] += 1
        if src == "slack":
            if not HERMES_OWNER.match(content) or dkind:
                continue
            content = HERMES_OWNER.sub("", content, count=1)
            chan = "hermes_slack"
        elif src in ("desktop", "tui"):
            if dkind in ("auto_continue", "internal_notification"):
                continue
            chan = f"hermes_{src}"
        elif src == "api_server" and str(sid).startswith("ses-") and not PROBE.search(content):
            chan = "hermes_argo"  # the owner typing into Argo's Hermes chat
        else:  # api_server (api-*), oneshot, cli: run by agents (integration tests, validation rounds)
            probes.append({"ts": iso(ts), "src": src, "len": len(content), "text": content[:300]})
            continue
        if HERMES_NOISE.match(content) or not content.strip():
            stats["hermes_noise"] += 1
            continue
        if PROBE.search(content) or len(content) > 3000:
            stats["hermes_probe_or_long"] += 1
            if PROBE.search(content):
                probes.append({"ts": iso(ts), "src": src, "len": len(content), "text": content[:300]})
            continue
        key = (sid, hashlib.sha1(content.encode()).hexdigest(), int(ts // 120))
        if key in seen:
            stats["hermes_dup"] += 1
            continue
        seen.add(key)
        # the agent's turn: rows after this message until the next real user message
        turn = {"answered": False, "answer_s": None, "first_text_s": None, "asst": 0, "tools": 0, "path": [], "interrupted": False, "capped": False}
        for rid, role, rts, fr, tname, tcalls, rcontent, rkind in con.execute(
            "SELECT id, role, timestamp, coalesce(finish_reason,''), coalesce(tool_name,''), coalesce(tool_calls,''), substr(coalesce(content,''),1,60), coalesce(display_kind,'') FROM messages WHERE session_id=? AND id>? ORDER BY id LIMIT 120",
            (sid, mid),
        ):
            if role == "user" and rkind not in ("internal_notification", "steer", "auto_continue") and not rcontent.startswith(("[IMPORTANT: Background", "[CONTEXT COMPACTION", "[System note")):
                break
            if role == "assistant":
                turn["asst"] += 1
                dsec = rts - ts
                if tcalls:
                    try:
                        for tc in json.loads(tcalls):
                            fn_ = tc.get("function", {})
                            n_ = fn_.get("name", "")
                            turn["tools"] += 1
                            if n_ == "terminal":
                                turn["path"].extend(classify_hermes_cmd(fn_.get("arguments")))
                            elif n_ == "skill_view":
                                try:
                                    turn["path"].append("skill " + json.loads(fn_.get("arguments") or "{}").get("name", ""))
                                except ValueError:
                                    turn["path"].append("skill_view")
                            else:
                                turn["path"].append(n_)
                    except ValueError:
                        pass
                if fr == "stop" and not turn["answered"]:
                    turn["answered"] = 0 <= dsec <= 10800
                    turn["answer_s"] = round(dsec, 1) if 0 <= dsec <= 10800 else None
                    break
        rows.append({"ts": iso(ts), "sid": hashlib.sha1(str(sid).encode()).hexdigest()[:8], "ws": "hermes", "repo": None, "len": len(content),
                     "text": content[:LONG_MSG + 200], "uuid": f"h{mid}", "chan": chan, "turn": turn,
                     "slack_channel": None})
    # cron: the standing questions already answered by push (titles only, counts)
    cron = {}
    for title, n in con.execute("SELECT substr(title,1,instr(title,' · ')-1), count(*) FROM sessions WHERE source='cron' AND started_at>=? AND started_at<? AND instr(title,' · ')>0 GROUP BY 1 ORDER BY 2 DESC", (since_ts, until_ts)):
        cron[title] = n
    sess = dict(con.execute("SELECT source, count(*) FROM sessions WHERE started_at>=? AND started_at<? GROUP BY 1", (since_ts, until_ts)).fetchall())
    um = dict(con.execute("SELECT s.source, count(*) FROM messages m JOIN sessions s ON s.id=m.session_id WHERE m.role='user' AND m.timestamp>=? AND m.timestamp<? GROUP BY 1", (since_ts, until_ts)).fetchall())
    con.close()
    stats["owner_rows"] = len(rows)
    return rows, probes, cron, {"sessions_by_source": sess, "user_msgs_by_source": um, **dict(stats)}


def mac_from_dump(path, since, until, why):
    """Fallback when ssh iumac is down: owner-message rows from an earlier raw dump of the same window
    (JSONL of human-origin entries: ts, sid, cwd, uuid, text). The provenance gate is re-applied here;
    turn metrics are not available for these rows."""
    rows, seen = [], set()
    st = collections.Counter()
    for line in open(path):
        r = json.loads(line)
        if not (since <= r["ts"] < until):
            continue
        st["human"] += 1
        if r["uuid"] in seen:
            st["dup_uuid"] += 1
            continue
        seen.add(r["uuid"])
        if not owner_voice(r["text"], r["cwd"]):
            st["agent_fed_or_wrapper"] += 1
            continue
        ws, repo = cwd_split(r["cwd"])
        t = unwrap(r["text"])
        rows.append({"ts": r["ts"], "sid": (r.get("sid") or "")[:8], "ws": ws, "repo": repo, "len": len(t), "text": t[:LONG_MSG + 200], "uuid": r["uuid"],
                     "turn": {"answered": False, "answer_s": None, "first_text_s": None, "asst": 0, "tools": 0, "path": [], "interrupted": False, "capped": False}})
    st["owner"] = len(rows)
    st["rows"] = len(rows)
    st["fallback"] = f"ssh unavailable ({why.splitlines()[-1][:60]}); rows from an earlier raw dump of the same window, no turn metrics"
    return rows, dict(st)


def collect_mac(since, until):
    here = os.path.abspath(__file__)
    try:
        p = subprocess.run(
            ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=10",
             "iumac", f"python3 -I - collect-claude {since} {until}"],
            input=open(here, "rb").read(), capture_output=True,
        )
    except OSError as e:
        return [], {"error": f"ssh failed: {e}"}
    if p.returncode != 0:
        return [], {"error": f"remote rc={p.returncode}: {p.stderr.decode(errors='replace')[-300:]}"}
    out = p.stdout.decode()
    lines = out.splitlines()
    rows = [json.loads(x) for x in lines if x.startswith('{"ts"')]
    st = {}
    for x in lines:
        if x.startswith('{"__stats__"'):
            st = json.loads(x)["__stats__"]
    return rows, st


# --------------------------------------------------------------------------- the catalog
I = re.I


def R(p):
    return re.compile(p, I)


FILLER = r"(?:ok(?:ay)?|so|and|hmm+|well|nice|great|awesome|yeah|yes|also|but|aber|und|dann|ah+|oh+|wow|hey|sorry|sry|btw|alright|right|super|cool|good|gut|genau|jo|ja|nee|na|then)"
STEM = (r"(?:where|what|what's|whats|how|why|when|which|who|is|are|was|were|do|does|did|can|could|should|would|will|has|have|"
        r"wo|was|wie|warum|wieso|weshalb|wann|welche[rsmn]?|ist|sind|hast|haben|kann|kannst|könnte|soll|sollte|gibt|läuft|laufen|"
        r"check|verify|show|tell|list|look|any|anything|still|ready|wurde|wurden|hat|habe|not sure if|wondering|i wonder|unsure)")
STEM_RX = re.compile(rf"^\s*(?:{FILLER}[, ]+)*{STEM}\b", I)
UNSURE = re.compile(r"\b(?:not sure (?:if|whether|how|what|why|where)|wondering (?:if|whether|about)|i wonder|unsure (?:if|whether)|ob (?:das|es|er|sie) wohl)\b", I)


def is_question_form(u):
    return "?" in u or bool(STEM_RX.match(u)) or bool(UNSURE.search(u))


# Each class: id, area, canonical question, paraphrase, entities, push coverage, rules.
# rules: list of (regex, needs_question_form). `exclude`: units matching any of these are skipped.
# kind="statement": the class is an implied need (the owner states it, he does not ask).
PROBLEM = (r"(?:not working|isn'?t working|doesn'?t work|be working|offline|slow|stuck|failing|failed|fails|error|broken|crash\w*|"
           r"still (?:use|see|show|says?|shows?|on)|unauth\w+|only|old|unknown|so big|came from|didn'?t (?:come|run|work|start|arrive|show)|"
           r"can'?t connect|cant connect|cannot connect|gone|missing|wrong|nothing|empty|weird|strange|so long|too long)")
CATALOG = [
    dict(id="where_are_we", max_len=240, area="Orientation", q="Where are we on this effort -- how is it going?",
         para="Where are we at with the thing you are working on, how is it going?",
         entities=["Agent", "Task (wave/plan)", "Project", "Change", "Attempt"], covered=False,
         rules=[(R(r"\bwh?ere (?:are|r) (?:we|you)(?: at| now| here| with)?\b"), False), (R(r"\bwhere we are\b"), True), (R(r"\bwh?ere do we stand\b"), False),
                (R(r"\bwo stehen wir\b"), False),
                (R(r"\bhow(?:'s| is| are| was)? (?:it|that|this|everything|things|all (?:the |of )?\w+|the \w+) (?:going|doing|goin)\b"), False),
                (R(r"\bhow (?:going|did it go|did that go|did it work|is it going)\b"), False), (R(r"\bhow did (?:it|that) (?:work|go) (?:until|so far)"), False),
                (R(r"\bwie läuft\b"), False), (R(r"\bwas ist der stand\b"), False), (R(r"\bwhat(?:'s| is) the status\b"), False), (R(r"^\W*status\W*$"), False),
                (R(r"\bany (?:update|news|progress)\b"), True), (R(r"\bwhat(?:'s|s| is) (?:going on|happening)\b"), True)]),
    dict(id="since_away", area="Orientation", q="What happened while I was away (overnight, vacation, laptop closed)?",
         para="I am back / good morning -- what got built or changed since I left?",
         entities=["Change", "Deployment", "Agent", "Incident", "Task"], covered=True,
         exclude=[R(r"\bwill\b|\bwerd\w*\b|\bbuild\b.{0,30}over the night|back at the macbook")],
         rules=[(R(r"\b(?:overnight|over the night|über die nacht|while i (?:was|am) (?:away|gone|sleeping|out)|since (?:yesterday|last night|i left|this morning)|seit gestern)\b"), True),
                (R(r"\b(?:i am back|i'm back|im back|am back|bin zurück|we are back)\b"), False), (R(r"\bgood morning\b|\bguten morgen\b"), False),
                (R(r"\bwas wurde (?:alles )?(?:gebaut|gemacht|erreicht)\b"), False),
                (R(r"\bwhat (?:was|has been|have you|did you|all) (?:all )?(?:built|done|shipped|achieved)\b"), True),
                (R(r"\bhow (?:everything|it all|that all|that|it) went\b"), True), (R(r"\bin the last (?:two |2 )?weeks\b"), False)]),
    dict(id="all_agents", max_len=240, area="Fleet", q="How are all my agents / tabs / waves doing, across projects and hosts?",
         para="Show me every running agent and wave: working, idle, done, stuck -- on the mini and on the MacBook.",
         entities=["Agent", "Project", "Task (wave/plan)", "Infra host"], covered=True,
         exclude=[R(r"\bwait until\b|\bclose in\b")],
         rules=[(R(r"\b(?:how are|how is|check|look at|wie geht'?s) (?:all |on all |over )?(?:my |the |die |meine |your )?(?:other |all )?(?:herdr |herder )?(?:agents?|agenten|tabs|waves?|fleet|threads|workers|leads|mothers)\b"), False),
                (R(r"\bcheck (?:all )?(?:the |on the )?(?:other |all )?(?:tabs|threads|agents|panes|spaces)\b"), False),
                (R(r"\b(?:all|alle) (?:of )?(?:the |your |my |die )?(?:agents?|agenten|waves|workers|threads|lunar agents)\b.{0,50}\b(?:finished|fertig|done|running|laufen|deployed|delivered|nicely|properly)\b"), True),
                (R(r"\bfleet or wave\b"), False), (R(r"\bwhat(?:'s| is) active or not\b"), False), (R(r"\bwhich (?:agents?|tabs|waves|sessions)\b"), True),
                (R(r"\b(?:started|gestartet)\b.{0,40}\b(?:herdr|warden)\b"), True)]),
    dict(id="needs_me", area="Fleet", q="What is waiting for me? Which agent or item needs my input?",
         para="What needs me right now, and what happens if I ignore it?",
         entities=["Decision", "Agent", "Incident", "Artifact"], covered=True,
         rules=[(R(r"\b(?:waiting for me|needs? me\b|brauchen? mich|anything (?:a )?human|human needs|what do you need from me|do you need (?:anything|something)|braucht er|need(?:s)? (?:my )?(?:input|decision|approval|answer)|something for me|(?:nothing|anything|something) (?:to ?do|todo))\b"), False)]),
    dict(id="what_pending", max_len=240, area="Orientation", q="What is still pending / missing / open in the plan?",
         para="How much of the plan is still open, what did you achieve, what is left?",
         entities=["Task (wave/plan)", "Change", "Project"], covered=False,
         rules=[(R(r"\b(?:still pending|what(?:'s|s| is| else)? (?:still )?(?:pending|missing|left|open|remaining)|anything else (?:pending|open|left)|how much is (?:still )?(?:pending|left|missing)|noch offen|was fehlt|what remains)\b"), True)]),
    dict(id="agent_alive", max_len=240, area="Fleet", q="Is that agent still running, stuck, or done -- does it need something?",
         para="Are you still going? Why are you stuck? Is it done, what does it say, does it need anything?",
         entities=["Agent", "Attempt", "Task"], covered=False,
         rules=[(R(r"\b(?:still (?:going|running|working|alive|on it)|you(?:r|'re| are) running right|are you (?:stuck|still|ok|alive|there|working)|why are you stuck|you (?:were|got) stuck|(?:is|are) (?:it|he|she|they|that|the agent|the tab) (?:stuck|dead|frozen|crashed|still)|ist er (?:schon )?fertig|wie läuft seine|(?:previous agent|other \w+ tab|tab|agent|session) (?:is |was )?(?:crashed|stuck|dead)|you(?:'re| are| were) (?:\w+ or )?(?:stuck|stumbling|blocked)|what is (?:now )?the issue|did it (?:maybe )?(?:resolve|fix|help))\b"), False)]),
    dict(id="nudge_continue", area="Fleet", q="(implied) Which parked agent must I nudge to continue -- quota reset, laptop closed, crash?",
         para="'continue' / 'go' / 'limit resets in 5 min' typed at an agent that stopped and waited for him.",
         entities=["Agent", "Quota window", "Infra host (MacBook power/lid)"], covered=False, kind="statement",
         rules=[(R(r"^\W*(?:ok(?:ay)?[, ]+)?(?:continue|cpntinue|you can continue|keep going|go on|go now|go go go|go|goo|weiter|resume|proceed|carry on|continue now|go for it)\W*$"), False),
                (R(r"^\W*(?:ok(?:ay)?[, ]+)?(?:continue|you can continue|keep going|go on)\b[^?]{0,160}\b(?:limit|reset|laptop|closed|battery|connected|electricity|unlocked|updated|orchestrating|herdr|restart\w*|back|power)\b[^?]{0,80}$"), False),
                (R(r"^\W*unlocked,? push again\W*$"), False)]),
    dict(id="tab_cleanup", area="Fleet", q="Which herdr tabs / agents are finished and can be closed? Why are so many open?",
         para="Why are there still so many tabs open; which are needed; close the finished ones.",
         entities=["Agent", "Project (herdr workspace)", "Attempt"], covered=False, kind="statement",
         rules=[(R(r"\b(?:so many|too many|sooo many|still (?:so )?many)\b.{0,40}\b(?:tabs?|agents?|spaces?|herdr|herder|herda|herta)\b"), False),
                (R(r"\b(?:tabs?|agents?|spaces?)\b.{0,30}\b(?:still open|open here|left open|leftover)\b"), False),
                (R(r"\b(?:close|closing|clean ?up|aufräumen|schließ\w*|cleaned? up|celanup)\b.{0,50}\b(?:herdr|herder|herda|herta)\b"), False),
                (R(r"\b(?:herdr|herder|herda|herta)\b.{0,40}\b(?:tabs?|spaces?)\b.{0,40}\b(?:clean|close|schließ|aufräum)"), False),
                (R(r"\bclosing these herder tabs\b"), False)]),
    dict(id="done_shipped_live", max_len=240, area="Delivery", q="Is it done, merged, deployed and verified live? Can I close the thread?",
         para="Is everything merged and shipped, is it live, can we close this?",
         entities=["Change", "Deployment", "Verification", "Task", "Project"], covered=False,
         exclude=[R(r"\bwhen you(?:'re| are) done\b")],
         rules=[(R(r"\b(?:is|are|was|were|ist|sind|wurde|wurden|has|have|hast)\b[^.?!]{0,60}\b(?:done|finished|fertig|merged|deployed|shipped|delivered|verified|gemerged|ausgerollt|erledigt|wrapped up|applied|live|ready|released)\b"), True),
                (R(r"\b(?:everything|alles)\b[^.?!]{0,40}\b(?:done|merged|shipped|deployed|delivered|finished|fertig|clean|wrapped up)\b"), True),
                (R(r"\bare we (?:fully |all |now )?(?:done|finished|good|ready|clean|wrapped up)\b|\balmost wrapped up\b"), True),
                (R(r"\b(?:fully|completely|really) (?:finished|done|delivered|deployed|wrapped)\b"), True),
                (R(r"\bdeployed (?:to|on) (?:both )?(?:[\w-]+ )?(?:stage|prod|production)\b"), True),
                (R(r"\b(?:i can|can i|should i|kann ich) close (?:this|the|that) thread\b"), False),
                (R(r"\bnot sure if all\b.{0,40}\b(?:finished|deployed|delivered|done)\b"), False), (R(r"\bapplied where needed\b"), False),
                (R(r"^\W*(?:ok(?:ay)?[, ]+)?ready\b.{0,40}\?"), False)]),
    dict(id="version_per_env", max_len=240, area="Delivery", q="Which version runs where -- is the latest code on stage and prod?",
         para="Is the most recent code deployed to both stage and prod?",
         entities=["Deployment", "Change", "Project (environment)"], covered=False,
         rules=[(R(r"\b(?:most recent|latest|newest|aktuellste|neueste|recent)\b.{0,40}\b(?:code|work|version|build|release)\b.{0,60}\b(?:stage|prod|production|live|deployed)\b"), False),
                (R(r"\b(?:deployed|live|running) (?:to |on |in )?(?:both )?(?:[\w-]+ )?(?:stage|prod|production)\b"), True), (R(r"\b(?:stage|prod|production)\b.{0,40}\b(?:up to date|latest|recent)\b"), True)]),
    dict(id="scheduled_ran", max_len=240, area="Delivery", q="Did the nightly / scheduled / auto-update job run, and did it succeed?",
         para="Did last night's run happen, what did the auto-update do, check the log tomorrow morning.",
         entities=["Deployment (job run)", "Verification", "Infra host"], covered=False,
         rules=[(R(r"\b(?:auto-?update|nightly|analysis run|ran last night|run (?:last night|overnight)|report .{0,20}(?:gelaufen|ran)|every morning|morning (?:restart|cycle)|check the .{0,20}log)\b"), True),
                (R(r"\bverify the auto-?deploys?\b"), False)]),
    dict(id="where_to_see", area="Delivery", q="Where do I see the report / PR / dashboard / result?",
         para="Where can I look at it -- I do not see a link, a PR, or a verdict; reports land in random folders.",
         entities=["Artifact", "Change", "Project (links)"], covered=False,
         rules=[(R(r"\bwhere (?:do|can|could) i (?:see|find|look|open|check)\b"), False), (R(r"\bwhere (?:is|are) (?:the |my )?(?:report|pr|dashboard|link|result|results|doc|document|plan)\b"), False),
                (R(r"\bi (?:don'?t|do not|cant|can'?t|dont) see (?:a |the |any |it\b|anything|your|my)"), False), (R(r"\bwo (?:sehe|finde|kann ich)\b"), False), (R(r"\bno link\b"), False),
                (R(r"\b(?:reports?|plans?)\b.{0,70}\b(?:random fo?lders?|accumulates? waste)\b"), False)]),
    dict(id="anything_broken", max_len=240, area="Health", q="Is everything healthy -- is anything broken right now?",
         para="Are all systems healthy, is it all good, why so many alerts at once?",
         entities=["Incident", "Condition", "Project", "Infra host"], covered=True,
         rules=[(R(r"\b(?:healthy|gesund|all (?:good|ok|fine|green)|everything (?:is )?(?:good|ok|fine|working|smooth|clean|validated|optimally)|alles (?:ok|gut|in ordnung)|anything (?:broken|wrong|failing|down)|kaputt|are all systems|so many alerts|soviel alerts)\b"), True),
                (R(r"\bwie geht es der infrastruktur\b"), False), (R(r"\bis it (?:all )?good and fine\b"), False)]),
    dict(id="why_recurring", area="Health", q="Why does this keep coming back -- is the recurring issue resolved?",
         para="Why does this alert/issue keep happening; is it resolved or do I have to help manually?",
         entities=["Incident", "Signal (fingerprint)", "Known error", "Project"], covered=False,
         rules=[(R(r"\b(?:immer wieder|again and again|over and over|keeps? (?:coming|happening|flapping|firing|failing|breaking|dying|dropping)|coming back and back|recurring|flapping|flaky|is it resolved|ist (?:es|das) (?:gelöst|behoben)|schon wieder|reoccurring|re-occurring)\b"), True)]),
    dict(id="why_failing", max_len=240, area="Health", q="Why does X not work / fail / show the wrong thing?",
         para="Why is this not working, why does the page still show the old thing?",
         entities=["Incident", "Project", "Deployment", "Signal"], covered=False,
         rules=[(R(r"\bwhy (?:is|are|does|do|did|isn'?t|doesn'?t|don'?t|can'?t|cant|won'?t|wouldn'?t|was|were|didn'?t)\b.{0,80}\b" + PROBLEM + r"\b"), True),
                (R(r"\bwarum (?:geht|funktioniert|ist|sind|läuft|passiert)\b.{0,60}\b(?:nicht|nur|noch|alt|weg|leer|langsam|kaputt)\b"), True),
                (R(r"\b(?:not working|doesn'?t work|isn'?t working|funktioniert nicht|geht nicht)\b"), True),
                (R(r"\b(?:häh|höh|wtf)\b.{0,80}\b(?:see|show\w*|still|only|old|wrong|missing|gone|nothing|now)\b"), True), (R(r"\bwhat happened\b"), True)]),
    dict(id="fresh_data", max_len=240, area="Health", q="Is the data / report / page fresh -- how old is it?",
         para="How old is this data, is the report current?",
         entities=["Signal (freshness)", "Project", "Deployment"], covered=False,
         exclude=[R(r"\b\d+ up to date\b")],
         rules=[(R(r"\b\d+\s?h(?:ours?)?(?: \d+ ?min)? old\b"), False), (R(r"\b(?:how old|wie alt)\b"), True),
                (R(r"\b(?:report|data|dashboard|page|model|blend|forecast)\b.{0,40}\b(?:stale|veraltet|out of date)\b"), True),
                (R(r"\b(?:report|data|dashboard|page|model|blend|forecast|stats|numbers|results?)\b.{0,40}\b(?:still )?up to date\b"), True),
                (R(r"\b(?:still )?up to date\b.{0,40}\b(?:report|data|dashboard|page|model|blend|forecast)\b"), True)]),
    dict(id="infra_resources", area="Infra", q="Is a host low on disk / CPU / memory -- what is eating it?",
         para="The disk is nearly full, CPU is at 100% all the time -- is it us?",
         entities=["Infra host", "Condition", "Project (consumer)"], covered=True, kind="statement",
         exclude=[R(r"\bsacrifices\b")],
         rules=[(R(r"\b(?:disk|storage|speicher|platte)\b.{0,40}\b(?:full|voll|left|free|gb|space)\b"), False), (R(r"\bmacbook is full\b"), False),
                (R(r"\bcpu\b.{0,25}\b(?:100|high|hoch|all the time)\b"), False), (R(r"\b(?:memory|ram|swap|load)\b.{0,30}\b(?:high|full|leak|hoch)\b"), False),
                (R(r"\b\d+\s?gb (?:free|left)\b"), False)]),
    dict(id="connectivity_auth", area="Infra", q="Is a connection or credential broken -- do I need to log in / unlock something?",
         para="Why does it say unauthorized; are the agents losing connection; do I need to re-auth; the keychain prompt again.",
         entities=["Condition (credential/connection)", "Infra host", "Agent"], covered=False,
         rules=[(R(r"\b(?:unauth\w+|logged in|login|log in|1pw|1password|biometric|token (?:expired|invalid|missing)|re-?auth|session (?:expired|not alive)|mam session)\b"), True),
                (R(r"\b(?:keychain|password prompt)\b"), False),
                (R(r"\b(?:mini|herdr|agents?|tailscale|vpn|ssh|macbook)\b.{0,40}\b(?:connection|disconnect\w*|offline|unreachable|lost|issues?)\b"), True),
                (R(r"\b(?:connection|connectivity)\b.{0,40}\b(?:issues?|drop|lost|problems?)\b.{0,40}\b(?:mini|herdr|agents?|tailscale|vpn|ssh|macbook)\b"), True), (R(r"\bpermission denied\b"), False)]),
    dict(id="quota_now", area="Cost", q="Where is my Claude quota (5 h / 7 d) and when does it reset?",
         para="What is my Claude usage, when does the limit reset, can we keep spending tokens?",
         entities=["Quota window", "Agent (consumer)", "Cost"], covered=False,
         exclude=[R(r"\bstorage quota\b|\"Claude Usage\"")],
         rules=[(R(r"\b(?:claude usage|my usage|usage (?:is|at|left))\b"), True),
                (R(r"\b(?:usage limit|session limit|weekly limit|week(?:ly)? (?:usage|limit|quota)|limit (?:reset|resets|is reset)|my limit|our limit|token spend|chill our token|token budget|max usage|rate limit)\b"), False)]),
    dict(id="spend", max_len=240, area="Cost", q="What does it cost -- is cost / usage tracking wired and right?",
         para="What does this cost, which model is cheaper, is usage tracking wired end to end?",
         entities=["Cost", "Usage record", "Project"], covered=False,
         rules=[(R(r"\b(?:cost|costs|kosten|spend|billing|price|preis|preiswert|cheap(?:er)?|expensive|teuer|invoice|budget)\b"), True), (R(r"\b(?:cost|usage|token) tracking\b"), False)]),
    dict(id="config_state", max_len=240, area="Setup", q="Which model / tool / version is configured -- do we have access to the new one?",
         para="Do we already have the new model, which model does X use, is that integration available?",
         entities=["Project (config)", "Agent (engine)", "Cost"], covered=False,
         rules=[(R(r"\b(?:which|what|welche[sn]?) (?:model|modell|version|provider|tool|skill|endpoint|api)\b"), True),
                (R(r"\b(?:do we|haben wir|are we|sind wir|do you|are you) (?:have|use|using|on|running|already|still using|still on|got)\b.{0,70}\b(?:model|version|access|haiku|sonnet|opus|deepseek|gemini|kimi|release|the new|latest|v\d)\b"), True),
                (R(r"\bhow (?:optimal|good|well) (?:is|does|are)\b"), True), (R(r"\bhow (?:are|is) .{0,40}(?:behaving|performing)\b"), True)]),
    dict(id="healing_worked", max_len=240, area="Autonomy", q="Did the automatic recovery / self-healing work -- or did I have to intervene?",
         para="Was the recovery optimal; why did the watchdog not recover it; I had to restart and reconnect manually.",
         entities=["Condition", "Attempt (heal)", "Verification", "Incident"], covered=False,
         rules=[(R(r"\b(?:recovery|recovered|self-?heal\w*|selfhealing|watchdog)\b"), True), (R(r"\b(?:i|we) (?:needed|had) to manually (?:restart|reconnect|do)\b"), False)]),
    dict(id="warden_handled", area="Autonomy", q="What did warden / the loop handle alone -- why did this reach me?",
         para="Should this not have gone through automatically; are the policies too strict; why is the agent so cautious?",
         entities=["Decision", "Incident", "Verification", "Project (policy)"], covered=False, kind="statement",
         rules=[(R(r"\b(?:shouldn'?t|should|müsste|hätte) (?:most of them |it |that )?(?:have )?(?:gone|go|laufen|gehen) through(?: on their own)? auto\w*"), False),
                (R(r"\bunnecessary friction\b"), False), (R(r"\bwarden\b.{0,80}\b(?:policy|policies|friction|autonom\w*)\b"), False), (R(r"\b(?:self[- ]?approve|approve (?:it )?(?:on )?(?:your|its) own)\b"), True),
                (R(r"\b(?:why|warum) (?:do|did|does|muss|should) i (?:need|have|must|manually)\b"), False), (R(r"\bwhy are you being so annoying\b"), False),
                (R(r"\bnot sure if most of them shouldn'?t\b"), False)]),
    dict(id="delegate_decision", area="Autonomy", q="(implied) Which approvals am I still giving that the agent could decide itself?",
         para="You can approve and merge that yourself -- permission handed over, case by case.",
         entities=["Decision", "Change", "Verification"], covered=False, kind="statement",
         rules=[(R(r"\byou (?:can|could|may) (?:then |now )?(?:also )?(?:approve|merge|decide|ship|self[- ]approve)\b"), False),
                (R(r"\b(?:self[- ]?approv\w+|approve (?:it )?(?:and merge )?on your own|merge (?:it |those |them )?on your own)\b"), False),
                (R(r"\bi (?:think )?you can do (?:all|that|it|so)\b|\byou can do (?:all|that|it) (?:of )?(?:them|this|those)?\b"), False),
                (R(r"\bi (?:allow|erlaube|permit)\b"), False), (R(r"\bdon'?t ask (?:me|for confirmation)\b"), False), (R(r"\bship it\b"), False),
                (R(r"\b(?:updated in 1password|updated 1pw),? (?:you can )?go (?:ahead|forward)\b"), False)]),
    dict(id="update_state", max_len=240, area="Infra", q="Are my machines / tools / dependencies up to date -- what still needs an update or restart?",
         para="Is the herdr setup on the mini and here up to date; ready for all the restarts; do the macOS update.",
         entities=["Project (dependencies)", "Infra host", "Condition (drift)"], covered=False,
         rules=[(R(r"\b(?:mini|macbook|herdr|brew|macos|mac osx|setup|machines?|tools?|dependenc\w+|packages?)\b.{0,50}\b(?:up to date|updated|upgraded|outdated)\b"), True),
                (R(r"\b(?:restarts?|restart)\b.{0,30}\?"), False), (R(r"\b(?:mac ?os(?: x)?|osx) update\b"), False)]),
    dict(id="docs_current", max_len=240, area="Setup", q="Are the docs / AGENTS.md / skills current and consistent?",
         para="Is the documentation up to date everywhere, not stale or confusing?",
         entities=["Project (docs)", "Artifact"], covered=False,
         rules=[(R(r"\b(?:documentations?|dokumentation|docs|readmes?|agents\.?md|claude\.?md|skills?|stale|outdated|veraltet)\b.{0,80}\b(?:current|updated|aligned|consistent|clean|thorough\w*|up to date|stale|outdated|confus\w+)\b"), True),
                (R(r"\bscared of stale\b"), False), (R(r"\b(?:document|doc|guide|readme|cutover)\b.{0,30}\bup to date\b"), True)]),
    dict(id="is_wired", max_len=240, area="Setup", q="Is X wired end to end -- observability, cost tracking, Hermes access?",
         para="Is monitoring/cost/usage wired up everywhere; are all gateways reachable from Hermes?",
         entities=["Project (integrations)", "Cost", "Signal (telemetry)"], covered=False,
         rules=[(R(r"\bwired (?:up )?(?:well |nicely |correctly |properly )?e2e\b"), False), (R(r"\b(?:monitoring|observability|cost|usage|tracking|otel|metrics)\b.{0,60}\b(?:wired|connected|integrated|in argo|updated in argo)\b"), True),
                (R(r"\bwired\b.{0,20}\?"), False), (R(r"\bgateways?\b.{0,60}\b(?:in hermes|accessible|accessabile|reachable|erreichbar)\b"), True)]),
]
CAT = {c["id"]: c for c in CATALOG}

ENT = {
    "Project": R(r"\b(?:weatherorb|basalt-ui|argo|warden|hermes|agent-gateway|research-gateway|email-gateway|audio-gateway|image-gateway|homelab|vps|dotfiles|shutterflow|tinycast|modelpick|rollhook|linewatch|brain|sideclaw|usage-tracker|jkrumm\.com|prometheus|rb)\b"),
    "Agent": R(r"\b(?:agents?|agenten|tabs?|pane|herdr|herder|herda|mother|lead|workers?|orchestrat\w+|sessions?|waves?|fleet)\b"),
    "Incident/alert": R(r"\b(?:alerts?|incident|outage|down|broken|kaputt|error|failed|crash\w*|stuck|flaky|flapping|unhealthy|healthy)\b"),
    "Task/plan": R(r"\b(?:waves?|plan|pending|todo|tasks?|ticket|issues?|backlog|missing|open items?)\b"),
    "Change/PR": R(r"\b(?:prs?|mr|merge[d]?|branch|commit|rebase|review|pull request)\b"),
    "Deployment": R(r"\b(?:deploy\w*|release\w*|ship\w*|live|stage|prod|production|rollout|cutover|auto-?update)\b"),
    "Cost/quota": R(r"\b(?:cost|costs|kosten|quota|limit|usage|spend|tokens?|billing|price)\b"),
    "Infra host": R(r"\b(?:mini|homelab|vps|macbook|disk|cpu|memory|container|docker|colima|tailscale|network|router|server|host)\b"),
}
# What the Hermes morning briefing (daily 07:00, cron) already pushes, verified against the latest run's
# section headings: weather, appointments, Infrastruktur (Kuma, Docker, watchdog and warden counts),
# 24 h warnings, health, work sprint and reviews, GitHub, "Agenten & Projekte" (per-project changelog
# lines; the agent overview was unavailable on 2026-10-22), tasks. The evening report is personal only.
PUSH = {
    "anything_broken": ("yes", "Kuma, Docker, watchdog, 24 h warnings, warden counts"),
    "since_away": ("partial", "per-project changelog lines, 24 h warnings; no per-agent record"),
    "all_agents": ("partial", "agent overview section (unavailable on 2026-10-22); counts, not per agent"),
    "needs_me": ("partial", "warden needs_decision count and items that ask a question"),
    "infra_resources": ("partial", "Dev Host heartbeat warnings; no disk or CPU series"),
}

SHORT = {
    "where_are_we": "where are we / how is it going", "since_away": "what happened while I was away", "all_agents": "how are all my agents and waves",
    "needs_me": "what is waiting for me", "what_pending": "what is still pending", "agent_alive": "is that agent stuck or done",
    "nudge_continue": "continue-nudges to parked agents", "tab_cleanup": "which herdr tabs can close", "done_shipped_live": "is it done, merged, live",
    "version_per_env": "which version runs where", "scheduled_ran": "did the nightly job run", "where_to_see": "where do I see the result",
    "anything_broken": "is anything broken", "why_recurring": "why does it keep coming back", "why_failing": "why does X not work",
    "fresh_data": "how fresh is the data", "infra_resources": "disk and CPU pressure", "connectivity_auth": "broken connection or login",
    "quota_now": "Claude quota and reset time", "spend": "what does it cost", "config_state": "which model or tool is configured",
    "healing_worked": "did self-healing work", "warden_handled": "why did this reach me", "delegate_decision": "approvals the agent could take",
    "update_state": "what needs an update", "docs_current": "are the docs current", "is_wired": "is X wired end to end",
}

# Where the answer comes from when the agent's tool calls are not the answer. Each line is backed by owner
# messages in the candidate set (quota: "Why is CU menu bar saying unauthorized and not showing weekly usage?",
# "it shows 12 on the weekly"; fleet: "confused by the Herdr setup and what is active or not", "so many tabs open").
TODAY_NOTE = {
    "quota_now": "The agents are told, not asked: he reads the 5 h / 7 d windows himself in a Claude Usage menu-bar extension he built (its unauthorized state is itself one of the asks) and the statusline, then types the reset time at the agents. Hermes can run the usage fetcher on request.",
    "all_agents": "He also reads herdr himself and gets lost in it (\"confused by the Herdr setup and what is active or not\"); Hermes answers from `herdr` workspace/agent lists, the warden skill and `git log`.",
    "tab_cleanup": "He asks an agent to review the tabs and close what is not needed (\"review where they are, what is really still needed\"); the closing decision is not automated.",
    "needs_me": "The lists he has are the briefing's agents-and-projects section and warden's Slack cards; mid-session he asks the repo's agent.",
}

ESTATE_GATE = R(r"\b(?:herdr|herder|agents?|agenten|warden|argo|hermes|waves?|fleet|mother|lead|workers?|orchestrat\w+|tabs?|claude|usage|quota|limit|deploy\w*|mini|homelab|vps|alerts?|kuma|docker|ssh|tailscale|repo|prs?|session|gateway|launchd|cron|systeme|systems|healthy|gesund|infrastruktur|infrastructure|container|server|backups?|disk|brain|obsidian|ticktick|monitoring|incident|outage)\b")

# The owner's two design prompts name things he wants to see. Hand-extracted, each mapped to
# canonical classes; probes count how often the log mentions them in owner voice.
STATED_WANTS = [
    ("A", "Argo shows the state of fleets, agents, warden and projects", ["all_agents", "agent_alive", "needs_me", "where_are_we"], r"\b(?:fleet|agents?)\b.{0,60}\b(?:state|status|overview|show)\b"),
    ("A", "Per-project page: links (herdr mother, app, git), key stats", ["where_are_we"], r"\b(?:project page|per project|project view)\b"),
    ("A", "Per-project: needs attention", ["needs_me"], r"\bneeds attention\b"),
    ("A", "Per-project: tasks and todos (Beads, TickTick)", ["what_pending"], r"\b(?:ticktick|beads|todos?)\b"),
    ("A", "Per-project: artifacts (plans, reports to comment on)", ["where_to_see"], r"\b(?:artifacts?|plannotator|review (?:service|gateway))\b"),
    ("A", "Per-project: health", ["anything_broken"], r"\bhealth\b"),
    ("A", "Per-project: changelog (today a Slack cron)", ["since_away"], r"\bchangelog\b"),
    ("A", "Per-project: cost stats / usage tracking", ["quota_now", "spend"], r"\b(?:usage|cost) (?:stats|tracking)\b"),
    ("A", "Per-project: traffic", [], r"\b(?:traffic|umami|visitors|analytics)\b"),
    ("A", "Per-project: git status", ["where_are_we"], r"\bgit status\b"),
    ("A", "Per-project: dependency state", [], r"\b(?:dependenc\w+|outdated packages|renovate)\b"),
    ("A", "Pages for health, usage-tracking, traffic, needs attention, artifacts", ["anything_broken", "quota_now", "needs_me"], r"\b(?:health page|usage page)\b"),
    ("A", "Infra of mini, homelab, vps monitored and self-healed; anomalies and attacks", ["anything_broken", "infra_resources"], r"\b(?:attack|anomal\w+|intrusion|crowdsec)\b"),
    ("A", "Herdr cleanup: close finished tabs, truncate or compact old agents", ["tab_cleanup"], r"\b(?:compact|truncate|rotate)\b.{0,30}\b(?:agents?|mothers?|leads?)\b"),
    ("A", "A human business decision in < 1 % of cases", ["needs_me", "delegate_decision"], r"\bbusiness decision\b"),
    ("B", "Where things are, where the agents are", ["all_agents"], r"\bwo (?:die|sind) .{0,30}agent"),
    ("B", "Show what is important, what to do, where to look, what happened", ["needs_me", "since_away", "anything_broken"], r"\bwas wichtig ist\b"),
    ("B", "Morning and evening briefings, Hermes chat, Slack alerts inside Argo", ["since_away", "anything_broken"], r"\b(?:morning|evening) (?:briefing|report)\b"),
    ("B", "Things I must still look at; things that are finished, close them", ["needs_me", "tab_cleanup"], r"\bwirklich fertig\b"),
    ("B", "Requests I must allow that the agent could decide alone", ["warden_handled", "delegate_decision"], r"\berlauben müsste\b"),
    ("B", "How warden really ran", ["warden_handled"], r"\bwie .{0,10}warden .{0,10}lief\b"),
    ("B", "Mini remote-dev status and the MacBook's local herdr (Shutterflow)", ["all_agents"], r"\bmacbook herdr\b"),
    ("B", "Metrics, monitoring and cross-tracking, all in one place", ["is_wired", "spend"], r"\bcross.?track\w+\b"),
]


# --------------------------------------------------------------------------- classification
def atoms(t):
    t = re.sub(r"https?://\S+", "<url>", t)
    return [p.strip() for p in re.split(r"(?<=[.!?])\s+|\n+", t) if p.strip()]


def units_of(t):
    """Units to test. Short messages: the message and its atoms. Long: only `?` atoms."""
    if len(t) <= MAX_UNIT:
        return [t] + [a for a in atoms(t) if a != t and len(a) <= MAX_UNIT]
    if len(t) > LONG_MSG:
        return [a for a in atoms(t) if "?" in a and len(a) <= 250]
    return [a for a in atoms(t) if len(a) <= MAX_UNIT]


def classify(row):
    """Sets row['classes'] (sorted list), row['form'] ('question'|'statement'), row['unit'] (best unit)."""
    t = row["text"]
    hits = {}
    for u in units_of(t):
        qf = is_question_form(u)
        for c in CATALOG:
            if any(ex.search(u) for ex in c.get("exclude", [])) or len(u) > c.get("max_len", 10**6):
                continue
            for i, (rx, need_q) in enumerate(c["rules"]):
                if need_q and not qf:
                    continue
                if rx.search(u):
                    prev = hits.get(c["id"])
                    if prev is None or (qf and not prev[1]):
                        hits[c["id"]] = (u, qf)
                        row.setdefault("_rule", {})[c["id"]] = i
                    break
    if row["ws"] in ("home", "hermes") or row["repo"] == "brain":
        if not ESTATE_GATE.search(t):
            hits = {}
    row["classes"] = sorted(hits)
    row["unit"] = {k: v[0] for k, v in hits.items()}
    row["qform"] = {k: v[1] for k, v in hits.items()}
    return row


PRIVATE_TOPICS = re.compile(r"\b(?:MAM|torrent\w*|1337x|seeding|jelly\w+|audiobookshelf|annas\w*|sehlfmark|qbittorrent|prowlarr|karakeep|immich|immihc|samba|dufs)\b", re.I)


def safe_excerpt(row, cid=None):
    """<= 160 chars, redacted. None for IuRoot sessions (repo name only, never quotes) and for
    homelab-private (self-contained: its services are never referenced elsewhere)."""
    from redact import redact  # noqa: PLC0415  (local only)
    if row["ws"] == "IuRoot" or row["repo"] == "homelab-private":
        return None
    u = (row["unit"].get(cid) if cid else None) or row["text"]
    if PRIVATE_TOPICS.search(u):
        return None
    u = re.sub(r"\bjkrumm@[\w.-]+", "<user>@<host>", u)
    u = re.sub(r"\b[A-Z]{2}\d{2}(?: ?\d{4}){3,7} ?\d{0,4}\b", "<iban>", u)
    u = re.sub(r"\+?\d[\d ()./-]{8,}\d", "<num>", u)
    u = re.sub(r"\s+", " ", u).strip()
    u = redact(u)
    return (u[: EXCERPT - 1] + "…") if len(u) > EXCERPT else u


# --------------------------------------------------------------------------- aggregation
def pct(vals, p):
    if not vals:
        return None
    v = sorted(vals)
    k = (len(v) - 1) * p
    lo, hi = int(math.floor(k)), int(math.ceil(k))
    return round(v[lo] + (v[hi] - v[lo]) * (k - lo), 1)


def day_of(ts):
    return ts[:10]


def age_days(ts, as_of_dt):
    return (as_of_dt - dt.datetime.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=dt.timezone.utc)).total_seconds() / 86400


def aggregate(rows, as_of_dt):
    by_class = collections.defaultdict(list)
    for r in rows:
        for c in r["classes"]:
            by_class[c].append(r)
    out = []
    for c in CATALOG:
        cid = c["id"]
        rs = sorted(by_class.get(cid, []), key=lambda r: r["ts"])
        if not rs:
            out.append(dict(id=cid, area=c["area"], question=c["q"], paraphrase=c["para"], count=0, rank_score=0.0, push_level=PUSH.get(cid, ("no", ""))[0], push_note=PUSH.get(cid, ("no", ""))[1], kind=c.get("kind", "question")))
            continue
        w = sum(0.5 ** (age_days(r["ts"], as_of_dt) / HALF_LIFE_D) for r in rs)
        days = collections.Counter(day_of(r["ts"]) for r in rs)
        repeat_days = sorted(d for d, n in days.items() if n >= 2)
        by_sess = collections.defaultdict(list)
        for r in rs:
            by_sess[(r.get("chan", "claude"), r["sid"])].append(r["ts"])
        fast = 0
        sess_rep = 0
        gaps = []
        for _k, tss in by_sess.items():
            if len(tss) >= 2:
                sess_rep += 1
                tss.sort()
                for a, b in zip(tss, tss[1:]):
                    gap = (dt.datetime.strptime(b[:19], "%Y-%m-%dT%H:%M:%S") - dt.datetime.strptime(a[:19], "%Y-%m-%dT%H:%M:%S")).total_seconds()
                    if gap <= 86400:
                        gaps.append(gap)
                    if gap <= 7200:
                        fast += 1
        chans = collections.Counter(r.get("chan", "claude") for r in rs)
        repos = collections.Counter((r["repo"] if r["ws"] != "hermes" else "(hermes)") for r in rs if r["repo"] or r["ws"] == "hermes")
        ws = collections.Counter(r["ws"] for r in rs)
        q_n = sum(1 for r in rs if r["qform"].get(cid))
        turns = [r["turn"] for r in rs if r["turn"]["asst"] > 0 or r["turn"]["answered"] or r["turn"]["interrupted"]]
        lat = [t["answer_s"] for t in turns if t["answered"] and t["answer_s"] is not None]
        ft = [t["first_text_s"] for t in turns if t["first_text_s"] is not None]
        tools = [t["tools"] for t in turns if t["answered"]]
        no_tool = sum(1 for t in turns if t["answered"] and t["tools"] == 0)
        paths = collections.Counter()
        for t in turns:
            for tok in set(t["path"]):
                paths[tok] += 1
        n_t = max(1, len(turns))
        ent = {}
        for name, rx in ENT.items():
            n = sum(1 for r in rs if rx.search(r["unit"].get(cid, "") + " " + (r["text"] if len(r["text"]) <= 300 else "")))
            if n:
                ent[name] = n
        last14 = sum(1 for r in rs if age_days(r["ts"], as_of_dt) <= 14)
        out.append(dict(
            id=cid, area=c["area"], question=c["q"], paraphrase=c["para"], kind=c.get("kind", "question"),
            count=len(rs), count_question_form=q_n, count_last_14d=last14, count_prior_31d=len(rs) - last14,
            rank_score=round(w, 3), first_seen=rs[0]["ts"][:10], last_seen=rs[-1]["ts"][:10], days_active=len(days),
            channels=dict(sorted(chans.items())), top_projects=dict(repos.most_common(6)), workspaces=dict(sorted(ws.items())),
            entities_needed=c["entities"], entity_mentions=dict(sorted(ent.items(), key=lambda kv: -kv[1])),
            repeat_days=repeat_days, max_per_day=max(days.values()), sessions_with_repeat=sess_rep, fast_repeats_2h=fast,
            repeated_within_day=bool(repeat_days),
            turn_n=len(turns), answered_n=len(lat), answer_s_median=pct(lat, 0.5), answer_s_p90=pct(lat, 0.9),
            first_text_s_median=pct(ft, 0.5), tool_calls_median=pct(tools, 0.5), no_tool_share=round(no_tool / max(1, len(tools)), 2) if tools else None,
            path_top=[(k, round(v / n_t, 2)) for k, v in paths.most_common(60) if k not in GENERIC][:6],
            path_generic={k: round(v / n_t, 2) for k, v in sorted(paths.items()) if k in GENERIC},
            push_level=PUSH.get(cid, ("no", ""))[0], push_note=PUSH.get(cid, ("no", ""))[1],
            gap_s_median_same_session=pct(gaps, 0.5), assistant_entries_median=pct([t["asst"] for t in turns if t["answered"]], 0.5),
        ))
    out.sort(key=lambda x: (-x["rank_score"], x["id"]))
    for i, x in enumerate(out, 1):
        x["rank"] = i
    return out


# --------------------------------------------------------------------------- rendering
def fmt_s(s):
    if s is None:
        return "n/a"
    if s < 90:
        return f"{s:.0f} s"
    if s < 5400:
        return f"{s / 60:.0f} min"
    return f"{s / 3600:.1f} h"


def short_path(q, k=4):
    if not q.get("path_top"):
        return "no tool call (answered from the session's own context)" if q.get("turn_n") else "not measured (no turn data)"
    return ", ".join(f"`{t}` {int(s * 100)}%" for t, s in q["path_top"][:k])


def render_md(doc):
    f = doc["funnel"]
    T = doc["totals"]
    qs = [q for q in doc["questions"] if q["count"] > 0]
    by_id = {q["id"]: q for q in doc["questions"]}
    questions_only = [q for q in qs if q["kind"] == "question"]
    L = []
    L.append("# What the owner asks about the estate -- question inventory\n")
    L.append(f"AS_OF {doc['as_of']}. Built by `questions.py` from his own messages (`questions.out.json`, `candidates.out.json`). "
             "Phase 1/5 evidence: Argo is designed from these questions, so every row below is a class of real owner messages, not an imagined one. "
             "Numbers here are rendered from the JSON; nothing is typed by hand except the paraphrases and the verdict wording.\n")
    L.append("## Verdict\n")
    ch = T["by_channel"]
    L.append(f"- **{T['owner_messages']} owner messages** survive the provenance gate (Claude Code on the mini {ch.get('claude_mini', 0)}, on the MacBook {ch.get('claude_macbook', 0)}, "
             f"Hermes {sum(v for k, v in ch.items() if k.startswith('hermes'))}). **{T['classified_messages']}** ({T['classified_messages'] * 100 // max(1, T['owner_messages'])}%) fall into one of "
             f"**{len(qs)} canonical questions**; {T['classified_question_form']} of them are phrased as a question. The remaining messages are direction, product feedback and personal research.")
    h_cls = sum(v for k, v in T["classified_by_channel"].items() if k.startswith("hermes"))
    L.append(f"- **He asks his session agents, not his tools.** {T['classified_messages'] - h_cls} classified asks went to a Claude Code session in a repo root, {h_cls} to Hermes. "
             f"Hermes drew {doc['hermes']['owner_rows']} owner messages in 60 days, {ch.get('hermes_argo', 0)} of them through Argo's chat (Argo UI views are not logged in these sources). Besides Slack alerts, the standing push is the 07:00 briefing.")
    L.append("- **Ranking (frequency x recency):** " + "; ".join(f"{SHORT[q['id']]} ({q['count']})" for q in qs[:8]) + ". Classes marked implied are needs he states instead of asks.")
    nc = by_id.get("nudge_continue", {})
    if nc.get("count"):
        gap = nc.get("gap_s_median_same_session")
        L.append(f"- **The loudest signal is not a question.** {nc['count']} messages are `continue` / `go` / `limit resets in 5 min` typed at an agent that had stopped with work left, on {nc['days_active']} of the last 45 days"
                 + (f"; consecutive nudges in one session are a median {fmt_s(gap)} apart" if gap else "") + ". Which agent is parked, and why, is something he has to find out himself.")
    rep = [q for q in qs if q["repeated_within_day"]]
    L.append(f"- **Answer not at hand:** {len(rep)} of {len(qs)} classes were asked on a day with at least two asks; {sum(q['fast_repeats_2h'] for q in qs)} asks repeat within 2 h in the same session "
             f"(strongest in: {', '.join(q['id'] for q in sorted(qs, key=lambda q: -q['fast_repeats_2h'])[:3] if q['fast_repeats_2h'])}).")
    L.append(f"- **The push does not stop the asking.** {T['classified_in_pushed_classes']} classified asks fall in classes the Hermes morning briefing already touches (infrastructure, warnings, agents and projects, needs-decision counts); "
             "he asked anyway, mid-session, with the repo's agent. The briefing counts and lists; it does not say which agent is stuck, what shipped, or what the quota is.")
    L.append(f"- **Every answer is rebuilt from scratch.** Across answered turns the median is {fmt_s(T['answer_s_median'])} to a final answer after {T['tool_calls_median']} tool calls; "
             f"{int(T['no_tool_share'] * 100)}% are answered with no tool call. The agent runs " + ", ".join(f"`{t}`" for t, _ in T["path_top"][:5]) + f" -- there is no read model to ask (answered turns measured: {T['turns_measured']}).")
    unm = [w["want"].split(": ")[-1] for w in doc["stated_wants"] if not w["maps_to"]]
    L.append("- **Named in the prompts, never a question in the logs:** per-project " + " and ".join(unm) + " appear only as tool setup and directives (see the design-prompt table). Build them behind the exception line.\n")
    L.append("## Method and limits\n")
    L.append("- **Owner message:** `origin.kind == human`, CLI entrypoint, not sidechain, not a wrapper, not an agent brief, session cwd not a worktree, deduplicated by uuid. "
             "Briefs, relays and fleet traffic typed into panes look human to Claude Code, so they are removed by pattern (`AGENT_FED`) and by cwd. This errs towards dropping real messages: precision over recall.")
    L.append("- **A class counts a message once;** one message can hold several questions. Classes are plain regex rules in `CATALOG`, nothing is learned. `question form` = a `?`, an interrogative or status stem, or an uncertainty marker.")
    L.append("- **Rank** = sum of 0.5^(age/14 d) over the class's messages. Days are UTC. Repeat day = a day with >= 2 asks of the class across all sessions; fast repeat = the same class re-asked in the same session within 2 h.")
    L.append("- **Latency** = owner message to the first final answer (`stop_reason end_turn`); turns that were interrupted or ran past 150 assistant entries are not timed. Hermes uses the first `finish_reason stop`.")
    L.append(f"- **Probes excluded:** Hermes API sessions `api-*`, `oneshot` and `cli` messages are run by agents (\"reply with pong\", \"Validation r3: how many open watchdog items?\"): {doc['hermes']['probe_count']} in the window, listed under *Synthetic probes*.")
    L.append("- **Privacy:** excerpts are <= 160 chars and redacted; IuRoot sessions contribute counts and repo names only. Sessions in `brain/` and `~` count only when they name an estate entity.")
    mac = doc["claude_stats"]["macbook"]
    if "fallback" in mac:
        L.append(f"- **MacBook leg degraded:** {mac['fallback']}. Counts include those rows; latency and answer paths for MacBook-only asks are missing.")
    L.append("")
    L.append("## Funnel\n")
    L.append("| Stage | n |")
    L.append("|-|-|")
    for k, v in f["rows"]:
        L.append(f"| {k.strip()} | {v} |")
    L.append("")
    L.append("## The questions, ranked by frequency x recency\n")
    L.append("| # | Question | Asks (q-form) | Last 14 d / prior 31 d | Days | Repeat days (max/day) | Fast repeats | Channels | Median answer | Push |")
    L.append("|-|-|-|-|-|-|-|-|-|-|")
    for q in qs:
        chs = ", ".join(f"{k.replace('claude_', 'cc ').replace('hermes_', 'h ')} {v}" for k, v in q["channels"].items())
        stmt = q["kind"] == "statement"
        ans = "-" if stmt else f"{fmt_s(q['answer_s_median'])} (n={q['answered_n']})"
        L.append(f"| {q['rank']} | {q['question']}{' *(implied)*' if stmt and not q['question'].startswith('(implied)') else ''} | {q['count']} ({q['count_question_form']}) | {q['count_last_14d']} / {q['count_prior_31d']} | {q['days_active']} | "
                 f"{len(q['repeat_days'])} ({q['max_per_day']}) | {q['fast_repeats_2h']} | {chs} | {ans} | {q['push_level']} |")
    L.append("")
    L.append("`Repeat days`: a number here means the answer was not at hand on that day. `Push`: whether the Hermes morning briefing already carries the class (yes, partial, no). Implied classes are needs the owner states instead of asks.\n")
    L.append("## Per question: paraphrase, entities, how he gets the answer today\n")
    for q in qs:
        L.append(f"### {q['rank']}. {q['question']}\n")
        L.append(f"- **Paraphrase:** {q['paraphrase']}")
        L.append(f"- **Asked:** {q['count']} messages ({q['count_question_form']} in question form) over {q['days_active']} days, {q['first_seen']} to {q['last_seen']}; last 14 d {q['count_last_14d']}. Where: " + ", ".join(f"{k} {v}" for k, v in q["top_projects"].items()))
        L.append(f"- **Entities the answer needs:** {', '.join(q['entities_needed'])}. Named in the asks: " + (", ".join(f"{k} {v}" for k, v in list(q["entity_mentions"].items())[:5]) or "-"))
        if not q["turn_n"]:
            L.append("- **Answer today / time:** not measured -- no turn data for these asks (MacBook-only rows when the ssh leg is down).")
            if q["repeated_within_day"]:
                L.append(f"- **Repeated within a day:** {len(q['repeat_days'])} day(s) with >= 2 asks (max {q['max_per_day']} in one day); fast same-session repeats {q['fast_repeats_2h']}. Days: " + ", ".join(q["repeat_days"][:8]))
            L.append("")
            continue
        ans = f"- **{'What the agent does next' if q['kind'] == 'statement' else 'Answer today'}:** {short_path(q)}"
        if q.get("path_generic"):
            ans += "; also " + ", ".join(f"{k} {int(v * 100)}%" for k, v in q["path_generic"].items())
        ans += f". Tool calls per answered turn (median) {q['tool_calls_median'] if q['tool_calls_median'] is not None else 'n/a'}; answered without a tool call {int((q['no_tool_share'] or 0) * 100)}%."
        if q["push_level"] != "no":
            ans += f" **Push:** {q['push_level']} -- {q['push_note']}."
        L.append(ans)
        if q["id"] in TODAY_NOTE:
            L.append(f"- **Also today:** {TODAY_NOTE[q['id']]}")
        if q["kind"] == "statement":
            L.append(f"- **Time:** an action, not an answer. After it the agent runs a median {fmt_s(q['answer_s_median'])} before it ends its turn again (n={q['answered_n']})"
                     + (f"; consecutive asks in one session are a median {fmt_s(q['gap_s_median_same_session'])} apart." if q.get("gap_s_median_same_session") else "."))
        else:
            L.append(f"- **Time:** median {fmt_s(q['answer_s_median'])}, p90 {fmt_s(q['answer_s_p90'])} to a final answer after {q['assistant_entries_median'] if q.get('assistant_entries_median') is not None else 'n/a'} assistant entries (n={q['answered_n']} of {q['turn_n']} measured turns); first visible text {fmt_s(q['first_text_s_median'])}."
                     + (f" Consecutive asks in one session: median {fmt_s(q['gap_s_median_same_session'])} apart." if q.get("gap_s_median_same_session") else ""))
        if q["repeated_within_day"]:
            L.append(f"- **Repeated within a day:** {len(q['repeat_days'])} day(s) with >= 2 asks (max {q['max_per_day']} in one day); fast same-session repeats {q['fast_repeats_2h']}. Days: " + ", ".join(q["repeat_days"][:8]))
        L.append("")
    L.append("## By area: what each cluster of questions needs\n")
    L.append("| Area | Distinct asks | Classes | Entities the answers draw on |")
    L.append("|-|-|-|-|")
    for a in doc["areas"]:
        L.append(f"| {a['area']} | {a['asks']} | {', '.join(a['classes'])} | {', '.join(a['entities'])} |")
    L.append("")
    L.append("## Entity demand\n")
    L.append("How many classified asks touch each entity (keyword match on the matched unit and short messages; a lower bound). This is the read-model shopping list.\n")
    L.append("| Entity | Asks |")
    L.append("|-|-|")
    for k, v in doc["entity_demand"]:
        L.append(f"| {k} | {v} |")
    L.append("")
    L.append("## Named in the design prompts, and what the logs say\n")
    L.append("| Prompt | Wants to see | Maps to | Owner asks in those classes | Keyword probe (q-form / any) |")
    L.append("|-|-|-|-|-|")
    for w in doc["stated_wants"]:
        probe = f"{w['asked']} / {w['mentioned']}" if w["asked"] is not None else "-"
        asks = w["class_asks"] if w["class_asks"] is not None else "-"
        L.append(f"| {w['prompt']} | {w['want']} | {', '.join(w['maps_to']) or '(no class)'} | {asks} | {probe} |")
    L.append("")
    unm = [w for w in doc["stated_wants"] if not w["maps_to"]]
    L.append("Prompt A = session 94025058 (2026-10-22); prompt B = session b224d6e5 (2026-10-21, German). Asks = distinct classified owner messages in the mapped classes. "
             "Wants with no class (" + "; ".join(f"{w['want'].split(': ')[-1]} {w['asked']}/{w['mentioned']}" for w in unm) + " question-form / any keyword mention) show only tool setup and directives in the logs "
             "(an Umami key, \"update the dependencies\"), never a question about the state itself. They are design wishes, not recurring questions: put them behind the exception line, not on the home view.\n")
    L.append("## Standing questions already answered by push (Hermes cron, 60 d)\n")
    L.append("| Job | Runs |")
    L.append("|-|-|")
    for k, v in doc["hermes"]["cron"]:
        L.append(f"| {k} | {v} |")
    L.append("")
    L.append("The morning briefing (07:00 host time) carries: weather, appointments, **Infrastruktur** (Kuma monitors up/total, homelab and VPS containers, watchdog items, warden state counts), 24 h warnings, health and training, work sprint and reviews, GitHub, "
             "**Agenten & Projekte** (per-project changelog lines; on 2026-10-22 the agent overview itself was unavailable), tasks. The 22:00 evening report is personal only (training, recovery, tomorrow). "
             "Neither says which agent is stuck, what is waiting for him with a deadline, or what the quota is.\n")
    L.append("## Synthetic probes (not owner messages)\n")
    L.append(f"{doc['hermes']['probe_count']} agent-authored Hermes API/CLI probes in the window, {doc['hermes']['probe_status_like']} phrased as status questions "
             "(\"which of my Claude agents need me, where does basalt-ui stand\", \"what is going on with warden, short status\", \"how is the infrastructure, all healthy\", "
             "\"how many containers on homelab and VPS, which has the most restarts\", \"how many open watchdog items\"). They show what the integrators assume he asks; none is counted above.\n")
    L.append("## Hand check\n")
    hc = doc["hand_check"]
    L.append(hc["note"] + "\n")
    L.append("| Class | Sampled | Correct | Precision |")
    L.append("|-|-|-|-|")
    for r in hc["rows"]:
        L.append(f"| {r['id']} | {r['sampled']} | {r['correct']} | {r['precision']} |")
    L.append("")
    L.append(f"Overall {hc['correct']}/{hc['sampled']} ({hc['precision']}). Single annotator, small per-class samples: read the per-class figures as a sanity check, not as a confidence interval. Recall is not measured; see the residue.\n")
    L.append("## Residue: question-form messages no class caught\n")
    L.append(f"{doc['residue']['count']} owner messages (<= 700 chars) are in question form or carry a status stem, name an estate entity (agent, tab, warden, deploy, quota, host ...) and match no class (per repo in `candidates.out.json`; no excerpts are stored for them). "
             "Reading them: product feedback on the apps he builds (Shutterflow, TinyCast), model and tool choices, personal research, and directions phrased as questions. "
             "No further estate-state class stood out above two messages.\n")
    return "\n".join(L) + "\n"


# --------------------------------------------------------------------------- hand check
def load_labels(path):
    """labels.json: {"<candidate id>:<class>": true|false} -- my verdicts on a seeded sample."""
    try:
        return json.load(open(path))
    except (OSError, ValueError):
        return {}


# --------------------------------------------------------------------------- main
def run(argv):
    from redact import redact  # noqa: PLC0415,F401

    as_of_dt = dt.datetime.strptime(AS_OF, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
    since_c = (as_of_dt - dt.timedelta(days=CLAUDE_DAYS)).strftime("%Y-%m-%dT%H:%M:%SZ")
    since_h = (as_of_dt - dt.timedelta(days=HERMES_DAYS)).timestamp()
    cache = argv[argv.index("--cache") + 1] if "--cache" in argv else None
    funnel_rows = []
    if cache and os.path.exists(cache):
        blob = json.load(open(cache))
        mini_rows, mini_stats, mac_rows, mac_stats = blob["mini_rows"], blob["mini_stats"], blob["mac_rows"], blob["mac_stats"]
        h_rows, probes, cron, h_stats = blob["h_rows"], blob["probes"], blob["cron"], blob["h_stats"]
    else:
        mini_rows, mini_stats = collect_claude(os.path.expanduser("~/.claude/projects"), since_c, AS_OF)
        mac_rows, mac_stats = ([], {"skipped": True}) if "--no-mac" in argv else collect_mac(since_c, AS_OF)
        if "error" in mac_stats and "--mac-dump" in argv:
            mac_rows, mac_stats = mac_from_dump(argv[argv.index("--mac-dump") + 1], since_c, AS_OF, mac_stats["error"])
        h_rows, probes, cron, h_stats = collect_hermes(os.path.expanduser("~/.hermes/state.db"), since_h, as_of_dt.timestamp())
        if cache:
            json.dump(dict(mini_rows=mini_rows, mini_stats=mini_stats, mac_rows=mac_rows, mac_stats=mac_stats, h_rows=h_rows, probes=probes, cron=cron, h_stats=h_stats), open(cache, "w"))
    if "error" in mac_stats and "--allow-partial" not in argv:
        sys.exit(f"MacBook leg failed: {mac_stats['error']}\n(retry later, or pass --no-mac / --allow-partial to write outputs without it)")
    for r in mini_rows:
        r["chan"] = "claude_mini"
    for r in mac_rows:
        r["chan"] = "claude_macbook"
    rows = sorted(mini_rows + mac_rows + h_rows, key=lambda r: (r["ts"], r["uuid"]))  # deterministic order, stable diffs
    for r in rows:
        classify(r)
        r["id"] = hashlib.sha1(f"{r['ts']}|{r['sid']}|{r['text'][:80]}".encode()).hexdigest()[:12]

    if "--sample" in argv:  # print the seeded hand-check sample (verdicts go in labels.json)
        by = collections.defaultdict(list)
        for r in rows:
            for c in r["classes"]:
                by[c].append(r)
        for c in CATALOG:
            rs = sorted(by.get(c["id"], []), key=lambda r: r["id"])
            pick = rs if len(rs) <= SAMPLE_PER_CLASS else random.Random(f"{SAMPLE_SEED}:{c['id']}").sample(rs, SAMPLE_PER_CLASS)
            for r in sorted(pick, key=lambda r: r["id"]):
                print(f"{r['id']}:{c['id']}\t{r['ws']}/{r['repo']}\t{r['unit'][c['id']][:260]!r}")
        return

    classified = [r for r in rows if r["classes"]]
    resid = [r for r in rows if not r["classes"] and any(is_question_form(u) for u in units_of(r["text"])[:6]) and r["len"] <= 700 and ESTATE_GATE.search(r["text"])]
    resid_by_repo = collections.Counter((r["repo"] if r["ws"] != "hermes" else "(hermes)") for r in resid)
    cue_c = collections.Counter()
    for r in resid:
        m = re.search(r"\b(where|what|how|why|which|is|are|do|does|did|can|could|should|wo|was|wie|warum|check|verify|show|any|still)\b", r["text"], re.I)
        cue_c[(m.group(1).lower() if m else "?")] += 1

    questions = aggregate(rows, as_of_dt)
    ent_demand = collections.Counter()
    for r in classified:
        for name, rx in ENT.items():
            if rx.search(" ".join(r["unit"].values()) + " " + (r["text"] if len(r["text"]) <= 300 else "")):
                ent_demand[name] += 1

    areas = []
    for area in dict.fromkeys(c["area"] for c in CATALOG):
        ids = [c["id"] for c in CATALOG if c["area"] == area]
        msgs = [r for r in classified if set(r["classes"]) & set(ids)]
        ents = list(dict.fromkeys(re.sub(r"\s*\(.*\)", "", e) for c in CATALOG if c["area"] == area for e in c["entities"]))
        areas.append(dict(area=area, asks=len(msgs), classes=[i for i in ids if any(i in r["classes"] for r in classified)], entities=ents))
    areas.sort(key=lambda a: -a["asks"])

    # stated wants
    wants = []
    for prompt, want, maps_to, probe in STATED_WANTS:
        if maps_to:  # evidence = asks the owner really made in the mapped classes
            wants.append(dict(prompt=prompt, want=want, maps_to=maps_to, class_asks=sum(1 for r in classified if set(r["classes"]) & set(maps_to)), asked=None, mentioned=None))
            continue
        rx = re.compile(probe, re.I)  # unmapped wish: probe the keywords, question-form vs any mention
        any_n = sum(1 for r in rows if rx.search(r["text"][:1500]))
        ask_n = sum(1 for r in rows if any(rx.search(u) and is_question_form(u) for u in units_of(r["text"])))
        wants.append(dict(prompt=prompt, want=want, maps_to=[], class_asks=None, asked=ask_n, mentioned=any_n))

    labels_all = load_labels(os.path.join(HERE, "labels.json"))
    valid_keys = {f"{r['id']}:{c}" for r in classified for c in r["classes"]}
    labels = {k: v for k, v in labels_all.items() if k in valid_keys}
    stale = len(labels_all) - len(labels)
    hc_rows = []
    for c in CATALOG:
        got = [(k, v) for k, v in labels.items() if k.endswith(":" + c["id"])]
        if got:
            ok = sum(1 for _k, v in got if v)
            hc_rows.append(dict(id=c["id"], sampled=len(got), correct=ok, precision=f"{ok / len(got):.0%}"))
    hc_ok = sum(r["correct"] for r in hc_rows)
    hc_n = sum(r["sampled"] for r in hc_rows)
    hand_note = (f"Seeded sample (seed {SAMPLE_SEED}): up to {SAMPLE_PER_CLASS} classified messages per class (`python3 -I questions.py --sample` prints them), read and judged: does the message really ask "
                 f"this question (or state it as a need) of the estate? Verdicts live in `labels.json`; {len(labels)} verdicts over {len(hc_rows)} classes"
                 + (f", {stale} stale label(s) ignored (the pair no longer classifies)." if stale else ".")) if labels else "No labels.json present: precision unchecked."

    # per-message candidates (no full text)
    cands = []
    for r in sorted(classified, key=lambda r: r["ts"]):
        cands.append(dict(
            id=r["id"], ts=r["ts"], chan=r["chan"], ws=r["ws"], repo=r["repo"], sid=r["sid"], len=r["len"],
            classes=r["classes"], question_form=sorted(k for k, v in r["qform"].items() if v),
            excerpt={k: safe_excerpt(r, k) for k in r["classes"]},
            turn=dict(answered=r["turn"]["answered"], answer_s=r["turn"]["answer_s"], first_text_s=r["turn"]["first_text_s"], asst=r["turn"]["asst"], tools=r["turn"]["tools"], interrupted=r["turn"]["interrupted"], path=sorted(set(r["turn"]["path"]))[:8]),
        ))

    by_group = collections.Counter(("hermes" if r["chan"].startswith("hermes") else "claude_code") for r in classified)
    q_turns = [r["turn"] for r in classified if r["turn"]["answered"] and any(CAT[c].get("kind", "question") == "question" for c in r["classes"])]
    ans_s = [t["answer_s"] for t in q_turns if t["answer_s"] is not None]
    ans_tools = [t["tools"] for t in q_turns]
    path_all = collections.Counter(tok for t in q_turns for tok in set(t["path"]))
    funnel_rows = [
        ("transcript files in window, mini", mini_stats.get("files")),
        ("human-origin entries in window, mini", mini_stats.get("human")),
        ("  of which agent-fed briefs / wrappers removed", mini_stats.get("agent_fed_or_wrapper")),
        ("owner messages, mini", mini_stats.get("owner")),
        ("MacBook leg", mac_stats["fallback"] if "fallback" in mac_stats else ("unavailable: " + mac_stats["error"].splitlines()[-1][:80] if "error" in mac_stats else ("skipped" if mac_stats.get("skipped") else "ok (ssh)"))),
        ("transcript files in window, MacBook", mac_stats.get("files")),
        ("human-origin entries in window, MacBook", mac_stats.get("human")),
        ("  of which agent-fed briefs / wrappers removed", mac_stats.get("agent_fed_or_wrapper")),
        ("owner messages, MacBook", mac_stats.get("owner")),
        ("Hermes user messages scanned (60 d)", h_stats.get("user_msgs_scanned")),
        ("Hermes owner messages (slack, desktop, tui, cli)", len(h_rows)),
        ("Hermes agent-authored probes", len(probes)),
        ("owner messages, all channels", len(rows)),
        ("classified into a canonical question", len(classified)),
        ("  of which in question form", sum(1 for r in classified if any(r["qform"].values()))),
        ("question-form, no class (residue)", len(resid)),
    ]
    doc = dict(
        as_of=AS_OF, windows=dict(claude_days=CLAUDE_DAYS, hermes_days=HERMES_DAYS, half_life_days=HALF_LIFE_D),
        totals=dict(owner_messages=len(rows), classified_messages=len(classified), classified_question_form=sum(1 for r in classified if any(r["qform"].values())), by_channel_group=dict(by_group),
                    by_channel=dict(sorted(collections.Counter(r["chan"] for r in rows).items())),
                    classified_by_channel=dict(sorted(collections.Counter(r["chan"] for r in classified).items())),
                    classified_in_pushed_classes=sum(1 for r in classified if any(PUSH.get(c, ("no",))[0] != "no" for c in r["classes"])),
                    path_top=[(k, v) for k, v in path_all.most_common(40) if k not in GENERIC][:8],
                    answer_s_median=pct(ans_s, 0.5), tool_calls_median=pct(ans_tools, 0.5), no_tool_share=round(sum(1 for x in ans_tools if x == 0) / max(1, len(ans_tools)), 2), turns_measured=len(ans_s)),
        funnel=dict(rows=[(k, v) for k, v in funnel_rows if v is not None]),
        questions=questions, entity_demand=ent_demand.most_common(), stated_wants=wants, areas=areas,
        hermes=dict(owner_rows=len(h_rows), probe_count=len(probes), probe_status_like=sum(1 for p in probes if re.search(r"\b(?:status|los|healthy|gesund|brauchen|wie viele|how many)\b", p["text"], re.I)),
                    cron=sorted(cron.items(), key=lambda kv: -kv[1])[:6], sessions_by_source=h_stats.get("sessions_by_source"), user_msgs_by_source=h_stats.get("user_msgs_by_source")),
        hand_check=dict(note=hand_note, rows=hc_rows, sampled=hc_n, correct=hc_ok, precision=f"{hc_ok / max(1, hc_n):.0%}"),
        residue=dict(count=len(resid), top_cues=cue_c.most_common(15), by_repo=dict(resid_by_repo.most_common(10))),
        claude_stats=dict(mini=mini_stats, macbook=mac_stats),
    )
    for name, obj in (("candidates.out.json", dict(as_of=AS_OF, funnel=doc["funnel"], definitions="see questions.py docstring", candidates=cands, residue_by_repo=dict(resid_by_repo.most_common()))),
                      ("questions.out.json", doc)):
        with open(os.path.join(HERE, name), "w") as fh:
            json.dump(obj, fh, indent=1, sort_keys=False, ensure_ascii=False)
            fh.write("\n")
    with open(os.path.join(HERE, "questions.md"), "w") as fh:
        fh.write(render_md(doc))
    print(f"owner messages {len(rows)}, classified {len(classified)}, questions with data {sum(1 for q in questions if q['count'])}")


def main(argv):
    if argv and argv[0] == "collect-claude":
        rows, st = collect_claude(os.path.expanduser("~/.claude/projects"), argv[1], argv[2])
        sys.stdout.write(json.dumps({"__stats__": st}) + "\n")
        for r in rows:
            sys.stdout.write(json.dumps(r, ensure_ascii=False) + "\n")
        return
    sys.path.insert(0, os.path.join(HERE, "..", "lib"))
    run(argv)


if __name__ == "__main__":
    main(sys.argv[1:])
