#!/usr/bin/env python3
"""How fast did each "locked" model's claims stop being true, and what contradicted them?

Question (postmortem): every locked model since the September estate round drifted
within days. For each locked model, which mechanically checkable claims held, which did
not, and which commit first made a claim false?

Method. A model is a dated lock (a commit). A claim is a predicate over files in one or
more repos (a table's row count, model ids in prose, an allow-list against a promise in
another repo, a hook that must exist). The predicate is replayed over every commit that
touches its files, oldest first, from before the lock to AS_OF. It returns True (claim
present and consistent), False (claim present and contradicted) or None (claim absent).

  holds_at_lock         last non-None state committed before the lock instant
  born_false            already False at the lock, or False at the very commit that
                        introduced the claim; days_to_drift = 0, false_since names the
                        commit that made it false
  first_contradiction   first commit after the claim's start (lock, or the claim's own
                        introduction) at which the predicate is False
  days_to_drift         first_contradiction.date - t0, in days (UTC commit times)
  days_from_lock        first_contradiction.date - model lock, for cross-model comparison
  holds_at_as_of        last non-None state before AS_OF; `flips` counts transitions

Claim kinds: `replay` (predicate over file contents, above), `introduced` (a needle that
the claim says must not exist appears in a path: git pickaxe, verified at the commit) and
`snapshot` (cross-repo count, sampled at the lock and at AS_OF; when it fails at the lock
and holds at AS_OF, daily samples bound the date it converged). Only what a regex or a file
parse can decide is here. Why a claim drifted, whether a later rewrite was deliberate and
which doc should have won is judgment: postmortem.md. The human-authored fields per claim
are `mechanism` (a tag for the pattern) and `cause_class` (enforced, prose, cross_repo,
changed_on_purpose); every date, sha and count is computed. `contradicted_in` attributes the
first contradiction to the round window that contains it: false_at_lock, own_round,
later_round or between_rounds.

Definition keys: none from DEFINITIONS.md; this script defines its own terms above.
Inputs: git objects of ~/SourceRoot repos at commits before AS_OF (never the working
tree). No network. Free text goes through ../lib/redact.py:redact(), plus a scrub of
1Password refs and URLs.

Reproducible as long as no commit dated before AS_OF arrives late (a pull from another
machine); `repo_revs_at_as_of` records the commit read per repo so a diff shows which moved.

Run:  python3 -I drift.py            # writes drift.out.json next to this file
      AS_OF=2026-10-22T08:00:00Z python3 -I drift.py
"""

import json
import os
import re
import statistics
import subprocess
import sys
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))
from redact import redact as _redact  # noqa: E402


def redact(text):
    """lib/redact.py plus two scrubs this public repo wants: 1Password refs and URLs."""
    text = re.sub(r"op://\S+", "op://<ref>", text or "")
    text = re.sub(r"https?://[^\s)`'\"]+", "<url>", text)
    return _redact(text)

AS_OF = os.environ.get("AS_OF", "2026-10-22T08:00:00Z")
ROOT = os.path.expanduser("~/SourceRoot")
OUT = os.path.join(HERE, "drift.out.json")
LOOK_BACK = "2026-08-01T00:00:00Z"
SNIP = 220

# ---------------------------------------------------------------------------- git


def git(repo, *args):
    p = subprocess.run(
        ["git", "-C", os.path.join(ROOT, repo), "-c", "core.quotepath=off", *args],
        capture_output=True, text=True, encoding="utf-8", errors="replace",
    )
    return p.stdout if p.returncode == 0 else None


def utc(iso):
    return datetime.fromisoformat(iso).astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def days_between(a, b):
    fa = datetime.strptime(a, "%Y-%m-%dT%H:%M:%SZ")
    fb = datetime.strptime(b, "%Y-%m-%dT%H:%M:%SZ")
    return round((fb - fa).total_seconds() / 86400, 2)


def commit_info(repo, sha):
    out = (git(repo, "log", "-1", "--format=%H %cI %s", sha) or "").strip()
    full, iso, subj = out.split(" ", 2)
    return {"repo": repo, "sha": full[:7], "date": utc(iso), "subject": redact(subj)[:120]}


_blob_cache = {}


def blobs(repo, sha, paths):
    need = [p for p in paths if (repo, sha, p) not in _blob_cache]
    if need:
        p = subprocess.run(
            ["git", "-C", os.path.join(ROOT, repo), "cat-file", "--batch"],
            input="".join(f"{sha}:{x}\n" for x in need).encode(), capture_output=True,
        )
        data, pos = p.stdout, 0
        for x in need:
            nl = data.index(b"\n", pos)
            header = data[pos:nl].decode("utf-8", "replace")
            pos = nl + 1
            if header.endswith(" missing") or header.endswith(" ambiguous"):
                _blob_cache[(repo, sha, x)] = None
                continue
            size = int(header.split()[2])
            _blob_cache[(repo, sha, x)] = data[pos:pos + size].decode("utf-8", "replace")
            pos += size + 1
    return {p: _blob_cache[(repo, sha, p)] for p in paths if _blob_cache[(repo, sha, p)] is not None}


def rev_at(repo, iso):
    out = git(repo, "rev-list", "-1", f"--before={iso}", "HEAD")
    return out.strip() if out and out.strip() else None


def read_scope(scope, shas):
    return {repo: (blobs(repo, shas[repo], paths) if shas.get(repo) else {}) for repo, paths in scope.items()}


def events(scope, start):
    ev = []
    for repo, paths in scope.items():
        out = git(repo, "log", f"--before={AS_OF}", "--reverse", "--format=%H %cI %s", "--", *paths) or ""
        for line in out.splitlines():
            sha, iso, subj = line.split(" ", 2)
            d = utc(iso)
            if d > start:
                ev.append({"repo": repo, "sha": sha, "date": d, "subject": subj})
    ev.sort(key=lambda e: (e["date"], e["repo"], e["sha"]))
    return ev


# -------------------------------------------------------------------------- replay


