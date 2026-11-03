---
description: How to write documents an agent reads — AGENTS.md, global CLAUDE.md, skills, rules, docs reached by a pointer. Pointer wording, disclosure, completion criteria, leading words, pruning.
paths: ["**/AGENTS.md", "**/SKILL.md", "**/.claude/rules/**", "**/.claude/skills/**", "**/rules/*.md", "**/global.CLAUDE.md"]
---

# Writing for Agents

Applies to any document an agent consumes. Prose for humans is `brain/voice.md`; this is the agent-facing counterpart. Defaults, not laws: a document is judged by running it, not by debate.

- **A pointer's wording decides when the material is reached.** A skill description and an AGENTS.md line naming a doc are the same object. Sharpen the wording before inlining the target. List the distinct branches that should trigger it, one trigger per branch (synonyms are one branch written twice), the leading word first, no identity the body already carries.
- **Two loads.** Context load: always-loaded tokens, paid every turn. Cognitive load: what Johannes must remember exists. Reach-by-pointer escapes the first; a hand-fired skill with no pointer rides on the second. Spend each where it earns.
- **Hierarchy: step, reference, disclosed reference.** Inline what every branch needs; push behind a pointer what only some branches reach. Keep a concept's definition, rules and caveats under one heading. A document too long is a failure even when every line is live: split by branch or sequence.
- **Every step ends on a checkable, exhaustive criterion.** "Every modified model accounted for" beats "produce a change list". A vague bound invites premature completion: sharpen the bound first; hide later steps only across a real context boundary (hand-off, subagent), never inline.
- **Leading words.** Reuse a word the model already holds (lesson, tracer bullet, red) and repeat it as a token, never as a sentence. A coined word recruits no priors and costs its definition. A triad spelled out at three sites is a word waiting to be named.
- **State the positive target.** A ban names the thing it forbids. Write the behaviour wanted ("one-line comments"); keep a bare prohibition only for a hard guardrail, paired with its positive. Test it by running the document.
- **Prune.** One source of truth per meaning. The environment (`package.json`, Makefile, `--help`, directory layout) is a source too: a document that restates it is a cache, worth its load only for what lookup cannot reveal (the convention, the reason, the gotcha). Delete a whole sentence that fails the no-op test (does it change behaviour against the default?). A weak word is a no-op: use a stronger one. Stale layers settle as sediment; removing is the discipline.
- **Project psychosis.** State what this project obsesses over that a general model would not assume: stakes, who the users are and what they never see, the scar behind each rule. Define the parties ("you" the agent, "we" the humans, "users") and name recurring failures once, then use the name. Borrowed files do not transfer; the priorities are the content.
- **Calibrate ambition.** Agents plan on pre-agent timelines. When the work is bold, one line says so.

## Skills

- **Model-invoked** skills carry a description that stays loaded: permanent context load for autonomous reach and reach from other skills. **User-invoked** (`disable-model-invocation: true`) cost no context and spend cognitive load: a one-line human summary replaces the trigger list.
- A skill that only ever fires by hand is user-invoked. Johannes never types skill names himself, so here almost none qualifies: `disable-model-invocation` on a skill the agents need makes it unreachable. Split off a model-invoked skill only for a trigger word actually used in prompts, or because another skill must reach it.
- Reference two skills share lives in a plain file both point at, not in either skill.
- A pile of user-invoked skills too large to remember gets one router skill that names them and when to reach for each. It can hint, never fire.
