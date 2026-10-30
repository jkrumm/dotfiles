#!/usr/bin/env python3
"""Spike 4 driver: MCP vs CLI on the owner's own gateways.

  spike4.py configs                       write the scratch MCP configs (never touches ~/.claude.json)
  spike4.py turn1                         first-turn input tokens per server x condition + baselines
  spike4.py matrix [--gateways agw,research,email] [--conditions mcp,cli,mcp_deferred] [--reps 3]
                   [--tasks id,id] [--workers 4] [--force]
  spike4.py aggregate                     medians per gateway x condition -> raw/summary.json + tables

Conditions (all under the lab config in lib_run.py, one gateway at a time):
  mcp           --tools ""         that server's MCP tools, definitions inline in the first turn
  mcp_deferred  --tools ToolSearch ENABLE_TOOL_SEARCH=true: names only up front, schemas fetched on demand
  cli           --tools Bash       no MCP; the generated routing block (render_routing.py) appended to the system prompt
"""

from __future__ import annotations

import argparse
import functools
import json
import os
import random
import re
import shutil
import sqlite3
import statistics
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from lib_iu import SCRATCH, iu_key, iu_base  # noqa: E402
from lib_run import Session, analyze, extract_answer, run_session  # noqa: E402
import render_routing  # noqa: E402

os.environ["PATH"] = f"{SCRATCH / 'bin'}:{os.environ['PATH']}"  # the scratch CLI (mailgw) must resolve for the renderer too
REPORT = HERE.parent
RAW = REPORT / "raw"
CONFIGS, RUNS, WORK = SCRATCH / "configs", SCRATCH / "runs", SCRATCH / "work"
EMAIL_DIR = SCRATCH / "email"
USAGE_TRACKER = Path("~/SourceRoot/usage-tracker").expanduser()
FIXTURE_GMAIL = "gmail:fixture.owner" + "@" + "example.com"  # split so the public-repo redaction check stays green
SMALL_COMMIT = "09fec1c"  # fix(collectors): a subdirectory deleted mid-scan is empty, not an ingest failure
JOBS_DB = Path("~/.local/share/agent-gateway/jobs.db").expanduser()


def resolve_model() -> str:
    """The `ca` launcher's default Claude tier, read from the repo's single source (no id typed here)."""
    if os.environ.get("SPIKE_MODEL"):
        return os.environ["SPIKE_MODEL"]
    zsh = Path("~/SourceRoot/dotfiles/config/zsh/claude.zsh").expanduser().read_text()
    m = re.search(r'local m="\$\{model:-([^}]+)\}"', zsh)
    if not m:
        raise SystemExit("cannot resolve the model; set SPIKE_MODEL")
    return m.group(1)


SERVERS = {
    "agw": {"mcp_key": "agent-gateway", "cli": "agw"},
    "research": {"mcp_key": "research-gateway", "cli": "research"},
    "email": {"mcp_key": "email-gateway", "cli": "mailgw"},
}
CONDITIONS = {
    "mcp": {"tools": "", "env": {}, "mcp": True, "block": False},
    "mcp_deferred": {"tools": "ToolSearch", "env": {"ENABLE_TOOL_SEARCH": "true"}, "mcp": True, "block": False},
    "cli": {"tools": "Bash", "env": {}, "mcp": False, "block": True},
    # Ablation of the first routing block and the first scratch CLI: the intro promised `--json` everywhere,
    # and mailgw swallowed an unknown flag as a positional argument (see write_ablation).
    "mcp_deferred_hint": {"tools": "ToolSearch", "env": {"ENABLE_TOOL_SEARCH": "true"}, "mcp": True, "block": False, "hint": True},
    "cli_v0": {"tools": "Bash", "env": {}, "mcp": False, "block": True, "ablation": True},
    # Ablation of the routing block's policy line: long jobs must be submitted with --no-wait and polled.
    "cli_v2": {"tools": "Bash", "env": {}, "mcp": False, "block": True, "block_config": "routing.v2.config.json"},
    # Ablation: tell the agent to use the Bash tool's own timeout parameter instead of backgrounding.
    "cli_v3": {"tools": "Bash", "env": {}, "mcp": False, "block": True, "block_config": "routing.v3.config.json"},
}
# Hybrid: deferred MCP plus a one-line hint that removes the second ToolSearch hop of a submit-then-wait pair.
# A generator would derive these lines from tools/list (descriptions that tell the caller to use job_wait).
HINTS = {
    "agw": "Deferred tools: agent-gateway jobs are submit-then-wait. Load the submit tool and job_wait in ONE ToolSearch call, e.g. select:mcp__agent-gateway__check,mcp__agent-gateway__job_wait",
    "research": "Deferred tools: research-gateway jobs are submit-then-wait. Load research and job_wait in ONE ToolSearch call: select:mcp__research-gateway__research,mcp__research-gateway__job_wait",
}
ABLATION = SCRATCH / "ablation"
SECRETS: list[str] = []  # exact values scrubbed from persisted transcripts


