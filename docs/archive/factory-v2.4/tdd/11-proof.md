# 11. How we know it works

Neither you nor an agent says the factory works. These do:

1. **The frozen golden set** — 959 labelled events from warden's history (`evidence/golden/`). Every
   dedup rule or threshold change replays it; grouping F1 may not drop below 0.889.
2. **Gamedays** on scratch targets, each tied to an SLO and a wave gate:

   | Gameday | Gate | Pass |
   |-|-|-|
   | the factory is killed mid-spawn and while a lead works | W1a | the lead keeps working; on restart the factory reconciles; no duplicate effect, no lost Issue |
   | a lead stops with its Issue open and nothing reported | W1a | the Stop hook sends it back; nobody types `continue` |
   | a usage wall, injected by faking the usage reading | W1a | Witness marks the lead walled and resumes it at the reset, or on the other account after an hour |
   | the database is restored from last night's dump | W1a | startup reconciliation; ids move past the running panes'; no duplicate effect |
   | a seeded bug passes CI but breaks production | W1b | the lead's production check catches it and fixes forward before `ship`; or the factory's `make verify` after the hold reopens the Issue |
   | a container stops (`glance` on the homelab, which v1's baseline saw and never fixed) | W2 | restarted by the runbook within 5 minutes of its grace window ending; nothing reaches you |
   | the factory is killed mid-runbook | W2 | the runbook runs once to its end after restart |
   | both Max accounts walled with an outage open | W3 | settle and runbooks still run; leads wait for the first reset; nothing spills |
   | a scripted attack pattern in CrowdSec | W4 | blocked by the runbook, one line in the briefing |

3. **Six numbers, computed by SQL views the loop cannot edit**, shown on *Now* and at the top of the
   scorecard (§9):

   | KPI | SLO, over 14 days |
   |-|-|
   | non-business items that reached you | 0; business decision cards are counted and shown |
   | notifications to you | ≤ 2 a week + the briefing |
   | shipped changes whose deployed version lacked the merged commit at close | 0 |
   | change failure rate: shipped changes followed by a regression within 7 days | < 5 % |
   | time to heal an incident, median / p90 | ≤ 0.5 h / ≤ 4 h |
   | green job runs that spent tokens | 0 |

   Requests have no time SLO until the observation period gives a baseline; their times are on the
   scorecard's pipeline row.

4. **Evidence on every ship** (§4): `ship` is refused without the evidence its change needs, the
   review comes from another model family, and the factory re-runs `make verify` itself after the hold.

v1's open weak spots and where each went are in appendix C.
