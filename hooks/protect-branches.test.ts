#!/usr/bin/env bun

/**
 * Tests for the protect-branches PreToolUse hook.
 *
 * The hook is symlinked live into ~/.claude/hooks, so a regression here changes
 * real behaviour immediately, and the two failure directions are not symmetric.
 * A false allow lets Claude push to a branch that must go through a PR. A false
 * block is worse than annoying: it is silent about *which* repo it protected,
 * so a fleet run reads it as "this repo is protected" and abandons a push that
 * was always allowed. Both directions are covered below.
 */

import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { inspectGit, inspectPush, loadRepoConfig, repoDirectories } from "./protect-branches";

const HOOK = join(import.meta.dir, "protect-branches.ts");
const REAL_CONFIG = join(import.meta.dir, "..", "config", "pr-required-repos.json");

describe("inspectGit — the subcommand is not always at index 1", () => {
  test("plain invocation", () => {
    expect(inspectGit(["git", "push", "origin", "master"])).toEqual({
      subcommand: "push",
      args: ["origin", "master"],
      cDirs: [],
    });
  });

  test("global flags are walked, not counted", () => {
    expect(inspectGit(["git", "-C", "/repo", "-c", "user.name=x", "push"])).toEqual({
      subcommand: "push",
      args: [],
      cDirs: ["/repo"],
    });
  });

  test("a wrapper prefix does not hide the invocation", () => {
    expect(inspectGit(["timeout", "60", "git", "push"])?.subcommand).toBe("push");
  });

  test("a non-git command is not one", () => {
    expect(inspectGit(["bun", "test"])).toBeNull();
  });

  test("git with only global flags has no subcommand", () => {
    expect(inspectGit(["git", "--version"])?.subcommand).toBeNull();
  });
});

describe("inspectPush — a protected branch named in prose is data", () => {
  test("an explicit refspec is a protected-ref push", () => {
    expect(inspectPush("git push origin master")).toEqual({ kind: "protected-ref" });
    expect(inspectPush("git push origin HEAD:main")).toEqual({ kind: "protected-ref" });
    expect(inspectPush("git push origin +HEAD:refs/heads/master")).toEqual({
      kind: "protected-ref",
    });
  });

  test("a bare push defers to the current branch", () => {
    expect(inspectPush("git push")).toEqual({ kind: "current-branch" });
    expect(inspectPush("git push origin")).toEqual({ kind: "current-branch" });
    expect(inspectPush("git push -u origin HEAD")).toEqual({ kind: "current-branch" });
  });

  test("a feature branch is neither", () => {
    expect(inspectPush("git push origin feat/thing")).toEqual({ kind: "none" });
    expect(inspectPush("git push --force-with-lease origin feat/thing")).toEqual({ kind: "none" });
  });

  test("hard force outranks everything, on any branch", () => {
    expect(inspectPush("git push --force origin feat/thing")).toEqual({ kind: "hard-force" });
    expect(inspectPush("git push -f origin feat/thing")).toEqual({ kind: "hard-force" });
  });

  test("--force-with-lease is not a hard force", () => {
    expect(inspectPush("git push --force-with-lease origin feat/x")).toEqual({ kind: "none" });
  });

  test("no push at all", () => {
    expect(inspectPush("git commit -m 'ship it'")).toEqual({ kind: "none" });
    expect(inspectPush("echo 'git push origin master'")).toEqual({ kind: "none" });
  });

  test("the branch name inside a commit message body is not a push target", () => {
    // The regression that blocked writing the hook's own docblock: the old
    // whole-string scan matched `master` anywhere, heredoc bodies included.
    const command = [
      "git commit -F - <<'EOF' && git push origin feat/x",
      "fix: stop the hook blocking every push to master in other repos",
      "EOF",
    ].join("\n");
    expect(inspectPush(command)).toEqual({ kind: "none" });
  });

  test("a value-taking flag does not become a refspec", () => {
    expect(inspectPush("git push -o ci.skip origin feat/x")).toEqual({ kind: "none" });
  });

  test("deleting a protected branch is still a protected-ref push", () => {
    expect(inspectPush("git push origin --delete master")).toEqual({ kind: "protected-ref" });
  });
});

