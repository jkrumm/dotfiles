# 11. How we know it works

Neither you nor an agent says the factory works. These do:

1. **The frozen golden set** — 959 labelled events from warden's history (`evidence/golden/`). Every
   dedup rule or threshold change replays it; grouping F1 may not drop below 0.889.
2. **Gamedays** on scratch targets, each tied to an SLO and a wave gate:

   | Gameday | Gate | Pass |
   |-|-|-|
   | a container stops (`glance` on the homelab, which v1's baseline saw and never fixed) | W1 | restarted by the runbook within 5 minutes of its grace window ending; nothing reaches you |
   | the factory is killed mid-runbook (W1), then mid-merge (W2) | W1, W2 | no duplicate effect, no lost Task |
   | a deploy breaks `make verify` | W2 | rolled back to the last held deploy, artifact marked bad |
   | both Max accounts walled with an outage open | W2 | runbook and rollback still run; code Tasks wait; nothing spills |
   | the database is restored from last night's dump | W1 | adopt mode, then no duplicate effect |
   | a scripted attack pattern in CrowdSec | W4 | blocked by the runbook, one line in the briefing |

3. **Five numbers, computed by SQL views the loop cannot edit**, shown on *Now*:

   | KPI | SLO, over 14 days |
   |-|-|
   | items that reached you | < 1 % |
   | notifications to you | ≤ 2 a week + the briefing |
   | failed post-deploy checks rolled back automatically | all |
   | time to resolve, median / p90 | ≤ 0.5 h / ≤ 4 h |
   | green job runs that spent tokens | 0 |

4. **Verification the candidate cannot weaken** (§4): base-branch checks on the merge result,
   acceptance checks written from the plan by a separate session, no auto-ship without evidence.

v1's open weak spots and where each went are in appendix C.
