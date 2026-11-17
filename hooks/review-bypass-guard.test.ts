#!/usr/bin/env bun

/**
 * Tests for the review-bypass-guard PreToolUse hook (incident 2026-11-05: a
 * factory lead admin-merged a work repo's PR past its required review).
 *
 * A false allow lets a lead bypass another team's review; a false deny blocks
 * an ordinary merge. Both directions are covered, plus the FACTORY_SESSION gate.
 */

import { describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { findViolation, gitRepoResolver } from "./review-bypass-guard";

const HOOK = `${import.meta.dir}/review-bypass-guard.ts`;

const denied = (cmd: string) => expect(findViolation(cmd)).not.toBeNull();
const allowed = (cmd: string) => expect(findViolation(cmd)).toBeNull();

describe("deny", () => {
  test("gh pr merge --admin in any position", () => {
    denied("gh pr merge --admin");
    denied("gh pr merge 12 --admin");
    denied("gh pr merge 12 --squash --admin");
    denied("gh pr merge --admin --squash 12");
    denied("gh pr merge 12 --admin=true");
    denied("gh pr merge 12 -R owner/repo --admin");
    denied("gh -R owner/repo pr merge 12 --admin");
    denied("gh pr merge https://github.com/o/r/pull/12 --admin --delete-branch");
  });

  test("wrappers, chains and shells do not hide the call", () => {
    denied("/opt/homebrew/bin/gh pr merge 12 --admin");
    denied("env GH_TOKEN=x gh pr merge 12 --admin");
    denied("command gh pr merge 12 --admin");
    denied("echo ok && gh pr merge 12 --squash --admin");
    denied("bash -c 'gh pr merge 12 --admin'");
    denied(`sh -lc "gh pr merge 12 --admin"`);
    denied(`eval "gh pr merge 12 --admin"`);
    denied("echo $(gh pr merge 12 --admin)");
    denied("bash <<'EOF'\ngh pr merge 12 --admin\nEOF");
    denied("echo 12 | xargs gh pr merge --admin");
    denied("timeout 30 gh pr merge 12 --admin");
  });

  test("gh api on a merge endpoint", () => {
    denied("gh api -X PUT repos/o/r/pulls/12/merge");
    denied("gh api --method PUT /repos/o/r/pulls/12/merge -f merge_method=squash");
    denied("gh api repos/o/r/pulls/12/merge -f merge_method=squash");
    denied("gh api -XPUT repos/o/r/pulls/12/merge");
    denied("gh api --method=PUT repos/o/r/pulls/12/merge");
    denied("gh api repos/{owner}/{repo}/pulls/12/merge -X PUT");
    denied("gh api https://api.github.com/repos/o/r/pulls/12/merge -X PUT");
    denied("gh api -X POST repos/o/r/merges -f base=main -f head=x");
  });

  test("gh api that writes rulesets or branch protection", () => {
    denied("gh api -X PUT repos/o/r/branches/main/protection --input p.json");
    denied("gh api -X DELETE repos/o/r/branches/main/protection");
    denied("gh api -X DELETE repos/o/r/branches/main/protection/required_pull_request_reviews");
    denied("gh api -X POST repos/o/r/rulesets --input r.json");
    denied("gh api -X PUT repos/o/r/rulesets/42 -F enforcement=disabled");
    denied("gh api -X DELETE repos/o/r/rulesets/42");
    denied("gh api -X PUT orgs/o/rulesets/42 -f enforcement=disabled");
    denied("gh api repos/o/r/rulesets -f name=x");
    denied("gh api -X PATCH /repos/o/r/rulesets/42 -f enforcement=disabled");
  });

  test("gh api graphql mutations", () => {
    denied(`gh api graphql -f query='mutation { mergePullRequest(input: {pullRequestId: "x"}) { clientMutationId } }'`);
    denied(`gh api graphql -f query='mutation { updateRepositoryRuleset(input: {}) { clientMutationId } }'`);
    denied(`gh api graphql -f query='mutation { deleteBranchProtectionRule(input: {}) { clientMutationId } }'`);
    denied(`gh api graphql -F query='mutation { createBranchProtectionRule(input: {}) { clientMutationId } }'`);
  });

  test("gh api graphql with a query that cannot be read", () => {
    denied("gh api graphql --input query.json");
    denied("gh api graphql -F query=@merge.graphql");
    denied("gh api graphql -f query=@- <<'EOF'\nmutation { x }\nEOF");
    denied('gh api graphql -f query="$(cat m.graphql)"');
    denied("gh api graphql -f query=`cat m.graphql`");
    denied('Q=\'mutation { x }\'; gh api graphql -f query="$Q"');
    denied('gh api graphql -F query="${Q}"');
  });

  test("gh api on an endpoint built from variables", () => {
    denied('gh api "$EP" -X PUT');
    denied('gh api "$(cat ep)" -X DELETE');
    denied('gh api "${EP}" -f enforcement=disabled');
    denied("gh api repos/o/r/pulls/$N/merge -X PUT");
    denied('gh api "repos/$REPO/rulesets/$ID" -X DELETE');
    denied('gh api "repos/$REPO/pulls/$N/merge" -X PUT');
    denied('S=pulls/12/merge; gh api -X PUT repos/o/r/$S');
    denied('gh api -X DELETE repos/o/r/$KIND/42');
    denied('gh api -X PUT "repos/$REPO/$TAIL"');
    denied('gh api -X PUT repos/o/r/pulls/$N/$ACTION');
    denied('gh api -X POST repos/o/r/$(cat kind)');
  });
});

describe("allow", () => {
  test("a plain merge", () => {
    allowed("gh pr merge 12 --squash");
    allowed("gh pr merge 12 --rebase --delete-branch");
    allowed("gh pr merge 12 --merge");
    allowed("gh pr merge --auto --squash");
    allowed("gh pr merge");
    allowed("gh pr merge 12 --admin=false");
  });

  test("other gh commands", () => {
    allowed("gh pr create --title x --body y");
    allowed("gh pr view 12 --json state");
    allowed("gh pr checks 12");
    allowed("gh pr list --admin");
    allowed("gh issue list");
    allowed("gh run watch");
  });

  test("gh api reads of the same endpoints", () => {
    allowed("gh api repos/o/r/pulls/12/merge");
    allowed("gh api repos/o/r/rulesets");
    allowed("gh api repos/o/r/rulesets/42 --jq .enforcement");
    allowed("gh api repos/o/r/branches/main/protection");
    allowed("gh api -X GET repos/o/r/rulesets -f per_page=5");
    allowed("gh api repos/o/r/pulls/12");
    allowed("gh api -X POST repos/o/r/issues/12/comments -f body=hi");
    allowed("gh api -X PATCH repos/o/r/pulls/12 -f state=closed");
    allowed("gh api repos/o/r/pulls/12/reviews");
  });

  test("gh api with variables that cannot reach a bypass", () => {
    allowed('gh api "$EP"');
    allowed('gh api -X POST repos/o/r/issues/$N/labels -f labels[]=x');
    allowed('gh api "repos/$REPO/rulesets"');
    allowed('gh api -X POST "repos/$REPO/issues/$N/comments" -f body=hi');
    allowed('gh api -X PATCH repos/o/r/pulls/$N -f state=closed');
    allowed('gh api graphql -f query=\'{ viewer { login } }\' -f owner="$OWNER"');
  });

  test("gh api graphql reads", () => {
    allowed(`gh api graphql -f query='{ viewer { login } }'`);
    allowed(`gh api graphql -f query='query { repository(owner: "o", name: "r") { id } }'`);
  });

  test("the words inside quoted text are data", () => {
    allowed(`git commit -m "deny gh pr merge --admin"`);
    allowed(`grep -rn 'gh pr merge --admin' docs/`);
    allowed(`echo "gh api -X PUT repos/o/r/pulls/12/merge"`);
    allowed(`rg 'rulesets' hooks/`);
    allowed(`cat <<'EOF'\ngh pr merge 12 --admin\nEOF`);
    allowed(`gh pr create --body "never run gh pr merge --admin"`);
  });

  test("empty and unrelated commands", () => {
    allowed("");
    allowed("ls -la");
    allowed("make check");
    allowed("git push origin HEAD");
    allowed("bash -c 'echo hi'");
  });
});

describe("the GitHub config sync (Issue 1886)", () => {
  // The script writes rulesets itself; in a factory session it runs tighten-only
  // (scripts/github-config.sh), so the sync is allowed and only turning that off is denied.
  test("the sync runs in a factory session", () => {
    allowed("make -C ~/SourceRoot/dotfiles github-config");
    allowed("make github-config");
    allowed("make -C ~/SourceRoot/dotfiles github-config-tighten");
    allowed("make github-config-dry");
    allowed("~/SourceRoot/dotfiles/scripts/github-config.sh");
    allowed("bash scripts/github-config.sh --tighten-only");
    allowed("env GITHUB_OWNER=jkrumm make github-config");
    allowed("DRY_RUN=1 scripts/github-config.sh --tighten-only");
    allowed("GITHUB_OWNER=jkrumm make github-config");
  });

  test("clearing or overriding the factory marker is denied", () => {
    denied("FACTORY_SESSION= make github-config");
    denied("env -u FACTORY_SESSION make -C ~/SourceRoot/dotfiles github-config");
    denied("unset FACTORY_SESSION; make github-config");
    denied("TIGHTEN_ONLY=0 make github-config");
    denied("make github-config TIGHTEN_ONLY=0");
    denied("make github-config FACTORY_SESSION=");
    denied("bash scripts/github-config.sh FACTORY_SESSION=");
    denied("env -i make github-config");
    denied("env -i bash scripts/github-config.sh");
    denied("FACTORY_SESSION= ~/SourceRoot/dotfiles/scripts/github-config.sh");
    denied("FACTORY_SESSION= bash -c 'make github-config'");
    denied("cd ~/SourceRoot/dotfiles && unset FACTORY_SESSION && make github-config");
  });

  test("the marker without the sync is no business of this guard", () => {
    allowed("echo $FACTORY_SESSION");
    allowed("FACTORY_SESSION=1 make check");
    allowed(`git commit -m "make github-config stays tighten-only"`);
  });

  test("a plain ruleset write is still denied", () => {
    denied("gh api -X POST repos/o/r/rulesets --input ruleset.json");
    denied("gh api -X PUT repos/jkrumm/software-factory/rulesets/27439448 --input -");
    denied("gh api -X DELETE repos/o/r/rulesets/9");
    denied("gh api -X PUT repos/o/r/branches/master/protection --input p.json");
  });

  test("the denial names the Errand path", () => {
    const reason = findViolation("TIGHTEN_ONLY=0 make github-config") ?? "";
    expect(reason).toContain("tighten-only");
    expect(reason).toContain("factory errand raise");
  });
});

describe("deny reason", () => {
  test("says it is the owner's to do by hand", () => {
    const reason = findViolation("gh pr merge 12 -R o/r --admin") ?? "";
    expect(reason).toContain("owner's to do by hand");
    expect(reason).toContain("factory issue ask");
  });
});

describe("hook I/O", () => {
  const run = async (tool_name: string, command: string, factory: boolean) => {
    const env: Record<string, string> = { ...(process.env as Record<string, string>) };
    delete env.FACTORY_SESSION;
    if (factory) env.FACTORY_SESSION = "w1";
    const proc = Bun.spawn(["bun", HOOK], {
      stdin: new Blob([JSON.stringify({ tool_name, tool_input: { command } })]),
      stdout: "pipe",
      stderr: "pipe",
      env,
    });
    const stdout = await new Response(proc.stdout).text();
    return { code: await proc.exited, stdout };
  };

  test("denies with the PreToolUse deny shape when FACTORY_SESSION is set", async () => {
    const { code, stdout } = await run("Bash", "gh pr merge 12 --squash --admin", true);
    expect(code).toBe(0);
    const out = JSON.parse(stdout).hookSpecificOutput;
    expect(out.hookEventName).toBe("PreToolUse");
    expect(out.permissionDecision).toBe("deny");
    expect(out.permissionDecisionReason).toContain("owner's to do by hand");
  });

  test("passes the same command through without FACTORY_SESSION", async () => {
    expect(await run("Bash", "gh pr merge 12 --squash --admin", false)).toEqual({ code: 0, stdout: "" });
    expect(await run("Bash", "gh api -X PUT repos/o/r/rulesets/1 -f enforcement=disabled", false)).toEqual({
      code: 0,
      stdout: "",
    });
  });

  test("a plain gh pr merge --squash stays allowed in a factory session", async () => {
    expect(await run("Bash", "gh pr merge 12 --squash", true)).toEqual({ code: 0, stdout: "" });
  });

  test("silent on a non-Bash tool", async () => {
    expect(await run("Edit", "gh pr merge 12 --admin", true)).toEqual({ code: 0, stdout: "" });
  });
});

describe("the owner's admin-merge exception", () => {
  const TOOL = "IU-Group-Engineering/epos-tool-athena";
  const TEAMCHAT = "IU-Group-Engineering/epos-ai-teamchat-athena";
  const IMPORT_DASHBOARD = "IU-Group-Engineering/epos-import-dashboard-athena";

  test("allowed only when the command names a listed repo", () => {
    allowed(`gh pr merge 64 -R ${TOOL} --squash --admin`);
    allowed(`gh -R ${TEAMCHAT} pr merge 72 --admin`);
    allowed(`gh pr merge 72 --repo=${TEAMCHAT} --admin`);
    allowed(`gh pr merge https://github.com/${TOOL}/pull/64 --admin --delete-branch`);
    allowed(`GH_CONFIG_DIR=/x gh pr merge 64 -R ${TOOL} --admin`);
    allowed(`gh pr merge 5 -R ${IMPORT_DASHBOARD} --squash --admin`);
  });

  test("no repo named, no checkout to read: denied with the hint to name it", () => {
    for (const cmd of ["gh pr merge 64 --admin", "gh pr merge 125 --squash --admin"]) {
      const reason = findViolation(cmd) ?? "";
      expect(reason).toContain("-R <owner>/<repo>");
      expect(reason).not.toContain("factory issue ask");
    }
  });

  test("another repo, or one name near a listed repo: denied", () => {
    denied("gh pr merge 1 -R IU-Group-Engineering/other --admin");
    denied(`gh pr merge 1 -R ${TOOL}-fork --admin`);
    denied("gh pr merge 1 -R someone/epos-tool-athena --admin");
    denied("gh pr merge https://github.com/IU-Group-Engineering/other/pull/1 --admin");
    denied(`gh pr merge https://evil.example/${TOOL}/pull/1 --admin`);
    denied(`gh pr merge https://github.com/IU-Group-Engineering/other/pull/1 -R ${TOOL} --admin`);
  });

  test("a listed repo's URL in a message is text, not a target", () => {
    denied(`gh pr merge 12 --admin --body https://github.com/${TOOL}/pull/64`);
    denied(`gh pr merge 12 --admin -t https://github.com/${TOOL}/pull/64`);
  });

  test("a chain is judged call by call", () => {
    denied(`gh pr merge 64 -R ${TOOL} --admin && gh pr merge 1 --admin`);
  });

  test("gh api stays denied on the listed repos", () => {
    denied(`gh api -X PUT repos/${TOOL}/pulls/64/merge`);
    denied(`gh api -X DELETE repos/${TOOL}/rulesets/1`);
  });
});

describe("the repo comes from the working directory when the command names none", () => {
  const TEAMCHAT = "IU-Group-Engineering/epos-ai-teamchat-athena";
  const at = (repos: string[] | null) => ({ cwd: "/work/checkout", resolveRepos: () => repos });
  const reasonOf = (cmd: string, repos: string[] | null) => findViolation(cmd, at(repos)) ?? "";

  test("a listed repo: allowed", () => {
    expect(findViolation("gh pr merge 125 --admin", at([TEAMCHAT]))).toBeNull();
    expect(findViolation("gh pr merge 125 --squash --admin 2>&1; echo rc=$?", at([TEAMCHAT]))).toBeNull();
    expect(findViolation("gh pr merge --squash --admin", at([TEAMCHAT, TEAMCHAT]))).toBeNull();
  });

  test("an unlisted repo: denied with the owner text", () => {
    const reason = reasonOf("gh pr merge 125 --admin", ["someone/else"]);
    expect(reason).toContain("owner's to do by hand");
    expect(reason).toContain("factory issue ask");
  });

  test("one unlisted remote among listed ones, or one gh cannot read: denied", () => {
    expect(reasonOf("gh pr merge 1 --admin", [TEAMCHAT, "someone/else"])).toContain("owner's to do by hand");
    expect(reasonOf("gh pr merge 1 --admin", [TEAMCHAT, ""])).toContain("owner's to do by hand");
  });

  test("no checkout or no remote: denied with the hint to name the repo", () => {
    for (const repos of [null, []]) {
      const reason = reasonOf("gh pr merge 125 --admin", repos);
      expect(reason).toContain("-R <owner>/<repo>");
      expect(reason).not.toContain("factory issue ask");
    }
  });

  test("a cd, --chdir, GH_REPO or GIT_DIR means the directory proves nothing: denied with the hint", () => {
    for (const cmd of [
      "cd /elsewhere && gh pr merge 64 --admin",
      "(cd /elsewhere; gh pr merge 64 --admin)",
      "pushd /elsewhere && gh pr merge 64 --admin",
      "bash -c 'cd /elsewhere && gh pr merge 64 --admin'",
      "env -C /elsewhere gh pr merge 64 --admin",
      "GH_REPO=someone/else gh pr merge 64 --admin",
      "export GH_REPO=someone/else; gh pr merge 64 --admin",
      "GIT_DIR=/x/.git gh pr merge 64 --admin",
      "GIT_WORK_TREE=/x gh pr merge 64 --admin",
      "GH_HOST=ghe.example gh pr merge 64 --admin",
    ]) {
      const reason = reasonOf(cmd, [TEAMCHAT]);
      expect(reason).toContain("-R <owner>/<repo>");
      expect(reason).not.toContain("factory issue ask");
    }
  });

  test("a named repo wins over the directory", () => {
    expect(findViolation(`gh pr merge 1 -R someone/else --admin`, at([TEAMCHAT]))).not.toBeNull();
    expect(findViolation(`gh pr merge 1 -R ${TEAMCHAT} --admin`, at(["someone/else"]))).toBeNull();
  });
});

describe("gitRepoResolver", () => {
  const git = (cwd: string, ...args: string[]) => {
    const p = Bun.spawnSync(["git", "-C", cwd, ...args], { stdout: "ignore", stderr: "pipe" });
    expect(p.exitCode).toBe(0);
  };
  const repo = (setup: (dir: string) => void) => {
    const dir = mkdtempSync(join(tmpdir(), "rbg-"));
    try {
      git(dir, "init", "-q");
      setup(dir);
      return gitRepoResolver(dir);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  };

  test("reads github remotes in https, scp and ssh form", () => {
    expect(repo((d) => git(d, "remote", "add", "origin", "https://github.com/o/r.git"))).toEqual(["o/r"]);
    expect(repo((d) => git(d, "remote", "add", "origin", "git@github.com:o/r.git"))).toEqual(["o/r"]);
    expect(repo((d) => git(d, "remote", "add", "origin", "ssh://git@github.com/o/r"))).toEqual(["o/r"]);
    expect(repo((d) => git(d, "remote", "add", "origin", "https://x-access-token@github.com/o/r"))).toEqual(["o/r"]);
  });

  test("another host is unreadable, a set-default pin replaces the URL", () => {
    expect(repo((d) => git(d, "remote", "add", "origin", "https://gitlab.com/o/r.git"))).toEqual([""]);
    expect(
      repo((d) => {
        git(d, "remote", "add", "origin", "https://github.com/o/r.git");
        git(d, "config", "remote.origin.gh-resolved", "up/stream");
      }),
    ).toEqual(["up/stream"]);
    expect(
      repo((d) => {
        git(d, "remote", "add", "origin", "https://github.com/o/r.git");
        git(d, "config", "remote.origin.gh-resolved", "base");
      }),
    ).toEqual(["o/r"]);
  });

  test("no remotes, or no checkout at all: empty", () => {
    expect(repo(() => {})).toEqual([]);
    const dir = mkdtempSync(join(tmpdir(), "rbg-"));
    try {
      expect(gitRepoResolver(dir)).toEqual([]);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("hook I/O: the cwd of the hook input decides", async () => {
    const dir = mkdtempSync(join(tmpdir(), "rbg-"));
    try {
      git(dir, "init", "-q");
      const run = async (url: string) => {
        git(dir, "remote", "remove", "origin");
        git(dir, "remote", "add", "origin", url);
        const env: Record<string, string> = { ...(process.env as Record<string, string>), FACTORY_SESSION: "w1" };
        delete env.GH_REPO;
        const proc = Bun.spawn(["bun", HOOK], {
          stdin: new Blob([JSON.stringify({ tool_name: "Bash", cwd: dir, tool_input: { command: "gh pr merge 125 --squash --admin" } })]),
          stdout: "pipe",
          env,
        });
        const out = await new Response(proc.stdout).text();
        await proc.exited;
        return out;
      };
      git(dir, "remote", "add", "origin", "x");
      expect(await run("git@github.com:IU-Group-Engineering/epos-ai-teamchat-athena.git")).toBe("");
      expect(await run("git@github.com:someone/else.git")).toContain("owner's to do by hand");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
