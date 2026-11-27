# Browsers on the mini

Three kinds of browser run on the mini, each for one job. The expensive one is the browser a test suite launches: three pages
cost 503 MiB on installed Chrome and 288 MiB on Playwright's headless shell. The rule an agent follows is `rules/browser.md`.
This page holds what the rule rests on: what runs, what it costs, how page reads get past bot walls, and what was evaluated and
turned down on 2026-11-16.

Memory is the factory's binding gate: it stops admitting work when the mini swaps out (software-factory decision NL6; admission
refused on swap-out on 2026-11-09 and 2026-11-10). A browser is the one large consumer a suite picks freely, so the choices
below are memory decisions first.

## What runs

| Browser | Process | Lives | Footprint | Owner |
|-|-|-|-|-|
| Research Chrome | installed Chrome, headed, DevTools on `127.0.0.1:9222`, profile `~/.local/share/research-chrome` | always on | 236 MiB fresh, 510 MiB after a day idle, about 120 MiB per open tab | agent-workflows (`make research-chrome`) |
| Shared Chrome | installed Chrome, `--headless=new`, DevTools on `127.0.0.1:9223`, profile `~/.local/share/shared-chrome` | on demand: starts on `shared-chrome ensure`, stops 60 s after the last context | 201 MiB idle, about 75 MiB per context | dotfiles (`scripts/shared-chrome.ts`, `docs/global-reference.md` §Shared browser) |
| Test browsers | whatever a suite launches, inside a test slot | for the length of the suite; orphans end at `browser-reap` | 288 MiB (headless shell) or 503 MiB (Chrome headless) per three pages | each repo |
| The owner's Chrome | the macOS session's default browser | whenever something runs `open <url>` | 558 MiB on 2026-11-16 | the owner; finances' `chrome-live` skill attaches to it while he watches, nothing else of ours uses it, nothing reaps it |

Screen sharing shows the research Chrome and the owner's Chrome as windows. The shared Chrome is headless, and a suite's browser
is too: `rules/browser.md` allows no headed one.

### Why they are not one Chrome

