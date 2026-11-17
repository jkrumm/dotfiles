# skills

**Adding a global skill:** `skills/{name}/SKILL.md` → `make setup`. **Per-repo
skill:** `.claude/skills/{name}/SKILL.md`, committed, no symlink. **Global rule:**
`rules/{name}.md` — the whole dir is symlinked; no `paths:` means always-on.

## archify (vendored, patched)

`skills/archify` is upstream `tt-a1i/archify` (stable channel; the commit is in `.upstream-ref`, the version in `skill-release.json`), trimmed of the pre-rendered example HTML and the lockfile. **It carries one local patch, `config/archify/basalt.patch`**: the `basalt` visual preset (enum in `schemas/common.schema.json` and `workflow.schema.json`, a `[data-preset="basalt"]` block in `assets/template.html` mapping the diagram variables onto basalt-ui's `--basalt-*` tokens, and `assets/basalt-tokens.css` inlined by the renderer when the preset is basalt, so a standalone export resolves them). The patch also shortens the `SKILL.md` description to the 600-character budget (`make context-load-check`). `generated-validators.mjs` is rebuilt, not patched.

Never edit the skill in place without saving the patch. Everything goes through `scripts/archify-vendor.sh`:

- Upstream bump: `make archify-update` (stable manifest) or `ARCHIFY_REF=v3.3.0 make archify-update`. It replaces the tree, re-applies the patch and exits 1 naming what failed if the patch no longer applies. Then redo the change by hand in `skills/archify`, run `make archify-patch-save`, and `make archify-test`.
- A change to the preset: edit the skill, `make archify-patch-save`. `make archify-test` (part of `make check`) fails when the tree and the patch differ, or when a basalt architecture or workflow stops rendering.
- `assets/basalt-tokens.css` is a copy of basalt-ui's `src/css/tokens.css` (3.0.0, unreleased when copied). Refresh it from the installed `basalt-ui/tokens.css` and re-save the patch. The `[data-preset="basalt"]` block is hand-mapped: replace it with the block from basalt-ui's generated `archify.css` once that ships.
- An inline SVG on a page that already loads the tokens needs only `data-preset="basalt"` on the SVG or a wrapper.