def replay(claim):
    scope = claim["scope"]
    shas = {repo: rev_at(repo, LOOK_BACK) for repo in scope}
    files = read_scope(scope, shas)
    holds, snip = claim["check"](files)
    series = [{"date": "start", "repo": None, "sha": None, "subject": "state at look-back", "holds": holds, "snip": snip}]
    for e in events(scope, LOOK_BACK):
        shas[e["repo"]] = e["sha"]
        files[e["repo"]] = read_scope({e["repo"]: scope[e["repo"]]}, shas)[e["repo"]]
        holds, snip = claim["check"](files)
        series.append({"date": e["date"], "repo": e["repo"], "sha": e["sha"], "subject": e["subject"],
                       "holds": holds, "snip": snip})
    return series


def ref(row):
    return {"repo": row["repo"], "sha": (row["sha"] or "")[:7] or None,
            "date": None if row["date"] == "start" else row["date"], "subject": redact(row["subject"])[:120]}


def state_at(live, instant):
    rows = [r for r in live if r["date"] == "start" or r["date"] <= instant]
    return rows[-1] if rows else None


def evaluate_replay(claim, lock):
    lock_date = lock["date"]
    series = replay(claim)
    live = [r for r in series if r["holds"] is not None]
    base = lock_date
    res = {}
    if claim.get("from"):
        landed = commit_info(*claim["from"])
        base = landed["date"]
        res["measured_from"] = {"basis": "the commit that landed the claim", **landed}
    state = state_at(live, base)
    res["holds_at_lock"] = None if state is None else state["holds"]
    res["lock_evidence"] = "" if state is None else redact(state["snip"])[:SNIP]
    res["flips"] = sum(1 for a, b in zip(live, live[1:]) if a["holds"] != b["holds"])
    res["claim_first_seen"] = None if not live or live[0]["date"] == "start" else live[0]["date"]

    if state is not None and state["holds"] is False:
        idx = max((i for i, r in enumerate(live) if r["holds"] is True and r["date"] != "start" and r["date"] <= base),
                  default=None)
        if idx is None and live and live[0]["date"] == "start" and live[0]["holds"] is True:
            idx = 0
        rows = live[(idx + 1) if idx is not None else 0:]
        since = next((r for r in rows if r["holds"] is False), None)
        res.update(born_false=True, never_held_before_lock=idx is None, t0=base,
                   first_contradiction=None if since is None else ref(since), days_to_drift=0.0,
                   days_from_lock=0.0, contradiction_evidence=res["lock_evidence"])
        res["false_since"] = res["first_contradiction"]
    else:
        t0, born, introduced = base, False, None
        if state is None:
            introduced = next((r for r in live if r["date"] != "start" and r["date"] > base), None)
            if introduced is not None:
                t0, born = introduced["date"], introduced["holds"] is False
        after = [r for r in live if r["date"] != "start" and r["date"] > t0 and r["holds"] is False]
        bad = introduced if born else (after[0] if after else None)
        res.update(born_false=born, t0=t0, claim_introduced_after_lock=introduced is not None)
        res["first_contradiction"] = None if bad is None else ref(bad)
        res["days_to_drift"] = 0.0 if born else (None if bad is None else days_between(t0, bad["date"]))
        res["days_from_lock"] = None if bad is None else max(0.0, days_between(lock_date, bad["date"]))
        res["contradiction_evidence"] = "" if bad is None else redact(bad["snip"])[:SNIP]
    final = live[-1] if live else None
    res["holds_at_as_of"] = None if final is None else final["holds"]
    res["as_of_evidence"] = "" if final is None else redact(final["snip"])[:SNIP]
    res["days_held_to_as_of"] = days_between(res["t0"], AS_OF) if res["holds_at_as_of"] else None
    intervals, cur = [], None
    for r in live:
        if r["holds"] is False and cur is None:
            cur = r
        elif r["holds"] is True and cur is not None:
            intervals.append((cur, r))
            cur = None
    if cur is not None:
        intervals.append((cur, None))
    res["false_intervals"] = [
        {"from": None if a["date"] == "start" else a["date"], "from_sha": (a["sha"] or "")[:7] or None,
         "to": None if b is None else b["date"], "to_sha": None if b is None else b["sha"][:7],
         "days": days_between(a["date"] if a["date"] != "start" else LOOK_BACK, b["date"] if b else AS_OF),
         "open": b is None}
        for a, b in intervals if b is None or b["date"] > base]
    fc = res["first_contradiction"]
    res["days_false_to_as_of"] = (days_between(fc["date"], AS_OF) if fc and fc["date"] and res["holds_at_as_of"] is False
                                  else None)
    return res


def evaluate_introduced(claim, lock):
    """The claim says `needle` must not exist under `paths`; find the commit that adds it."""
    repo, needle, paths = claim["repo"], claim["needle"], claim["paths"]
    lock_date = lock["date"]

    def present(sha):
        out = git(repo, "grep", "-l", "-E", needle, sha, "--", *paths)
        return bool(out and out.strip())

    at = rev_at(repo, lock_date)
    res = {"holds_at_lock": None if at is None else not present(at), "flips": None}
    res["lock_evidence"] = "needle present at lock" if at and present(at) else ""
    out = git(repo, "log", f"--before={AS_OF}", "--reverse", "--format=%H %cI %s", "-G" + needle, "--", *paths) or ""
    first = None
    for line in out.splitlines():
        sha, iso, subj = line.split(" ", 2)
        if utc(iso) > lock_date and present(sha):
            first = {"repo": repo, "sha": sha[:7], "date": utc(iso), "subject": redact(subj)[:120]}
            break
    born = res["holds_at_lock"] is False
    res.update(born_false=born, t0=lock_date,
               first_contradiction=None if born else first,
               days_to_drift=0.0 if born else (None if first is None else days_between(lock_date, first["date"])),
               days_from_lock=0.0 if born else (None if first is None else days_between(lock_date, first["date"])),
               contradiction_evidence=res["lock_evidence"] if born else (f"needle /{needle}/ first present" if first else ""))
    head = rev_at(repo, AS_OF)
    res["holds_at_as_of"] = None if head is None else not present(head)
    res["as_of_evidence"] = ""
    res["days_held_to_as_of"] = days_between(lock_date, AS_OF) if res["holds_at_as_of"] else None
    res["days_false_to_as_of"] = (days_between(first["date"], AS_OF) if first and res["holds_at_as_of"] is False else None)
    return res