describe("repoDirectories — the target repo, not the session's", () => {
  // A throwaway HOME: the tests must not depend on ~/SourceRoot existing.
  const realHome = process.env.HOME;
  const HOME = realpathSync(mkdtempSync(join(tmpdir(), "pb-home-")));
  const session = `${HOME}/SourceRoot/dotfiles`;

  beforeAll(() => {
    mkdirSync(session, { recursive: true });
    process.env.HOME = HOME;
  });
  afterAll(() => {
    process.env.HOME = realHome;
    rmSync(HOME, { recursive: true, force: true });
  });

  test("no target named: the session cwd", () => {
    expect(repoDirectories("git push origin master", session)).toEqual([session]);
  });

  test("a leading cd REPLACES the session cwd", () => {
    // The bug this file exists for: a session in a PR-required repo must not
    // decide the fate of a push that happens somewhere else.
    const dirs = repoDirectories(`cd ${HOME}/SourceRoot && git push origin master`, session);
    expect(dirs).toEqual([`${HOME}/SourceRoot`]);
    expect(dirs).not.toContain(session);
  });

  test("git -C names the target without moving the shell", () => {
    const dirs = repoDirectories(`git -C ${HOME}/SourceRoot push origin master`, session);
    expect(dirs).toEqual([`${HOME}/SourceRoot`]);
  });

  test("a relative -C resolves against the cd, which is where git runs", () => {
    // Both are real targets — the -C repo and the directory the shell stands
    // in — so both are reported, most specific first.
    const dirs = repoDirectories(`cd ${HOME} && git -C SourceRoot push origin master`, session);
    expect(dirs).toEqual([`${HOME}/SourceRoot`, HOME]);
  });

  test("a target that does not exist falls back to the session cwd, not to nothing", () => {
    expect(repoDirectories("git -C /no/such/dir push origin master", session)).toEqual([session]);
  });

  test("several targets are all reported", () => {
    const dirs = repoDirectories(
      `git -C ${HOME}/SourceRoot push origin master && git -C ${HOME} push origin master`,
      session
    );
    expect(dirs).toEqual([`${HOME}/SourceRoot`, HOME]);
  });
});

describe("inspectPush — bypasses that used to classify as allowed", () => {
  test("a dynamic refspec is judged as the current branch", () => {
    expect(inspectPush('git push origin "$(git branch --show-current)"')).toEqual({
      kind: "current-branch",
    });
    expect(inspectPush("git push origin $BRANCH")).toEqual({ kind: "current-branch" });
    expect(inspectPush("git push origin HEAD:$BRANCH")).toEqual({ kind: "current-branch" });
  });

  test("a leading + is a hard force, even on a feature branch", () => {
    expect(inspectPush("git push origin +main")).toEqual({ kind: "protected-ref" });
    expect(inspectPush("git push origin +feat/x")).toEqual({ kind: "hard-force" });
  });

  test("short-flag clusters are split", () => {
    expect(inspectPush("git push -fu origin feat/x")).toEqual({ kind: "hard-force" });
    expect(inspectPush("git push -uf origin feat/x")).toEqual({ kind: "hard-force" });
    expect(inspectPush("git push -u origin feat/x")).toEqual({ kind: "none" });
  });

  test("--all and --mirror are their own kind", () => {
    expect(inspectPush("git push --all")).toEqual({ kind: "all-refs" });
    expect(inspectPush("git push --mirror origin")).toEqual({ kind: "all-refs" });
  });

  test("shell -c and eval strings are parsed", () => {
    expect(inspectPush('bash -c "git push origin main"')).toEqual({ kind: "protected-ref" });
    expect(inspectPush("sh -c 'git push origin main'")).toEqual({ kind: "protected-ref" });
    expect(inspectPush('zsh -c "git push origin main"')).toEqual({ kind: "protected-ref" });
    expect(inspectPush('sudo bash -lc "git push -f origin x"')).toEqual({ kind: "hard-force" });
    expect(inspectPush('eval "git push origin main"')).toEqual({ kind: "protected-ref" });
  });

  test("an alias defined with -c is expanded", () => {
    expect(inspectPush("git -c alias.p=push p origin main")).toEqual({ kind: "protected-ref" });
    expect(inspectPush("git -c 'alias.p=!git push origin main' p")).toEqual({
      kind: "protected-ref",
    });
    expect(inspectPush("git -c alias.p=status p")).toEqual({ kind: "none" });
  });

  test("a backslash-newline between git and push is a continuation", () => {
    expect(inspectPush("git \\\npush origin main")).toEqual({ kind: "protected-ref" });
    expect(inspectPush("git \\\npush --force origin x")).toEqual({ kind: "hard-force" });
  });
});

