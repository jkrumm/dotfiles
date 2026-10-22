#!/usr/bin/env python3
"""Spike 1, step 3: stand up one topology on the real datasets and measure it.

Question: what does it cost to set up and operate beads per-repo-embedded vs one shared Dolt
server (one database per project prefix), on the same data?

Usage: python3 -I 03-topologies.py embedded|shared
Needs: 01-install.sh, 02-build-datasets.py. Writes results/topology-<name>.json.
Measures, per topology: setup (commands, seconds, what bd init writes into git), load of the
three real datasets (210 tasks), the ready set against an independent oracle, per-op latency
(create/update/ready/claim/heartbeat/close/list/show; median of 20, wall and CPU), blocker
semantics (chain, fan-in close race, reopen), cross-repo `external:` deps, git footprint.
"""
import json
import os
import shutil
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from spike import *  # noqa: E402,F401,F403
import spike  # noqa: E402

TOPO = sys.argv[1] if len(sys.argv) > 1 else "embedded"
assert TOPO in ("embedded", "shared")
PORT = "43308"
EXTRA = {"BEADS_DOLT_SERVER_PORT": PORT} if TOPO == "shared" else {}
ROOT = f"{SPIKE}/data/{TOPO}"
REPOS = [("df", "dotfiles"), ("wo", "weatherorb"), ("bu", "basalt-ui")]
OUT = {"topology": TOPO, "loadavg_at_start": loadavg()}


def dolt_pids():
    r = run(["pgrep", "-f", f"{SPIKE}/bin/dolt sql-server"])
    return [int(x) for x in r.out.split()]


def stop_servers():
    for pid in dolt_pids():
        try:
            os.kill(pid, 9)
        except ProcessLookupError:
            pass
    time.sleep(1)


def rss_mb(pids):
    if not pids:
        return 0
    r = run(["ps", "-o", "rss=", "-p", ",".join(map(str, pids))])
    return round(sum(int(x) for x in r.out.split()) / 1024, 1)


def du_kb(path):
    return int(run(["du", "-sk", path]).out.split()[0])


def setup():
    stop_servers()
    shutil.rmtree(ROOT, ignore_errors=True)
    shutil.rmtree(f"{ISO}/.beads/shared-server", ignore_errors=True)
    os.makedirs(ROOT)
    out = {"repos": {}}
    t0 = time.perf_counter()
    for prefix, name in REPOS:
        d = f"{ROOT}/{name}"
        os.makedirs(d)
        git("init", "-q", ".", cwd=d)
        open(f"{d}/README.md", "w").write(f"# {name}\n")
        git("add", "-A", cwd=d)
        git("commit", "-qm", "initial", cwd=d)
        flags = ["--skip-agents", "--skip-hooks"] + (["--shared-server"] if TOPO == "shared" else [])
        r = bd("init", "-p", prefix, "--non-interactive", "--quiet", *flags, cwd=d, extra_env=EXTRA)
        if r.rc != 0:
            raise RuntimeError(f"init failed: {r}")
        out["repos"][name] = {
            "init_s": round(r.secs, 2), "init_cpu_s": round(r.cpu, 2),
            "commits_after_init": int(git("rev-list", "--count", "HEAD", cwd=d).out),
            "tracked_files": git("ls-files", cwd=d).out.split(),
            "untracked_after_init": [l for l in git("status", "--short", cwd=d).out.splitlines()],
            "beads_dir_kb": du_kb(f"{d}/.beads"),
        }
    out["setup_total_s"] = round(time.perf_counter() - t0, 2)
    out["setup_commands"] = len(REPOS) * 1 + (0 if TOPO == "embedded" else 0)
    pids = dolt_pids()
    out["dolt_server_processes_after_setup"] = len(pids)
    out["dolt_server_rss_mb_after_setup"] = rss_mb(pids)
    return out


def ready_keys(cwd, id2key, extra=()):
    r = bd("ready", "--json", "--limit", "0", *extra, cwd=cwd, extra_env=EXTRA)
    rows = r.json() or []
    return {id2key.get(x["id"], x["id"]) for x in rows}, r


