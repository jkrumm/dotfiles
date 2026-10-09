# herdr — sidebar groups

**Sidebar groups** — herdr has no folder and no separator primitive, so
`config/herdr/groups.json` declares the taxonomy and `make herdr-groups` makes
each header a **workspace** whose label is the rule (`── TOOLING ─────`),
ordered above its members via the socket API's `workspace.move_block`. A
metadata token in its own sidebar row was tried first and lost: herdr indents
rows 2+ of an entry, so any two-row entry pushes its own name out of line —
`scripts/herdr-groups.py` carries the full comparison. Nothing re-applies this
and nothing has to; both halves are workspace state, which `session.json`
persists. A separator costs an idle shell and a slot in the workspace picker,
and stays invisible to agent-gateway's overview (agent-driven; `workspace list` is
only an id→label map there). `make herdr-groups-check` prints the plan,
`herdr-groups.py clear` is the undo. Adding a repo is one line in the JSON; an
unopened space is skipped, so listing one early costs nothing.