# ------------------------------------------------------------------ configs

def write_configs() -> None:
    CONFIGS.mkdir(parents=True, exist_ok=True)
    claude_json = json.loads(Path("~/.claude.json").expanduser().read_text())["mcpServers"]  # read-only
    email_key = (EMAIL_DIR / "api.key").read_text().strip() if (EMAIL_DIR / "api.key").exists() else ""
    cfgs = {
        "empty": {"mcpServers": {}},
        "agw": {"mcpServers": {"agent-gateway": claude_json["agent-gateway"]}},
        "research": {"mcpServers": {"research-gateway": claude_json["research-gateway"]}},
        "email": {"mcpServers": {"email-gateway": {
            "type": "http", "url": "http://127.0.0.1:39107/mcp", "headers": {"Authorization": f"Bearer {email_key}"}}}},
    }
    for name, cfg in cfgs.items():
        p = CONFIGS / f"{name}.json"
        p.write_text(json.dumps(cfg, indent=1))
        p.chmod(0o600)
    print(f"wrote {len(cfgs)} configs to {CONFIGS}")


def load_secrets() -> None:
    SECRETS.extend([iu_key(), iu_base()])
    if (EMAIL_DIR / "api.key").exists():
        SECRETS.append((EMAIL_DIR / "api.key").read_text().strip())
    claude_json = json.loads(Path("~/.claude.json").expanduser().read_text())["mcpServers"]
    SECRETS.append(claude_json["research-gateway"]["url"].rsplit("/mcp", 1)[0])


# ------------------------------------------------------------------ tasks

@dataclass
class Ctx:
    run_id: str
    cwd: Path
    clone: Path | None = None


@dataclass
class Task:
    id: str
    gateway: str
    prompt: str
    keys: str
    grade: Callable[[Ctx, dict, dict | None], tuple[bool, dict]]
    clone: str | None = None  # None | "clean" | "red"
    commit: str = SMALL_COMMIT


def make_clone(dest: Path, red: bool, commit: str = SMALL_COMMIT) -> None:
    subprocess.run(["git", "clone", "-q", "--local", str(USAGE_TRACKER), str(dest)], check=True)
    subprocess.run(["git", "-C", str(dest), "checkout", "-q", "-B", "spike", commit], check=True)
    subprocess.run(["cp", "-cR", str(USAGE_TRACKER / "node_modules"), str(dest / "node_modules")], check=True)
    if red:  # a deterministic type error appended to src/db.ts
        with open(dest / "src" / "db.ts", "a") as f:
            f.write('\nexport const spikeBroken: number = "not a number";\n')


def agw_jobs(clone: Path) -> list[dict]:
    """Jobs the gateway ran for this run's private clone (read-only look at the jobs table)."""
    con = sqlite3.connect(f"file:{JOBS_DB}?mode=ro", uri=True)
    rows = con.execute(
        "SELECT id, tool, status, result, error, created_at, started_at, finished_at FROM jobs "
        "WHERE params LIKE ? ORDER BY created_at", (f"%{clone}%",)).fetchall()
    con.close()
    return [{"id": r[0], "tool": r[1], "status": r[2], "result": json.loads(r[3]) if r[3] else None, "error": r[4],
             "queue_ms": (r[6] - r[5]) if r[6] else None, "run_ms": (r[7] - r[6]) if r[7] and r[6] else None} for r in rows]


def _last(jobs: list[dict], tool: str) -> dict | None:
    done = [j for j in jobs if j["tool"] == tool and j["status"] == "done" and j["result"]]
    return done[-1] if done else None


def grade_check_clean(ctx: Ctx, rec: dict, ans: dict | None):
    jobs = agw_jobs(ctx.clone)
    job = _last(jobs, "check")
    truth = {"passed": job["result"]["passed"], "steps": len(job["result"]["steps"])} if job else None
    ok = bool(ans and truth and ans.get("passed") is truth["passed"] and ans.get("steps") == truth["steps"])
    return ok, {"truth": truth, "jobs": jobs}


