#!/usr/bin/env bun

/**
 * Tests for the model-discipline PreToolUse hook.
 *
 * The two failure directions are not symmetric. A false allow lets a Fable
 * worker or a Fable/Opus fork through — the exact leak Round 2 of the estate
 * audit probed and found. A false block wedges every legitimate `Agent` call
 * (Sonnet workers, justified `model: opus`) in the estate. Both are covered.
 */

import { describe, expect, test } from "bun:test";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { callerModel, isFable, isFableOrOpus } from "./model-discipline";

describe("isFable — the worker-model check", () => {
  test("bare alias", () => {
    expect(isFable("fable")).toBe(true);
  });

  test("full id, case-insensitive", () => {
    expect(isFable("claude-Fable-5-1")).toBe(true);
  });

  test("sonnet is not fable", () => {
    expect(isFable("claude-sonnet-5")).toBe(false);
  });

  test("undefined (no model override) is not fable", () => {
    expect(isFable(undefined)).toBe(false);
  });
});

describe("isFableOrOpus — the fork-origin check", () => {
  test("fable and opus both match", () => {
    expect(isFableOrOpus("fable")).toBe(true);
    expect(isFableOrOpus("claude-opus-5[1m]")).toBe(true);
  });

  test("sonnet does not match", () => {
    expect(isFableOrOpus("claude-sonnet-5")).toBe(false);
  });
});

describe("callerModel — reads the last assistant turn from the transcript", () => {
  let dir: string;

  test("last assistant model wins over an earlier one", async () => {
    dir = await mkdtemp(join(tmpdir(), "model-discipline-"));
    const path = join(dir, "session.jsonl");
    const lines = [
      JSON.stringify({ type: "assistant", message: { model: "claude-opus-5" } }),
      JSON.stringify({ type: "user", message: { content: "go on" } }),
      JSON.stringify({ type: "assistant", message: { model: "claude-fable-5-1" } }),
    ];
    await writeFile(path, lines.join("\n"));
    expect(await callerModel(path)).toBe("claude-fable-5-1");
    await rm(dir, { recursive: true, force: true });
  });

  test("missing file fails open (undefined, not a throw)", async () => {
    expect(await callerModel("/nonexistent/path/session.jsonl")).toBeUndefined();
  });

  test("undefined path fails open", async () => {
    expect(await callerModel(undefined)).toBeUndefined();
  });

  test("malformed lines are skipped, not fatal", async () => {
    dir = await mkdtemp(join(tmpdir(), "model-discipline-"));
    const path = join(dir, "session.jsonl");
    const lines = [
      "not json at all",
      JSON.stringify({ type: "assistant", message: { model: "claude-sonnet-5" } }),
      "",
    ];
    await writeFile(path, lines.join("\n"));
    expect(await callerModel(path)).toBe("claude-sonnet-5");
    await rm(dir, { recursive: true, force: true });
  });
});
