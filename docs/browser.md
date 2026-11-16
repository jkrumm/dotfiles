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
| The owner's Chrome | the macOS session's default browser | whenever something runs `open <url>` | 558 MiB on 2026-11-16 | the owner; nothing of ours uses it, nothing reaps it |

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

## Open work

| Issue | Repo | What |
|-|-|-|
| 1610 | agent-workflows | browser leg: focus emulation, a 45 s limit for a page still in a challenge, browser-first for a challenged host, one tab per host, tab cap 8 |
| 1611 | agent-workflows | Stack Exchange API and Wayback legs for pages behind an interactive check |
| 1612 | basalt-ui | layout and quality-matrix suites on the headless shell where results match |
| 1613 | shutterflow | e2e projects on the headless shell where they pass |