def evaluate_snapshot(claim, lock):
    at_lock, ev_lock = claim["snapshot"](lock["date"])
    at_asof, ev_asof = claim["snapshot"](AS_OF)
    converged = None
    if at_lock is False and at_asof is True:  # sample daily until it first holds (an upper bound)
        t = datetime.strptime(lock["date"], "%Y-%m-%dT%H:%M:%SZ")
        for k in range(1, 40):
            when = (t + timedelta(days=k)).strftime("%Y-%m-%dT%H:%M:%SZ")
            if when > AS_OF:
                break
            ok, ev = claim["snapshot"](when)
            if ok:
                converged = {"by": when, "days_after_lock": k, "evidence": redact(ev)[:SNIP]}
                break
    return {
        "holds_at_lock": at_lock, "lock_evidence": redact(ev_lock)[:SNIP], "flips": None,
        "born_false": at_lock is False, "t0": lock["date"], "first_contradiction": None,
        "days_to_drift": 0.0 if at_lock is False else None, "days_from_lock": 0.0 if at_lock is False else None,
        "contradiction_evidence": redact(ev_lock)[:SNIP] if at_lock is False else "",
        "holds_at_as_of": at_asof, "as_of_evidence": redact(ev_asof)[:SNIP],
        "days_held_to_as_of": days_between(lock["date"], AS_OF) if at_asof else None,
        "days_false_to_as_of": None, "converged_after_declared_done": converged,
    }


# ------------------------------------------------------------------------ helpers

MODEL_ID_RX = re.compile(
    r"\b(?:deepseek-v\d[\w.-]*|DeepSeek-V\d[\w.-]*|gpt-\d[\w.-]*|claude-(?:sonnet|opus|haiku|fable)[\w.-]*"
    r"|glm-\d[\w.-]*|gemini-\d[\w.-]*|(?:Haiku|Sonnet|Opus|Fable) \d(?:\.\d)?)",
)


def grep_lines(text, pattern, flags=re.I):
    rx = re.compile(pattern, flags)
    return [ln.strip() for ln in (text or "").splitlines() if rx.search(ln)]


def one_line(s, n=90):
    return re.sub(r"\s+", " ", s).strip()[:n]


def get(files, repo, path):
    return (files.get(repo) or {}).get(path)


def section(text, heading_rx):
    m = re.search(r"^#{2,3} " + heading_rx + r"[^\n]*\n(.*?)(?=^#{1,3} |\Z)", text or "", re.S | re.M)
    return m.group(1) if m else None


def table_rows(block):
    return [ln for ln in (block or "").splitlines() if ln.startswith("|") and not re.match(r"^\|[-| :]+\|$", ln)][1:]


# ---------------------------------------------------------------------------- checks


def chk_four_lanes(files):
    t = get(files, "dotfiles", "docs/agent-platform.md")
    if t is None:
        return None, ""
    rows = table_rows(section(t, "Four lanes"))
    if not re.search(r"^## Four lanes", t, re.M):
        return None, "heading 'Four lanes' absent"
    return len(rows) == 4, f"heading 'Four lanes', table rows = {len(rows)}"


def chk_no_model_ids_platform(files):
    t = get(files, "dotfiles", "docs/agent-platform.md")
    if t is None:
        return None, ""
    rule = re.search(r"never a model id in prose", t)
    if not rule:
        return None, "rule absent"
    hits = sorted({m.group(0) for m in MODEL_ID_RX.finditer(t)})
    return not hits, f"rule 'never a model id in prose' + {len(hits)} distinct ids in the same page: {', '.join(hits[:5])}"


def chk_herdr_never_unattended(files):
    t = get(files, "dotfiles", "docs/agent-platform.md")
    if t is None:
        return None, ""
    never = grep_lines(t, r"herdr.*\|.*run unattended work")
    chain = grep_lines(t, r"each wave spawns the next")
    if not never:
        return None, "never-list row absent"
    return not chain, f"never-list '{one_line(never[0], 70)}' vs same page: '{one_line(chain[0], 60) if chain else ''}'"


def chk_hermes_never_code(files):
    soul = get(files, "hermes-agent", "SOUL.md")
    cfg = get(files, "hermes-agent", "config.yaml")
    if soul is None or cfg is None:
        return None, ""
    claim = grep_lines(soul, r"code changes are never yours")
    if not claim:
        return None, "SOUL line absent"
    block = re.search(r"^platform_toolsets:\n(.*?)(?=^\S)", cfg, re.S | re.M)
    tools = sorted(set(re.findall(r"^\s+-\s+(code_execution|file|terminal)\s*$", block.group(1) if block else "", re.M)))
    return not tools, f"SOUL: '{one_line(claim[0], 60)}'; platform_toolsets include {', '.join(tools) or 'none of file/terminal/code_execution'}"


def chk_argo_verbs(files):
    argo = get(files, "argo", "apps/api/src/routes/warden.ts")
    w = None
    for path in ("scripts/loop/notify.py", "scripts/triage.py"):
        t = get(files, "warden", path)
        if t and "ARGO_ACTION_VERBS" in t:
            w = t
    if argo is None or w is None:
        return None, ""
    a = re.search(r"WARDEN_ACTION_VERBS\s*=\s*\[(.*?)\]", argo, re.S)
    b = re.search(r"ARGO_ACTION_VERBS\s*=\s*frozenset\(\{(.*?)\}\)", w, re.S)
    if not a or not b:
        return None, ""
    va = set(re.findall(r"'([a-z_]+)'", a.group(1)))
    vb = set(re.findall(r"\"([a-z_]+)\"", b.group(1)))
    return va == vb, f"warden verbs minus argo verbs = {sorted(vb - va)}; argo minus warden = {sorted(va - vb)}"