/**
 * The decision path: the hook as the harness runs it — JSON on stdin, a deny
 * object on stdout — against throwaway repos and a throwaway HOME.
 */
describe("decision path — the hook as a subprocess", () => {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "pb-decision-")));
  const home = join(root, "home");
  const prRepo = join(home, "SourceRoot", "pr-app");
  const directRepo = join(home, "SourceRoot", "direct-app");
  const scratch = join(home, "scratch");

  const git = (cwd: string, ...args: string[]) => {
    const r = Bun.spawnSync(
      ["git", "-c", "user.name=t", "-c", "user.email=t@example.com", ...args],
      { cwd, stdout: "pipe", stderr: "pipe", env: cleanEnv(home) }
    );
    if (r.exitCode !== 0) throw new Error(`git ${args.join(" ")}: ${r.stderr.toString()}`);
  };

  const initRepo = (dir: string, name: string, branch: string) => {
    mkdirSync(dir, { recursive: true });
    git(dir, "init", "-q", "-b", "master");
    git(dir, "commit", "-q", "--allow-empty", "-m", "init");
    git(dir, "remote", "add", "origin", `git@example.com:u/${name}.git`);
    if (branch !== "master") git(dir, "checkout", "-q", "-b", branch);
  };

  beforeAll(() => {
    mkdirSync(join(home, ".claude"), { recursive: true });
    mkdirSync(scratch, { recursive: true });
    writeFileSync(
      join(home, ".claude", "pr-required-repos.json"),
      JSON.stringify({ repos: ["pr-app"], directToMain: [] })
    );
    initRepo(prRepo, "pr-app", "master");
    initRepo(directRepo, "direct-app", "master");
  });
  afterAll(() => rmSync(root, { recursive: true, force: true }));

  function run(command: string, cwd: string, homeDir = home) {
    const r = Bun.spawnSync(["bun", HOOK], {
      stdin: Buffer.from(JSON.stringify({ tool_name: "Bash", tool_input: { command }, cwd })),
      stdout: "pipe",
      stderr: "pipe",
      env: cleanEnv(homeDir),
    });
    const out = r.stdout.toString();
    const verdict = out ? JSON.parse(out).hookSpecificOutput : null;
    return { exitCode: r.exitCode, verdict, stderr: r.stderr.toString() };
  }
  const denied = (command: string, cwd = prRepo) => run(command, cwd).verdict?.permissionDecision === "deny";

  test("push to a PR-required repo's master is denied with the documented shape", () => {
    const { exitCode, verdict } = run("git push origin master", prRepo);
    expect(exitCode).toBe(0);
    expect(verdict.hookEventName).toBe("PreToolUse");
    expect(verdict.permissionDecision).toBe("deny");
    expect(verdict.permissionDecisionReason).toContain("requires a PR");
  });

  test("a bare push on master is denied; on a feature branch it is allowed", () => {
    expect(denied("git push")).toBe(true);
    git(prRepo, "checkout", "-q", "-b", "feat/x");
    try {
      expect(denied("git push")).toBe(false);
      expect(denied("git push -u origin feat/x")).toBe(false);
      expect(denied("git push --force-with-lease origin feat/x")).toBe(false);
      expect(denied("git push --all")).toBe(true);
      expect(denied("git push origin +feat/x")).toBe(true);
    } finally {
      git(prRepo, "checkout", "-q", "master");
    }
  });

  test("a direct-to-master repo may push master", () => {
    expect(denied("git push origin master", directRepo)).toBe(false);
  });

  test("a non-push and a non-Bash call are untouched", () => {
    expect(run("git status", prRepo).verdict).toBeNull();
    const r = Bun.spawnSync(["bun", HOOK], {
      stdin: Buffer.from(JSON.stringify({ tool_name: "Read", cwd: prRepo })),
      stdout: "pipe",
      env: cleanEnv(home),
    });
    expect(r.stdout.toString()).toBe("");
  });

  test.each([
    ['git push origin "$(git branch --show-current)"'],
    ["git push origin $BRANCH"],
    ["git push origin +main"],
    ["git push -fu origin x"],
    ["git push --all"],
    ["git push --mirror"],
    ['bash -c "git push origin main"'],
    ["sh -c 'git push origin master'"],
    ['zsh -c "git push origin master"'],
    ['eval "git push origin master"'],
    ["git -c alias.p=push p origin master"],
    ["git \\\npush origin master"],
  ])("bypass denied: %s", (command) => {
    expect(denied(command)).toBe(true);
  });

  test("--git-dir / GIT_DIR: the repo git will use is judged, not the cwd", () => {
    const prGit = join(prRepo, ".git");
    const directGit = join(directRepo, ".git");
    expect(denied(`git --git-dir=${prGit} push origin master`, scratch)).toBe(true);
    expect(denied(`git --git-dir ${prGit} push origin master`, scratch)).toBe(true);
    expect(denied(`GIT_DIR=${prGit} git push origin master`, scratch)).toBe(true);
    expect(denied(`export GIT_DIR=${prGit}; git push origin master`, scratch)).toBe(true);
    // Session sits in the PR-required repo but git acts on the direct one.
    expect(denied(`git --git-dir=${directGit} push origin master`, prRepo)).toBe(false);
    // Unresolvable: deny rather than guess.
    expect(denied("git --git-dir=/no/such/dir push origin master", scratch)).toBe(true);
    expect(denied("git --git-dir=$X push origin master", scratch)).toBe(true);
  });

  test("a malformed config falls back loudly without changing the outcome", () => {
    const badHome = join(root, "bad-home");
    mkdirSync(join(badHome, ".claude"), { recursive: true });
    writeFileSync(join(badHome, ".claude", "pr-required-repos.json"), "{ not json");
    const fallbackRepo = join(badHome, "basalt-ui");
    initRepo(fallbackRepo, "basalt-ui", "master");

    const { verdict, stderr } = run("git push origin master", fallbackRepo, badHome);
    expect(verdict.permissionDecision).toBe("deny");
    expect(stderr).toContain("pr-required-repos.json is unreadable");
    expect(stderr).toContain("built-in fallback");
  });

  test("a well-formed config is silent", () => {
    expect(run("git push origin master", prRepo).stderr).toBe("");
  });
});

