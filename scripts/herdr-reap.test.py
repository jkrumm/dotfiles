#!/usr/bin/env python3
"""Hermetic tests for herdr-reap.py: fake `herdr` and `claude` on PATH, real throwaway git repos,
HOME pointed at a tmpdir (transcripts, state, log). Run: python3 scripts/herdr-reap.test.py"""
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest

REAP = os.path.join(os.path.dirname(os.path.abspath(__file__)), "herdr-reap.py")

FAKE_HERDR = r'''#!/usr/bin/env python3
import json, os, subprocess, sys
a = sys.argv[1:]
with open(os.environ["FAKE_WORLD"]) as f:
    d = json.load(f)
with open(os.environ["FAKE_CALLS"], "a") as f:
    f.write(" ".join(a) + "\n")
with open(os.environ["FAKE_CALLS"]) as f:
    seen = [l for l in f if l.startswith(" ".join(a[:2]))]
n = len(seen)
if a[:2] == ["pane", "list"]:
    panes = list(d["panes"])
    if d.get("new_pane_after") is not None and n > d["new_pane_after"]:
        panes.append({"pane_id": "newp", "tab_id": d["new_pane_tab"]})
    print(json.dumps({"result": {"panes": panes}}))
elif a[:2] == ["agent", "list"]:
    if d.get("recheck_cmd") and n == 2:  # the re-query right before the close: something changes in between
        subprocess.run(d["recheck_cmd"], check=True)
    flip = d.get("flip_after")
    only = d.get("flip_panes")
    agents = [dict(x, agent_status="working") if flip is not None and n > flip and (only is None or x["pane_id"] in only) else x
              for x in d["agents"]]
    print(json.dumps({"result": {"agents": agents}}))
elif a[:2] == ["tab", "list"]:
    print(json.dumps({"result": {"tabs": d["tabs"]}}))
else:
    print(json.dumps({"result": {"type": "ok"}}))
'''
FAKE_GH = r'''#!/usr/bin/env python3
import json, os, sys
with open(os.environ["FAKE_WORLD"]) as f:
    d = json.load(f)
with open(os.environ["FAKE_CALLS"], "a") as f:
    f.write("gh " + " ".join(sys.argv[1:]) + "\n")
prs = d.get("prs")
if prs is None:
    sys.exit(1)
print(json.dumps([{"state": pr[0], "headRefOid": pr[1], "baseRefName": pr[2] if len(pr) > 2 else "master"} for pr in prs]))
'''
FAKE_CLAUDE = r'''#!/usr/bin/env python3
import json, os, sys
with open(os.environ["FAKE_WORLD"]) as f:
    d = json.load(f)
with open(os.environ["FAKE_CALLS"], "a") as f:
    f.write("claude " + " ".join(sys.argv[1:]) + "\n")
if sys.argv[1:3] == ["agents", "--json"]:
    print(json.dumps(d.get("bg", [])))
'''


def write(path, text):
    with open(path, "w") as f:
        f.write(text)


def git(cwd, *a):
    subprocess.run(["git", "-C", cwd, *a], check=True, capture_output=True)