def chk_control_plane_owner(files):
    arch = get(files, "dotfiles", "docs/architecture.md")
    plan = get(files, "dotfiles", "docs/waves/PLAN.md") or ""
    if arch is None:
        return None, ""
    w = grep_lines(arch, r"warden.*control plane|control plane.*warden")
    a = grep_lines(plan, r"\|\s*Argo\s*\|[^|]*control plane|Argo becomes the control plane")
    return not (w and a), f"architecture.md names warden the control plane ({len(w)} line(s)); the dotfiles plan names Argo ({len(a)} line(s))"


def chk_dispatch_lanes_exist(files):
    sh = get(files, "dotfiles", "scripts/remote-dev.sh")
    if sh is None:
        return None, ""
    ad = get(files, "dotfiles", "scripts/agent-dispatch.sh") is not None
    bg = bool(re.search(r"^cmd_bg\(\)", sh, re.M))
    return ad and bg, f"scripts/agent-dispatch.sh present = {ad}; rd bg handler present = {bg}"


def chk_self_pin(files):
    t = get(files, "agent-gateway", "server/lib/dispatch-policy.ts")
    if t is None:
        return None, ""
    pinned = "PINNED_RULES" in t
    return pinned, "dispatch-policy.ts keeps an un-overridable investigate pin on sideclaw/warden" if pinned else "no PINNED_RULES: the loop's own repos are implement-reachable"


def chk_hermes_no_read_path(files):
    skill = get(files, "hermes-agent", "skills/warden/SKILL.md")
    return skill is None, "no skills/warden/SKILL.md in hermes-agent" if skill is None else "hermes-agent has skills/warden/SKILL.md (a read path into warden)"


def chk_model_discipline(files):
    d = files.get("dotfiles") or {}
    have = [p for p in ("hooks/model-discipline.ts", "hooks/model-discipline.test.ts") if p in d]
    wired = "model-discipline" in (d.get("config/settings.template.json") or "")
    return len(have) == 2 and wired, f"hook + test present = {len(have) == 2}; wired in settings template = {wired}"


def chk_wave_gate(files):
    d = files.get("dotfiles") or {}
    ok = "scripts/wave-gate.py" in d and "wave-gate.py" in (d.get("scripts/remote-dev.sh") or "")
    return ok, f"scripts/wave-gate.py present and invoked by rd wave = {ok}"


def chk_deleted_lanes_stay_deleted(files):
    sh = get(files, "dotfiles", "scripts/remote-dev.sh")
    if sh is None:
        return None, ""
    ad = get(files, "dotfiles", "scripts/agent-dispatch.sh") is not None
    bg = bool(re.search(r"^cmd_bg\(\)", sh, re.M))
    return not ad and not bg, f"scripts/agent-dispatch.sh present = {ad}; rd bg handler present = {bg}"


def chk_wave_shapes(files):
    doc = get(files, "dotfiles", "docs/agent-platform.md")
    skill = get(files, "dotfiles", "skills/wave/SKILL.md")
    if doc is None or skill is None:
        return None, ""
    shapes = sorted(set(m.lower() for m in re.findall(r"^\|\s*\*\*(sequential|fan-out|fleet)\*\*", skill, re.M)))
    if not shapes:
        return None, "skill has no shape table yet"
    herdr = section(doc, "herdr") or ""
    missing = [s for s in shapes if s not in herdr.lower()]
    return not missing, f"/wave skill shapes {shapes}; herdr section of agent-platform.md lacks {missing}"


def chk_model_ids_global_config(files):
    d = files.get("dotfiles") or {}
    paths = ("config/global.CLAUDE.md", "docs/global-reference.md")
    hits = {}
    for p in paths:
        ids = sorted({m.group(0) for m in MODEL_ID_RX.finditer(d.get(p) or "")})
        if ids:
            hits[p] = ids
    if not any(p in d for p in paths):
        return None, ""
    return not hits, "model ids in " + ("; ".join(f"{p}: {', '.join(v[:3])}" for p, v in hits.items()) or "neither lean global file")


def chk_remote_dev_ids(files):
    t = get(files, "dotfiles", "scripts/remote-dev.sh")
    if t is None:
        return None, ""
    hits = sorted({m.group(0) for m in re.finditer(r"\b(?:iu/)?(?:deepseek-v\d[\w.-]*|claude-(?:sonnet|opus|haiku)[\w.-]*|gpt-\d[\w.-]*|glm-\d[\w.-]*)", t)})
    return not hits, f"model id literals in scripts/remote-dev.sh: {', '.join(hits) or 'none'}"


def chk_ops_ceiling(files):
    ops = get(files, "dotfiles", "docs/ops-signals.md")
    plan = get(files, "dotfiles", "docs/waves/PLAN.md") or ""
    if ops is None:
        return None, ""
    said = grep_lines(ops, r"no investigate-only ceiling")
    reversed_ = grep_lines(plan, r"default dispatch ceiling `investigate`")
    if not said:
        return None, "ops-signals decision absent"
    return not reversed_, f"ops-signals.md: '{one_line(said[0], 60)}'; the dotfiles plan: '{one_line(reversed_[0], 70) if reversed_ else ''}'"


def chk_webhook_fed(files):
    poll = get(files, "warden", "scripts/watchdog-poll.py")
    intake = get(files, "warden", "scripts/loop/intake.py") or ""
    if poll is None:
        return None, ""
    skips = "skip_webhook_fed" in poll and "HYPERDX_SLACK_RE" in poll
    snapshot_poll = bool(re.search(r"^def poll_uk\(", intake + poll, re.M))
    return skips and not snapshot_poll, f"#alerts webhook-fed lines skipped = {skips}; Kuma snapshot poll still present = {snapshot_poll}"


def chk_brief_vs_allowlist(files):
    brief = get(files, "warden", "scripts/loop/work.py")
    allow = get(files, "agent-gateway", "server/mcp/opencode-server.ts")
    if brief is None or allow is None:
        return None, ""
    promises = bool(re.search(r"`make logs`", brief))
    rules = re.search(r"READ_ONLY_SHELL_RULES[^=]*=\s*\[(.*?)\n\];", allow, re.S)
    if not promises or not rules:
        return None, "brief promise or allow-list absent"
    allowed = sorted(set(re.findall(r'shell\("([a-z]+)[ "*]', rules.group(1))) - {"*"})
    ok = "make" in allowed
    return ok, f"warden brief promises `make logs`; agw-readonly allows only: {', '.join(allowed)}"


