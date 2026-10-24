# 12. How we know it works

Neither you nor an agent says the factory works; four things outside both do.

1. **The frozen golden set.** 959 labelled events from warden's history, held out and pre-registered
   in v1 (`evidence/golden/`). Every dedup rule change replays it; grouping may not drop below F1 0.889.
   Known-fix matching (0.479) is re-measured at W9 on fresh labels and must reach 0.6.
2. **Gamedays.** v1's catalogue of failures from this estate's own history (`design/proof.md` §2):
   a stopped container, a full disk, an expired cert, a failed backup, a resolver blackhole, a crash
   loop, a bad deploy. Each is injected on a scratch target and must heal with zero owner touch. The
   first one — `glance` stopped, which v1's baseline noticed after 6.8 minutes and never fixed — is
   W1's gate.
3. **KPIs computed by scripts the loop cannot edit** (`evidence/DEFINITIONS.md`, kept), shown in Argo:

   | KPI | SLO |
   |-|-|
   | items that reached you | < 1 % over 14 days, stretch 0.1 % |
   | owner notifications | ≤ 2 a week + the briefing |
   | `continue` nudges | 0 |
   | time to resolve, median / p90 | ≤ 0.5 h / ≤ 4 h |
   | reopen and regression rate | ≤ 5 % each |
   | automatic revert on failed post-deploy verify | 100 % |
   | green job runs that spent tokens | 0 |
   | your interactive session blocked by the factory | 0 minutes |

4. **Holdout scenarios** for fleet projects: plain-language checks of "the product works" (v1
   `design/proof.md` §4), written by the project's mother when a feature lands, stored outside the
   repo they judge, run after every deploy. You may edit them; you are never asked to write them.

## v1's open weak spots, and what v2 does about each

| Weak spot (v1 final verification) | v2 |
|-|-|
| Known-fix match failed (0.479 < 0.50) | similarity retrieval + label loop (§8); re-measured at W9 |
| Escalation recall failed on 6 genuine decisions in 959 | escalation shrinks to the four business classes, recognised by the investigation's structured output, not by keyword rules; measured on the fresh sample |
| No canary or test target, so code fixes stayed propose-only | `make verify` per target and `deploy.mode` per project (§7); gamedays run on scratch targets |
| The gameday did not heal (`glance`, 30 min manual restore) | W1's gate |
| Pre-registration amended twice, `--verify` exits 1 | v2 freezes a new pre-registration at W3 before the first rule change, hash-checked in CI |
| Failing `warden-backup`, `hermes-backup`, `drift-check` | W0 archives warden and Hermes state once with a checksum and removes those jobs; the backup job in §9 checks every remaining backup's age and a restore |
| Review door hand-started | retired at W7 |
| Days 1–8 of v1's plan worse than today | v2 heals from W1 (≈ day 3); raw alerts keep flowing to Slack until then |

## Per-wave proof gates

Each wave in §13 ends on an observable result, checked by the wave's own close-out — not by the agent
that built it.