class Reap(unittest.TestCase):
    def setUp(self):
        self.t = tempfile.mkdtemp()
        self.home = os.path.join(self.t, "home")
        self.bin = os.path.join(self.t, "bin")
        os.makedirs(self.bin)
        os.makedirs(os.path.join(self.home, ".claude/projects/p"))
        for n, body in (("herdr", FAKE_HERDR), ("claude", FAKE_CLAUDE), ("gh", FAKE_GH)):
            with open(os.path.join(self.bin, n), "w") as f:
                f.write(body)
            os.chmod(os.path.join(self.bin, n), 0o755)
        self.world = os.path.join(self.t, "world.json")
        self.calls = os.path.join(self.t, "calls.txt")
        with open(self.calls, "w"):
            pass

    def repo(self, name, dirty=False, plan_active=False):
        r = os.path.join(self.t, name)
        remote = os.path.join(self.t, f"{name}.git")
        subprocess.run(["git", "init", "-q", "--bare", remote], check=True)
        subprocess.run(["git", "clone", "-q", remote, r], check=True, capture_output=True)
        git(r, "config", "user.email", "t@t"); git(r, "config", "user.name", "t")
        os.makedirs(os.path.join(r, "docs/waves"))
        with open(os.path.join(r, "docs/waves/PLAN.md"), "w") as f:
            f.write(f"## Wave 1 — x   <!-- status: {'active' if plan_active else 'done'} -->\n")
        git(r, "add", "."); git(r, "commit", "-qm", "init"); git(r, "push", "-qu", "origin", "HEAD")
        os.makedirs(os.path.join(r, "sub"))
        if dirty:
            write(os.path.join(r, "x"), "x")
        return r

    def fleet_repo(self, name="fleet"):
        """A repo inside <home>/SourceRoot (the fleet the merged-fan rule is limited to), with an
        origin whose configured URL is a github.com one (insteadOf maps it to the local bare repo)."""
        r = os.path.join(self.home, "SourceRoot", name)
        remote = os.path.join(self.t, f"{name}.git")
        os.makedirs(os.path.dirname(r))
        subprocess.run(["git", "init", "-q", "--bare", "-b", "master", remote], check=True)
        subprocess.run(["git", "clone", "-q", remote, r], check=True, capture_output=True)
        git(r, "config", "user.email", "t@t"); git(r, "config", "user.name", "t")
        git(r, "checkout", "-qb", "master")
        os.makedirs(os.path.join(r, "docs/waves"))
        with open(os.path.join(r, "docs/waves/PLAN.md"), "w") as f:
            f.write("## Wave 1 — x   <!-- status: active -->\n")  # an active wave: the old rule keeps every tab
        git(r, "add", "."); git(r, "commit", "-qm", "init"); git(r, "push", "-qu", "origin", "master")
        git(r, "remote", "set-head", "origin", "master")
        git(r, "config", f"url.{remote}.insteadOf", f"https://github.com/t/{name}.git")
        git(r, "config", "remote.origin.url", f"https://github.com/t/{name}.git")
        return r

    def fan_branch(self, r, branch, how, mark=True):
        """Worktree under <repo>/.claude/worktrees on `branch` with one commit, landed per `how`:
        rebase (master gets the commit with a new sha), deleted (branch gone on origin, never merged),
        open (pushed, live), unpushed (never pushed), fresh (at the base, never pushed)."""
        wt = os.path.join(r, ".claude/worktrees", branch)
        git(r, "worktree", "add", "-q", "-b", branch, wt, "master")
        if mark:  # what scripts/fan-list.sh --mark writes for every worktree rd fan creates
            gd = subprocess.run(["git", "-C", wt, "rev-parse", "--absolute-git-dir"], check=True,
                                capture_output=True, text=True).stdout.strip()
            write(os.path.join(gd, "rd-fan"), "t")
        git(wt, "config", "user.email", "t@t"); git(wt, "config", "user.name", "t")
        if how == "fresh":
            return wt
        if how == "freshpushed":  # pushed at the base, no commit of its own
            git(wt, "push", "-qu", "origin", branch)
            return wt
        if how == "mergeonly":  # nothing of its own: a merge commit that pulled the default's newer commit in
            write(os.path.join(r, "newer.txt"), "newer")
            git(r, "add", "."); git(r, "commit", "-qm", "newer on master"); git(r, "push", "-q", "origin", "master")
            git(wt, "config", "user.email", "t@t"); git(wt, "config", "user.name", "t")
            git(wt, "fetch", "-q", "origin")
            git(wt, "merge", "-q", "--no-ff", "-m", "merge master", "origin/master")
            git(wt, "push", "-qu", "origin", branch)
            subprocess.run(["git", "--git-dir", os.path.join(self.t, f"{os.path.basename(r)}.git"), "branch", "-qD", branch],
                           check=True, capture_output=True)
            git(r, "fetch", "-q", "--prune", "origin")
            return wt
        write(os.path.join(wt, f"{branch}.txt"), branch)
        git(wt, "add", "."); git(wt, "commit", "-qm", branch)
        if how == "unpushed":
            return wt
        git(wt, "push", "-qu", "origin", branch)
        if how == "rebase":  # the PR's rebase merge: same patch, new commit, on master
            git(r, "checkout", "-q", "master")
            git(r, "cherry-pick", "-x", branch)
            git(r, "commit", "-q", "--amend", "-m", f"{branch} (rebased)")
            git(r, "push", "-q", "origin", "master")
            git(r, "checkout", "-q", "--detach")  # keep master free
        elif how in ("deleted", "pruned"):  # deleted on origin by someone else; "pruned" also drops our tracking ref
            subprocess.run(["git", "--git-dir", os.path.join(self.t, f"{os.path.basename(r)}.git"), "branch", "-qD", branch],
                           check=True, capture_output=True)
            if how == "pruned":
                git(r, "fetch", "-q", "--prune", "origin")
        return wt

    def agent(self, pane, tab, status, cwd, idle_h=30):
        sid = f"sid-{pane}"
        ts = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(time.time() - idle_h * 3600))
        with open(os.path.join(self.home, ".claude/projects/p", f"{sid}.jsonl"), "w") as f:
            f.write(json.dumps({"timestamp": ts}, separators=(",", ":")) + "\n")
        return ({"pane_id": pane, "tab_id": tab}, {"pane_id": pane, "tab_id": tab, "agent": "claude", "agent_status": status,
                "cwd": cwd, "agent_session": {"value": sid}}, {"tab_id": tab, "label": tab})

    def run_reap(self, agents, bg=(), *flags, prs=None, flip_after=None, flip_panes=None,
                 new_pane_after=None, new_pane_tab="t1", recheck_cmd=None):
        panes, ags, tabs = zip(*agents) if agents else ((), (), ())
        with open(self.world, "w") as f:
            json.dump({"panes": list(panes), "agents": list(ags), "tabs": list(tabs), "bg": list(bg), "prs": prs,
                       "flip_after": flip_after, "flip_panes": flip_panes, "new_pane_after": new_pane_after, "new_pane_tab": new_pane_tab,
                       "recheck_cmd": recheck_cmd}, f)
        env = dict(os.environ, HOME=self.home, PATH=f"{self.bin}:{os.environ['PATH']}", FAKE_WORLD=self.world,
                   FAKE_CALLS=self.calls, HERDR_PANE_ID="own", REAP_IDLE_H="12")
        r = subprocess.run([sys.executable, REAP, *flags], env=env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.last_out = r.stdout
        return self.calls_text()

    def calls_text(self):
        with open(self.calls) as f:
            return f.read()

    def log(self):
        p = os.path.join(self.home, "Library/Logs/herdr-reap.log")
        if not os.path.exists(p):
            return ""
        with open(p) as f:
            return f.read()

    def test_closes_idle_clean_pushed(self):
        r = self.repo("a")
        calls = self.run_reap([self.agent("p1", "t1", "idle", r)])
        self.assertIn("tab close t1", calls)
        self.assertIn("close tab=t1", self.log())

    def test_dry_run_changes_nothing(self):
        r = self.repo("a")
        calls = self.run_reap([self.agent("p1", "t1", "idle", r)], (), "--dry-run")
        self.assertNotIn("tab close", calls)
        self.assertEqual(self.log(), "")

    def test_recent_idle_is_kept(self):
        r = self.repo("a")
        self.assertNotIn("tab close", self.run_reap([self.agent("p1", "t1", "idle", r, idle_h=1)]))

    def test_never_working_or_blocked(self):
        r1, r2 = self.repo("a"), self.repo("b")
        calls = self.run_reap([self.agent("p1", "t1", "working", r1), self.agent("p2", "t2", "blocked", r2)])
        self.assertNotIn("tab close", calls)

    def test_working_agent_in_subdir_shields_the_checkout(self):
        r = self.repo("a")
        calls = self.run_reap([self.agent("p1", "t1", "idle", r), self.agent("p2", "t2", "working", os.path.join(r, "sub"))])
        self.assertNotIn("tab close", calls)
        self.assertNotIn("agent prompt", calls)

    def test_dirty_is_messaged_not_closed(self):
        r = self.repo("a", dirty=True)
        calls = self.run_reap([self.agent("p1", "t1", "done", r)])
        self.assertNotIn("tab close", calls)
        self.assertIn("agent prompt p1", calls)
        # and only once per 24 h
        calls = self.run_reap([self.agent("p1", "t1", "done", r)])
        self.assertEqual(calls.count("agent prompt p1"), 1)

    def test_unpushed_is_not_closed(self):
        r = self.repo("a")
        git(r, "commit", "--allow-empty", "-qm", "local")
        self.assertNotIn("tab close", self.run_reap([self.agent("p1", "t1", "idle", r)]))

    def test_active_wave_plan_shields_the_repo(self):
        r = self.repo("a", plan_active=True)
        self.assertNotIn("tab close", self.run_reap([self.agent("p1", "t1", "idle", r)]))

    def test_non_git_cwd_and_non_agent_pane_and_own_tab(self):
        r = self.repo("a")
        plain = os.path.join(self.t, "plain"); os.makedirs(plain)
        a1 = self.agent("p1", "t1", "idle", plain)
        a2 = self.agent("p2", "t2", "idle", r)
        a3 = self.agent("own", "t3", "idle", self.repo("c"))
        shell = ({"pane_id": "sh", "tab_id": "t2"}, None, None)
        panes = [a1, a2, a3]
        with open(self.world, "w") as f:
            json.dump({"panes": [x[0] for x in panes] + [shell[0]], "agents": [x[1] for x in panes],
                       "tabs": [x[2] for x in panes], "bg": []}, f)
        env = dict(os.environ, HOME=self.home, PATH=f"{self.bin}:{os.environ['PATH']}", FAKE_WORLD=self.world,
                   FAKE_CALLS=self.calls, HERDR_PANE_ID="own", REAP_IDLE_H="12")
        subprocess.run([sys.executable, REAP], env=env, check=True, capture_output=True)
        self.assertNotIn("tab close", self.calls_text())

    def merged_tab(self, wt, status="idle", name="fleet-slug", idle_h=1, tab="t1", pane="p1"):
        """A tab the old rule would keep (recent idle, active wave): only the merged-fan rule can close it."""
        panes, ag, tabs = self.agent(pane, tab, status, wt, idle_h=idle_h)
        ag["name"] = name
        return (panes, ag, tabs)

    def test_merged_fan_closes_despite_active_wave_and_recent_idle(self):
        r = self.fleet_repo()
        wt = self.fan_branch(r, "feat-a", "rebase")
        calls = self.run_reap([self.merged_tab(wt)])
        self.assertIn("tab close t1", calls)
        self.assertIn("merged into origin/master", self.log())

    def test_pr_merged_state_closes(self):
        r = self.fleet_repo()
        wt = self.fan_branch(r, "feat-a", "open")  # squash-merged on GitHub: patches do not match, PR does
        self.assertNotIn("tab close", self.run_reap([self.merged_tab(wt)], prs=[("OPEN", self.head(wt))]))
        calls = self.run_reap([self.merged_tab(wt)], prs=[("MERGED", self.head(wt))])
        self.assertIn("tab close t1", calls)
        self.assertIn("PR merged", self.log())

    def test_pr_merged_after_prune_needs_head_inside_the_pr(self):
        r = self.fleet_repo()
        wt = self.fan_branch(r, "feat-a", "pruned")  # squash-merged, branch deleted and pruned: only the PR is left
        head = self.head(wt)
        self.assertNotIn("tab close", self.run_reap([self.merged_tab(wt)]))  # no gh answer: unverifiable, kept
        write(os.path.join(wt, "later.txt"), "later")
        git(wt, "add", "."); git(wt, "commit", "-qm", "after the PR head")
        self.assertNotIn("tab close", self.run_reap([self.merged_tab(wt)], prs=[("MERGED", head)]))
        git(wt, "reset", "-q", "--hard", head)
        self.assertIn("tab close t1", self.run_reap([self.merged_tab(wt)], prs=[("CLOSED", head)]))

    def head(self, wt):
        return subprocess.run(["git", "-C", wt, "rev-parse", "HEAD"], check=True, capture_output=True, text=True).stdout.strip()

    def test_branch_deleted_on_origin_closes(self):
        r = self.fleet_repo()
        wt = self.fan_branch(r, "feat-a", "deleted")
        self.assertIn("tab close t1", self.run_reap([self.merged_tab(wt)]))
        self.assertIn("branch deleted on origin", self.log())

    def test_merged_fan_dry_run_lists_without_closing(self):
        r = self.fleet_repo()
        wt = self.fan_branch(r, "feat-a", "rebase")
        calls = self.run_reap([self.merged_tab(wt)], (), "--dry-run")
        self.assertNotIn("tab close", calls)
        self.assertEqual(self.log(), "")

    def test_merged_fan_kept_when_agent_working_or_blocked(self):
        r = self.fleet_repo()
        wt1 = self.fan_branch(r, "feat-a", "rebase")
        wt2 = self.fan_branch(r, "feat-b", "deleted")
        calls = self.run_reap([self.merged_tab(wt1, "working"), self.merged_tab(wt2, "blocked", tab="t2", pane="p2")])
        self.assertNotIn("tab close", calls)

    def test_merged_fan_kept_when_another_agent_works_in_the_checkout(self):
        r = self.fleet_repo()
        wt = self.fan_branch(r, "feat-a", "rebase")
        calls = self.run_reap([self.merged_tab(wt), self.merged_tab(wt, "working", tab="t2", pane="p2")])
        self.assertNotIn("tab close t1", calls)

    def test_merged_fan_kept_when_dirty(self):
        r = self.fleet_repo()
        wt = self.fan_branch(r, "feat-a", "rebase")
        write(os.path.join(wt, "scratch"), "x")
        self.assertNotIn("tab close", self.run_reap([self.merged_tab(wt)]))

    def test_merged_fan_kept_when_commits_unpushed(self):
        r = self.fleet_repo()
        wt = self.fan_branch(r, "feat-a", "rebase")
        write(os.path.join(wt, "later.txt"), "later")
        git(wt, "add", "."); git(wt, "commit", "-qm", "after the merge")
        self.assertNotIn("tab close", self.run_reap([self.merged_tab(wt)]))

    def test_unmerged_live_unpushed_and_fresh_fan_branches_are_kept(self):
        r = self.fleet_repo()
        tabs = [self.merged_tab(self.fan_branch(r, b, how), tab=f"t{i}", pane=f"p{i}")
                for i, (b, how) in enumerate((("live", "open"), ("local", "unpushed"), ("new", "fresh")), 1)]
        self.assertNotIn("tab close", self.run_reap(tabs))

    def test_mother_lead_and_wave_tabs_are_kept(self):
        r = self.fleet_repo()
        tabs = []
        for i, (label, name) in enumerate((("mother", "fleet-slug"), ("wave 3", "fleet-slug"),
                                           ("fan x", "fleet-mother"), ("fan y", "fleet-w3"), ("lead", "fleet-slug")), 1):
            wt = self.fan_branch(r, f"b{i}", "rebase")
            panes, ag, tab = self.merged_tab(wt, name=name, tab=f"t{i}", pane=f"p{i}")
            tab["label"] = label
            tabs.append((panes, ag, tab))
        self.assertNotIn("tab close", self.run_reap(tabs))

    def test_merged_fan_outside_the_fleets_is_kept(self):
        r = self.fleet_repo()
        wt = self.fan_branch(r, "feat-a", "rebase")
        moved = os.path.join(self.t, "elsewhere")
        os.makedirs(moved)
        git(r, "worktree", "move", wt, os.path.join(moved, "wt"))
        main = os.path.join(self.t, "outside")
        os.rename(r, main)  # the main repo now lives outside ~/SourceRoot and ~/IuRoot
        subprocess.run(["git", "-C", main, "worktree", "repair", os.path.join(moved, "wt")], check=True, capture_output=True)
        self.assertNotIn("tab close", self.run_reap([self.merged_tab(os.path.join(moved, "wt"))]))

    def test_stale_pr_never_closes_a_fresh_worker(self):
        r = self.fleet_repo()
        fresh = self.fan_branch(r, "fresh", "fresh")  # never pushed, at the base: any PR head contains it
        self.assertNotIn("tab close", self.run_reap([self.merged_tab(fresh)], prs=[("MERGED", self.head(fresh))]))
        old = self.fan_branch(r, "old", "open")
        newer = self.fan_branch(r, "newer", "open")  # pushed, live; the PR of an earlier use of the name
        calls = self.run_reap([self.merged_tab(newer)], prs=[("MERGED", self.head(old))])
        self.assertNotIn("tab close", calls)

    def test_merged_pr_with_newer_pushed_commits_is_kept(self):
        r = self.fleet_repo()
        wt = self.fan_branch(r, "feat-a", "open")
        pr_head = self.head(wt)
        write(os.path.join(wt, "later.txt"), "later")
        git(wt, "add", "."); git(wt, "commit", "-qm", "after the PR head"); git(wt, "push", "-q", "origin", "feat-a")
        self.assertNotIn("tab close", self.run_reap([self.merged_tab(wt)], prs=[("MERGED", pr_head)]))

    def test_origin_ahead_of_the_pr_head_is_kept(self):
        r = self.fleet_repo()
        wt = self.fan_branch(r, "feat-a", "open")
        pr_head = self.head(wt)
        other = os.path.join(self.t, "other")
        subprocess.run(["git", "clone", "-q", os.path.join(self.t, "fleet.git"), other], check=True, capture_output=True)
        git(other, "config", "user.email", "t@t"); git(other, "config", "user.name", "t")
        git(other, "checkout", "-q", "feat-a")
        write(os.path.join(other, "more.txt"), "more")
        git(other, "add", "."); git(other, "commit", "-qm", "pushed from elsewhere"); git(other, "push", "-q", "origin", "feat-a")
        self.assertNotIn("tab close", self.run_reap([self.merged_tab(wt)], prs=[("MERGED", pr_head)]))

    def test_closed_pr_with_a_live_branch_is_kept(self):
        r = self.fleet_repo()
        wt = self.fan_branch(r, "feat-a", "open")
        self.assertNotIn("tab close", self.run_reap([self.merged_tab(wt)], prs=[("CLOSED", self.head(wt))]))

    def test_unmarked_worktree_is_kept(self):
        r = self.fleet_repo()
        wt = self.fan_branch(r, "feat-a", "rebase", mark=False)  # under .claude/worktrees but not made by rd fan
        self.assertNotIn("tab close", self.run_reap([self.merged_tab(wt)]))

    def test_lead_shaped_tab_label_is_kept(self):
        r = self.fleet_repo()
        tabs = []
        for i, label in enumerate(("x-mother", "x-w3"), 1):
            panes, ag, tab = self.merged_tab(self.fan_branch(r, f"b{i}", "rebase"), tab=f"t{i}", pane=f"p{i}")
            tab["label"] = label
            tabs.append((panes, ag, tab))
        self.assertNotIn("tab close", self.run_reap(tabs))

    def test_status_flip_before_the_close_keeps_the_tab(self):
        r = self.fleet_repo()
        wt = self.fan_branch(r, "feat-a", "rebase")
        calls = self.run_reap([self.merged_tab(wt)], flip_after=1)  # first roster read: idle; the re-query: working
        self.assertNotIn("tab close", calls)
        self.assertIn("close-skipped", self.log())

    def test_unknown_agent_in_the_checkout_protects_it(self):
        r = self.fleet_repo()
        wt = self.fan_branch(r, "feat-a", "rebase")
        calls = self.run_reap([self.merged_tab(wt), self.merged_tab(wt, "unknown", tab="t2", pane="p2")])
        self.assertNotIn("tab close", calls)

    def test_merge_commit_only_branch_is_kept(self):
        r = self.fleet_repo()
        wt = self.fan_branch(r, "feat-a", "mergeonly")  # pushed once, deleted and pruned; cherry sees nothing to port
        self.assertNotIn("tab close", self.run_reap([self.merged_tab(wt)]))

    def test_fresh_but_pushed_branch_is_kept(self):
        r = self.fleet_repo()
        wt = self.fan_branch(r, "feat-a", "freshpushed")  # on origin at the base: patch-equal to everything
        self.assertNotIn("tab close", self.run_reap([self.merged_tab(wt)]))
        self.assertIn("fresh", self.log() + self.last_out)

    def test_pr_merged_into_a_feature_branch_is_not_merged(self):
        r = self.fleet_repo()
        wt = self.fan_branch(r, "feat-a", "pruned")
        head = self.head(wt)
        self.assertNotIn("tab close", self.run_reap([self.merged_tab(wt)], prs=[("MERGED", head, "feat-base")]))
        self.assertIn("tab close t1", self.run_reap([self.merged_tab(wt)], prs=[("MERGED", head, "master")]))

    def test_new_pane_in_the_tab_before_the_close_keeps_it(self):
        r = self.fleet_repo()
        wt = self.fan_branch(r, "feat-a", "rebase")
        calls = self.run_reap([self.merged_tab(wt)], new_pane_after=1)  # a shell pane appears after the plan
        self.assertNotIn("tab close", calls)
        self.assertIn("panes changed", self.log())

    def test_head_moving_between_plan_and_close_keeps_it(self):
        r = self.fleet_repo()
        wt = self.fan_branch(r, "feat-a", "rebase")
        calls = self.run_reap([self.merged_tab(wt)], recheck_cmd=["git", "-C", wt, "commit", "--allow-empty", "-qm", "more"])
        self.assertNotIn("tab close", calls)
        self.assertIn("HEAD moved", self.log())

    def test_tree_dirtied_between_plan_and_close_keeps_it(self):
        r = self.fleet_repo()
        wt = self.fan_branch(r, "feat-a", "rebase")
        calls = self.run_reap([self.merged_tab(wt)], recheck_cmd=["touch", os.path.join(wt, "scratch")])
        self.assertNotIn("tab close", calls)
        self.assertIn("became dirty", self.log())

    def test_another_agent_joining_the_checkout_before_the_close_keeps_it(self):
        r = self.fleet_repo()
        wt = self.fan_branch(r, "feat-a", "rebase")
        other = self.merged_tab(wt, "idle", tab="t2", pane="p2")  # idle at plan time, working at the re-query
        calls = self.run_reap([self.merged_tab(wt), other], flip_after=1, flip_panes=["p2"])
        self.assertNotIn("tab close", calls)

    def test_bg_filter(self):
        old = int((time.time() - 48 * 3600) * 1000)
        bg = [{"id": "aaa", "kind": "background", "state": "blocked", "startedAt": old, "name": "n", "cwd": "/x"},
              {"id": "bbb", "kind": "background", "state": "working", "startedAt": old, "name": "n", "cwd": "/x"},
              {"id": "ccc", "kind": "background", "startedAt": old, "name": "n", "cwd": "/x"},
              {"id": "ddd", "kind": "background", "state": "blocked", "startedAt": int(time.time() * 1000), "name": "n", "cwd": "/x"}]
        calls = self.run_reap([], bg)
        self.assertIn("claude stop aaa", calls)
        for x in ("bbb", "ccc", "ddd"):
            self.assertNotIn(f"claude stop {x}", calls)


if __name__ == "__main__":
    unittest.main()
