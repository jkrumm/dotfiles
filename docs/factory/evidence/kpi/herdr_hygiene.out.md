# herdr_hygiene

AS_OF `2026-10-22T08:00:00Z` (nominal). Measured live at `2026-10-22T08:22:37Z`. Definition key `herdr_hygiene`. Script `herdr_hygiene.py`.

**A Phase 0 janitor wave (rd reap, herdr event recorder) is running while the baseline is taken and may close finished tabs or kill claude --bg leftovers. Treat these numbers as the state at measured_at, not as a stable baseline; compare against the next run, not against AS_OF.**

Live measurement; herdr keeps no history, so as_of itself cannot be reconstructed.

## Counts

|what|count|
|-|-|
|workspaces (repo workspaces)|29|
|separator workspaces|7|
|tabs|49|
|panes|50|
|agents|24|
|finished-but-open tabs (done + idle)|16 (11 done, 5 idle)|
|of those older than 24 h (known age)|3 of 16 with a known age|
|finished tabs with unknown age|0|
|`claude --bg` leftovers|2 (blocked: 2)|

Tabs by status: done 11, idle 5, unknown 25, working 8.
Agents by status: done 11, idle 5, working 8.
Workspaces by status: done 9, idle 1, unknown 15, working 4.

Workspace labels that appear more than once: hermes-agent (2), homelab-private (2).

## Workspaces by sidebar group

|group|workspaces|tabs|
|-|-|-|
|APPS|4|9|
|HERD|1|1|
|INFRA|3|3|
|OTHER|3|5|
|PERSONAL|2|3|
|TOOLING|13|17|
|WORK|3|4|

## Finished-but-open tabs

no: the herdr API returns sequence counters, not timestamps; age_hours is the time since the last entry in the agent's Claude transcript.

Age buckets: 1-3d 1, 1-6h 2, 6-24h 1, <1h 10, >3d 2.

|workspace|tab|status|repo|age (h)|events since state change|
|-|-|-|-|-|-|
|sy-serendipity|1|idle|sy-serendipity|192.9|7010|
|dotfiles|1|idle|dotfiles|88.7|1862|
|prometheus-scripts|<label withheld>|idle|prometheus-scripts|39.1|446|
|SourceRoot|1|idle|-|21.3|403|
|basalt-ui|fan w44-fixtures|done|basalt-ui|2.8|67|
|homelab-private|1|done|homelab-private|1.1|49|
|rb|1|done|rb|0.9|39|
|homelab|1|done|homelab|0.9|35|
|basalt-ui|fan w44-seam|done|basalt-ui|0.7|32|
|SourceRoot|2|idle|-|0.6|28|
|weatherorb|orchestrator|done|weatherorb|0.4|21|
|hermes-agent|1|done|hermes-agent|0.3|11|
|epos.student-enrolment|1|done|epos.student-enrolment|0.3|12|
|basalt-ui|mother|done|basalt-ui|0.3|7|
|agent-gateway|wave 12|done|agent-gateway|0.1|5|
|prometheus-scripts|2|done|prometheus-scripts|0.1|0|

## claude --bg leftovers

Source: claude agents --json (kind = background). Older than 24 h: 2.

|id|repo|state|started|age (h)|last activity (h ago)|
|-|-|-|-|-|-|
|4eca7240|research-gateway|blocked|2026-09-22T23:32:10Z|704.8|704.6|
|7d5572c0|weatherorb|blocked|2026-10-06T06:15:02Z|386.1|386.1|

## rd agents cross-check

Rows 26 by lane {'bg': 2, 'herdr': 24}; herdr lane rows 24 vs `herdr agent list` 24; bg rows 2 vs claude background agents 2; consistent: True.

## Notes

- Tabs with agent_status `unknown` hold a plain shell or an agent herdr does not detect; they are not counted as finished.
- Separator workspaces (labels starting with a rule) only group the sidebar and are excluded from repo_workspaces.
- age_hours is the time since the agent's last transcript entry; a later resume or a janitor message writes a new entry and makes the tab look younger.
- Terminal titles are free text and are not written to this file.
