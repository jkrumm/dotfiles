#!/usr/bin/env bun

/** Tests for the web-fetch-route PreToolUse hook: a false deny wedges WebFetch, a false allow quietly loses the agw route. */

import { describe, expect, test } from "bun:test";
import { agwAvailable, isInternalHost, routeReason } from "./web-fetch-route";

const fetchCall = (url: string, prompt?: string) => ({ tool_name: "WebFetch", tool_input: { url, ...(prompt ? { prompt } : {}) } });

describe("routeReason", () => {
  test("a page goes to agw web read with the prompt as --ask, quoted for the shell", () => {
    const reason = routeReason(fetchCall("https://www.idealo.de/preisvergleich/x?q=a&b=c", "What's the price of the E4?"), true);
    expect(reason).toContain("agw web read 'https://www.idealo.de/preisvergleich/x?q=a&b=c' --ask 'What'\\''s the price of the E4?'");
  });

  test("a call without a prompt reads the page without --ask", () => {
    expect(routeReason(fetchCall("https://example.com/a"), true)).toContain("agw web read 'https://example.com/a'\n");
  });

  test("YouTube goes to agw web youtube, with the summarize pipe for a long video", () => {
    for (const url of ["https://www.youtube.com/watch?v=dQw4w9WgXcQ", "https://youtu.be/dQw4w9WgXcQ", "https://m.youtube.com/shorts/dQw4w9WgXcQ"]) {
      const reason = routeReason(fetchCall(url, "summarise"), true);
      expect(reason).toContain(`agw web youtube '${url}'`);
      expect(reason).toContain("agw llm summarize");
    }
  });

  test("fails open: no agw, another tool, a URL agw refuses, not http(s), not a URL, no url", () => {
    expect(routeReason(fetchCall("https://example.com/a"), false)).toBeNull();
    expect(routeReason({ tool_name: "Read", tool_input: { url: "https://example.com/a" } }, true)).toBeNull();
    for (const url of ["http://localhost:3000/x", "http://127.0.0.1/x", "http://192.168.1.5/x", "http://printer.local/x", "https://box.tail1234.ts.net/x", "ftp://example.com/x", "file:///etc/hosts", "not a url"])
      expect(routeReason(fetchCall(url), true)).toBeNull();
    expect(routeReason({ tool_name: "WebFetch", tool_input: {} }, true)).toBeNull();
  });
});

describe("isInternalHost", () => {
  test("private, loopback, link-local, tailnet and internal names; public names and addresses are not", () => {
    for (const host of ["localhost", "10.1.2.3", "172.16.0.1", "172.31.255.1", "169.254.169.254", "100.64.0.1", "[::1]", "x.internal"])
      expect(isInternalHost(host)).toBe(true);
    for (const host of ["example.com", "93.184.216.34", "172.32.0.1", "100.128.0.1", "www.idealo.de"]) expect(isInternalHost(host)).toBe(false);
  });
});

describe("agwAvailable", () => {
  test("needs the credentials file and the CLI", () => {
    expect(agwAvailable("/nonexistent-home", () => "/usr/local/bin/agw")).toBe(false);
    expect(agwAvailable(process.env.HOME, () => null)).toBe(false);
  });
});
