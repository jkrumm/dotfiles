#!/usr/bin/env bun

/** Tests for the nested-agents PreToolUse hook: a missed delivery leaves a nested AGENTS.md out of an edit, a repeated one burns context. */

import { afterAll, beforeEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { CONTENT_BUDGET, nestedContext, nestedAgentsFiles, resetSession } from "./nested-agents";

const HOOK = `${import.meta.dir}/nested-agents.ts`;
const base = realpathSync(mkdtempSync(join(tmpdir(), "nested-agents-")));
afterAll(() => rmSync(base, { recursive: true, force: true }));

let n = 0;
let repo = "";
let state = "";

beforeEach(() => {
  n += 1;
  repo = join(base, `repo${n}`);
  state = join(base, `state${n}`);
  mkdirSync(join(repo, ".git"), { recursive: true });
});

const put = (rel: string, text: string) => {
  const path = join(repo, rel);
  mkdirSync(join(path, ".."), { recursive: true });
  writeFileSync(path, text);
  return path;
};
const edit = (rel: string, over: Record<string, unknown> = {}) => ({
  hook_event_name: "PreToolUse",
  session_id: "s1",
  cwd: repo,
  tool_name: "Edit",
  tool_input: { file_path: join(repo, rel) },
  ...over,
});
const call = (rel: string, over: Record<string, unknown> = {}) => nestedContext(edit(rel, over), state);

describe("delivery", () => {
  test("an Edit under a directory with an AGENTS.md returns its text once, nothing on the second call", () => {
    put("AGENTS.md", "ROOT-MARKER");
    put("server/AGENTS.md", "SERVER-MARKER rules");
    put("server/a.ts", "x");
    const first = call("server/a.ts");
    expect(first).toContain("SERVER-MARKER rules");
    expect(first).toContain(join(repo, "server", "AGENTS.md"));
    expect(first).not.toContain("ROOT-MARKER");
    expect(call("server/a.ts")).toBeNull();
    expect(call("server/b.ts")).toBeNull();
  });

  test("a directory without a nested file, or an untouched sibling, delivers nothing", () => {
    put("server/AGENTS.md", "SERVER-MARKER");
    put("web/a.ts", "x");
    expect(call("web/a.ts")).toBeNull();
  });

  test("a changed file is returned again, by size or mtime", () => {
    const path = put("server/AGENTS.md", "version one");
    expect(call("server/a.ts")).toContain("version one");
    expect(call("server/a.ts")).toBeNull();
    writeFileSync(path, "version two");
    expect(call("server/a.ts")).toContain("version two");
    expect(call("server/a.ts")).toBeNull();
    const later = new Date(Date.now() + 60_000);
    utimesSync(path, later, later);
    expect(call("server/a.ts")).toContain("version two");
  });

  test("a file in the repository root returns nothing, root AGENTS.md or not", () => {
    put("AGENTS.md", "ROOT-MARKER");
    expect(call("a.ts")).toBeNull();
    expect(call("AGENTS.md")).toBeNull();
  });

  test("a chain of two nested files returns both, nearest last, and a deeper edit adds only what is new", () => {
    put("server/AGENTS.md", "OUTER-MARKER");
    put("server/db/AGENTS.md", "INNER-MARKER");
    const first = call("server/db/q.ts") as string;
    expect(first.indexOf("OUTER-MARKER")).toBeGreaterThan(-1);
    expect(first.indexOf("INNER-MARKER")).toBeGreaterThan(first.indexOf("OUTER-MARKER"));
    put("server/AGENTS.md", "OUTER-MARKER changed");
    const again = call("server/db/q.ts") as string;
    expect(again).toContain("OUTER-MARKER changed");
    expect(again).not.toContain("INNER-MARKER");
  });

  test("a Write to a new file in a new directory and a NotebookEdit path are covered; a relative path resolves against cwd", () => {
    put("server/AGENTS.md", "SERVER-MARKER");
    expect(call("server/new/deep/file.ts")).toContain("SERVER-MARKER");
    put("nb/AGENTS.md", "NB-MARKER");
    const notebook = { tool_name: "NotebookEdit", tool_input: { notebook_path: join(repo, "nb", "x.ipynb") } };
    expect(call("nb/x.ipynb", notebook)).toContain("NB-MARKER");
    put("rel/AGENTS.md", "REL-MARKER");
    expect(nestedContext({ ...edit("x"), tool_input: { file_path: "rel/a.ts" } }, state)).toContain("REL-MARKER");
  });

  test("a subagent has its own state: the parent's delivery does not silence it", () => {
    put("server/AGENTS.md", "SERVER-MARKER");
    expect(call("server/a.ts")).toContain("SERVER-MARKER");
    expect(call("server/a.ts", { agent_id: "sub1" })).toContain("SERVER-MARKER");
    expect(call("server/a.ts", { agent_id: "sub1" })).toBeNull();
    expect(call("server/a.ts", { session_id: "s2" })).toContain("SERVER-MARKER");
  });

  test("compact resets the session's state, the subagents' too, and no other session's", () => {
    put("server/AGENTS.md", "SERVER-MARKER");
    call("server/a.ts");
    call("server/a.ts", { agent_id: "sub1" });
    call("server/a.ts", { session_id: "s2" });
    resetSession({ hook_event_name: "SessionStart", session_id: "s1" }, state);
    expect(call("server/a.ts")).toContain("SERVER-MARKER");
    expect(call("server/a.ts", { agent_id: "sub1" })).toContain("SERVER-MARKER");
    expect(call("server/a.ts", { session_id: "s2" })).toBeNull();
  });
});

describe("bounds", () => {
  test("a chain over the budget is cut: the nearest file is delivered, the rest is named with 'Read it'", () => {
    const outer = put("a/AGENTS.md", "OUTER-MARKER " + "o".repeat(7_900));
    const middle = put("a/b/AGENTS.md", "MIDDLE-MARKER " + "m".repeat(7_900));
    put("a/b/c/AGENTS.md", "INNER-MARKER " + "i".repeat(7_900));
    const out = call("a/b/c/x.ts") as string;
    expect(out).toContain("INNER-MARKER");
    expect(out).not.toContain("OUTER-MARKER");
    expect(out).toContain(`${outer}`);
    expect(out).toContain(middle);
    expect(out).toContain("Read it");
    expect(Buffer.byteLength(out)).toBeLessThanOrEqual(10_000);
    // the named files are tried again on the next call
    const next = call("a/b/c/x.ts") as string;
    expect(next).toContain("MIDDLE-MARKER");
    expect(next).not.toContain("INNER-MARKER");
  });

  test("one file over the per-file budget is cut and says where to read the rest", () => {
    const path = put("server/AGENTS.md", "BIG-MARKER " + "é".repeat(9_000));
    const out = call("server/a.ts") as string;
    expect(out).toContain("BIG-MARKER");
    expect(out).toContain(`Read ${path} for the rest`);
    expect(out).not.toContain("�");
    expect(Buffer.byteLength(out)).toBeLessThanOrEqual(CONTENT_BUDGET + 1_000);
    expect(call("server/a.ts")).toBeNull();
  });
});

describe("fails open", () => {
  test("no git repository returns nothing", () => {
    const loose = join(base, "loose-no-git");
    mkdirSync(join(loose, "server"), { recursive: true });
    writeFileSync(join(loose, "server", "AGENTS.md"), "X-MARKER");
    expect(nestedAgentsFiles(join(loose, "server", "a.ts"))).toBeNull();
    expect(nestedContext({ ...edit("x"), cwd: loose, tool_input: { file_path: join(loose, "server", "a.ts") } }, state)).toBeNull();
  });

  test("a worktree, whose .git is a file, is a root too", () => {
    const wt = join(base, `wt${n}`);
    mkdirSync(join(wt, "server"), { recursive: true });
    writeFileSync(join(wt, ".git"), "gitdir: /elsewhere");
    writeFileSync(join(wt, "AGENTS.md"), "ROOT");
    writeFileSync(join(wt, "server", "AGENTS.md"), "WT-MARKER");
    expect(nestedAgentsFiles(join(wt, "server", "a.ts"))).toEqual([join(wt, "server", "AGENTS.md")]);
  });

  test("a call without a path, with a non-string path or a path under a missing tree returns nothing", () => {
    expect(nestedContext({ tool_name: "Edit", tool_input: {} }, state)).toBeNull();
    expect(nestedContext({ tool_name: "Edit", tool_input: { file_path: 42 } }, state)).toBeNull();
    expect(nestedContext({ tool_name: "Edit" }, state)).toBeNull();
    expect(call("nope/deeper/a.ts")).toBeNull();
  });
});

describe("the hook process", () => {
  const run = async (stdin: string) => {
    const proc = Bun.spawn(["bun", HOOK], {
      stdin: new Blob([stdin]),
      stdout: "pipe",
      stderr: "pipe",
      env: { ...process.env, NESTED_AGENTS_STATE_DIR: state },
    });
    const [stdout, code] = await Promise.all([new Response(proc.stdout).text(), proc.exited]);
    return { stdout, code };
  };

  test("an Edit prints the PreToolUse additionalContext JSON, exit 0; the second run prints nothing", async () => {
    put("server/AGENTS.md", "PROC-MARKER");
    const first = await run(JSON.stringify(edit("server/a.ts")));
    expect(first.code).toBe(0);
    const parsed = JSON.parse(first.stdout);
    expect(parsed.hookSpecificOutput.hookEventName).toBe("PreToolUse");
    expect(parsed.hookSpecificOutput.additionalContext).toContain("PROC-MARKER");
    expect(parsed.hookSpecificOutput.permissionDecision).toBeUndefined();
    expect(await run(JSON.stringify(edit("server/a.ts")))).toEqual({ stdout: "", code: 0 });
  });

  test("malformed input exits 0 with no output", async () => {
    for (const stdin of ["", "not json", "{", "null", "[]", '{"tool_input":"x"}'])
      expect(await run(stdin)).toEqual({ stdout: "", code: 0 });
  });

  test("a warm run answers well inside the budget", async () => {
    put("server/AGENTS.md", "PROC-MARKER");
    await run(JSON.stringify(edit("server/a.ts")));
    const start = performance.now();
    await run(JSON.stringify(edit("server/a.ts")));
    expect(performance.now() - start).toBeLessThan(250);
  });
});