def chk_warden_never_writes_code(files):
    t = get(files, "warden", "docs/improve/LOOP.md")
    if t is None:
        return None, ""
    hit = grep_lines(t, r"a git worktree of the affected repo, a minimal fix")
    return not hit, ("improve-loop brief: 'a git worktree of the affected repo, a minimal fix, make check, /review, fast-forward, make deploy'" if hit else "no in-session code fix path")


def chk_agw_never_writes_code(files):
    t = get(files, "agent-gateway", "AGENTS.md") or get(files, "agent-gateway", "CLAUDE.md")
    if t is None:
        return None, ""
    hit = re.search(r"`implement`-reachable by default", t)
    return not hit, "agent-gateway AGENTS.md: every repo but the sensitive ones and brain is `implement`-reachable by default" if hit else "no default implement reachability"


def chk_locked_binds(files):
    t = get(files, "dotfiles", "docs/factory/BRIEF.md")
    if t is None:
        return True, "no factory brief yet"
    hit = grep_lines(t, r"locked model is the baseline, not a constraint")
    return not hit, one_line(hit[0], 120) if hit else "brief keeps the locked model"


# ---------------------------------------------------------------------- snapshots


def tree_files(repo, rev):
    return (git(repo, "ls-tree", "-r", "--name-only", rev) or "").split("\n")


def all_repos():
    out = []
    for name in sorted(os.listdir(ROOT)):
        p = os.path.join(ROOT, name, ".git")
        if os.path.isdir(p):  # linked worktrees have a .git file and share their parent's history
            out.append(name)
    return out


def snap_repo_contract(iso):
    """Of the repos with a Makefile, the share whose AGENTS.md has the four contract sections
    and whose Makefile has check/deploy/verify/logs. The claim holds at >= 85 %."""
    heads = ["## Validate", "## Deploy", "## Verify & Monitor", "## Gotchas"]
    ok, total = 0, 0
    for r in all_repos():
        rev = rev_at(r, iso)
        mk = git(r, "show", f"{rev}:Makefile") if rev else None
        if mk is None:
            continue
        total += 1
        a = git(r, "show", f"{rev}:AGENTS.md") or ""
        if all(re.search(r"^" + re.escape(h) + r"\b", a, re.M) for h in heads) and \
                all(re.search(r"^" + t + r"\s*:", mk, re.M) for t in ("check", "deploy", "verify", "logs")):
            ok += 1
    return (ok / total >= 0.85 if total else None), f"{ok} of {total} repos with a Makefile carry the four make targets and the four AGENTS.md sections"


def snap_agents_md_only(iso):
    stray = []
    for r in all_repos():
        rev = rev_at(r, iso)
        if not rev:
            continue
        for p in tree_files(r, rev):
            if re.search(r"(^|/)CLAUDE(\.local)?\.md$", p) and "node_modules" not in p and "fixtures/" not in p:
                stray.append(f"{r}:{p}")
    return not stray, f"{len(stray)} tracked CLAUDE.md outside fixtures" + (f": {', '.join(stray[:3])}" if stray else "")


def snap_no_ask_rules(iso):
    bad = []
    for r in all_repos():
        rev = rev_at(r, iso)
        if not rev:
            continue
        t = git(r, "show", f"{rev}:.claude/settings.json")
        if t and re.search(r'"ask"\s*:', t):
            bad.append(r)
    return not bad, f"{len(bad)} repos with an `ask` rule in checked-in .claude/settings.json"


# ------------------------------------------------------------------------ registry

