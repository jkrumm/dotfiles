#!/usr/bin/env bun

/** Tests for the launchd-env-guard PreToolUse hook (incident 2026-11-17, issue 2152). */

import { describe, expect, test } from "bun:test";
import { findViolation } from "./launchd-env-guard";

const HOOK = `${import.meta.dir}/launchd-env-guard.ts`;

const denied = (cmd: string) => expect(findViolation(cmd)).not.toBeNull();
const allowed = (cmd: string) => expect(findViolation(cmd)).toBeNull();

describe("deny", () => {
  test("the incident command", () => {
    denied("launchctl setenv HTTPS_PROXY http://127.0.0.1:9");
  });

  test("through wrappers and chains", () => {
    denied("sudo launchctl setenv FOO bar");
    denied("env X=1 launchctl setenv FOO bar");
    denied("make check && launchctl setenv FOO bar; make test");
    denied("bash -c 'launchctl setenv FOO bar'");
    denied("ssh mini 'launchctl setenv FOO bar'");
    denied("/bin/launchctl setenv FOO bar");
  });
});

describe("allow", () => {
  test("the read and undo verbs", () => {
    allowed("launchctl unsetenv HTTPS_PROXY");
    allowed("launchctl getenv HTTPS_PROXY");
    allowed("launchctl print gui/501");
  });

  test("the variable handed to the test's own child", () => {
    allowed("HTTPS_PROXY=http://127.0.0.1:9 bun test scripts/foo.test.ts");
    allowed("env HTTPS_PROXY=http://127.0.0.1:9 ./run.sh");
  });

  test("the words inside quotes are data", () => {
    allowed("git commit -m 'deny launchctl setenv'");
    allowed("rg 'launchctl setenv' hooks");
    allowed("echo launchctl setenv");
  });
});

describe("hook process", () => {
  const run = async (command: string) => {
    const proc = Bun.spawn(["bun", HOOK], { stdin: new Blob([JSON.stringify({ tool_name: "Bash", tool_input: { command } })]), stdout: "pipe" });
    return (await new Response(proc.stdout).text()).trim();
  };

  test("emits a deny decision", async () => {
    const out = JSON.parse(await run("launchctl setenv FOO bar"));
    expect(out.hookSpecificOutput.permissionDecision).toBe("deny");
  });

  test("stays silent on an allowed command", async () => {
    expect(await run("launchctl print gui/501")).toBe("");
  });
});