def grade_check_red(ctx: Ctx, rec: dict, ans: dict | None):
    jobs = agw_jobs(ctx.clone)
    job = _last(jobs, "check")
    truth = {"passed": job["result"]["passed"] if job else None, "file": "src/db.ts", "error_code": "TS2322"}
    ok = bool(ans and job and truth["passed"] is False and ans.get("passed") is False
              and str(ans.get("file", "")).endswith("src/db.ts") and ans.get("error_code") == "TS2322")
    return ok, {"truth": truth, "jobs": jobs}


def grade_review(ctx: Ctx, rec: dict, ans: dict | None):
    jobs = agw_jobs(ctx.clone)
    job = _last(jobs, "review")
    truth = ({"outcome": job["result"]["outcome"], "blocking": len(job["result"].get("blocking", [])),
              "improvements": len(job["result"].get("improvements", []))} if job else None)
    ok = bool(ans and truth and ans.get("outcome") == truth["outcome"] and ans.get("blocking") == truth["blocking"]
              and ans.get("improvements") == truth["improvements"])
    return ok, {"truth": truth, "jobs": jobs}


def _grounded(url: object, rec: dict) -> bool:
    """The cited URL must appear in something the gateway actually returned."""
    return isinstance(url, str) and url.startswith("http") and any(url.rstrip("/") in c.get("result_text", "") for c in rec["calls"])


def grade_r1(ctx, rec, ans):
    ok = bool(ans and re.search(r"ignor|only", str(ans.get("behavior", "")), re.I) and _grounded(ans.get("source_url"), rec))
    return ok, {"truth": "only MCP servers from --mcp-config, ignoring all other MCP configurations"}


def grade_r2(ctx, rec, ans):
    return bool(ans and ans.get("default_max_retries") == 2 and _grounded(ans.get("source_url"), rec)), {"truth": 2}


def grade_r3(ctx, rec, ans):
    ok = bool(ans and ans.get("bun_test_default_timeout_ms") == 5000 and ans.get("openai_node_default_max_retries") == 2)
    return ok, {"truth": {"bun_test_default_timeout_ms": 5000, "openai_node_default_max_retries": 2}}


def _truth() -> dict:
    return json.loads((EMAIL_DIR / "truth.json").read_text())


def _norm(s: object) -> str:
    return re.sub(r"\s+", " ", str(s or "")).strip().lower()


def grade_e1(ctx, rec, ans):
    t = _truth()
    ok = bool(ans and ans.get("count") == t["needs_action_count"] and _norm(ans.get("newest_subject")) == _norm(t["newest_needs_action_subject"]))
    return ok, {"truth": {"count": t["needs_action_count"], "newest_subject": t["newest_needs_action_subject"]}}


def grade_e2(ctx, rec, ans):
    t = _truth()
    ok = bool(ans and ans.get("key") == t["invoice_key"] and _norm(ans.get("category")) == t["invoice_category"])
    return ok, {"truth": {"key": t["invoice_key"], "category": t["invoice_category"]}}


def grade_e3(ctx, rec, ans):
    t = _truth()
    digits = re.sub(r"\D", "", str((ans or {}).get("amount", "")))
    ok = bool(ans and digits == re.sub(r"\D", "", t["invoice_amount"]) and ans.get("due_date") == t["invoice_due"])
    return ok, {"truth": {"amount": t["invoice_amount"], "due_date": t["invoice_due"]}}


def grade_probe(ctx, rec, ans):
    t = _truth()
    got = (ans or {}).get("unread", "missing")
    return got == t["unread_gmail_total"], {"truth": {"unread": t["unread_gmail_total"]}, "abstained": got is None}


def grade_r4(ctx, rec, ans):
    names = " ".join(str(v) for v in (ans or {}).get("variables", [])) if isinstance((ans or {}).get("variables"), list) else ""
    ok = bool(ans and "CLAUDE_CODE_ENABLE_TELEMETRY" in names and "CLAUDE_CODE_ENHANCED_TELEMETRY_BETA" in names and _grounded(ans.get("source_url"), rec))
    return ok, {"truth": ["CLAUDE_CODE_ENABLE_TELEMETRY", "CLAUDE_CODE_ENHANCED_TELEMETRY_BETA"]}


