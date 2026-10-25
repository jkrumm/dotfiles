# Owner voice note on v2.2 (2026-10-25, evening)

Transcribed voice message, sent from the car after the v2.2 podcast; the owner had not read the
report. Summary of what it asked, in the order it came:

1. The trajectory is right: the factory manages the lifecycle around Claude Code, and Claude Code
   handles its own delivery cycle.
2. Mother, lead and wave agents read as three layers; the owner's model is two: an orchestrator that
   works the queue (order, parallel or sequential, compacted or restarted at meaningful boundaries)
   and implementers that take one item and build it end to end.
3. Is herdr the right substrate for the factory's sessions, or should they move to `claude -p` or the
   Agent SDK on the subscription in a more managed environment? herdr is liked for plain sessions,
   cross-session reading and remote work, but resuming its sessions is "kind of quirky". Wants old
   chats retrievable later. Look at how others do it (T3 Code named).
4. Two modes should coexist: the orchestrated factory for the wired repos, and plain single sessions
   for simpler repos (website, brain) that are not wired into triage and monitoring; Hermes reaches both.
5. DBOS or not: "I don't care."
6. Dig deep into Warp's factories (docs, site, blog, GitHub, the YouTube talk): domain language,
   industry standards, what applies to a solo developer versus a company.
7. Career angle: become an expert on software factories, understand the field and its language, and
   publish a general guide on the personal website; build the solo example implementation.
8. KPIs and measurability matter; adapters for GitHub issues, Uptime Kuma, HyperDX, Hermes requests.
9. The podcast's dedup part (decision model vs DeepSeek OpenCode, two pipelines) was confusing: is it
   a POC and compare, or what is the strategy?

Mid-turn follow-up: https://github.com/anthropics/claude-code/issues/97074 (headless `claude -p`
metered at about 1.8× the interactive rate on the 5-hour window).