MODELS = [
    {
        "id": "estate-2026-09",
        "name": "Estate round 2 (warden is the control plane; three lanes; enforcement not prose)",
        "lock": ("brain", "e7cde13"),
        "plan": ("dotfiles", "9526827"),
        "closed": ("dotfiles", "7ae6d38"),
        "claims": [
            dict(id="estate.control-plane-one-owner", cause_class="prose", kind="replay", check=chk_control_plane_owner,
                 text="Warden is 'the control plane' (one owner of the noun)",
                 asserted_in=["brain:wiki/engineering/warden-control-plane.md", "dotfiles:docs/architecture.md warden row"],
                 scope={"dotfiles": ["docs/architecture.md", "docs/waves/PLAN.md"]}, mechanism="supersession-without-propagation"),
            dict(id="estate.dispatch-lanes", cause_class="changed_on_purpose", kind="replay", check=chk_dispatch_lanes_exist,
                 text="The delegation roster includes the agent-dispatch subprocess lane and the `rd bg` colleague lane",
                 asserted_in=["brain:wiki/engineering/agent-estate-model.md delegation roster"],
                 scope={"dotfiles": ["scripts/agent-dispatch.sh", "scripts/remote-dev.sh"]}, mechanism="supersession-by-next-round"),
            dict(id="estate.self-modification-pinned", kind="replay", check=chk_self_pin,
                 text="The executor and the loop cannot implement on themselves: sideclaw and warden are pinned to investigate, un-overridable",
                 asserted_in=["agent-gateway:server/lib/dispatch-policy.ts PINNED_RULES", "agent-gateway:docs/dispatch-security.md"],
                 scope={"agent-gateway": ["server/lib/dispatch-policy.ts"]}, mechanism="owner-override-of-a-code-invariant",
                 cause_class="changed_on_purpose"),
            dict(id="estate.hermes-no-read-path", cause_class="changed_on_purpose", kind="replay", check=chk_hermes_no_read_path,
                 text="Hermes has no read path back into warden's ledger",
                 asserted_in=["brain:wiki/engineering/warden-control-plane.md 'what is still partial'"],
                 scope={"hermes-agent": ["skills/warden/SKILL.md"]}, mechanism="snapshot-of-a-transition"),
            dict(id="estate.host-fixes-need-a-human", cause_class="changed_on_purpose", kind="introduced", repo="warden", needle="HOST_VERB_ALLOWLIST", paths=["scripts"],
                 text="No autonomous host-level fix path: host actions go to needs_human on purpose",
                 asserted_in=["warden:DESIGN.md §Boundaries", "warden:docs/history/state-log.md §58"],
                 mechanism="field-override-within-a-day"),
            dict(id="estate.model-discipline-is-a-hook", cause_class="enforced", kind="replay", check=chk_model_discipline,
                 text="Model discipline is enforced by a PreToolUse hook (hooks/model-discipline.ts), not prose",
                 asserted_in=["brain:wiki/engineering/agent-estate-model.md 'Model discipline'"],
                 scope={"dotfiles": ["hooks/model-discipline.ts", "hooks/model-discipline.test.ts", "config/settings.template.json"]},
                 mechanism="enforced-by-code"),
            dict(id="estate.wave-gate-is-mechanical", cause_class="enforced", kind="replay", check=chk_wave_gate,
                 text="The /wave green gate is mechanical: scripts/wave-gate.py runs inside rd wave",
                 asserted_in=["brain:wiki/engineering/agent-estate-model.md '/wave'"],
                 scope={"dotfiles": ["scripts/wave-gate.py", "scripts/remote-dev.sh"]}, mechanism="enforced-by-code"),
        ],
    },
    {
        "id": "agent-platform-2026-10",
        "name": "Agent platform (one core, four lanes, one repo contract; roles with never-lists)",
        "lock": ("dotfiles", "bc77d3f"),
        "plan": ("dotfiles", "bc77d3f"),
        "closed": ("warden", "3c13d8d"),
        "claims": [
            dict(id="platform.four-lanes", cause_class="prose", kind="replay", check=chk_four_lanes,
                 text="'Four lanes — the only ways to start agent work' lists four lanes",
                 asserted_in=["dotfiles:docs/agent-platform.md §Four lanes"],
                 scope={"dotfiles": ["docs/agent-platform.md"]}, mechanism="append-without-restructure"),
            dict(id="platform.no-model-ids-in-prose", cause_class="prose", kind="replay", check=chk_no_model_ids_platform,
                 text="'Never a model id in prose' (model ids live only in agw routing)",
                 asserted_in=["dotfiles:docs/agent-platform.md §Sideclaw — the engine"],
                 scope={"dotfiles": ["docs/agent-platform.md"]}, mechanism="self-contradiction"),
            dict(id="platform.herdr-never-unattended", cause_class="prose", kind="replay", check=chk_herdr_never_unattended,
                 text="herdr + rd 'never run unattended work (that is warden)'",
                 asserted_in=["dotfiles:docs/agent-platform.md §Roles"],
                 scope={"dotfiles": ["docs/agent-platform.md"]}, mechanism="self-contradiction"),
            dict(id="platform.hermes-never-codes", cause_class="prose", kind="replay", check=chk_hermes_never_code,
                 text="Hermes never changes code (SOUL.md) while its toolsets grant file, terminal and code_execution",
                 asserted_in=["hermes-agent:SOUL.md", "dotfiles:docs/agent-platform.md §Roles (Hermes never lands PRs)"],
                 scope={"hermes-agent": ["SOUL.md", "config.yaml"]}, mechanism="prose-never-without-capability-limit"),
            dict(id="platform.no-model-ids-in-code", cause_class="prose", kind="replay", check=chk_remote_dev_ids,
                 text="No model id literal in scripts/remote-dev.sh (ids live only in agw routing)",
                 asserted_in=["dotfiles:docs/agent-platform.md §Sideclaw — the engine"],
                 scope={"dotfiles": ["scripts/remote-dev.sh"]}, mechanism="rule-without-lint"),
            dict(id="platform.argo-verbs-mirror-warden", cause_class="cross_repo", kind="replay", check=chk_argo_verbs,
                 text="Argo's action-verb list equals warden's (two hand-mirrored copies, per Argo's own comment)",
                 asserted_in=["argo:apps/api/src/routes/warden.ts", "warden:scripts/loop/notify.py"],
                 scope={"argo": ["apps/api/src/routes/warden.ts"], "warden": ["scripts/loop/notify.py", "scripts/triage.py"]},
                 mechanism="hand-mirrored-contract"),
            dict(id="platform.deleted-lanes-stay-deleted", cause_class="enforced", kind="replay", check=chk_deleted_lanes_stay_deleted,
                 text="agent-dispatch and `rd bg` are deleted and stay deleted",
                 asserted_in=["dotfiles:docs/agent-platform.md 'Deleted: agent-dispatch, rd bg'"],
                 scope={"dotfiles": ["scripts/agent-dispatch.sh", "scripts/remote-dev.sh"]}, mechanism="enforced-by-removal",
                 **{"from": ("dotfiles", "1d73c79")}),
            dict(id="platform.repo-contract", cause_class="enforced", kind="snapshot", snapshot=snap_repo_contract,
                 text="Every repo with a runtime ships make check/deploy/verify/logs and the four AGENTS.md sections",
                 asserted_in=["dotfiles:docs/agent-platform.md §Repo contract", "dotfiles:docs/agents-md.md"],
                 scope={"all repos": ["AGENTS.md"]}, mechanism="consumed-contract (warden runs make deploy/verify)",
                 lock_override=("dotfiles", "4e01db2")),
        ],
    },
    {
        "id": "setup-round-4-2026-10",
        "name": "Setup round 4 (agent-gateway rename, fan-out lane, one /wave skill, AGENTS.md only)",
        "lock": ("dotfiles", "9f20473"),
        "plan": ("dotfiles", "318489d"),
        "closed": ("dotfiles", "18f2eb5"),
        "claims": [
            dict(id="round4.wave-shapes-one-vocabulary", cause_class="prose", kind="replay", check=chk_wave_shapes,
                 text="agent-platform.md and the /wave skill describe the same shapes (sequential, fan-out, fleet)",
                 asserted_in=["dotfiles:skills/wave/SKILL.md shape table", "dotfiles:docs/agent-platform.md §herdr"],
                 scope={"dotfiles": ["docs/agent-platform.md", "skills/wave/SKILL.md"]}, mechanism="sibling-divergence"),
            dict(id="round4.model-ids-out-of-global-config", cause_class="prose", kind="replay", check=chk_model_ids_global_config,
                 text="No model ids in the lean global files (global CLAUDE.md, global-reference.md): they live in agw routing",
                 asserted_in=["dotfiles:docs/waves/archive/2026-10-platform-PLAN.md Wave 8"],
                 scope={"dotfiles": ["config/global.CLAUDE.md", "docs/global-reference.md"]}, mechanism="short-routing-file-held"),
            dict(id="round4.agents-md-only", cause_class="enforced", kind="snapshot", snapshot=snap_agents_md_only,
                 text="AGENTS.md only: no CLAUDE.md in any repo (a CLAUDE.md suppresses AGENTS.md)",
                 asserted_in=["dotfiles:docs/agents-md.md"], scope={"all repos": ["CLAUDE.md"]}, mechanism="tool-enforced", lock_override=("dotfiles", "2c13e1a")),
            dict(id="round4.no-ask-rules", cause_class="enforced", kind="snapshot", snapshot=snap_no_ask_rules,
                 text="No `ask` rule in any checked-in .claude/settings.json (it stalls unattended agents)",
                 asserted_in=["dotfiles:config/global.CLAUDE.md §Config hierarchy"],
                 scope={"all repos": [".claude/settings.json"]}, mechanism="tool-enforced"),
        ],
    },
    {
        "id": "opencode-v2-2026-10",
        "name": "OpenCode v2 (agw-owned server; read-only permission profile; Haiku routes)",
        "lock": ("agent-gateway", "87c7d94"),
        "plan": ("agent-gateway", "87c7d94"),
        "closed": ("agent-gateway", "deade43"),
        "claims": [
            dict(id="opencode.brief-promise-vs-allowlist", cause_class="cross_repo", kind="replay", check=chk_brief_vs_allowlist,
                 text="Warden's alert brief promises an investigate episode `make logs`; agw-readonly allows it",
                 asserted_in=["warden:scripts/loop/work.py LIVE_STATE_INSTRUCTION", "agent-gateway:server/mcp/opencode-server.ts"],
                 scope={"warden": ["scripts/loop/work.py"], "agent-gateway": ["server/mcp/opencode-server.ts"]},
                 mechanism="cross-repo-promise"),
        ],
    },
    {
        "id": "background-jobs-2026-10",
        "name": "Background jobs (warden is THE loop; no investigate-only ceiling; direct webhooks)",
        "lock": ("dotfiles", "afec081"),
        "plan": ("dotfiles", "afec081"),
        "closed": ("dotfiles", "8e293ec"),
        "claims": [
            dict(id="jobs.kuma-and-hyperdx-reach-warden-directly", cause_class="enforced", kind="replay", check=chk_webhook_fed,
                 text="Kuma and HyperDX reach warden by webhook; their #alerts lines are no longer polled",
                 asserted_in=["dotfiles:docs/ops-signals.md §Owner decisions 3"],
                 scope={"warden": ["scripts/watchdog-poll.py", "scripts/loop/intake.py"]}, mechanism="enforced-by-code",
                 **{"from": ("dotfiles", "8e293ec")}),
            dict(id="jobs.no-investigate-ceiling", cause_class="changed_on_purpose", kind="replay", check=chk_ops_ceiling,
                 text="'There is no investigate-only ceiling: warden implements from day one in every owned repo'",
                 asserted_in=["dotfiles:docs/ops-signals.md §Owner decisions 2"],
                 scope={"dotfiles": ["docs/ops-signals.md", "docs/waves/PLAN.md"]}, mechanism="supersession-without-propagation"),
        ],
    },
    {
        "id": "round-5-2026-10",
        "name": "Round 5 (the dark factory: layers with never-lists; herdr the only code lane)",
        "lock": ("dotfiles", "238fccf"),
        "plan": ("dotfiles", "238fccf"),
        "closed": None,
        "claims": [
            dict(id="round5.agw-never-writes-code", cause_class="prose", kind="replay", check=chk_agw_never_writes_code,
                 text="agent-gateway never writes feature or fix code; herdr is the only place code is written",
                 asserted_in=["dotfiles:docs/waves/PLAN.md §The model — locked (L0, L1)"],
                 scope={"agent-gateway": ["AGENTS.md", "CLAUDE.md"]}, mechanism="aspiration-as-fact"),
            dict(id="round5.hermes-never-codes", cause_class="prose", kind="replay", check=chk_hermes_never_code,
                 text="Hermes never implements, commits or patches repos",
                 asserted_in=["dotfiles:docs/waves/PLAN.md §The model — locked (L3)"],
                 scope={"hermes-agent": ["SOUL.md", "config.yaml"]}, mechanism="prose-never-without-capability-limit"),
            dict(id="round5.warden-never-writes-code", cause_class="prose", kind="replay", check=chk_warden_never_writes_code,
                 text="Warden never writes code itself",
                 asserted_in=["dotfiles:docs/waves/PLAN.md §The model — locked (L2)"],
                 scope={"warden": ["docs/improve/LOOP.md"]}, mechanism="aspiration-as-fact"),
            dict(id="round5.locked-binds-the-next-session", cause_class="changed_on_purpose", kind="replay", check=chk_locked_binds,
                 text="The locked model is the baseline the next design session works from",
                 asserted_in=["dotfiles:docs/waves/PLAN.md §The model — locked"],
                 scope={"dotfiles": ["docs/factory/BRIEF.md"]}, mechanism="owner-restart"),
        ],
    },
]


