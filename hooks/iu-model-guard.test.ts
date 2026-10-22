#!/usr/bin/env bun

/**
 * Tests for the iu-model-guard hook. A false allow is the 2026-10-22 leak (Opus on
 * IU through a hand-rolled runner); a false block wedges every `ca` / `cdf` /
 * `claude_iu` session, or — worse — every Max session.
 */

import { describe, expect, test } from "bun:test";
import { isMetered, isPremium, mainModel, modelFromArgv, resolveAlias } from "./iu-model-guard";

const IU = { ANTHROPIC_BASE_URL: "https://gateway.example.com/anthropic" };

describe("isMetered", () => {
  test("unset or blank (`c`) is Max", () => {
    expect(isMetered({})).toBe(false);
    expect(isMetered({ ANTHROPIC_BASE_URL: "" })).toBe(false);
  });

  test("first-party Anthropic is not the IU endpoint", () => {
    expect(isMetered({ ANTHROPIC_BASE_URL: "https://api.anthropic.com" })).toBe(false);
  });

  test("any other base URL is metered", () => {
    expect(isMetered(IU)).toBe(true);
  });
});

describe("modelFromArgv", () => {
  test("space and equals forms", () => {
    expect(modelFromArgv("claude -p --model opus --no-session-persistence")).toBe("opus");
    expect(modelFromArgv("claude --model=claude-sonnet-5[1m]")).toBe("claude-sonnet-5[1m]");
  });

  test("no flag", () => {
    expect(modelFromArgv("claude -p --output-format json")).toBeUndefined();
  });
});

describe("resolveAlias", () => {
  test("bare opus on a hand-rolled runner stays opus", () => {
    expect(resolveAlias("opus", IU)).toBe("opus");
  });

  test("`ca` pins every tier, so opus resolves to its Sonnet", () => {
    expect(resolveAlias("opus", { ...IU, ANTHROPIC_DEFAULT_OPUS_MODEL: "claude-sonnet-5[1m]" })).toBe(
      "claude-sonnet-5[1m]"
    );
  });

  test("full ids pass through", () => {
    expect(resolveAlias("DeepSeek-V4-Flash", IU)).toBe("DeepSeek-V4-Flash");
  });
});

describe("mainModel + isPremium — the block decision", () => {
  test("the incident: claude -p --model opus on IU", () => {
    expect(isPremium(mainModel({ env: IU, argv: "claude -p --model opus" }))).toBe(true);
  });

  test("argv wins over ANTHROPIC_MODEL and settings", () => {
    const env = { ...IU, ANTHROPIC_MODEL: "claude-opus-5-5" };
    expect(mainModel({ env, argv: "claude --model sonnet", fromSettings: "fable" })).toBe("sonnet");
  });

  test("settings default fable with no flag is caught", () => {
    expect(isPremium(mainModel({ env: IU, argv: "claude -p", fromSettings: "fable" }))).toBe(true);
  });

  test("cdf, ca and unresolvable are allowed", () => {
    expect(isPremium(mainModel({ env: IU, argv: "claude --model DeepSeek-V4-Flash" }))).toBe(false);
    expect(isPremium(mainModel({ env: IU, argv: "claude --model claude-sonnet-5[1m]" }))).toBe(false);
    expect(isPremium(mainModel({ env: IU, argv: "claude -p" }))).toBe(false);
  });
});