FOOT = "\n\nFinish with a final line that starts with `ANSWER: ` followed by one single-line JSON object with the keys {keys} (no code fences)."
TASKS: dict[str, Task] = {t.id: t for t in [
    Task("agw-check-clean", "agw", "Use the agent-gateway to run the validation check on the git repository at {cwd}. Report whether it passed and how many validation steps the gateway reported.",
         '"passed" (boolean) and "steps" (integer)', grade_check_clean, "clean"),
    Task("agw-review-head", "agw", "Use the agent-gateway to run a code review of the most recent commit of the git repository at {cwd}. Report the review outcome and the number of blocking findings and of improvements the gateway returned.",
         '"outcome" (string), "blocking" (integer) and "improvements" (integer)', grade_review, "clean"),
    Task("agw-check-red", "agw", "Use the agent-gateway to run the validation check on the git repository at {cwd}. It is expected to fail. Report whether it passed and, for the first compiler or test error the gateway reports, the file path relative to the repository and the error code.",
         '"passed" (boolean), "file" (string) and "error_code" (string)', grade_check_red, "red"),
    Task("research-flag", "research", "Use the research gateway at quick depth to find out what the `--strict-mcp-config` flag of the Claude Code CLI does. Report its behavior in one sentence and one official documentation URL taken from the gateway's report.",
         '"behavior" (string) and "source_url" (string)', grade_r1),
    Task("research-sdk-retries", "research", "Use the research gateway at quick depth to find the default number of automatic retries of the official Anthropic TypeScript SDK (`@anthropic-ai/sdk`). Report the number and one source URL taken from the gateway's report.",
         '"default_max_retries" (integer) and "source_url" (string)', grade_r2),
    Task("research-batch", "research", "Use the research gateway, both questions at quick depth and in parallel: (1) what is the default per-test timeout of `bun test`, in milliseconds? (2) what is the default number of automatic retries in the official OpenAI Node.js SDK? Report both numbers.",
         '"bun_test_default_timeout_ms" (integer) and "openai_node_default_max_retries" (integer)', grade_r3),
    Task("agw-review-large", "agw", "Use the agent-gateway to run a code review of the most recent commit of the git repository at {cwd}. Report the review outcome and the number of blocking findings and of improvements the gateway returned.",
         '"outcome" (string), "blocking" (integer) and "improvements" (integer)', grade_review, "clean", commit="bbddd67"),
    Task("research-standard-long", "research", "Use the research gateway at standard depth to find which environment variables enable the distributed-traces export of Claude Code (OpenTelemetry tracing). Report the variable names that must be set and one official documentation URL taken from the gateway's report.",
         '"variables" (array of strings) and "source_url" (string)', grade_r4),
    Task("email-needs-action", "email", "Use the email gateway to find how many messages are currently flagged as needing action, and the subject of the newest one.",
         '"count" (integer) and "newest_subject" (string)', grade_e1),
    Task("email-find-invoice", "email", "Use the email gateway to find the invoice from Acme Cloud and report its message key and its category.",
         '"key" (string) and "category" (string)', grade_e2),
    Task("email-read-invoice", "email", "Use the email gateway to read the invoice message from Acme Cloud and report the amount due and the due date.",
         '"amount" (string, as written in the message) and "due_date" (string, YYYY-MM-DD)', grade_e3),
    Task("email-probe-unread", "email", "Use the email gateway to report how many unread messages the account {account} has (messages without the \\Seen flag). If the gateway cannot tell you, use null.",
         '"unread" (integer or null)', grade_probe),
]}
PROBE_TASKS = {"email-probe-unread", "agw-review-large", "research-standard-long"}


# ------------------------------------------------------------------ one run

@functools.lru_cache(maxsize=2)
def routing_block(config: str = "") -> str:
    return render_routing.render(json.loads(Path(config or render_routing.CONFIG).read_text()))