describe("the committed config/pr-required-repos.json", () => {
  test("has the shape loadRepoConfig accepts", async () => {
    const data = JSON.parse(await Bun.file(REAL_CONFIG).text());
    expect(Array.isArray(data.repos)).toBe(true);
    expect(data.repos.every((r: unknown) => typeof r === "string")).toBe(true);
    expect(data.repos.length).toBeGreaterThan(0);
    expect(Array.isArray(data.directToMain)).toBe(true);
    expect(data.directToMain.every((r: unknown) => typeof r === "string")).toBe(true);
  });

  test("loadRepoConfig reads it verbatim, with no fallback warning", async () => {
    const home = realpathSync(mkdtempSync(join(tmpdir(), "pb-cfg-")));
    const realHome = process.env.HOME;
    const realWrite = process.stderr.write;
    const warned: string[] = [];
    try {
      mkdirSync(join(home, ".claude"));
      writeFileSync(join(home, ".claude", "pr-required-repos.json"), await Bun.file(REAL_CONFIG).text());
      process.env.HOME = home;
      process.stderr.write = ((chunk: string) => (warned.push(String(chunk)), true)) as typeof process.stderr.write;
      const config = await loadRepoConfig();
      const data = JSON.parse(await Bun.file(REAL_CONFIG).text());
      expect(config).toEqual({ prRequired: data.repos, directToMain: data.directToMain });
      expect(warned).toEqual([]);
    } finally {
      process.stderr.write = realWrite;
      process.env.HOME = realHome;
      rmSync(home, { recursive: true, force: true });
    }
  });
});

/** Process env without any inherited GIT_* state, HOME pointed at a temp dir. */
function cleanEnv(home: string): Record<string, string> {
  const env: Record<string, string> = {};
  for (const [k, v] of Object.entries(process.env)) {
    if (v !== undefined && !k.startsWith("GIT_")) env[k] = v;
  }
  return { ...env, HOME: home, GIT_CONFIG_GLOBAL: "/dev/null", GIT_CONFIG_NOSYSTEM: "1" };
}
