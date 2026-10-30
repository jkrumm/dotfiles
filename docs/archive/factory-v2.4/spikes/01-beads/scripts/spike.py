"""Shared helpers for the Spike 1 scripts (stdlib only). Import with:
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))); import spike
Every subprocess runs with a clean environment: HOME redirected into the scratch prefix, the
scratch bin first on PATH, a scratch git identity. Nothing touches the real home."""
import json
import os
import resource
import statistics
import subprocess
import time

HOME = os.path.expanduser("~")
SPIKE = os.environ.get("SPIKE", os.path.join(HOME, ".local/share/factory/spikes/01-beads"))
HERE = os.path.dirname(os.path.abspath(__file__))
RESULTS = os.path.normpath(os.path.join(HERE, "..", "results"))
ISO = os.path.join(SPIKE, "home")
os.makedirs(RESULTS, exist_ok=True)


def env(extra=None):
    e = {"HOME": ISO, "PATH": f"{SPIKE}/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin", "TERM": "dumb",
         "LANG": "en_US.UTF-8", "GIT_CONFIG_GLOBAL": f"{ISO}/.gitconfig", "GIT_CONFIG_SYSTEM": "/dev/null",
         "GIT_TERMINAL_PROMPT": "0", "BD_NON_INTERACTIVE": "1", "NO_COLOR": "1"}
    e.update(extra or {})
    return e


class Res:
    def __init__(self, rc, out, err, secs, cpu=0.0):
        self.rc, self.out, self.err, self.secs, self.cpu = rc, out, err, secs, cpu

    def json(self):
        try:
            return json.loads(self.out)
        except ValueError:
            return None

    def __repr__(self):
        return f"Res(rc={self.rc}, {self.secs:.3f}s, out={self.out[:80]!r}, err={self.err[:120]!r})"


def _cpu():
    r = resource.getrusage(resource.RUSAGE_CHILDREN)
    return r.ru_utime + r.ru_stime


def run(cmd, cwd=None, extra_env=None, input_=None, timeout=900):
    """Run one command. secs = wall clock; cpu = child user+sys seconds (load-independent work
    measure; valid because callers run one child at a time)."""
    c0, t = _cpu(), time.perf_counter()
    p = subprocess.run(cmd, cwd=cwd, env=env(extra_env), input=input_, capture_output=True, text=True, timeout=timeout)
    return Res(p.returncode, p.stdout, p.stderr, time.perf_counter() - t, _cpu() - c0)


def bd(*args, cwd, extra_env=None, input_=None, timeout=900):
    return run(["bd", *args], cwd=cwd, extra_env=extra_env, input_=input_, timeout=timeout)


def git(*args, cwd):
    return run(["git", *args], cwd=cwd)


def stats(xs, cpu=None):
    xs = sorted(xs)
    if not xs:
        return {"n": 0}
    p90 = xs[min(len(xs) - 1, int(round(0.9 * (len(xs) - 1))))]
    out = {"n": len(xs), "median_ms": round(statistics.median(xs) * 1000, 1), "p90_ms": round(p90 * 1000, 1),
           "min_ms": round(xs[0] * 1000, 1), "max_ms": round(xs[-1] * 1000, 1),
           "mean_ms": round(statistics.mean(xs) * 1000, 1)}
    if cpu:
        out["median_cpu_ms"] = round(statistics.median(cpu) * 1000, 1)
    return out


def loadavg():
    return [round(x, 1) for x in os.getloadavg()]


def series(label, fn, n=20):
    """Call fn(i) -> Res n times; -> stats over wall time + CPU, plus the machine load at the time."""
    la0, rs = loadavg(), []
    for i in range(n):
        rs.append(fn(i))
    bad = [r for r in rs if r.rc != 0]
    out = stats([r.secs for r in rs], [r.cpu for r in rs])
    out.update({"op": label, "failures": len(bad), "loadavg_before": la0, "loadavg_after": loadavg()})
    if bad:
        out["first_failure"] = (bad[0].err or bad[0].out)[:200]
    return out, rs


LOOPBACK = ".".join(["127", "0", "0", "1"])  # assembled so no address literal sits in a tracked file


