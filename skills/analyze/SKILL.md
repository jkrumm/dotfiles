---
name: analyze
description: Deep static analysis (dead code, duplication, circular deps, complexity) via fallow in a native subagent
---

# Analyze — Deep Static Analysis

Runs fallow static analysis in a native subagent. Only the findings report returns to main context.

Fallow is a Rust-native project-graph analyzer. It operates at the whole-project dependency graph
level — catching what linters cannot: exports nobody imports across the entire codebase, packages
in package.json that nothing references, circular imports, code duplication, and complexity hotspots.
It replaces knip + jscpd + dependency-cruiser in a single binary.

## IMPORTANT — Subagent Only

Always run in one `Agent` call (`subagent_type: general-purpose`). Never execute fallow inline: the raw
JSON would land in the main context. If the subagent fails, report the error — do not fall back to
inline execution.

## Usage

```
/analyze              # Full analysis — dead code + dupes + health
/analyze dead         # Dead code only (unused exports, deps, circular)
/analyze dupes        # Duplication only
/analyze health       # Complexity hotspots only
/analyze web          # Scope to monorepo workspace named "web"
```

## Execution

One `Agent` call (`subagent_type: general-purpose`, description `fallow analysis`) whose prompt is the
block below, with `[SCOPE]` replaced by the user's argument. The subagent runs on the pinned
subagent model; do not set `model`.

````text
Run fallow static analysis in the current directory.

## Fallow CLI Reference

```
fallow                            # All analyses (dead-code + dupes + health)
fallow dead-code                  # Unused exports/files/deps + circular deps (alias: fallow check)
fallow dupes                      # Code duplication detection
fallow health                     # Complexity hotspots + maintainability scores

Key flags:
  --format json                   # Machine-readable output (use this)
  --format compact                # Terse one-line-per-issue output
  --workspace <name>              # Scope to one monorepo package (matches package.json "name")
  --changed-since <ref>           # Only files changed since git ref (e.g. main, HEAD~1)
  --production                    # Exclude test/story/dev files
  --summary                       # Print one-line issue count, then exit
  --only check,dupes,health       # Run specific analyses when using bare fallow
```

JSON output shape:
```json
{
  "issues": [{ "type": "...", "file": "...", "symbol": "...", "severity": "error|warn", "message": "..." }],
  "summary": { "total": 0, "errors": 0, "warnings": 0 }
}
```

Issue types: unused-file, unused-export, unused-type, unused-dep, unresolved-import,
             circular-dep, duplicate, complexity-hotspot

## Analysis Steps

First check if .fallowrc.json exists in the project root — it configures entry points and
ignore patterns. If present, fallow uses it automatically.

Run analyses based on SCOPE argument:
- SCOPE empty or "all": run all three analyses
- SCOPE is "dead": run dead code only
- SCOPE is "dupes": run duplication only
- SCOPE is "health": run complexity only
- SCOPE is a package name (e.g. "web", "api"): run all with --workspace <SCOPE>

Commands to run (`fallow` is installed globally by dotfiles `make setup`, pinned to `FALLOW_VERSION`; `which fallow` must succeed — do not fall back to `npx`):

```bash
# Full analysis
fallow --format json 2>/dev/null

# OR individual analyses for targeted reporting
fallow dead-code --format json 2>/dev/null
fallow dupes --format json 2>/dev/null
fallow health --format json 2>/dev/null

# Scoped to workspace
fallow dead-code --workspace web --format json 2>/dev/null

# Changed files only (useful during active development)
fallow dead-code --changed-since main --format json 2>/dev/null
```

Parse each JSON result. If fallow reports no .fallowrc.json and is unable to detect entry
points, note this in the report and suggest running `fallow init`.

## Output Format (under 2000 chars)

## Static Analysis Report

**Dead code (fallow dead-code):**
- [N] unused exports: [top files with counts]
- [N] unused files: [list]
- [N] unused deps: [package names]
- [N] circular deps: [shortest cycles]

**Duplication (fallow dupes):**
- [N] clones found ([X]% duplication)
- Largest: [file1]:[lines] ↔ [file2]:[lines]

**Complexity (fallow health):**
- [N] hotspots above threshold: [file:function (score)]

**Recommendations:**
1. [Highest impact action]
2. [Second action]
3. [Third action]

Prioritize actionable findings. Skip sections with zero issues. If all clean, say so.

SCOPE: [SCOPE]
````
