#!/usr/bin/env bun

import { describe, expect, test } from "bun:test";
import { decide } from "./permission-allow";

const HOOK = `${import.meta.dir}/permission-allow.ts`;
const bash = (command: string) => decide({ tool_name: "Bash", tool_input: { command } }).behavior;

describe("deny: rm on / or home", () => {
  for (const cmd of [
    "rm -rf /",
    "rm -rf /*",
    "rm -rf ~",
    "rm -rf ~/",
    "rm -rf ~/*",
    "rm -fr $HOME",
    'rm -rf "$HOME"',
    "rm -rf ${HOME}/",
    "sudo rm -rf /",
    "cd /tmp && rm -rf ~",
    "echo hi; rm -rf /",
    "/bin/rm -rf /",
    'bash -c "rm -rf ~"',
    "sh -c 'rm -rf /'",
    'rm -rf "$HOME"/*',
    "rm -rf /.",
    "\\rm -rf /",
    "echo rm -rf /", // conservative: a mention is denied too
  ]) {
    test(cmd, () => expect(bash(cmd)).toBe("deny"));
  }
});

describe("allow", () => {
  for (const cmd of [
    "rm -rf /tmp/build",
    "rm -rf ~/SourceRoot/x/node_modules",
    "rm -rf ./dist",
    "rm file.txt",
    "git status",
  ]) {
    test(cmd, () => expect(bash(cmd)).toBe("allow"));
  }

  test("non-Bash tools", () => {
    expect(decide({ tool_name: "Write", tool_input: {} }).behavior).toBe("allow");
    expect(decide({ tool_name: "mcp__x__y" }).behavior).toBe("allow");
  });
});

test("stdout is the PermissionRequest decision shape", async () => {
  const proc = Bun.spawn(["bun", HOOK], { stdin: "pipe", stdout: "pipe" });
  proc.stdin.write(JSON.stringify({ tool_name: "Edit", tool_input: { file_path: "/x/.claude/y" } }));
  proc.stdin.end();
  const out = JSON.parse(await new Response(proc.stdout).text());
  expect(out).toEqual({
    hookSpecificOutput: { hookEventName: "PermissionRequest", decision: { behavior: "allow" } },
  });
});