- **The owner's Chrome cannot take the research role.** Chrome 136 and later ignore `--remote-debugging-port` on the default
  profile ([Chrome blog, 2025-03-17](https://developer.chrome.com/blog/remote-debugging-port)), so a driven Chrome always has a
  profile of its own.
- **Research and shared stay two processes.** The research Chrome loads untrusted pages from the open web. The shared Chrome
  opens tailnet apps with their sessions. One process would put both behind one DevTools port. It would also force one mode on
  both: bot walls need the headed window, the checks need none.
- **The saving would be one idle browser,** about 200 MiB, and only while both are up. The shared Chrome is down most of the day.

## Measured on 2026-11-16

Each build launched on a fresh profile, three pages loaded (a TodoMVC app, a react.dev reference page, an MDN page), memory as
the sum of `footprint -p` `phys_footprint` over the process tree, CPU from `ps` `time`. One run each on the mini.

| Build | Idle | Three pages | Processes with three pages | CPU for the three loads | Launch until DevTools answers |
|-|-|-|-|-|-|
| Chrome, headed | 236 MiB | 589 MiB | 15 | 4.0 s | 0.53 s |
| Chrome `--headless=new` (what `channel: 'chrome'` runs) | 201 MiB | 503 MiB | 15 | 4.0 s | 0.47 s |
| chrome-headless-shell (Playwright's default without `channel`) | 39 MiB | 288 MiB | 7 | 1.6 s | 0.44 s |
| either, site isolation disabled | no change | no change | no change | no change | |

- **The build is the lever.** The shell takes 43 % less memory, 60 % less CPU and half the processes. An 868-site Linux
  benchmark found the same order: 582 MB against 1,065 MB mean peak
  ([headlessperfbench, March 2026](https://github.com/atom41research/headlessperfbench/blob/main/docs/results_analysis.md)).
- **The shell is not Chrome in every case.** The same benchmark saw more missing content on third-party sites, and bot walls
  flag it. Our own apps render on it: software-factory's and iris's suites already run there. Pixel baselines get a trial per
  suite (Issues below).
- **Playwright picks the shell by itself** when a launch is headless and sets no `channel`
  ([playwright.dev/docs/browsers](https://playwright.dev/docs/browsers)); `playwright install --only-shell chromium` fetches
  only that build.

### How to measure a browser

`footprint -p <pid>` for every process of the tree, summed. Two numbers that mislead:

- **`ps` RSS** counts shared pages once per process. It read 2.9 GiB for two Chromes whose footprint was 1.1 GiB.
- **`memory_pressure`'s free percentage** read 82 % while the compressor held 9.25 GiB and 1.7 of 3 GiB swap was used. Read
  `vm_stat` (pages stored in compressor, swapouts) and `factory capacity get` instead.

## Page reads and bot walls

`agw web read` and `WebFetch` go through agw's chain: a direct read, then a tab in the research Chrome, then an extract service.
Ten research-typical pages on 2026-11-16:

| Pages | Leg that answered | Time |
|-|-|-|
| react.dev, Anthropic docs, GitHub, TanStack docs, Vercel pricing, X | direct | 0.4 to 0.8 s |
| npm, OpenAI pricing, Reddit | research Chrome | 5.6 to 6.9 s |
| Stack Overflow | none: `challenge not cleared`, owner asked | 21 s |

The Stack Overflow read failed once. Replaying it against the research Chrome with agw's own CDP steps showed why:

- **A Cloudflare challenge clears by itself in 4 to 10 s,** in ten of ten reads on a quiet address. agw's two end-to-end repeats took 16.5
  and 23.6 s; after several direct 403s from the same address, two reads were still waiting at 30 and 39 s. agw's limit is 20 s.
- **The tab is hidden.** `document.visibilityState` read `hidden` in most reads, because the window is occluded on a headless
  Mac. `Emulation.setFocusEmulationEnabled` made it `visible`.
- **An interactive checkbox did not clear.** indeed.com showed "confirm you are human" unchanged after 45 s in five runs.
- **agw does not answer that check.** A headed Chrome passing a script challenge is a real browser being a real browser. Sending
  a click to a "verify you are human" box is a statement that is false. That case goes to the owner through the handoff, or to
  a source that may serve the page: the Stack Exchange API, an archived copy.

The tab cap in agw's browser leg (`MAX_TABS`) is machine-wide, because every read runs in the one agw host process. Issue
1610 raises it from 3 to 8: about 1 GiB at the cap.

## Evaluated

All on 2026-11-16. **To reopen a verdict, bring a measurement taken on the mini.**

| Candidate | Verdict | Why |
|-|-|-|
| Cloudflare Kitesurf | no | Cannot reach a local app, takes no traces, fails bot walls. Detail below |
| Lightpanda 1.0.4 | no | 10 to 80 MB per page in independent tests, but no rendering engine: screenshots are placeholders, bounding boxes are simulated. One context per connection, AGPL. Covers only script-built pages with no wall. Retired here once already |
| Hosted browsers (Cloudflare Browser Run, Kernel, Browserbase, Steel) | no | Cash, latency and private pages leaving the machine, for memory that the shell saves locally. Browser Run identifies itself as a bot on every request |
| agent-browser 0.43 | not now | One source measured 288 against 1,488 tokens for an 11-step run. `/browse` already runs in a Haiku fork, so the saving lands in the cheapest context; reports of orphaned processes |
| Playwright MCP, Stagehand, browser-use, dev-browser, Claude in Chrome | no | No performance tooling beyond playwright-cli, or sessions that collide on shared tabs |
| WebKit or Firefox as the light engine, Servo, Ladybird, Blitz, Obscura | no | Not lighter than headless Chromium in the one comparison found, or not able to render a client-side app yet |
| Disabling site isolation | no | Measured above: no change |
| Hosted readers (Jina Reader, Firecrawl) in place of Tavily Extract | open | Tavily Extract basic recovered 30 % of script-rendered text in the one independent benchmark, Jina 70 %, Firecrawl 79 % ([krabarena, 2026-10-29](https://krabarena.com/claims/js-rendered-pages-firecrawl-keenable-and-jina-recover-70-79-of-render-only-text)). Decide on agw's own telemetry (Issue 1592) |

### Kitesurf

- **Reach:** it runs on Workers, so the hosted engine reaches neither localhost nor the tailnet.
- **DevTools:** the Performance, Tracing, Memory and Profiler CDP domains answer empty, so no traces.
- **Pages:** no bot-wall handling, no WebGL or video. On our ten pages it failed the three walled ones the research Chrome read.
- **Cost:** its 49 MiB per page is Cloudflare's memory. Its own benchmark puts it at 1.7 to 2.4 times Chrome's wall time.
- **Local:** open source since 2026-11-13, but the local engine is wrangler plus workerd at about 680 MiB idle in the one
  independent test.

## chrome-devtools CLI

`agents/browser.md` used to declare the chrome-devtools MCP inline for traces, Lighthouse and CSS. The same package ships a
command-line client, and since 2026-11-16 the agent uses that: no MCP server is registered anywhere for the browser path.
Checked on the mini with `chrome-devtools-mcp` 1.13.0 (pinned in the Makefile, `CHROME_DEVTOOLS_VERSION`) against the shared
Chrome 157 on `127.0.0.1:9223`; CLI reference: [docs/cli.md](https://github.com/ChromeDevTools/chrome-devtools-mcp/blob/main/docs/cli.md).

| Need | Result |
|-|-|
| Attach to the shared Chrome | `chrome-devtools start --browserUrl=http://127.0.0.1:9223` attaches; no second Chrome (`ps`: one Chrome on `:9223`) |
| Isolated page | works on a tab playwright-cli opened with `tab-new --isolated-context`: `list_pages` shows it, its id is the one that is new |
| Performance trace with insights | `performance_start_trace <id> --filePath=…`: reloads, stops itself, prints LCP and its breakdown (TTFB, render delay), CLS; `performance_analyze_insight <id> NAVIGATION_0 LCPBreakdown` goes deeper |
| Lighthouse | `lighthouse_audit <id> --mode navigation --device desktop or mobile --outputDirPath <dir>`: category scores, failed audits, `report.html` and `report.json` |
| Computed CSS | `take_snapshot <id>` for uids, `get_css_styles <id> <uid>`: matched rules, inherited custom properties, `[overloaded]` losers, source lines |

### The daemon

- **It is one Node process.** `chrome-devtools start` forks `daemon/daemon.js` on a Unix socket under `/tmp/chrome-devtools-mcp-<uid>`.
  `footprint -p`: 122 MiB idle, 314 MiB after a trace, a Lighthouse run and a snapshot. With `--usageStatistics=false` there is no
  telemetry watchdog process. The MCP it replaces is an `npx` wrapper plus the server, per running agent.
- **It is one per user, and `start` is start-or-restart.** A second `start` replaces the first one's arguments and page ids, and
  `stop` ends whatever runs. So an agent never runs either. A first call without a daemon starts one with default arguments: a
  **second Chrome of its own** (measured), hence `shared-chrome devtools` before any other command.
- **It has no idle exit and no parent.** It outlives the shell, the agent and the Chrome it was attached to (measured: it kept
  running after `shared-chrome stop`). Only `stop` ends it.
- **It does not clean up what it opens.** A page made with `new_page --isolatedContext` survived `stop`, and closing it left an
  empty browser context behind (the shared Chrome only stops 60 s after the last *context*); the CLI also refuses to close the
  last page. So the agent never opens pages through it: playwright-cli opens the tab and its `detach` closes the context.
  `get_css_styles` was exercised here: matched rules, inherited custom properties, `[overloaded]` losers, source lines.
- **A per-agent `--sessionId`** (a hidden global flag, absent from `--help` and the CLI documentation) gives each agent its own
  socket and measured fine alongside the default daemon. It was not adopted: the owner's rule is one daemon with one owner, and
  an agent that dies before its own `stop` leaves an orphan with no reaper.

### Who owns the daemon

`scripts/shared-chrome.ts` does, in two places (`scripts/shared-chrome.test.ts` covers each):

| When | What |
|-|-|
| `shared-chrome devtools` | ensures Chrome, then starts the daemon (`start --browserUrl=<shared Chrome> --usageStatistics=false --performanceCrux=false`) if `chrome-devtools status` shows none; leaves a running one alone; restarts one of its own that started before the current Chrome or whose `list_pages` fails (an answer later than 15 s counts as busy with another agent's trace, not dead); the check-then-start runs under a lock, so two agents never start two |
| the supervisor stops Chrome (idle exit, `shared-chrome stop`, a crashed Chrome) | `chrome-devtools stop`, when `status` names this Chrome's URL |
| `shared-chrome devtools` finds a stray, or the supervisor stops Chrome with one running | `chrome-devtools stop` for a stray at least `SHARED_CHROME_STRAY_MS` (10 min) old; a younger one makes `devtools` exit 1 and stays |
| `shared-chrome status` | one `devtools:` line: no daemon, the daemon's pid on the shared Chrome, a stray, or one attached elsewhere |

- **A daemon attached elsewhere is never touched.** Finances' `chrome-live` skill starts the default daemon with `--autoConnect`
  against the owner's signed-in Chrome, and `--autoConnect` cannot run next to a `--browserUrl` daemon. Whichever runs first holds
  the one daemon slot; the other waits. `shared-chrome devtools` then exits 1 naming the pid and its arguments, and the browser agent
  reports that and stops. Mirror rule: the finances skill reads `chrome-devtools status` and refuses to restart a daemon that
  serves the shared Chrome.
- **A stray is a daemon nobody owns.** Its arguments hold no attach flag (`--autoConnect`, `--browserUrl`, `--wsEndpoint`) and no
  launch flag (`--channel`, `--executablePath`, `--userDataDir`), typically just `["--viaCli"]`: a bare `chrome-devtools <tool>`
  auto-started it and it launched a headless Chrome of its own. On 2026-11-25 one did, survived two days (the daemon has no idle
  exit) and made `shared-chrome status` read `attached elsewhere`, so finances' `chrome-live` refused to attach to the owner's
  Chrome. A stray serves nobody's Chrome, so shared-chrome reaps it at 10 min of age (age is all the daemon reports: it keeps no
  last-client time); younger, it may be a run in progress. `status` names it `stray`.
- **Stray or busy, for a skill that reads `chrome-devtools status`** (finances' `chrome-live`): `args` with `--autoConnect` or
  `--browserUrl` is held by its owner, so wait. `args` that is only `["--viaCli"]` (no attach flag) is a stray: it is no one's
  session, and `chrome-devtools stop` is safe once `start-date` is more than 10 min old; `shared-chrome devtools` does it too.
- **Page ids are shared** by every agent using the daemon, so an agent finds its page as the id that is new after its own `tab-new`
  and addresses only that one.

### A slow start is not a dead start

On 2026-11-20, -21 and -22 the shared Chrome failed to start in runs of three ("Chrome never answered on its DevTools port"). On 2026-11-22 the mini was
overloaded (load average 16 to 31 on 12 cores, swap 3.8 of 5.1 GB used) and Chrome's launch steps took seconds each, so it needed
more than the old 20 s to open its port; on an idle machine it answers in 0.5 s. The supervisor now waits `SHARED_CHROME_START_MS`
(120 s) before it kills a Chrome that has not answered, and `ensure` and `devtools` wait `SHARED_CHROME_ENSURE_MS` (90 s, capped
1 s below the start limit so `ensure` never prints the URL of a Chrome the supervisor is about to kill). A start slower than 5 s
logs `Chrome answered after <n> s`; when `ensure` gives up first, the supervisor is still waiting and a retry may find Chrome up.

## Strict MCP

Proved 2026-11-16 on Claude Code 2.1.325, interactive sessions in `hc run` terminals (never `claude -p`), scratch dirs, a `.mcp.json` server that writes a marker file on start:

- `--strict-mcp-config` with no `--mcp-config` blocks a repo's `.mcp.json` server: no marker, no process. Without it the marker appears and `/mcp` lists the server.
- It leaves alone the plugin tool (`mcp__easel__chart` stays connected), tool search (`select:WebSearch` loads a deferred tool), hooks (SessionStart `session_env` logged, Stop hook ran) and `/browse` (the browser agent returned a page title).
- It is accepted with `--resume <id>`: the session came back with its history, no marker, easel still connected.
- `c`/`ch`/`cs`/`cf` (`_CLAUDE_MCP_ARGS` in `config/zsh/claude.zsh`), `rd work`/factory spawns (`CLAUDE_MCP_ARGS` in `scripts/remote-dev.sh`) and the post-restart resume (`MCP_FLAGS` in `scripts/hc-resume.ts`) pass it; each has a test. A bare `claude` typed by hand does not.
- Not covered: a server named in `--mcp-config` or a `--plugin-dir` plugin that ships its own server (none of ours does); re-prove if a launcher adds either.

## Open work

finances' `chrome-live` moved off its `.mcp.json` on 2026-11-16 (Issue 1619, closed): the attach to a scratch profile is proven,
the attach to the owner's default profile behind Chrome's prompt is proven at its first supervised use.

| Issue | Repo | What |
|-|-|-|
| 1610 | agent-workflows | browser leg: focus emulation, a 45 s limit for a page still in a challenge, browser-first for a challenged host, one tab per host, tab cap 8 |
| 1611 | agent-workflows | Stack Exchange API and Wayback legs for pages behind an interactive check |
| 1612 | basalt-ui | layout and quality-matrix suites on the headless shell where results match |
| 1613 | shutterflow | e2e projects on the headless shell where they pass |
| 1616 | software-factory | hygiene probe: a suite that pins installed Chrome without a reason, and a checked-in `.mcp.json` |
| 1620 | software-factory | `--strict-mcp-config` on the lead launcher, after 1622 |

dotfiles ships no MCP entry since Issue 1615: the `browser` agent and `config/opencode/opencode.json` both went to the CLI.
The `--strict-mcp-config` guard in dotfiles is §Strict MCP; the factory lead launcher is Issue 1620 above.

## MCP servers (moved from the root AGENTS.md)

**MCP servers**: none registered at user scope, none inline in an agent, none in OpenCode's `opencode.json`. The `browser` subagent
(`/browse`) drives the **shared headless Chrome** (`shared-chrome ensure`, `127.0.0.1:9223`, on demand, one isolated context per agent, idle 15 min,
`docs/global-reference.md` §Shared browser) with `playwright-cli`, plus the `chrome-devtools` CLI (pinned in the
Makefile, `docs/browser.md` §chrome-devtools CLI) for traces, Lighthouse and CSS; a
user-scope server costs an `npx` + `node` pair (~124 MiB) in every session, 24 of them
held 2978 MiB idle on the mini. `c`/`ch`/`cs`/`cf`, `rd work` and the resume path pass `--strict-mcp-config`, so a repo `.mcp.json`
starts nothing; plugin tools, tool search, hooks and `--resume` survive it (`docs/browser.md` §Strict MCP). `make setup` removes any leftover registration, project-local ones too
(`projects[<dir>].mcpServers` in every account's `.claude.json`, which the user-scope remove and
`claude mcp list` from this directory never see; `scripts/claude-project-mcp.sh`, backup
`.claude.json.bak-chrome-devtools`), and `make status` §Browser debugging prints a ✗ line for one, naming account and
project. Test-browser Chrome trees that outlive their launcher (Playwright/puppeteer temp profile, parent
launchd, older than 30 min) are ended by `com.jkrumm.browser-reap` every 30 min
(`scripts/browser-reap.py`, `make browser-reap-run ARGS=--dry-run`, log `~/Library/Logs/browser-reap.log`);
never the owner's Chrome or a persistent profile. Which browser a suite, a check or a page read gets (headless shell by
default, installed Chrome only with `// chrome: <reason>`), every browser on the mini and its cost: `rules/browser.md`,
`docs/browser.md`. Claude Code
reaches the platform through `agw` (`/check`, `/review`, `/prose`,
`/excalidraw-diagram`, `/brain` lookups, `/otel` — mini-only). HyperDX is deliberately *not* registered — `/otel`
speaks its endpoint through `agw hdx`. Keep project MCPs minimal.