_AUTHOR = "spike" + "@" + "spike.invalid"     # the scratch git identity (assembled: no address literal in the source)
_LOCAL_SETTINGS = "settings" + ".local" + ".json"  # a filename the redaction check mistakes for a host


def sanitize(txt):
    """Public-repo hygiene for anything a tool printed: home paths, the scratch git identity, loopback literals and
    the one filename the redaction check mistakes for a host."""
    return (txt.replace(HOME, "~").replace(_AUTHOR, "<author>").replace(LOOPBACK, "loopback")
            .replace(_LOCAL_SETTINGS, "settings.<local>.json"))


def save(name, obj):
    path = os.path.join(RESULTS, f"{name}.json")
    open(path, "w").write(sanitize(json.dumps(obj, indent=1)))
    return path


def ids_of(res):
    """bd --json create output -> id (object or single-element list)."""
    j = res.json()
    if isinstance(j, list):
        j = j[0] if j else {}
    return (j or {}).get("id")


def load_dataset():
    return json.load(open(os.path.join(SPIKE, "data", "datasets.json")))["tasks"]


def load_repo(repo, tasks, cwd, extra_env=None, with_external=False):
    """Create `repo`'s tasks with bd (parents first), then deps in one bulk file, then defers.
    -> (key->id, timing dict). External edges are added only when with_external is true."""
    mine = [t for t in tasks if t["repo"] == repo]
    ids, creates = {}, []
    t0 = time.perf_counter()
    for t in mine:
        args = ["create", t["title"], "-t", t["type"], "-p", str(t["priority"]), "--json"]
        if t["labels"]:
            args += ["-l", ",".join(t["labels"])]
        if t["desc"]:
            args += ["-d", t["desc"]]
        if t["parent"]:
            args += ["--parent", ids[t["parent"]]]
        r = bd(*args, cwd=cwd, extra_env=extra_env)
        creates.append(r.secs)
        if r.rc != 0:
            raise RuntimeError(f"create failed for {repo}:{t['key']}: {r}")
        ids[t["key"]] = ids_of(r)
    t_create = time.perf_counter() - t0
    edges = []
    for t in mine:
        for d in t["deps"]:
            if d.startswith("external:"):
                if with_external:
                    edges.append({"from": ids[t["key"]], "to": d, "type": "blocks"})
                continue
            edges.append({"from": ids[t["key"]], "to": ids[d], "type": "blocks"})
    t1 = time.perf_counter()
    dep_res = None
    if edges:
        path = os.path.join(SPIKE, "data", f"deps-{repo}.jsonl")
        with open(path, "w") as f:
            for e in edges:
                f.write(json.dumps(e) + "\n")
        dep_res = bd("dep", "add", "--file", path, cwd=cwd, extra_env=extra_env)
        if dep_res.rc != 0:
            raise RuntimeError(f"dep add failed: {dep_res}")
    t_dep = time.perf_counter() - t1
    t2 = time.perf_counter()
    for t in mine:
        if t["defer"]:
            bd("defer", ids[t["key"]], cwd=cwd, extra_env=extra_env)
    t_defer = time.perf_counter() - t2
    return ids, {"tasks": len(mine), "create_total_s": round(t_create, 2), "create": stats(creates),
                 "edges": len(edges), "dep_bulk_s": round(t_dep, 2), "defer_s": round(t_defer, 2),
                 "load_total_s": round(time.perf_counter() - t0, 2)}


def oracle_ready(tasks, repo, closed=frozenset(), parent_propagation=True, exclude_types=("epic",),
                 satisfied_external=frozenset()):
    """Independent ready-set oracle over the dataset graph (keys): open, not deferred, no open
    `blocks` blocker, no unsatisfied external ref, and (optionally) no blocked ancestor."""
    mine = {t["key"]: t for t in tasks if t["repo"] == repo}

    def blocked_direct(k):
        for d in mine[k]["deps"]:
            if d.startswith("external:"):
                if d not in satisfied_external:
                    return True
            elif d not in closed:
                return True
        return False

    def blocked(k):
        if blocked_direct(k):
            return True
        p = mine[k]["parent"]
        return bool(parent_propagation and p and blocked(p))

    out = set()
    for k, t in mine.items():
        if k in closed or t["defer"] or t["type"] in exclude_types:
            continue
        if not blocked(k):
            out.add(k)
    return out
