---
description: Which browser a job gets — a test suite (e2e, layout, visual), a check of a running app, a page read. Headless shell by default, when installed Chrome is allowed and how the line says why, contexts and workers as memory, what was evaluated and rejected.
paths: ["**/playwright*.config.*", "**/e2e/**", "**/*.e2e.ts", "**/tests/**/harness/**", "**/agents/browser.md", "**/skills/browse/**", "**/shared-chrome*"]
---

# Browser

Memory is the factory's binding gate (software-factory decision NL6), and the browser is the one large consumer a suite picks
freely. One basalt-ui layout run held 13 GB of Chrome; on 2026-11-16 about 25 launch sites pinned installed Chrome and none said
why. The map of what runs, the measurements and the evaluations: `docs/browser.md` in dotfiles.

## Which browser

The first row that fits decides.

| Job | Browser | How |
|-|-|-|
| A test suite: e2e, layout, visual | Playwright's bundled headless shell, inside a test slot | no `channel`, headless; `factory slot run`; installed by `playwright install --only-shell chromium` |
| A suite the shell cannot serve | installed Chrome, headless, with the reason on the line | `channel: 'chrome', // chrome: <reason>` |
| A check of a running app: screenshot, console, network, trace | the shared headless Chrome, in a context of your own | `/browse` |
| A public page to read | agw's chain: direct read, the headed research Chrome, an extract service | `agw web read`, `WebFetch` |
| A portal behind the owner's login, with no API | the owner's own signed-in Chrome, attached while he watches and presses every submit | the repo's own skill (finances `chrome-live`); never a copy of his profile |

A reason for installed Chrome is a measured difference: a baseline that fails on the shell, a codec or GPU path the shell lacks,
print or PDF output, a screenshot a person will judge. Name the failing assertion or the format: the comment is written for a check to
read.

## In a suite

- **One browser per worker, one context per test, closed in `afterEach`.** A context left open keeps its pages until the browser
  ends: that was the 13 GB.
- **Workers are a memory figure.** Three loaded pages cost 288 MiB on the shell and 503 MiB on Chrome headless, before the app
  under test. Raise workers with that sum, inside the slot.
- **The build saves memory, flags do not.** Shell against Chrome headless for three page loads: 288 against 503 MiB, 7 against 15
  processes, 1.6 against 4.0 s CPU. Disabling site isolation changed nothing.
- **Measure with `footprint -p`** summed over the browser's process tree. `ps` RSS counts shared pages once per process and
  read 2.9 GiB for 1.1 GiB of Chrome; `memory_pressure`'s free percentage hides 9 GiB sitting in the compressor.

## Never

- A Chrome an agent starts for itself, or a browser MCP per session: `/browse` reaches the shared one.
- A new MCP server for a coding agent, in a repo's `.mcp.json`, an agent file or a tool's config. An agent with a shell gets a
  command-line tool and a skill; the MCP entries left on 2026-11-16 are listed in `docs/browser.md` §Open work with the Issue
  that removes each.
- `headless: false` in a suite.
- A test or a check on the research Chrome (`127.0.0.1:9222`). It loads untrusted pages; the shared Chrome reaches tailnet apps.
  They stay two processes.
- Input sent to a "verify you are human" check. An interactive check is the owner's, through agw's handoff.
- Lightpanda, Kitesurf, a hosted browser or another driver. Each was evaluated on 2026-11-16 and rejected (`docs/browser.md`
  §Evaluated); reopen one with a measurement on the mini.