def write_ablation() -> None:
    """cli_v0 = the first routing block (intro mentions `--json`) + the first mailgw (no --json handling)."""
    (ABLATION / "bin").mkdir(parents=True, exist_ok=True)
    cur = (HERE / "mailgw").read_text()
    old_line = 'cmd, rest, params, pos, i = argv[0], [a for a in argv[1:] if a != "--json"], {}, [], 0  # output is always JSON'
    assert old_line in cur, "mailgw changed; update the ablation"
    (ABLATION / "bin" / "mailgw").write_text(cur.replace(old_line, "cmd, rest, params, pos, i = argv[0], argv[1:], {}, [], 0"))
    (ABLATION / "bin" / "mailgw").chmod(0o755)
    cfg = json.loads(render_routing.CONFIG.read_text())
    cfg["intro"] = cfg["intro"].rstrip(".") + "; `--json` gives machine-readable stdout."
    (ABLATION / "routing.config.json").write_text(json.dumps(cfg, indent=1))
    v2 = json.loads(render_routing.CONFIG.read_text())
    v2["intro"] = ("Gateways are CLIs on PATH: call them through Bash, never their HTTP APIs. Jobs that can run past the 2-minute shell timeout "
                   "(`research --depth standard|deep`, `agw review`, `agw dispatch`): submit with `--no-wait`, keep the jobId, poll `status <jobId>`; never run the blocking form in the foreground.")
    (ABLATION / "routing.v2.config.json").write_text(json.dumps(v2, indent=1))
    v3 = json.loads(render_routing.CONFIG.read_text())
    v3["intro"] = ("Gateways are CLIs on PATH: call them through Bash, never their HTTP APIs. Jobs can run for minutes (`research --depth standard|deep`, `agw review`): "
                   "run the blocking form in the FOREGROUND with the Bash tool's `timeout` parameter set to 600000; do not background it and do not poll with sleep.")
    (ABLATION / "routing.v3.config.json").write_text(json.dumps(v3, indent=1))


def condition_session(gateway: str, cond: str, cwd: Path, prompt: str, model: str) -> Session:
    c = CONDITIONS[cond]
    env = dict(c["env"])
    if cond in ("cli", "cli_v0", "cli_v2", "cli_v3"):
        env["PATH"] = (f"{ABLATION / 'bin'}:" if c.get("ablation") else "") + f"{SCRATCH / 'bin'}:{os.environ['PATH']}"
        if gateway == "email":
            env["MAILGW_URL"] = "http://127.0.0.1:39107"
            env["MAILGW_KEY"] = (EMAIL_DIR / "api.key").read_text().strip()
    cfg = CONFIGS / (f"{gateway}.json" if c["mcp"] else "empty.json")
    block_cfg = str(ABLATION / c["block_config"]) if c.get("block_config") else (str(ABLATION / "routing.config.json") if c.get("ablation") else "")
    system = routing_block(block_cfg) if c["block"] else None
    if c.get("hint"):
        system = HINTS[gateway]
    return Session(cwd=cwd, prompt=prompt, model=model, tools=c["tools"], mcp_config=cfg, append_system=system, env=env)


def used_gateway(rec: dict, gateway: str, cond: str) -> bool:
    if cond in ("cli", "cli_v0", "cli_v2", "cli_v3"):
        pat = re.compile(rf"(^|[\s;&|(`$]){SERVERS[gateway]['cli']}(\s|$)")
        return any(pat.search(c["input"].get("command", "")) for c in rec["calls"] if c["name"] == "Bash")
    prefix = f"mcp__{SERVERS[gateway]['mcp_key']}__"
    return any(c["name"].startswith(prefix) for c in rec["calls"])


def classify_failure(rec: dict, ans: dict | None, ok: bool, used: bool) -> str | None:
    if ok and used:
        return None
    if rec["idle_killed"]:
        return "idle_watchdog"
    if not used:
        return "gateway_unused"
    if ans is None:
        return "no_answer"
    texts = " ".join(c.get("result_text", "")[:600] for c in rec["calls"] if c["is_error"])
    allt = " ".join(c.get("result_text", "")[:600] for c in rec["calls"])
    if re.search(r"timed out|timeout", texts, re.I):
        return "tool_timeout"
    if re.search(r"usage error|unknown (flag|option)|bad command|invalid (scope|input)", allt, re.I):
        return "usage_error"
    return "wrong_answer"