def bench_ops(cwd):
    res, ids = {}, []
    s, rs = series("create", lambda i: bd("create", f"bench {i}", "-t", "task", "-p", "3", "--json", cwd=cwd,
                                          extra_env=EXTRA))
    ids = [ids_of(r) for r in rs]
    res["create"] = s
    res["update"], _ = series("update", lambda i: bd("update", ids[i], "-p", "1", "--json", cwd=cwd, extra_env=EXTRA))
    res["ready"], _ = series("ready", lambda i: bd("ready", "--json", "--limit", "0", cwd=cwd, extra_env=EXTRA))
    res["ready_brief"], _ = series("ready --brief", lambda i: bd("ready", "--json", "--brief", "--limit", "0", cwd=cwd,
                                                                 extra_env=EXTRA))
    res["list"], _ = series("list", lambda i: bd("list", "--json", "-n", "20", cwd=cwd, extra_env=EXTRA))
    res["show"], _ = series("show", lambda i: bd("show", ids[i], "--json", cwd=cwd, extra_env=EXTRA))
    res["claim"], _ = series("claim", lambda i: bd("update", ids[i], "--claim", "--actor", "bench", "--json", cwd=cwd,
                                                    extra_env=EXTRA))
    res["heartbeat"], _ = series("heartbeat", lambda i: bd("heartbeat", ids[i], "--actor", "bench", cwd=cwd,
                                                            extra_env=EXTRA))
    res["close"], _ = series("close", lambda i: bd("close", ids[i], "-r", "bench", "--actor", "bench", "--json", cwd=cwd,
                                                     extra_env=EXTRA))
    res["close_fencing"] = {"close_by_other_actor_exit": bd("close", ids[0], "--actor", "intruder", cwd=cwd, extra_env=EXTRA).rc}
    floor, _ = series("floor: bd --version", lambda i: run(["bd", "--version"], cwd=cwd, extra_env=EXTRA))
    res["floor_bd_version"] = floor
    return res


def semantics(cwd):
    """Blocker semantics on throw-away tasks in `cwd` (labelled sem:*)."""
    out = {}

    def mk(title, *a):
        r = bd("create", title, "-t", "task", "--json", *a, cwd=cwd, extra_env=EXTRA)
        return ids_of(r)

    def ready_ids():
        return {x["id"] for x in (bd("ready", "--json", "--limit", "0", cwd=cwd, extra_env=EXTRA).json() or [])}

    # 1 chain: B depends on A
    a, b = mk("sem chain A"), mk("sem chain B")
    bd("dep", "add", b, a, cwd=cwd, extra_env=EXTRA)
    r0 = ready_ids()
    bd("close", a, "-r", "x", cwd=cwd, extra_env=EXTRA)
    r1 = ready_ids()
    out["chain"] = {"b_ready_before_close": b in r0, "a_ready_before_close": a in r0, "b_ready_after_close_a": b in r1}
    # 2 fan-in: C depends on A2 and B2, close both concurrently (the 1.3.1 stale is_blocked fix), 8 rounds
    stale, rounds = 0, 8
    rec = []
    for k in range(rounds):
        a2, b2, c2 = mk(f"sem fan A{k}"), mk(f"sem fan B{k}"), mk(f"sem fan C{k}")
        bd("dep", "add", c2, a2, cwd=cwd, extra_env=EXTRA)
        bd("dep", "add", c2, b2, cwd=cwd, extra_env=EXTRA)
        import subprocess
        ps = [subprocess.Popen(["bd", "close", x, "-r", "x"], cwd=cwd, env=spike.env(EXTRA), stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True) for x in (a2, b2)]
        codes = []
        errs = []
        for p in ps:
            o, e = p.communicate()
            codes.append(p.returncode)
            errs.append(e.strip()[:160])
        ok = c2 in ready_ids()
        stale += 0 if ok else 1
        rec.append({"close_exit_codes": codes, "dependent_ready": ok, "stderr": [e for e in errs if e]})
    out["fan_in_concurrent_close"] = {"rounds": rounds, "dependent_missing_from_ready": stale, "detail": rec[:3]}
    # 3 reopen a closed blocker -> dependent leaves ready
    a3, b3 = mk("sem reopen A"), mk("sem reopen B")
    bd("dep", "add", b3, a3, cwd=cwd, extra_env=EXTRA)
    bd("close", a3, "-r", "x", cwd=cwd, extra_env=EXTRA)
    in1 = b3 in ready_ids()
    bd("reopen", a3, cwd=cwd, extra_env=EXTRA)
    in2 = b3 in ready_ids()
    out["reopen_blocker"] = {"dependent_ready_after_close": in1, "dependent_ready_after_reopen": in2}
    # 4 edge types: related / discovered-from do not block; parent-child blocks structurally
    a4, b4, c4 = mk("sem rel A"), mk("sem rel B"), mk("sem rel C")
    bd("dep", "add", b4, a4, "-t", "related", cwd=cwd, extra_env=EXTRA)
    bd("dep", "add", c4, a4, "-t", "discovered-from", cwd=cwd, extra_env=EXTRA)
    rr = ready_ids()
    out["edge_types"] = {"related_blocks": b4 not in rr, "discovered_from_blocks": c4 not in rr}
    # 5 cycle rejected at write time
    a5, b5 = mk("sem cyc A"), mk("sem cyc B")
    bd("dep", "add", b5, a5, cwd=cwd, extra_env=EXTRA)
    rc = bd("dep", "add", a5, b5, cwd=cwd, extra_env=EXTRA)
    out["cycle_rejected"] = {"exit_code": rc.rc, "message": (rc.err or rc.out).strip()[:120]}
    # 6 compare-and-set and claim exit codes
    a6 = mk("sem cas")
    r_ok = bd("update", a6, "--if-status", "open", "-s", "in_progress", "-a", "w1", cwd=cwd, extra_env=EXTRA)
    r_stale = bd("update", a6, "--if-status", "open", "-s", "in_progress", "-a", "w2", cwd=cwd, extra_env=EXTRA)
    c1 = bd("update", a6, "--claim", "--actor", "w3", cwd=cwd, extra_env=EXTRA)
    out["cas"] = {"first_if_status_exit": r_ok.rc, "stale_if_status_exit": r_stale.rc,
                  "claim_on_foreign_claim_exit": c1.rc, "claim_on_foreign_claim_msg": (c1.err or c1.out).strip()[:140]}
    return out