def evaluate_claim(claim, lock):
    kind = claim["kind"]
    lk = dict(lock)
    if claim.get("lock_override"):
        lk = commit_info(*claim["lock_override"])
    if kind == "replay":
        res = evaluate_replay(claim, lk)
    elif kind == "introduced":
        res = evaluate_introduced(claim, lk)
    else:
        res = evaluate_snapshot(claim, lk)
        if claim.get("lock_override"):
            res["measured_at"] = {"basis": "end of the model's own rollout", **lk}
    out = {"id": claim["id"], "cause_class": claim["cause_class"], "kind": kind, "text": claim["text"], "asserted_in": claim["asserted_in"],
           "scope": claim.get("scope") or {claim["repo"]: claim["paths"]}, "mechanism": claim["mechanism"]}
    out.update(res)
    return out


def fanout():
    """Files, per instant, in which >=3 of the 4 lane commands co-occur (one model, N copies)."""
    pats = {"rd wave": r"rd wave", "dispatch": r"(agw|agent-gateway|sideclaw) dispatch|`dispatch`",
            "warden run": r"warden run", "implementer": r"@implementer"}
    excl = [":!docs/waves", ":!docs/history", ":!docs/factory", ":!*CHANGELOG*", ":!*.lock", ":!docs/diagrams",
            ":!**/archive/**", ":!*state-log*", ":!Inbox", ":!Areas/Podcasts"]
    instants = [(m["id"], commit_info(*m["lock"])["date"]) for m in MODELS] + [("as_of", AS_OF)]
    rows = []
    for label, iso in instants:
        files, repos = set(), set()
        for r in all_repos():
            rev = rev_at(r, iso)
            if not rev:
                continue
            sets = []
            for pt in pats.values():
                out = git(r, "grep", "-l", "-i", "-E", pt, rev, "--", ".", *excl) or ""
                sets.append({x.split(":", 1)[1] for x in out.split("\n") if ":" in x})
            for p in set().union(*sets):
                if sum(1 for s in sets if p in s) >= 3:
                    files.add((r, p))
                    repos.add(r)
        rows.append({"instant": label, "date": iso, "files": len(files), "repos": len(repos),
                     "paths": sorted(f"{r}:{p}" for r, p in files)[:40] if label == "as_of" else None})
    return rows


