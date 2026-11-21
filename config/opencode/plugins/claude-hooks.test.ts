import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ClaudeHooks } from "./claude-hooks.js";

const dirs: string[] = [];
afterEach(() => {
  for (const d of dirs.splice(0)) rmSync(d, { recursive: true, force: true });
});

function project(settings?: unknown): string {
  const dir = mkdtempSync(join(tmpdir(), "claude-hooks-"));
  dirs.push(dir);
  if (settings !== undefined) {
    mkdirSync(join(dir, ".claude"));
    writeFileSync(join(dir, ".claude", "settings.json"), JSON.stringify(settings));
  }
  return dir;
}

const hook = (command: string, matcher = "Edit|Write|MultiEdit") => ({
  matcher,
  hooks: [{ type: "command", command }],
});

async function post(dir: string, tool: string, args: unknown) {
  const hooks = await ClaudeHooks({ directory: dir } as never);
  const output = { title: "", output: "Edit applied successfully.", metadata: {} };
  await hooks["tool.execute.after"]({ tool, sessionID: "s1", callID: "c1", args }, output);
  return output.output;
}

async function pre(dir: string, tool: string, args: unknown) {
  const hooks = await ClaudeHooks({ directory: dir } as never);
  await hooks["tool.execute.before"]({ tool, sessionID: "s1", callID: "c1" }, { args });
}

describe("PostToolUse", () => {
  test("exit 2 appends the hook's stderr to the tool result", async () => {
    const dir = project({
      hooks: { PostToolUse: [hook("echo 'basalt/colour-literal at line 3' >&2; exit 2")] },
    });
    const out = await post(dir, "write", { filePath: join(dir, "a.ts"), content: "#ff0000" });
    expect(out).toContain("Edit applied successfully.");
    expect(out).toContain("basalt/colour-literal at line 3");
  });

  test("the hook gets the Claude Code event on stdin and CLAUDE_PROJECT_DIR", async () => {
    const dir = project({
      hooks: { PostToolUse: [hook('cat > "$CLAUDE_PROJECT_DIR/event.json"')] },
    });
    const file = join(dir, "src", "a.ts");
    await post(dir, "edit", { filePath: file, oldString: "a", newString: "b" });
    const event = JSON.parse(readFileSync(join(dir, "event.json"), "utf8"));
    expect(event).toMatchObject({
      hook_event_name: "PostToolUse",
      tool_name: "Edit",
      cwd: dir,
      session_id: "s1",
      tool_input: { file_path: file, old_string: "a", new_string: "b" },
    });
  });

  test("exit 0 and other non-2 exits add nothing", async () => {
    for (const code of [0, 1, 127]) {
      const dir = project({ hooks: { PostToolUse: [hook(`echo noise >&2; exit ${code}`)] } });
      expect(await post(dir, "write", { filePath: join(dir, "a.ts"), content: "x" })).toBe(
        "Edit applied successfully.",
      );
    }
  });

  test("a matcher that does not cover Edit or Write does not run", async () => {
    const dir = project({ hooks: { PostToolUse: [hook("echo no >&2; exit 2", "Bash")] } });
    expect(await post(dir, "edit", { filePath: join(dir, "a.ts") })).toBe("Edit applied successfully.");
  });

  test("non-writing tools never run hooks", async () => {
    const dir = project({ hooks: { PostToolUse: [hook("echo no >&2; exit 2", "*")] } });
    expect(await post(dir, "read", { filePath: join(dir, "a.ts") })).toBe("Edit applied successfully.");
  });

  test("apply_patch runs per file, skipping deletes", async () => {
    const dir = project({
      hooks: { PostToolUse: [hook('jq -r .tool_input.file_path >> "$CLAUDE_PROJECT_DIR/seen"')] },
    });
    const patchText = [
      "*** Begin Patch",
      "*** Update File: src/a.ts",
      "@@",
      "-a",
      "+b",
      "*** Add File: src/b.ts",
      "+x",
      "*** Delete File: src/gone.ts",
      "*** End Patch",
    ].join("\n");
    await post(dir, "apply_patch", { patchText });
    expect(readFileSync(join(dir, "seen"), "utf8").trim().split("\n")).toEqual([
      join(dir, "src/a.ts"),
      join(dir, "src/b.ts"),
    ]);
  });

  test("JSON decision:block feeds the reason back", async () => {
    const dir = project({
      hooks: { PostToolUse: [hook(`echo '{"decision":"block","reason":"fix the lint"}'`)] },
    });
    expect(await post(dir, "write", { filePath: join(dir, "a.ts"), content: "x" })).toContain("fix the lint");
  });
});

describe("PreToolUse", () => {
  test("exit 2 denies with the stderr as the error", async () => {
    const dir = project({
      hooks: { PreToolUse: [hook("echo 'managed file, do not edit' >&2; exit 2")] },
    });
    await expect(pre(dir, "edit", { filePath: join(dir, "a.ts") })).rejects.toThrow(
      "managed file, do not edit",
    );
  });

  test("exit 0 allows", async () => {
    const dir = project({ hooks: { PreToolUse: [hook("exit 0")] } });
    await pre(dir, "write", { filePath: join(dir, "a.ts"), content: "x" });
  });

  test("permissionDecision deny in JSON denies", async () => {
    const out = '{"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":"nope"}}';
    const dir = project({ hooks: { PreToolUse: [hook(`echo '${out}'`)] } });
    await expect(pre(dir, "write", { filePath: join(dir, "a.ts"), content: "x" })).rejects.toThrow("nope");
  });
});

describe("a project without hooks", () => {
  test("no settings.json: nothing happens", async () => {
    const dir = project();
    expect(await post(dir, "write", { filePath: join(dir, "a.ts"), content: "x" })).toBe(
      "Edit applied successfully.",
    );
    await pre(dir, "write", { filePath: join(dir, "a.ts"), content: "x" });
  });

  test("settings.json without hooks, or unparsable: nothing happens", async () => {
    const noHooks = project({ permissions: {} });
    expect(await post(noHooks, "edit", { filePath: join(noHooks, "a.ts") })).toBe("Edit applied successfully.");
    const bad = project();
    mkdirSync(join(bad, ".claude"));
    writeFileSync(join(bad, ".claude", "settings.json"), "{ not json");
    expect(await post(bad, "edit", { filePath: join(bad, "a.ts") })).toBe("Edit applied successfully.");
  });
});