def external_deps():
    """Does `external:<project>:<capability>` block `bd ready`? Matrix: project not configured / configured with
    a relative path / configured with an absolute path, each with the capability unshipped, closed-but-unshipped
    and shipped. The consumer is in wo, providers in bu."""
    wo, bu = f"{ROOT}/weatherorb", f"{ROOT}/basalt-ui"
    out = {"cases": []}

    def consumer_ready(x):
        rows = bd("ready", "--json", "--limit", "0", cwd=wo, extra_env=EXTRA).json() or []
        return x in {i["id"] for i in rows}

    def explain(x):
        t = bd("ready", "--explain", "--limit", "200", cwd=wo, extra_env=EXTRA).out
        i = t.find(x)
        return " ".join(t[i:i + 200].split())[:140] if i >= 0 else "not listed as ready"

    def case(label, cfg, cap, ship_steps):
        if cfg is None:
            bd("config", "unset", "external_projects.bu", cwd=wo, extra_env=EXTRA)
        else:
            bd("config", "set", "external_projects.bu", cfg, cwd=wo, extra_env=EXTRA)
        x = ids_of(bd("create", f"ext consumer {label}", "-t", "task", "--json", cwd=wo, extra_env=EXTRA))
        y = ids_of(bd("create", f"ext provider {label}", "-t", "task", "-l", f"export:{cap}", "--json", cwd=bu, extra_env=EXTRA))
        r = bd("dep", "add", x, f"external:bu:{cap}", cwd=wo, extra_env=EXTRA)
        steps = [{"state": "capability unshipped (provider open)", "consumer_in_ready": consumer_ready(x), "why": explain(x)}]
        if "close" in ship_steps:
            bd("close", y, "-r", "built", cwd=bu, extra_env=EXTRA)
            steps.append({"state": "provider closed, not shipped", "consumer_in_ready": consumer_ready(x), "why": explain(x)})
        if "ship" in ship_steps:
            rs = bd("ship", cap, cwd=bu, extra_env=EXTRA)
            steps.append({"state": f"shipped (bd ship exit {rs.rc})", "consumer_in_ready": consumer_ready(x), "why": explain(x)})
        out["cases"].append({"case": label, "dep_add_exit": r.rc, "steps": steps})
        return x

    case("A project not configured", None, "capa", ("close", "ship"))
    case("B relative path", "../basalt-ui", "capb", ("close", "ship"))
    case("C absolute path", bu, "capc", ("close", "ship"))
    out["enforced_in_ready"] = any((s["consumer_in_ready"] is False) for c in out["cases"] for s in c["steps"])
    out["config_yaml_has_external_projects"] = "external_projects" in open(f"{wo}/.beads/config.yaml").read()
    out["git_status_wo"] = git("status", "--short", cwd=wo).out.splitlines()
    return out