def main():
    models_out, all_claims = [], []
    for m in MODELS:
        lock = commit_info(*m["lock"])
        claims = [evaluate_claim(c, lock) for c in m["claims"]]
        all_claims.extend((m["id"], c) for c in claims)
        models_out.append({
            "id": m["id"], "name": m["name"], "lock": lock,
            "plan": commit_info(*m["plan"]),
            "closed": commit_info(*m["closed"]) if m["closed"] else None,
            "claims": claims,
        })
    windows = {m["id"]: (m["plan"]["date"], m["closed"]["date"] if m["closed"] else AS_OF) for m in models_out}
    for mid, c in all_claims:
        fc = c["first_contradiction"]
        c["contradicted_in"] = None
        if not fc or not fc.get("date"):
            continue
        inside = next((k for k, (a, b) in windows.items() if a <= fc["date"] <= b), None)
        if c.get("born_false") and c["days_from_lock"] == 0.0:
            lock_date = next(m["lock"]["date"] for m in models_out if m["id"] == mid)
            c["contradicted_in"] = {"window": inside, "relation": "false_at_lock",
                                    "false_for_days_before_lock": max(0.0, days_between(fc["date"], lock_date))}
            continue
        c["contradicted_in"] = {"window": inside, "relation": (
            "own_round" if inside == mid else ("later_round" if inside else "between_rounds"))}
    relation = {}
    for _, c in all_claims:
        if c["contradicted_in"]:
            relation[c["contradicted_in"]["relation"]] = relation.get(c["contradicted_in"]["relation"], 0) + 1
    drift_days = [c["days_from_lock"] for _, c in all_claims if c["kind"] != "snapshot"
                  and c["days_from_lock"] is not None]
    held = [c["id"] for _, c in all_claims if c["holds_at_as_of"] is True]
    born = [c["id"] for _, c in all_claims if c.get("born_false")]
    summary = {
        "claims": len(all_claims),
        "born_false": len(born), "born_false_ids": born,
        "contradicted_after_lock": sum(1 for _, c in all_claims if not c.get("born_false") and c["first_contradiction"]),
        "within_1_day": sum(1 for d in drift_days if d <= 1),
        "within_7_days": sum(1 for d in drift_days if d <= 7),
        "within_14_days": sum(1 for d in drift_days if d <= 14),
        "median_days_from_lock_to_first_contradiction": statistics.median(drift_days) if drift_days else None,
        "held_at_as_of": len(held), "held_ids": held,
        "false_at_as_of": sum(1 for _, c in all_claims if c["holds_at_as_of"] is False),
    }
    by_class = {}
    for _, c in all_claims:
        row = by_class.setdefault(c["cause_class"], {"claims": 0, "held_at_as_of": 0, "false_at_as_of": 0, "born_false": 0})
        row["claims"] += 1
        row["held_at_as_of"] += 1 if c["holds_at_as_of"] is True else 0
        row["false_at_as_of"] += 1 if c["holds_at_as_of"] is False else 0
        row["born_false"] += 1 if c.get("born_false") else 0
    summary["by_cause_class"] = dict(sorted(by_class.items()))
    summary["first_contradiction_authored_in"] = dict(sorted(relation.items()))
    result = {
        "as_of": AS_OF, "script": "drift.py",
        "cause_class": "author-assigned: enforced (code or a tool runs the claim), prose (a doc or prompt asserts it), "
                       "cross_repo (a contract two repos hold halves of), changed_on_purpose (the owner or the same round reversed it)",
        "mechanism_tags": "author-assigned label for the pattern a claim illustrates; every other field is computed",
        "repo_revs_at_as_of": {r: rev_at(r, AS_OF)[:9] for r in all_repos() if rev_at(r, AS_OF)},
        "models": models_out,
        "summary": summary,
        "lane_model_restatement": fanout(),
    }
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(result, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(f"wrote {OUT}: {len(models_out)} models, {len(all_claims)} claims; born false {len(born)}, "
          f"held at AS_OF {len(held)}, median days to first contradiction {summary['median_days_from_lock_to_first_contradiction']}")


if __name__ == "__main__":
    main()