def run_one(gateway: str, task: Task, cond: str, rep: int, model: str, sems: dict[str, threading.Semaphore], force: bool) -> dict | None:
    run_id = f"{task.id}__{cond}__r{rep}"
    out = RUNS / f"{run_id}.json"
    if out.exists() and not force:
        return json.loads(out.read_text())
    with sems[gateway]:
        ctx = Ctx(run_id=run_id, cwd=WORK / "sessions" / run_id)
        if task.clone:
            ctx.clone = WORK / "clones" / run_id
            shutil.rmtree(ctx.clone, ignore_errors=True)
            make_clone(ctx.clone, red=task.clone == "red", commit=task.commit)
            ctx.cwd = ctx.clone
        prompt = task.prompt.format(cwd=ctx.clone, account=FIXTURE_GMAIL) + FOOT.format(keys=task.keys)
        sess = condition_session(gateway, cond, ctx.cwd, prompt, model)
        t_start = time.time()
        raw = run_session(sess, RUNS / f"{run_id}.jsonl", SECRETS)
        rec = analyze(raw)
    ans = extract_answer(rec["final_text"])
    ok, detail = task.grade(ctx, rec, ans)
    used = used_gateway(rec, gateway, cond)
    record = {
        "run_id": run_id, "gateway": gateway, "task": task.id, "condition": cond, "rep": rep, "probe": task.id in PROBE_TASKS,
        "success": bool(ok and used), "answer_correct": bool(ok), "gateway_used": used,
        "failure_mode": "capability_gap_abstained" if detail.get("abstained") else classify_failure(rec, ans, ok, used), "answer": ans, "grade_detail": detail,
        "started_at": t_start, **{k: v for k, v in rec.items() if k not in ("calls", "final_text", "init_tools")},
        "init_tool_count": len(rec["init_tools"]), "final_text": rec["final_text"][:1500],
        "calls": [{k: v for k, v in c.items() if k not in ("result_text", "id")} for c in rec["calls"]],
    }
    out.write_text(json.dumps(redact_obj(record), indent=1) + "\n")
    # fully-clean up scratch clones; keep transcripts
    if ctx.clone:
        shutil.rmtree(ctx.clone, ignore_errors=True)
    return record


def redact_obj(obj):
    """Public-repo hygiene for every persisted record: exact secrets, then the shared patterns."""
    from redact import redact
    text = json.dumps(obj, ensure_ascii=False)
    for sec in SECRETS:
        if sec:
            text = text.replace(sec, "<scrubbed>")
    return json.loads(redact(text))


# ------------------------------------------------------------------ commands

def cmd_matrix(a: argparse.Namespace) -> None:
    load_secrets()
    RUNS.mkdir(parents=True, exist_ok=True)
    (WORK / "clones").mkdir(parents=True, exist_ok=True)
    if any(c in a.conditions for c in ("cli_v0", "cli_v2", "cli_v3")):
        write_ablation()
    model = resolve_model()
    gws, conds = a.gateways.split(","), a.conditions.split(",")
    wanted = set(a.tasks.split(",")) if a.tasks else None
    plan = [(t, c, r) for t in TASKS.values() if t.gateway in gws and (not wanted or t.id in wanted)
            for c in conds for r in range(1, a.reps + 1)]
    random.Random(20261022).shuffle(plan)  # interleave conditions so drift hits all of them alike
    sems = {"agw": threading.Semaphore(2), "research": threading.Semaphore(3), "email": threading.Semaphore(4)}
    print(f"{len(plan)} runs, {a.workers} workers")
    done = 0
    with ThreadPoolExecutor(max_workers=a.workers) as pool:
        futs = [pool.submit(run_one, t.gateway, t, c, r, model, sems, a.force) for t, c, r in plan]
        for f in futs:
            rec = f.result()
            done += 1
            if rec:
                print(f"[{done}/{len(plan)}] {rec['run_id']:<44} ok={rec['success']!s:<5} turn1={rec['turn1_input_tokens']:>6} "
                      f"calls={rec['tool_calls']:>2} wall={rec['wall_s']:>6}s fail={rec['failure_mode']}", flush=True)


