---
name: modern-web-guidance
description: Look up a modern web-platform guide (Chrome/Edge/Firefox/MDN corpus, 208 guides) before hand-writing HTML/CSS/DOM for a native capability — dialog or popover, anchor positioning, view transitions, scroll-driven animation, container queries, forms and autofill, dates, sanitization, CWV. Not in basalt-ui 2.x apps, not for backend, tooling or framework docs.
---

# Modern Web Guidance — wrapper over the upstream CLI

Upstream `GoogleChrome/modern-web-guidance` ships a skill that says "MANDATORY: execute first for all HTML/CSS and client JS". We do not install it: it would outrank basalt's rules and send agents to raw `dialog`/popover patterns that `basalt/import-boundary` forbids. This wrapper keeps the CLI and drops the mandate. The always-on distillate is `rules/web-platform.md`; this skill is the long tail.

## When

- A non-basalt app (or standalone HTML) needs a native web capability and you would otherwise write it from memory: dialog, popover, anchor positioning, view transitions, scroll-driven animation, forms/autofill, dates, sanitization, INP/LCP work.
- **Skip in basalt-ui 2.x consumers** (`package.json` depends on `basalt-ui` ^2): the shipped `basalt-*` rules and Base UI primitives own these; `frontend-routing.md` has the order.
- Skip for backend, infra, tooling, trivial copy edits, and library docs (those go through `/research`).

## Steps

1. Search with a 2–5 word query for one capability, no framework or app nouns (`"light dismiss dialog"`, not `"close React settings modal"`); split multi-feature tasks into separate searches:
   `npx -y modern-web-guidance@latest search "<query>"` → `[{id, description}]`.
2. A description matches: `npx -y modern-web-guidance@latest retrieve "<id>[,<id>]"` (also the broad discipline guide, e.g. `forms`, `accessibility`, `css`). Output over ~9.5 KB lands in a temp file: Read it in full.
   Weak or empty: rephrase once with the concrete noun (`dialog`, `popover`, `table`), then `list` once; no match means proceed without a guide.
3. Apply it, adapted to the framework: spread newly shipped attributes in React (`{...({ popover: 'hint' } as any)}`), guard `window` for SSR, `useId()` for per-instance ids and `anchor-name`s, `showModal()` via refs.
4. Check the result against the guide's fallbacks: Baseline Widely needs none, anything newer needs the guide's fallback unless the repo's AGENTS.md states a browser policy.

`legacy-scan <path> --json` (about 20% of the corpus has deterministic rules) only on an explicit "modernize this codebase" ask; verify each finding against its `keepWhen`/`dropWhen` rubric before editing.

## Needs

- Outbound network (npx fetches the package, guides are served from it). `npx --offline …` when offline.
- Node ≥ 22. `npx -y modern-web-guidance@latest *` is the only invocation to allowlist.
- Default `search` output is JSON; a guide's volatile and origin-trial content is off unless the repo opts in with `set-allow-volatile-features` / `set-allow-origin-trials`: do not run those.
