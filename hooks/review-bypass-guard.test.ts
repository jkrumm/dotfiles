#!/usr/bin/env bun

/**
 * Tests for the review-bypass-guard PreToolUse hook (incident 2026-11-05: a
 * factory lead admin-merged a work repo's PR past its required review).
 *
 * A false allow lets a lead bypass another team's review; a false deny blocks
 * an ordinary merge. Both directions are covered, plus the FACTORY_SESSION gate.
 */

import { describe, expect, test } from "bun:test";
import { findViolation } from "./review-bypass-guard";

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

describe("deny reason", () => {
  test("says it is the owner's to do by hand", () => {
    const reason = findViolation("gh pr merge 12 --admin") ?? "";
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