def main():
    OUT["setup"] = setup()
    tasks = load_dataset()
    maps, load = {}, {}
    for prefix, name in REPOS:
        ids, timing = load_repo(prefix, tasks, f"{ROOT}/{name}", EXTRA, with_external=False)
        maps[prefix] = ids
        load[name] = timing
    OUT["load"] = load
    OUT["load_total_s"] = round(sum(v["load_total_s"] for v in load.values()), 1)
    pids = dolt_pids()
    OUT["dolt_server_processes_after_load"] = len(pids)

    # ready set vs oracle (cross-repo edges not wired yet)
    oracle = {}
    for prefix, name in REPOS:
        cwd = f"{ROOT}/{name}"
        id2key = {v: k for k, v in maps[prefix].items()}
        got, r = ready_keys(cwd, id2key)
        exp = oracle_ready(tasks, prefix, parent_propagation=True, exclude_types=())
        exp_nopp = oracle_ready(tasks, prefix, parent_propagation=False, exclude_types=())
        oracle[name] = {"ready_rows": len(got), "oracle_with_parent_propagation": len(exp),
                        "match_with_parent_propagation": got == exp,
                        "oracle_direct_edges_only": len(exp_nopp), "match_direct_only": got == exp_nopp,
                        "ready_json_bytes": len(r.out), "ready_secs": round(r.secs, 3),
                        "ready_types": sorted({x["issue_type"] for x in (r.json() or [])})}
        # the mother's query: leaf work only
        leaf, _ = ready_keys(cwd, id2key, ("--exclude-type", "epic,decision"))
        oracle[name]["ready_leaf_work_rows"] = len(leaf)
    OUT["ready_vs_oracle"] = oracle

    # operations, semantics and externals on the biggest repo / the pair
    OUT["ops_df"] = bench_ops(f"{ROOT}/dotfiles")
    OUT["semantics"] = semantics(f"{ROOT}/dotfiles")
    OUT["external"] = external_deps()
    # wire the dataset's own cross-repo edges and re-check the ready set of wo
    wo = f"{ROOT}/weatherorb"
    edges = []
    for t in tasks:
        for d in t["deps"]:
            if d.startswith("external:") and t["repo"] == "wo":
                edges.append({"from": maps["wo"][t["key"]], "to": d, "type": "blocks"})
    p = f"{SPIKE}/data/deps-wo-ext.jsonl"
    open(p, "w").write("".join(json.dumps(e) + "\n" for e in edges))
    r = bd("dep", "add", "--file", p, cwd=wo, extra_env=EXTRA)
    id2key = {v: k for k, v in maps["wo"].items()}
    got, _ = ready_keys(wo, id2key)
    exp = oracle_ready(tasks, "wo", parent_propagation=True, exclude_types=())
    OUT["dataset_external_edges"] = {"added": len(edges), "exit": r.rc, "ready_rows": len(got),
                                      "oracle_rows": len(exp), "match": got == exp,
                                      "extra_in_bd": sorted(got - exp)[:8], "missing_in_bd": sorted(exp - got)[:8]}
    pids = dolt_pids()
    OUT["dolt_server_processes_end"] = len(pids)
    OUT["dolt_server_rss_mb_end"] = rss_mb(pids)
    OUT["disk_kb"] = {name: du_kb(f"{ROOT}/{name}/.beads") for _, name in REPOS}
    if TOPO == "shared":
        OUT["disk_kb"]["shared_server_dir"] = du_kb(f"{ISO}/.beads/shared-server")
    OUT["git_after"] = {name: {"commits": int(git("rev-list", "--count", "HEAD", cwd=f"{ROOT}/{name}").out),
                               "status": git("status", "--short", cwd=f"{ROOT}/{name}").out.splitlines()[:6]}
                        for _, name in REPOS}
    OUT["id_maps_saved"] = True
    json.dump(maps, open(f"{SPIKE}/data/idmap-{TOPO}.json", "w"))
    OUT["loadavg_at_end"] = loadavg()
    print(save(f"topology-{TOPO}", OUT))


if __name__ == "__main__":
    main()
