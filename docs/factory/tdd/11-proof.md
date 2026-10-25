# 11. How we know it works

Neither you nor an agent says the factory works. These do:

1. **The frozen golden set** — 959 labelled events from warden's history (`evidence/golden/`). Every
   dedup rule or threshold change replays it; grouping F1 may not drop below 0.889.
2. **Gamedays** on scratch targets, each tied to an SLO and a wave gate:

   | Gameday | Gate | Pass |
   |-|-|-|
   | a container stops (`glance` on the homelab, which v1's baseline saw and never fixed) | W2 | restarted by the runbook within 5 minutes of its grace window ending; nothing reaches you |
   | the factory is killed while a lead works, then mid-runbook | W1, W2 | the lead keeps working; on restart the factory re-reads herdr; no duplicate effect, no lost Issue |
   | a seeded bug passes CI but breaks production | W1 | the lead's production check catches it and fixes forward before `ship`; or the factory's `make verify` after the hold reopens the Issue |
   | both Max accounts walled with an outage open | W3 | settle and runbooks still run; leads wait for the first reset; nothing spills |
   | the database is restored from last night's dump | W1 | adopt mode, then no duplicate effect |
   | a lead stops with its Issue open and nothing reported | W1 | the Stop hook sends it back; nobody types `continue` |
   | a scripted attack pattern in CrowdSec | W4 | blocked by the runbook, one line in the briefing |

3. **Six numbers, computed by SQL views the loop cannot edit**, shown on *Now* (a subset of the §9
   scorecard):

   | KPI | SLO, over 14 days |
   |-|-|
   | items that reached you | < 1 % |
   | notifications to you | ≤ 2 a week + the briefing |
   | Issues closed without production evidence | 0 |
   | change failure rate: shipped changes followed by a regression within 7 days | < 5 % |
   | time to resolve, median / p90 | ≤ 0.5 h / ≤ 4 h |
   | green job runs that spent tokens | 0 |

4. **Evidence on every ship** (§4): `ship` is refused without the evidence its change needs, the
   review comes from another model family, and the factory re-runs `make verify` itself after the hold.

v1's open weak spots and where each went are in appendix C.
