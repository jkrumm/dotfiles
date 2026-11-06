#!/usr/bin/env bun

/**
 * Tests for the test-slot PreToolUse hook. A false rewrite wraps a harmless command in a
 * slot wait; a missed one leaves a test run unbounded; a rewrite inside a slot deadlocks.
 */

import { describe, expect, test } from "bun:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { rewrite, testRunner } from "./test-slot";

const HOOK = `${import.meta.dir}/test-slot.ts`;

const base = { cwd: "/tmp", env: {} as Record<string, string | undefined>, cores: 12, hasFactory: true };
const run = (command: string, over: Partial<typeof base> = {}) => rewrite(command, { ...base, ...over });
const wrapped = (command: string) => expect(run(command)).not.toBeNull();
const left = (command: string, over: Partial<typeof base> = {}) => expect(run(command, over)).toBeNull();

describe("runners that are wrapped", () => {
  test.each([
    "vitest run",
    "npx vitest",
    "bunx vitest run --coverage",
    "pytest -x tests/",
    "uv run pytest",
    "poetry run pytest",
    "python3 -m pytest",
    "bun test",
    "bun run test:unit",
    "npm test",
    "npm run test",
    "pnpm test",
    "pnpm exec vitest",
    "yarn check",
    "make check",
    "make -j4 test",
    "gmake test-unit",
    "go test ./...",
    "cargo test",
    "playwright test",
    "xcodebuild -scheme A test",
    "CI=1 time make check",
    "echo start && bun test && echo done",
  ])("%s", (cmd) => wrapped(cmd));
});

describe("commands left alone", () => {
  test.each([
    "bun install",
    "bun run build",
    "bun run dev",
    "npm install",
    "make deploy",
    "make verify",
    "make checkout-x",
    "git commit -m 'run bun test and make check'",
    "grep -rn 'vitest' src",
    "echo 'pytest'",
    "cat <<'EOF'\nmake check\nEOF",
    "python3 script.py",
    "go build ./...",
    "xcodebuild -scheme A build",
    "ls",
  ])("%s", (cmd) => left(cmd));

  test("agw check takes its own slot", () => left("agw check"));
  test("an explicit factory slot run is not wrapped twice", () => left("factory slot run -- bun test"));
  test("already inside a slot (FACTORY_SLOT_ACTIVE)", () => left("bun test", { env: { FACTORY_SLOT_ACTIVE: "1" } }));
  test("no factory on PATH fails open", () => left("bun test", { hasFactory: false }));

  test("a project that already runs its tests through the slot", () => {
    const dir = mkdtempSync(`${tmpdir()}/slot-`);
    writeFileSync(`${dir}/Makefile`, "test:\n\tfactory slot run -- bun test\n");
    left("make test", { cwd: dir });
    writeFileSync(`${dir}/Makefile`, "test:\n\tbun test\n");
    expect(run("make test", { cwd: dir })).not.toBeNull();
  });
});

describe("the rewrite", () => {
  test("wraps the whole command in the slot with caps", () => {
    const out = run("bun test", { cwd: "/Users/x/IuRoot/repo/.claude/worktrees/a-1" })!;
    expect(out.command).toStartWith("factory slot run --name 'repo bun test' -- env FACTORY_SLOT_ACTIVE=1 ");
    expect(out.command).toContain("VITEST_MAX_WORKERS=${VITEST_MAX_WORKERS:-6}");
    expect(out.command).toContain("PYTEST_XDIST_AUTO_NUM_WORKERS=${PYTEST_XDIST_AUTO_NUM_WORKERS:-6}");
    expect(out.command).toEndWith(`-c 'bun test'`);
  });

  test("the repo name comes from the worktree's main checkout", () => {
    const out = run("make check", { cwd: "/Users/x/SourceRoot/dotfiles/.claude/worktrees/factory-1-1" })!;
    expect(out.command).toContain("--name 'dotfiles make check'");
  });

  test("single quotes in the command survive", () => {
    const out = run(`bun test -t 'a b'`)!;
    expect(out.command).toEndWith(`-c 'bun test -t '\\''a b'\\'''`);
  });

  test("a leading cd stays outside so the session cwd follows it", () => {
    const out = run("cd /tmp && make check")!;
    expect(out.command).toStartWith("cd /tmp && factory slot run");
    expect(out.command).toEndWith(`-c 'make check'`);
  });

  test("a cd with shell expansion is wrapped whole, not hoisted", () => {
    const out = run('cd "$X" && make check')!;
    expect(out.command).toStartWith("factory slot run");
  });

  test("worker caps are at least one", () => {
    expect(run("bun test", { cores: 1 })!.command).toContain(":-1}");
  });
});

describe("testRunner", () => {
  test("names the runner", () => {
    expect(testRunner(["npx", "vitest", "run"])).toBe("vitest");
    expect(testRunner(["make", "check"])).toBe("make check");
    expect(testRunner(["ls"])).toBeNull();
  });
});

describe("hook process", () => {
  const spawn = (payload: unknown, env: Record<string, string> = {}) => {
    const r = Bun.spawnSync(["bun", HOOK], {
      stdin: new TextEncoder().encode(typeof payload === "string" ? payload : JSON.stringify(payload)),
      stdout: "pipe",
      stderr: "pipe",
      env: { ...process.env, ...env },
    });
    return { code: r.exitCode, out: r.stdout.toString() };
  };

  test("garbage input fails open, silently", () => {
    expect(spawn("not json")).toEqual({ code: 0, out: "" });
  });

  test("non-Bash tools are ignored", () => {
    expect(spawn({ tool_name: "Read", tool_input: { file_path: "/x" } })).toEqual({ code: 0, out: "" });
  });

  test("a test run returns updatedInput with the other fields intact", () => {
    // a fake factory on PATH, so the test does not depend on the machine
    const bin = mkdtempSync(`${tmpdir()}/bin-`);
    writeFileSync(`${bin}/factory`, "#!/bin/sh\n", { mode: 0o755 });
    const { code, out } = spawn(
      { tool_name: "Bash", cwd: "/tmp", tool_input: { command: "pytest", timeout: 5000 } },
      { PATH: `${bin}:${process.env.PATH}`, FACTORY_SLOT_ACTIVE: "" },
    );
    expect(code).toBe(0);
    const o = JSON.parse(out).hookSpecificOutput;
    expect(o.permissionDecision).toBe("allow");
    expect(o.updatedInput.timeout).toBe(5000);
    expect(o.updatedInput.command).toContain("factory slot run");
  });
});
