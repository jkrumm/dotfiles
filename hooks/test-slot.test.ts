#!/usr/bin/env bun

/**
 * Tests for the test-slot PreToolUse hook. A false rewrite wraps a harmless command in a
 * slot wait; a missed one leaves a test run unbounded; a rewrite inside a slot deadlocks.
 */

import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { rewrite, splitChain, testRunner } from "./test-slot";

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
    "make -j 4 test",
    "make -C packages/app check",
    "npx -y vitest",
    "uv run --with x pytest",
    "uv run --python 3.12 pytest -x",
    "gmake test-unit",
    "make ui-check",
    "make -C ui api_test",
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
    "make ui-build",
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
    writeFileSync(`${dir}/Makefile`, "check:\n\tagw check\n");
    left("make check", { cwd: dir });
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

  test("a cd with shell expansion stays outside too", () => {
    const out = run('cd "$X" && make check')!;
    expect(out.command).toStartWith('cd "$X" && factory slot run');
  });

  test("worker caps are at least one", () => {
    expect(run("bun test", { cores: 1 })!.command).toContain(":-1}");
  });
});

describe("a chain wraps only its test segment", () => {
  const parts = (command: string, over: Partial<typeof base> = {}) => run(command, over)!.command;

  test("vite build && bun test x", () => {
    const out = parts("vite build && bun test x");
    expect(out).toStartWith("vite build && factory slot run --name 'tmp bun test' -- ");
    expect(out).toEndWith(`-c 'bun test x'`);
    expect(out.match(/factory slot run/g)).toHaveLength(1);
  });

  test("build, shots, then the test, with ; and newlines", () => {
    const out = parts("vite build; bun shots.ts\nbun test apps/x.test.ts");
    expect(out).toStartWith("vite build; bun shots.ts\nfactory slot run");
    expect(out).toEndWith(`-c 'bun test apps/x.test.ts'`);
  });

  test("the part after the test runs outside it", () => {
    expect(parts("echo start && bun test && echo done")).toEndWith(`-c 'bun test' && echo done`);
  });

  test("two test segments take one slot each, one after the other", () => {
    const out = parts("bun test a && pytest b");
    expect(out.match(/factory slot run/g)).toHaveLength(2);
    expect(out).toContain(`-c 'bun test a' && factory slot run --name 'tmp pytest'`);
  });

  test("a pipe stays inside its segment", () => {
    const out = parts("make build && bun test x 2>&1 | tee out.log");
    expect(out).toStartWith("make build && factory slot run");
    expect(out).toEndWith(`-c 'bun test x 2>&1 | tee out.log'`);
  });

  test("separators inside quotes and substitutions do not cut", () => {
    const out = parts(`echo "a && b; c" && echo $(a; b) && bun test`);
    expect(out).toStartWith(`echo "a && b; c" && echo $(a; b) && factory slot run`);
  });

  test("the cwd a cd segment sets decides the slot name and the project check", () => {
    const dir = mkdtempSync(`${tmpdir()}/slot-`);
    writeFileSync(`${dir}/Makefile`, "check:\n\tagw check\n");
    expect(run(`cd ${dir} && vite build && make check`)).toBeNull();
    expect(parts("cd /opt/thing && vite build && bun test")).toContain("--name 'thing bun test'");
  });

  test("relative cd segments chain from the directory the last one set", () => {
    const root = mkdtempSync(`${tmpdir()}/slot-`);
    mkdirSync(`${root}/apps/web`, { recursive: true });
    writeFileSync(`${root}/apps/web/Makefile`, "check:\n\tagw check\n");
    expect(run("cd apps && cd web && make check", { cwd: root })).toBeNull();
    expect(parts("cd apps && cd web && cd .. && bun test", { cwd: root })).toContain("--name 'apps bun test'");
  });

  test.each([
    "vite build || echo fail && bun test",
    "a && b || bun test",
    "(cd x && vite build) && bun test",
    "vite build & bun test",
    "for f in a b; do bun test $f; done",
    "if true; then bun test; fi",
    "cat <<EOF\nx\nEOF\nbun test",
    "vite build # && later\nbun test",
    "echo 'open && bun test",
    "PORT=4000; bun test --port $PORT",
    'ARGS="--bail --silent"; bun test $ARGS',
    "ARGS=$(cmd x); bun test $ARGS",
    "set -o pipefail; pytest | tee log",
  ])("a chain that cannot be cut takes one slot whole: %s", (cmd) => {
    expect(splitChain(cmd)).toBeNull();
    const out = run(cmd);
    if (out) expect(out.command.match(/factory slot run/g)).toHaveLength(1);
  });

  test("redirections with & are not backgrounding", () => {
    expect(splitChain("a 2>&1 && b &> out")).toHaveLength(2);
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
    expect(o.permissionDecision).toBeUndefined();
    expect(o.updatedInput.timeout).toBe(5000);
    expect(o.updatedInput.command).toContain("factory slot run");
  });
});