def cmd_turn1(a: argparse.Namespace) -> None:
    """First-turn input tokens: one trivial prompt per configuration, repeated twice (tokens are deterministic)."""
    load_secrets()
    model = resolve_model()
    probe = "Reply with the single word OK."
    rows = []

    def measure(label: str, sess: Session) -> None:
        if a.only and a.only not in label:
            return
        vals = []
        for i in range(2):
            raw = run_session(sess, RUNS / f"turn1__{label.replace(chr(47), chr(95))}__{i}.jsonl", SECRETS)
            rec = analyze(raw)
            vals.append(rec["turn1_input_tokens"])
        rows.append({"label": label, "turn1_input_tokens": vals, "tools_in_init": len(rec["init_tools"]),
                     "mcp_connected": [m.get("status") for m in rec["init_mcp"]]})
        print(f"{label:<44} {vals}", flush=True)

    scratch_cwd = WORK / "sessions" / "turn1"
    block = routing_block()
    measure("lab/baseline/no-tools", Session(scratch_cwd, probe, model, "", CONFIGS / "empty.json"))
    measure("lab/baseline/bash", Session(scratch_cwd, probe, model, "Bash", CONFIGS / "empty.json"))
    measure("lab/cli/bash+routing-block", Session(scratch_cwd, probe, model, "Bash", CONFIGS / "empty.json", append_system=block))
    for gw in SERVERS:
        for cond in ("mcp", "mcp_deferred"):
            c = CONDITIONS[cond]
            measure(f"lab/{cond}/{gw}", Session(scratch_cwd, probe, model, c["tools"], CONFIGS / f"{gw}.json", env=dict(c["env"])))
    # Ambient: the owner's real settings, hooks, skills and every built-in tool; MCP deferral at the default
    # and forced off. Only --strict-mcp-config/--mcp-config and the env differ per row.
    def ambient(label: str, mcp: str, env: dict[str, str]) -> None:
        if a.only and a.only not in label:
            return
        vals = []
        for i in range(2):
            s = Session(scratch_cwd, probe, model, "default", CONFIGS / f"{mcp}.json", env=env)
            raw = run_session_ambient(s, RUNS / f"turn1__{label.replace(chr(47), chr(95))}__{i}.jsonl")
            vals.append(analyze(raw)["turn1_input_tokens"])
        rows.append({"label": label, "turn1_input_tokens": vals})
        print(f"{label:<44} {vals}", flush=True)

    ambient("ambient/no-mcp", "empty", {})
    ambient("ambient/no-mcp/tool-search-off", "empty", {"ENABLE_TOOL_SEARCH": "false"})
    for gw in SERVERS:
        ambient(f"ambient/{gw}/default", gw, {})
        ambient(f"ambient/{gw}/tool-search-off", gw, {"ENABLE_TOOL_SEARCH": "false"})
    RAW.mkdir(parents=True, exist_ok=True)
    out = RAW / "turn1.json"
    if a.only and out.exists():  # merge a partial re-measurement into the full table
        old = {r["label"]: r for r in json.loads(out.read_text())["rows"]}
        old.update({r["label"]: r for r in rows})
        rows = list(old.values())
    out.write_text(json.dumps({"model_source": "ca default (config/zsh/claude.zsh)", "rows": rows}, indent=1) + "\n")


def run_session_ambient(s: Session, raw_path: Path):
    """Owner-realistic session: user settings, hooks, skills, CLAUDE.md and all built-in tools stay on."""
    import lib_run
    from lib_iu import iu_env
    cmd = [lib_run.CLAUDE, "-p", "--output-format", "stream-json", "--verbose", "--dangerously-skip-permissions",
           "--no-session-persistence", "--strict-mcp-config", "--mcp-config", str(s.mcp_config), "--model", s.model]
    env = iu_env(dict(s.env))
    t0 = time.monotonic()
    p = subprocess.run(cmd, input=s.prompt, capture_output=True, text=True, env=env, cwd=s.cwd)
    events = [json.loads(l) for l in p.stdout.splitlines() if l.startswith("{")]
    text = "\n".join(json.dumps(e, ensure_ascii=False) for e in events)
    for sec in SECRETS:
        text = text.replace(sec, "<scrubbed>") if sec else text
    from redact import redact
    raw_path.write_text(redact(text) + "\n")
    return lib_run.Raw(events, time.monotonic() - t0, p.returncode, p.stderr, False)


def median(xs: list[float]) -> float | None:
    return statistics.median(xs) if xs else None


def agw_queue_s(rec: dict) -> float:
    """Seconds this run's agw jobs waited in the gateway queue (lane cap 3, shared with the owner's own work).

    Read from job_stats (kept 90 days; its `repo` column is the clone directory name = the run id), counting only
    jobs created after the run started so a re-run under the same run id does not inherit the old run's jobs."""
    con = sqlite3.connect(f"file:{JOBS_DB}?mode=ro", uri=True)
    rows = con.execute("SELECT created_at, started_at FROM job_stats WHERE repo = ? AND created_at >= ?",
                       (rec["run_id"], int(rec["started_at"] * 1000) - 2000)).fetchall()
    con.close()
    return round(sum((st - cr) for cr, st in rows if st) / 1000, 2)


def public_copy(rec: dict) -> dict:
    """The per-run record as committed: shapes, counts and timings, not the reviewed repo's finding text."""
    out = json.loads(json.dumps(rec))
    for j in out.get("grade_detail", {}).get("jobs", []):
        res = j.pop("result", None)
        if isinstance(res, dict):
            j["result_summary"] = {k: (len(v) if isinstance(v, list) else v) for k, v in res.items() if k in ("passed", "outcome", "blocking", "improvements", "steps", "discussions", "testGaps")}
    for c in out.get("calls", []):
        c["result_head"] = c.get("result_head", "")[:100]
    out["final_text"] = out.get("final_text", "")[:400]
    return out


