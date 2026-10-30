#!/usr/bin/env bun

/**
 * PreToolUse hook: send `WebFetch` to `agw web read` on a machine that has agw.
 *
 * `WebFetch` cannot read what bot walls, PDFs-as-text and YouTube need, and a session that meets that reports "I can't
 * access this page" although agent-workflows' fetch chain (direct, a real headed Chrome, Tavily Extract; PDF text;
 * YouTube transcripts) can. `agw web read <url> --ask <question>` is that chain plus the same kind of extraction pass
 * `WebFetch` does with its prompt, so it replaces it instead of backing it up. The route is one rule, no host list: a
 * list would be a second copy of what agw already knows.
 *
 * Fails open everywhere: no agw credentials on the machine (the MacBook), a URL agw refuses by design (private and
 * tailnet hosts), anything that is not an http(s) URL. A hook bug must not be able to wedge `WebFetch`.
 */

import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

interface HookInput {
  tool_name: string;
  tool_input?: { url?: string; prompt?: string; [key: string]: unknown };
}

const INTERNAL_SUFFIXES = [".local", ".internal", ".lan", ".localdomain", ".localhost", ".home.arpa", ".ts.net"];

/** Hosts agw's SSRF guard refuses (loopback, private, link-local, tailnet, internal names): WebFetch keeps those. */
export function isInternalHost(hostname: string): boolean {
  const host = hostname.replace(/^\[|\]$/g, "").toLowerCase().replace(/\.+$/, "");
  if (host === "localhost" || INTERNAL_SUFFIXES.some((suffix) => host.endsWith(suffix))) return true;
  if (host === "::1" || host.startsWith("fc") || host.startsWith("fd") || host.startsWith("fe80")) return host.includes(":");
  const octets = host.split(".").map(Number);
  if (octets.length !== 4 || octets.some((o) => !Number.isInteger(o) || o < 0 || o > 255)) return false;
  const [a, b] = octets as [number, number, number, number];
  return a === 0 || a === 10 || a === 127 || (a === 169 && b === 254) || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) || (a === 100 && b >= 64 && b <= 127);
}

/** True where agw can serve the call: its credentials file is there and the CLI is on the PATH. */
export function agwAvailable(home = homedir(), which: (name: string) => string | null = Bun.which): boolean {
  return existsSync(join(home, ".config", "agw", "env")) && which("agw") !== null;
}

const quote = (text: string) => `'${text.replaceAll("'", `'\\''`)}'`;

const isYoutube = (hostname: string) => /(^|\.)(youtube\.com|youtu\.be|youtube-nocookie\.com)$/i.test(hostname);

/** The deny reason for a URL that should go through agw, or null to let `WebFetch` run. */
export function routeReason(input: HookInput, available = agwAvailable()): string | null {
  if (input.tool_name !== "WebFetch" || !available) return null;
  const raw = input.tool_input?.url;
  if (!raw) return null;
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    return null;
  }
  if ((url.protocol !== "http:" && url.protocol !== "https:") || isInternalHost(url.hostname)) return null;
  const why =
    "WebFetch is routed through agw on this machine: its fetch chain reads bot-walled pages (a real browser), PDFs as text and " +
    "YouTube transcripts, which WebFetch cannot, and it extracts what you ask for.";
  if (isYoutube(url.hostname)) {
    return (
      `${why}\nThis is a video. Run: agw web youtube ${quote(raw)}  (transcript with [m:ss] lines plus title, channel, date, description; ` +
      "for a long one pipe it: agw web youtube <url> --format json | jq -r .transcript | agw llm summarize)."
    );
  }
  const ask = input.tool_input?.prompt?.trim();
  return `${why}\nRun: agw web read ${quote(raw)}${ask ? ` --ask ${quote(ask)}` : ""} --format plain\n(Add --fresh for a page that changes by the hour, --max-chars to read more of a long page.)`;
}

if (import.meta.main) {
  const input: HookInput = JSON.parse(await Bun.stdin.text());
  const reason = routeReason(input);
  if (reason) {
    process.stdout.write(
      JSON.stringify({
        hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: reason },
      }),
    );
  }
  process.exit(0);
}