def cmd_aggregate(a: argparse.Namespace) -> None:
    recs = [json.loads(p.read_text()) for p in sorted(RUNS.glob("*__r*.json"))]
    for r in recs:
        r["queue_s"] = agw_queue_s(r) if r["gateway"] == "agw" else 0.0
        r["wall_net_s"] = round(r["wall_s"] - r["queue_s"], 2)
    RAW.mkdir(parents=True, exist_ok=True)
    (RAW / "runs.jsonl").write_text("\n".join(json.dumps(public_copy(r)) for r in recs) + "\n")
    groups: dict[tuple[str, str, bool], list[dict]] = {}
    for r in recs:
        groups.setdefault((r["gateway"], r["condition"], r["probe"]), []).append(r)
    summary = []
    for (gw, cond, probe), rs in sorted(groups.items()):
        summary.append({
            "gateway": gw, "condition": cond, "probe": probe, "runs": len(rs),
            "success_rate": round(sum(r["success"] for r in rs) / len(rs), 3),
            "turn1_input_tokens": median([r["turn1_input_tokens"] for r in rs]),
            "input_tokens_total": median([r["input_tokens_total"] for r in rs]),
            "input_tokens_fresh": median([r["input_tokens_fresh"] for r in rs]),
            "output_tokens": median([r["output_tokens"] for r in rs]),
            "api_calls": median([r["api_calls"] for r in rs]),
            "tool_calls": median([r["tool_calls"] for r in rs]),
            "calls_to_success": median([r["tool_calls"] for r in rs if r["success"]]),
            "discovery_calls": median([r["discovery_calls"] for r in rs]),
            "tool_errors": median([r["tool_errors"] for r in rs]),
            "wall_s": median([r["wall_s"] for r in rs]),
            "wall_net_s": median([r["wall_net_s"] for r in rs]),
            "queue_s": median([r["queue_s"] for r in rs]),
            "cost_usd": median([r["cost_usd"] or 0 for r in rs]),
            "failure_modes": {m: sum(1 for r in rs if r["failure_mode"] == m) for m in sorted({r["failure_mode"] for r in rs if r["failure_mode"]})},
        })
    per_task = {}
    for r in recs:
        per_task.setdefault((r["task"], r["condition"]), []).append(r)
    task_rows = [{"task": t, "condition": c, "runs": len(rs), "success": sum(r["success"] for r in rs),
                  "turn1": median([r["turn1_input_tokens"] for r in rs]), "tokens_total": median([r["input_tokens_total"] for r in rs]),
                  "output": median([r["output_tokens"] for r in rs]), "tool_calls": median([r["tool_calls"] for r in rs]),
                  "wall_s": median([r["wall_s"] for r in rs]), "wall_net_s": median([r["wall_net_s"] for r in rs]),
                  "cost": median([r["cost_usd"] or 0 for r in rs])}
                 for (t, c), rs in sorted(per_task.items())]
    (RAW / "summary.json").write_text(json.dumps({"by_gateway_condition": summary, "by_task_condition": task_rows}, indent=1) + "\n")
    print(f"{len(recs)} runs aggregated")
    for s in summary:
        print(f"{s['gateway']:<9}{s['condition']:<13}{'probe' if s['probe'] else '':<6} n={s['runs']:<3} ok={s['success_rate']:<5} turn1={s['turn1_input_tokens']:<8} "
              f"in={s['input_tokens_total']:<8} out={s['output_tokens']:<6} calls={s['tool_calls']:<4} disc={s['discovery_calls']:<3} wall={s['wall_s']:<7} ${s['cost_usd']:.3f} {s['failure_modes']}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("configs")
    t1 = sub.add_parser("turn1")
    t1.add_argument("--only", default="", help="re-measure only labels containing this text; merges into raw/turn1.json")
    m = sub.add_parser("matrix")
    m.add_argument("--gateways", default="agw,research,email")
    m.add_argument("--conditions", default="mcp,cli,mcp_deferred")
    m.add_argument("--reps", type=int, default=3)
    m.add_argument("--tasks", default="")
    m.add_argument("--workers", type=int, default=4)
    m.add_argument("--force", action="store_true")
    sub.add_parser("aggregate")
    a = ap.parse_args()
    {"configs": lambda _: write_configs(), "turn1": cmd_turn1, "matrix": cmd_matrix, "aggregate": cmd_aggregate}[a.cmd](a)


if __name__ == "__main__":
    main()
